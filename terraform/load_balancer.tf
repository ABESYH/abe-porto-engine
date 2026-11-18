# @@@@@@@@@ Backend Bucket for Static Frontend (index.html & assets) @@@@@@@@@@@@
resource "google_compute_backend_bucket" "web_backend" {
  name        = "abe-web-backend-bucket"
  bucket_name = google_storage_bucket.web_bucket.name
  enable_cdn  = false
}

# @@@@@@@@@ Unmanaged Instance Group wrapping Ops VM for Grafana routing @@@@@@@@@
resource "google_compute_instance_group" "ops_group" {
  name      = "abe-ops-group"
  zone      = "${var.region}-a"
  instances = [google_compute_instance.ops_vm.id]

  named_port {
    name = "http-grafana"
    port = 3000
  }
}

resource "google_compute_health_check" "grafana_hc" {
  name                = "abe-grafana-health-check"
  check_interval_sec  = 15
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 3000
    request_path = "/grafana/api/health"
  }
}

# @@@@@@@@@@ Backend Service for Grafana @@@@@@@@@@@@@
resource "google_compute_backend_service" "grafana_backend" {
  name                  = "abe-grafana-backend-service"
  protocol              = "HTTP"
  port_name             = "http-grafana"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.grafana_hc.id]

  backend {
    group = google_compute_instance_group.ops_group.id
  }
}

# @@@@@@@@@@ Backend Service for 2-VM App MIG (High Availability) @@@@@@@@@@@
resource "google_compute_backend_service" "api_backend" {
  name                  = "abe-api-backend-service"
  protocol              = "HTTP"
  port_name             = "http-api"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.app_hc.id]

  backend {
    group = google_compute_region_instance_group_manager.app_mig.instance_group
  }
}

# @@@@@@@ Path-Based URL Routing Map @@@@@@@@@
resource "google_compute_url_map" "url_map" {
  name            = "abe-url-map"
  default_service = google_compute_backend_bucket.web_backend.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "abe-paths"
  }

  path_matcher {
    name            = "abe-paths"
    default_service = google_compute_backend_bucket.web_backend.id

    path_rule {
      paths   = ["/api/*"]
      service = google_compute_backend_service.api_backend.id
    }

    path_rule {
      paths   = ["/grafana", "/grafana/*"]
      service = google_compute_backend_service.grafana_backend.id
    }
  }
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "abe-http-proxy"
  url_map = google_compute_url_map.url_map.id
}

resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  name                  = "abe-http-forwarding-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_proxy.id
  ip_address            = google_compute_global_address.lb_ip.id
}