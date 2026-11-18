data "google_project" "current" {}

# @@@@@@ 1. BACKEND VM SERVICE ACCOUNT (LEAST PRIVILEGE) @@@@@@@@
resource "google_service_account" "backend_sa" {
  account_id   = "sa-abe-backend"
  display_name = "ABE Backend VM Service Account"
}

# @@@@@@@@ Grant storage access ONLY on the media bucket (not tfstate or web bucket) @@@@@@@
resource "google_storage_bucket_iam_member" "backend_media_access" {
  bucket = google_storage_bucket.media_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backend_sa.email}"
}

# @@@@@@ Allow Backend VM to self-sign GCS v4 Signed URLs without JSON key files @@@@@@@@
resource "google_service_account_iam_member" "backend_token_creator" {
  service_account_id = google_service_account.backend_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.backend_sa.email}"
}

resource "google_project_iam_member" "backend_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

resource "google_project_iam_member" "backend_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

resource "google_project_iam_member" "backend_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

resource "google_project_iam_member" "backend_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

# @@@@@@ 2. SECRET MANAGER SHELLS @@@@@@@
resource "google_secret_manager_secret" "app_secrets" {
  for_each = toset([
    "abe-vip-passcode",
    "abe-runpod-api-key",
    "abe-runpod-endpoint-id",
    "abe-webhook-secret",
    "abe-db-password"
  ])

  secret_id = each.value

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "backend_secret_access" {
  for_each  = google_secret_manager_secret.app_secrets
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.backend_sa.email}"
}

# @@@@@@@ 3. WORKLOAD IDENTITY FEDERATION (GITHUB ACTIONS) @@@@@@@@@@@@@
resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions Pool"
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc-provider"
  display_name                       = "GitHub OIDC Provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository == 'ABESYH/abe-porto-engine'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "cicd_sa" {
  account_id   = "sa-abe-github-cicd"
  display_name = "ABE GitHub Actions CI/CD"
}

resource "google_service_account_iam_member" "github_wif_binding" {
  service_account_id = google_service_account.cicd_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github_pool.workload_identity_pool_id}/attribute.repository/ABESYH/abe-porto-engine"
}

resource "google_project_iam_member" "cicd_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

resource "google_storage_bucket_iam_member" "cicd_web_access" {
  bucket = google_storage_bucket.web_bucket.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cicd_sa.email}"
}

resource "google_project_iam_member" "cicd_compute_admin" {
  project = var.project_id
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

resource "google_project_iam_member" "cicd_iap_user" {
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

resource "google_project_iam_member" "cicd_sa_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

# Allow CI/CD to run read-only `terraform plan` against live state on Pull Requests
resource "google_project_iam_member" "cicd_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

resource "google_project_iam_member" "cicd_security_reviewer" {
  project = var.project_id
  role    = "roles/iam.securityReviewer"
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}

resource "google_storage_bucket_iam_member" "cicd_tfstate_access" {
  bucket = "abe-porto-tfstate-501516"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cicd_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "cicd_db_secret_read" {
  secret_id = google_secret_manager_secret.app_secrets["abe-db-password"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cicd_sa.email}"
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github_provider.name
}

output "cicd_service_account_email" {
  value = google_service_account.cicd_sa.email
}