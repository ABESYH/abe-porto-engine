# @@@@@@ Custom Mode VPC @@@@@@@
resource "google_compute_network" "vpc" {
  name                    = "abe-vpc"
  auto_create_subnetworks = false
}

# @@@@@@@@@@@ Private Subnet in Jakarta (asia-southeast2) @@@@@@@@@@
resource "google_compute_subnetwork" "private_subnet" {
  name                     = "abe-private-subnet"
  ip_cidr_range            = "10.10.1.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# @@@@@@@@@ Cloud Router & Cloud NAT for outbound internet access from Private VMs @@@@@@@@@@
resource "google_compute_router" "router" {
  name    = "abe-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "abe-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# @@@@@@@ Allow GCP Load Balancer & Health Check Probes to reach backend services @@@@@@@@@@@@
resource "google_compute_firewall" "allow_lb_hc" {
  name    = "abe-allow-lb-and-hc"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["80", "8000", "3000"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["abe-backend"]
}

# @@@@@@@@@@ Allow SSH strictly through Google Cloud IAP Tunnel @@@@@@@@@@@@@@@
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "abe-allow-iap-ssh"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["abe-backend"]
}

# @@@@@@@@@@ Allow internal communication between VMs inside the Private Subnet @@@@@@@@@@@@@@@@@@
resource "google_compute_firewall" "allow_internal" {
  name    = "abe-allow-internal"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  source_ranges = ["10.10.1.0/24"]
}