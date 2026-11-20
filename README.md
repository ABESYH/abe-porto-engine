# ABE PORTO — Cloud & AI Video Infrastructure Engine

[![CI Quality Gate](https://github.com/ABESYH/abe-porto-engine/actions/workflows/ci.yml/badge.svg)](https://github.com/ABESYH/abe-porto-engine/actions/workflows/ci.yml)
[![CD Production Deploy](https://github.com/ABESYH/abe-porto-engine/actions/workflows/deploy.yml/badge.svg)](https://github.com/ABESYH/abe-porto-engine/actions/workflows/deploy.yml)
[![GCP Region](https://img.shields.io/badge/GCP%20Region-asia--southeast2%20(Jakarta)-blue)](https://cloud.google.com/about/locations/jakarta)
[![Terraform](https://img.shields.io/badge/IaC-Terraform%20v1.9.8-623CE4)](https://www.terraform.io/)
[![Security](https://img.shields.io/badge/Auth-Workload%20Identity%20Federation%20(Keyless)-success)](https://cloud.google.com/iam/docs/workload-identity-federation)

An interactive, enterprise-grade cloud architecture powering asynchronous AI video synthesis workloads. Built and operated independently by **Abe (Abrar Syah Putra)**, translating 3.5+ years of production SaaS builder experience into modern Cloud & DevOps engineering.

> **Live System:** [https://abeporto.my.id](https://abeporto.my.id) *(Experience live cloud engineering)*  
> **Read-Only Telemetry:** [https://abeporto.my.id/grafana/](https://abeporto.my.id/grafana/) *(Real-time Prometheus Metrics & Loki Logs)*

---

## 🏛️ End-to-End System Architecture

```text
[ Cloudflare DNS & DDoS Protection (Full Strict SSL) ]
                        │
                        ▼ (HTTPS Port 443)
[ GCP Global External Application Load Balancer ] ──(Google-Managed SSL)
       │                                │
       ├─► Path: "/"                    ├─► Path: "/grafana/*"
       │   └── [ GCS Static Web Bucket ]│   └── [ Ops VM: 10.10.1.10:3000 ]
       │       (index.html & assets)    │       (Prometheus, Loki, Grafana)
       │                                │
       └─► Path: "/api/*" ──────────────┘
               │
               ▼
======================= PRIVATE SUBNET (10.10.1.0/24) =======================
  ┌───────────────────────────────────────────────────────────────────────┐
  │  Regional Managed Instance Group (MIG: 2 VMs in Zone A & Zone B)      │
  │  [ abe-app-vm-1 (10.10.1.x) ]      [ abe-app-vm-2 (10.10.1.y) ]       │
  │  ├── Engine: Docker (FastAPI)       ├── Engine: Docker (FastAPI)      │
  │  ├── Exporter: Node Exporter        ├── Exporter: Node Exporter       │
  │  └── Collector: Fluent Bit          └── Collector: Fluent Bit         │
  └──────────────────┬─────────────────────────────────┬──────────────────┘
                     │                                 │
                     ▼ (Private IP Peering)            ▼ (Cloud NAT Egress)
            [ Cloud SQL Postgres 15 ]          [ Serverless GPU Worker ]
               (Private: 172.29.0.3)              (Decoupled Inference)
                     ▲                                 │ (Direct Signed PUT)
                     │                                 ▼
         [ Daily pg_dump Cron ] ────────────► [ Private GCS Media Bucket ]
         (Lifecycle: 14-day retention)        (Lifecycle: 7-day retention)
=============================================================================
```

---

## 💡 Key Architectural Decisions & Engineering Trade-Offs

### 1. Multi-Zone High Availability & Auto-Healing (MIG)

- **The "Why":** A single VM presents a single point of failure (SPOF). Instead of manual VM creation, backend services run inside a **Regional Managed Instance Group (MIG)** distributed across `asia-southeast2-a` and `asia-southeast2-b`.
- **Zero-Downtime Surge Replacement:** Deployments enforce `--max-surge=2 --max-unavailable=0`, creating healthy replacement instances before terminating older nodes.
- **Auto-Healing:** If an instance fails the `/api/health` check 3 consecutive times, GCP automatically recreates the unhealthy node without operator intervention.

### 2. Defense-in-Depth & Zero Public IPs (VPC & IAP)

- **Private Isolation:** Backend compute and Cloud SQL database have **0 public IP addresses**.
- **Cloud NAT Egress:** Outbound external API calls (e.g. GPU orchestration) route strictly through Cloud NAT (`abe-nat`), preventing ingress attacks.
- **Keyless SSH Access:** Operator access is restricted exclusively to **Google Cloud Identity-Aware Proxy (IAP) Tunneling** on port 22 (`35.235.240.0/20`), eliminating exposed bastion hosts.

### 3. Asynchronous Anti-Timeout Pattern & Presigned URLs

- **Async Job Queuing:** Long-running generative AI tasks cannot be awaited synchronously over HTTP without triggering `504 Gateway Timeout`. The API records transient state in **Redis**, persists metadata in **Cloud SQL**, dispatches the job to the GPU worker, and returns in `< 1s` with a `job_id`.
- **Direct-to-Storage Streaming:** The backend generates short-lived **GCS v4 Presigned URLs**. GPU workers upload multi-megabyte `.mp4` payloads directly to Cloud Storage, protecting backend VM RAM and egress bandwidth.

### 4. Enterprise Identity & Keyless CI/CD (Workload Identity Federation)

- **Zero Long-Lived Service Account Keys:** No `service-account-key.json` exists in local workstations or GitHub Secrets.
- **OIDC Authentication:** GitHub Actions requests short-lived Google Cloud STS tokens via **Workload Identity Federation (WIF)**, scoped strictly to repository `ABESYH/abe-porto-engine`.

### 5. FinOps & Cost Governance

- **Decoupled Compute:** General API traffic runs 24/7 on cost-efficient `e2-small` instances, while costly GPU resources scale to zero (`min_workers=0`).
- **GPU Access Passcode Guard:** Public portfolio visitors test the pipeline in free simulation mode, protecting GPU credits from bot drainage.
- **Storage Lifecycle Policies:** Automated rules delete demo media artifacts older than 7 days and DB dumps older than 14 days.
- **Billing Budget Alerts:** Automated budget thresholds (`50%, 80%, 100%`) trigger immediate admin alerts.

---

## 📁 Repository Structure

```text
├── .github/workflows/
│   ├── ci.yml                 # PR Quality Gate: Pytest Unit Tests + Dry-Run Terraform Plan
│   ├── deploy.yml             # CD Pipeline: Buildx, Semantic Versioning, GCS Sync & MIG Surge Replace
│   └── rollback.yml           # Emergency Rollback: Instant tag repoint & zero-downtime rollback
├── terraform/
│   ├── providers.tf           # HashiCorp GCP Provider & GCS Remote State Backend
│   ├── variables.tf           # Configurable variables (Project ID, Region: asia-southeast2)
│   ├── network.tf             # Custom VPC, Private Subnet, Cloud Router, Cloud NAT & Firewalls
│   ├── storage.tf             # Private Media Bucket, Public Web Bucket & Artifact Registry
│   ├── iam.tf                 # Least-Privilege SAs, Secret Manager shells & WIF Pool/Provider
│   ├── database.tf            # Private IP Cloud SQL PostgreSQL 15 & Automated Backups
│   ├── compute.tf             # Ops VM (Observability/Backup), MIG Instance Template & Health Checks
│   └── load_balancer.tf       # Global HTTP(S) Load Balancer, Managed SSL & Path URL Routing
├── backend/
│   ├── main.py                # FastAPI Engine: /health, /metrics, rate-limiting & structured JSON logging
│   ├── Dockerfile             # Multi-stage container definition with non-root security user
│   ├── requirements.txt       # Pinned dependencies
│   └── test_main.py           # Pytest suite validating endpoints, auth & webhook guards
├── frontend/
│   ├── index.html             # High-performance glassmorphic SPA (9:16 layout, trilingual ID/EN/ZH)
│   ├── nginx.conf             # Local reverse proxy definition
│   └── assets/                # Permanent project logos & profile assets
├── monitoring/
│   ├── prometheus.yml         # Prometheus scrape configuration
│   ├── fluent-bit.conf        # Fluent Bit container log parser shipping to Loki
│   ├── grafana-dashboards.yml # Grafana auto-provisioning dashboard provider
│   ├── grafana-datasources.yml# Grafana Prometheus & Loki datasource definitions
│   └── dashboards/            # Pre-baked JSON dashboard (Metrics, Latency, & Correlated Logs)
├── ai-engine/                 # Sanitized 2-layer Docker & Self-Hosted Runner build reference archive
├── scripts/
│   └── backup-db.sh           # Automated PostgreSQL pg_dump cron script shipping to GCS
└── docs/
    └── billing-budget-alert.png # Verified proof of GCP Billing Budget Alert configuration
```

---

## 🚀 CI/CD & Delivery Lifecycle (GitHub Flow)

1. **Feature Branch:** 
   - Developer creates a new feature branch from `main` (`feat/feature-name`).

2. **Quality Gate (CI):** 
   - Pull Request triggers `.github/workflows/ci.yml`:
     - Automated unit test suite via `pytest`.
     - Syntax formatting check via `terraform fmt -check`.
     - Infrastructure plan validation via `terraform plan -no-color` against live GCS state.

3. **Automated Promotion (CD):** 
   - Merging into `main` triggers `.github/workflows/deploy.yml`:
     - Docker image build tagged with Git Commit SHA and Semantic Version (`v1.0.X`).
     - Push to GCP Artifact Registry (`asia-southeast2-docker.pkg.dev`).
     - Frontend static assets synced to `gs://abe-porto-web-501516`.
     - Zero-downtime rolling surge replacement triggered on `abe-app-mig`.
     - Automated Git Tag created and pushed by `github-actions[bot]`.

4. **Disaster Recovery:** 
   - `.github/workflows/rollback.yml` allows instant manual rollback to any prior release tag via `workflow_dispatch`.

---

## 👨‍💻 Author & Contact

**ABE**  
*Cloud & DevOps Engineer • SaaS Builder*

- **Portfolio:** [https://abeporto.my.id](https://abeporto.my.id)
- **LinkedIn:** [https://linkedin.com/in/aabbee](https://linkedin.com/in/aabbee)
- **GitHub:** [https://github.com/ABESYH](https://github.com/ABESYH)
- **Email:** [sr.abesyh@gmail.com](mailto:sr.abesyh@gmail.com)