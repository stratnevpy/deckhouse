data "google_compute_zones" "available" {}

data "google_compute_address" "reserved" {
  for_each = toset(local.cloud_nat_addresses)
  name     = each.value
}

resource "google_compute_network" "kube" {
  name                      = local.prefix
  auto_create_subnetworks   = false
  remove_routes_on_deletion = true
}

resource "google_compute_subnetwork" "kube" {
  name          = local.prefix
  network       = google_compute_network.kube.self_link
  ip_cidr_range = local.subnetwork_cidr
}

resource "google_compute_router" "kube" {
  count   = var.providerClusterConfiguration.layout == "Standard" ? 1 : 0
  name    = local.prefix
  network = google_compute_network.kube.self_link
}

resource "google_compute_router_nat" "kube" {
  count                              = var.providerClusterConfiguration.layout == "Standard" ? 1 : 0
  name                               = local.prefix
  router                             = join("", google_compute_router.kube.*.name)
  nat_ip_allocate_option             = length(local.cloud_nat_addresses) > 0 ? "MANUAL_ONLY" : "AUTO_ONLY"
  nat_ips                            = length(local.cloud_nat_addresses) > 0 ? [for v in data.google_compute_address.reserved : v.self_link] : null
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  min_ports_per_vm                   = 1024
  subnetwork {
    name                    = google_compute_subnetwork.kube.self_link
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

module "firewall" {
  source            = "../../../terraform-modules/firewall"
  prefix            = local.prefix
  network_self_link = google_compute_network.kube.self_link
  pod_subnet_cidr   = local.pod_subnet_cidr
}

locals {
  peered_vpcs = local.peered_vpcs_names
}

# network peering
data "google_compute_network" "other" {
  count = length(local.peered_vpcs)
  name  = local.peered_vpcs[count.index]
}

resource "google_compute_network_peering" "kube-with-other" {
  count        = length(local.peered_vpcs)
  name         = join("-with-", [local.prefix, local.peered_vpcs[count.index]])
  network      = google_compute_network.kube.self_link
  peer_network = data.google_compute_network.other[count.index].self_link
}

resource "google_compute_network_peering" "other-with-kube" {
  count        = length(local.peered_vpcs)
  name         = join("-with-", [local.peered_vpcs[count.index], local.prefix])
  network      = data.google_compute_network.other[count.index].self_link
  peer_network = google_compute_network.kube.self_link
}
