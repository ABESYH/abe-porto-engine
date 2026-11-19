# Reserve Static External IP for the Cloud Load Balancer
resource "google_compute_global_address" "lb_ip" {
  name = "abe-lb-static-ip"
}

# Dedicated Least-Privilege Service Account for Ops/Monitoring VM
resource "google_service_account" "ops_sa" {
  account_id   = "sa-abe-ops"
  display_name = "ABE Ops & Monitoring VM Service Account"
}

resource "google_project_iam_member" "ops_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.ops_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "ops_db_secret" {
  secret_id = google_secret_manager_secret.app_secrets["abe-db-password"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ops_sa.email}"
}

resource "google_storage_bucket_iam_member" "ops_backup_access" {
  bucket = google_storage_bucket.media_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ops_sa.email}"
}

# Daily Persistent Disk Snapshot Schedule (ACE Exam 3.1)
resource "google_compute_resource_policy" "daily_snapshot" {
  name   = "abe-daily-snapshot-policy"
  region = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "03:00"
      }
    }
    retention_policy {
      max_retention_days    = 7
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
  }
}

# ================= 1. OPS & MONITORING VM =================
resource "google_compute_instance" "ops_vm" {
  name         = "abe-ops-vm"
  machine_type = "e2-small"
  zone         = "${var.region}-a"
  tags         = ["abe-backend"]

  boot_disk {
    initialize_params {
      image             = "ubuntu-os-cloud/ubuntu-2204-lts"
      size              = 20
      resource_policies = [google_compute_resource_policy.daily_snapshot.id]
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private_subnet.id
    network_ip = "10.10.1.10"
  }

  service_account {
    email  = google_service_account.ops_sa.email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    set -e
    export HOME=/root
    export PATH=$PATH:/snap/bin

    apt-get update
    apt-get install -y docker.io git postgresql-client
    systemctl enable --now docker

    mkdir -p /opt/abe-porto
    git clone https://github.com/ABESYH/abe-porto-engine.git /opt/abe-porto || (cd /opt/abe-porto && git pull)
    chmod +x /opt/abe-porto/scripts/backup-db.sh

    # Prometheus config using GCE Service Discovery to dynamically scrape MIG App VMs
    cat << 'PROM' > /opt/abe-porto/monitoring/prometheus-gcp.yml
    global:
      scrape_interval: 5s

    scrape_configs:
      - job_name: "abe-backend-mig"
        metrics_path: "/metrics"
        gce_sd_configs:
          - project: "${var.project_id}"
            zone: "${var.region}-a"
            port: 8000
          - project: "${var.project_id}"
            zone: "${var.region}-b"
            port: 8000
        relabel_configs:
          - source_labels: [__meta_gce_instance_name]
            regex: abe-app-.*
            action: keep

      - job_name: "abe-nodes"
        gce_sd_configs:
          - project: "${var.project_id}"
            zone: "${var.region}-a"
            port: 9100
          - project: "${var.project_id}"
            zone: "${var.region}-b"
            port: 9100
        relabel_configs:
          - source_labels: [__meta_gce_instance_name]
            regex: abe-app-.*
            action: keep
    PROM

    docker network create ops-net || true

    docker rm -f redis loki prometheus grafana || true

    docker run -d --name redis --restart always --network ops-net -p 6379:6379 redis:7-alpine
    docker run -d --name loki --restart always --network ops-net -p 3100:3100 grafana/loki:2.9.8 -config.file=/etc/loki/local-config.yaml
    docker run -d --name prometheus --restart always --network ops-net -p 9090:9090 \
      -v /opt/abe-porto/monitoring/prometheus-gcp.yml:/etc/prometheus/prometheus.yml:ro \
      prom/prometheus:v2.54.1

    docker run -d --name grafana --restart always --network ops-net -p 3000:3000 \
      -e GF_SERVER_ROOT_URL="http://${google_compute_global_address.lb_ip.address}/grafana/" \
      -e GF_SERVER_SERVE_FROM_SUB_PATH="true" \
      -e GF_AUTH_ANONYMOUS_ENABLED="true" \
      -e GF_AUTH_ANONYMOUS_ORG_ROLE="Viewer" \
      -e GF_SECURITY_ADMIN_USER="admin" \
      -e GF_SECURITY_ADMIN_PASSWORD="abe_admin_pass" \
      -e GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH="/var/lib/grafana/dashboards/abe-observability.json" \
      -v /opt/abe-porto/monitoring/grafana-datasources.yml:/etc/grafana/provisioning/datasources/datasources.yml:ro \
      -v /opt/abe-porto/monitoring/grafana-dashboards.yml:/etc/grafana/provisioning/dashboards/dashboards.yml:ro \
      -v /opt/abe-porto/monitoring/dashboards:/var/lib/grafana/dashboards:ro \
      grafana/grafana:11.1.0

    # Daily automated pg_dump backup to GCS at 03:00 UTC
    echo "0 3 * * * root /opt/abe-porto/scripts/backup-db.sh ${google_sql_database_instance.postgres.private_ip_address} ${google_storage_bucket.media_bucket.name} >> /var/log/abe-backup.log 2>&1" > /etc/cron.d/abe-db-backup
  EOF

  depends_on = [google_compute_router_nat.nat, google_sql_database_instance.postgres]
}

# ================= 2. APP VMs: INSTANCE TEMPLATE & MANAGED INSTANCE GROUP =================
resource "google_compute_instance_template" "app_template" {
  name_prefix  = "abe-app-tmpl-"
  machine_type = "e2-small"
  tags         = ["abe-backend"]

  disk {
    source_image = "ubuntu-os-cloud/ubuntu-2204-lts"
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private_subnet.id
  }

  service_account {
    email  = google_service_account.backend_sa.email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    set -e
    export HOME=/root
    export PATH=$PATH:/snap/bin

    apt-get update
    apt-get install -y docker.io curl
    systemctl enable --now docker

    # Install GCP Ops Agent for Cloud Logging & Cloud Monitoring (ACE Exam 3.4)
    curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    bash add-google-cloud-ops-agent-repo.sh --also-install || true

    gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet

    DB_PASS=$(gcloud secrets versions access latest --secret="abe-db-password")
    VIP_PASS=$(gcloud secrets versions access latest --secret="abe-vip-passcode")
    GPU_KEY=$(gcloud secrets versions access latest --secret="abe-gpu-api-key")
    GPU_URL=$(gcloud secrets versions access latest --secret="abe-gpu-dispatch-url")
    WH_SECRET=$(gcloud secrets versions access latest --secret="abe-webhook-secret")

    IMAGE="${var.region}-docker.pkg.dev/${var.project_id}/abe-porto-repo/abe-backend:latest"
    docker pull "$IMAGE"

    docker rm -f abe-backend node-exporter fluent-bit || true

    docker run -d --name abe-backend --restart always -p 8000:8000 \
      --hostname "$(hostname)" \
      -e DB_HOST="${google_sql_database_instance.postgres.private_ip_address}" \
      -e DB_NAME="geneta_db" \
      -e DB_USER="geneta_user" \
      -e DB_PASS="$DB_PASS" \
      -e REDIS_HOST="10.10.1.10" \
      -e VIP_PASSCODE="$VIP_PASS" \
      -e GPU_API_KEY="$GPU_KEY" \
      -e GPU_DISPATCH_URL="$GPU_URL" \
      -e GCS_BUCKET_NAME="${google_storage_bucket.media_bucket.name}" \
      -e PUBLIC_BASE_URL="http://${google_compute_global_address.lb_ip.address}" \
      -e WEBHOOK_SECRET="$WH_SECRET" \
      "$IMAGE"

    docker run -d --name node-exporter --restart always --net="host" --pid="host" prom/node-exporter:v1.8.2

    mkdir -p /etc/fluent-bit
    cat << 'FB' > /etc/fluent-bit/fluent-bit.conf
    [SERVICE]
        Flush         2
        Log_Level     info
        Daemon        off
        Parsers_File  parsers.conf

    [INPUT]
        Name              tail
        Tag               docker.*
        Path              /var/lib/docker/containers/*/*-json.log
        Parser            docker
        Refresh_Interval  5
        Mem_Buf_Limit     10MB

    [OUTPUT]
        Name              loki
        Match             docker.*
        Host              10.10.1.10
        Port              3100
        Labels            job=abe-docker, collector=fluent-bit
    FB

    docker run -d --name fluent-bit --restart always \
      -v /etc/fluent-bit/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro \
      -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
      fluent/fluent-bit:3.1
  EOF

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_compute_instance.ops_vm]
}

resource "google_compute_health_check" "app_hc" {
  name                = "abe-app-health-check"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8000
    request_path = "/api/health"
  }
}

resource "google_compute_region_instance_group_manager" "app_mig" {
  name               = "abe-app-mig"
  base_instance_name = "abe-app-vm"
  region             = var.region
  target_size        = 2

  distribution_policy_zones = ["${var.region}-a", "${var.region}-b"]

  version {
    instance_template = google_compute_instance_template.app_template.id
  }

  named_port {
    name = "http-api"
    port = 8000
  }

  named_port {
    name = "http-metrics"
    port = 8000
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.app_hc.id
    initial_delay_sec = 240
  }

  update_policy {
    type                           = "PROACTIVE"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_fixed                = 2
    max_unavailable_fixed          = 0
  }
}

output "load_balancer_static_ip" {
  value = google_compute_global_address.lb_ip.address
}