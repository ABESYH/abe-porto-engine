# @@@@@@ Reserve internal IP range for Cloud SQL Private Service Access @@@@@@
resource "google_compute_global_address" "private_ip_range" {
  name          = "abe-sql-private-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

# @@@@@@@ Establish private VPC peering between abe-vpc and Google-managed Cloud SQL  @@@@@@@
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
}

# @@@@@@@ Read database password securely from Secret Manager @@@@@@@@
data "google_secret_manager_secret_version" "db_password" {
  secret = "abe-db-password"
}

# @@@@@@ Cloud SQL PostgreSQL 15 Instance (Private IP only + Automated Backups) @@@@@@@@
resource "google_sql_database_instance" "postgres" {
  name                = "abe-porto-pg-01"
  database_version    = "POSTGRES_15"
  region              = var.region
  deletion_protection = false

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier = "db-f1-micro"

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      point_in_time_recovery_enabled = true
    }
  }
}

resource "google_sql_database" "app_db" {
  name     = "geneta_db"
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "app_user" {
  name     = "geneta_user"
  instance = google_sql_database_instance.postgres.name
  password = data.google_secret_manager_secret_version.db_password.secret_data
}

output "cloud_sql_private_ip" {
  value = google_sql_database_instance.postgres.private_ip_address
}