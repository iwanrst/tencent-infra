###############################################################################
# ACME -- staging
#
# Onboarding a new client: copy envs/ to a new directory (or point a new
# workspace at it), then change client, region, vpc_cidr, admin_cidrs and the
# backend bucket. Everything else can usually stay as it is.
###############################################################################

client      = "acme"
environment = "staging"
region      = "ap-singapore"

extra_tags = {
  CostCenter = "platform"
  Owner      = "platform-team"
}

# --- Topology ---------------------------------------------------------------
# Two AZs is enough for staging. Pin them explicitly so subnets never move.
availability_zones = ["ap-singapore-1", "ap-singapore-2"]

# Keep every environment of every client on a distinct range so they stay
# peerable later. Convention used here: 10.<client>.<env>.0/16
#   acme staging 10.10.0.0/16   acme prod 10.20.0.0/16
vpc_cidr = "10.10.0.0/16"

tiers = {
  public = { cidr_block = "10.10.0.0/20", az_newbits = 2, public = true }
  app    = { cidr_block = "10.10.16.0/20", az_newbits = 2 }
  data   = { cidr_block = "10.10.32.0/20", az_newbits = 2, nat_egress = false }
  eni    = { cidr_block = "10.10.64.0/18", az_newbits = 2 }
}

# --- Cost posture -----------------------------------------------------------
# One NAT gateway shared across AZs. A zone outage takes staging egress with
# it, which is an acceptable trade at roughly a third of the cost.
nat_gateway_mode      = "single"
nat_gateway_bandwidth = 100

enable_flow_logs    = false
enable_network_acls = false
log_retention_days  = 14

# --- Access control ---------------------------------------------------------
# Replace with the client's real office / VPN ranges before the first apply.
admin_cidrs = [
  "203.0.113.0/24", # HQ office
  "198.51.100.7/32" # CI runner egress
]

public_ingress_cidrs = ["0.0.0.0/0"]
public_ingress_ports = ["80", "443"]

restrict_egress = false

# --- TKE --------------------------------------------------------------------
kubernetes_version = "1.30.0"
tke_network_type   = "VPC-CNI"
tke_service_cidr   = "172.20.0.0/18"
tke_cluster_level  = "L5"

# Public API endpoint is on in staging so developers can reach it without the
# VPN -- but only from admin_cidrs, enforced by both a security group and the
# TKE allowlist.
tke_enable_public_endpoint = true

node_pools = {
  system = {
    instance_types = ["S5.MEDIUM4", "SA3.MEDIUM4"]
    min_size       = 1
    max_size       = 3
    desired_size   = 1
    data_disk_size = 100
    labels         = { "workload-class" = "system" }
    taints = [{
      key    = "dedicated"
      value  = "system"
      effect = "PreferNoSchedule"
    }]
  }

  general = {
    instance_types = ["S5.LARGE8", "SA3.LARGE8"]
    min_size       = 1
    max_size       = 6
    desired_size   = 2
    data_disk_size = 100
    labels         = { "workload-class" = "general" }
  }

  # Spot capacity for CI and batch. Tainted so only tolerant workloads land here.
  spot = {
    instance_types = ["S5.LARGE8", "SA3.LARGE8", "S5.2XLARGE16"]
    min_size       = 0
    max_size       = 10
    desired_size   = 0
    data_disk_size = 100
    spot           = true
    labels         = { "workload-class" = "spot" }
    taints = [{
      key    = "spot"
      value  = "true"
      effect = "NoSchedule"
    }]
  }
}

# Populate with the client's CVM key pair IDs, or leave empty to disable SSH.
node_ssh_key_ids = []

tke_addons = {
  cbs = {}
}
