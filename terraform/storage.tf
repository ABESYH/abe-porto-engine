# @@@@@@@@@@@ Private bucket for AI inputs, output videos, DB backups, and private workflow JSON @@@@@@@
resource "google_storage_bucket" "media_bucket" {
  name                        = "abe-porto-media-501516"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age            = 7
      matches_prefix = ["inputs/", "outputs/"]
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age            = 14
      matches_prefix = ["backups/"]
    }
    action {
      type = "Delete"
    }
  }
}

# @@@@@@@@@ Static website bucket for public frontend assets (index.html & logos) @@@@@@@@@@@@@@
resource "google_storage_bucket" "web_bucket" {
  name                        = "abe-porto-web-501516"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  website {
    main_page_suffix = "index.html"
    not_found_page   = "index.html"
  }
}

# @@@@ Allow public read ONLY on the frontend static web bucket @@@@@@
resource "google_storage_bucket_iam_member" "web_public_read" {
  bucket = google_storage_bucket.web_bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# @@@@@@@@@ Private Docker Registry for backend container images @@@@@@@@@@@@@@@
resource "google_artifact_registry_repository" "docker_repo" {
  location      = var.region
  repository_id = "abe-porto-repo"
  description   = "Docker repository for ABE PORTO backend"
  format        = "DOCKER"
}