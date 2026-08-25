###############################################################################
# ACME -- production
#
# The code here is byte-identical to staging; only these values differ.
###############################################################################

client      = "acme"
environment = "prod"
region      = "ap-singapore"

extra_tags = {
  CostCenter  = "platform"
  Owner       = "platform-team"
  Criticality = "tier-1"
  Compliance  = "iso27001"
}

# --- Topology ---------------------------------------------------------------
# Three AZs. Pinned, because auto-selection shifting would move subnets.
availability_zones = ["ap-singapore-1", "ap-singapore-2", "ap-singapore-3"]

vpc_cidr = "10.20.0.0/16"

tiers = {
  public = { cidr_block = "10.20.0.0/20", az_newbits = 2, public = true }
  app    = { cidr_block = "10.20.16.0/20", az_newbits = 2 }
  data   = { cidr_block = "10.20.32.0/20", az_newbits = 2, nat_egress = false }
  eni    = { cidr_block = "10.20.64.0/18", az_newbits = 2 }
}

# --- Resilience posture -----------------------------------------------------
# One NAT gateway per AZ: a zone failure cannot take out egress cluster-wide,
# and cross-AZ NAT traffic charges disappear.
nat_gateway_mode      = "per_az"
nat_gateway_bandwidth = 500

enable_flow_logs    = true
enable_network_acls = true
log_retention_days  = 90

# --- Access control ---------------------------------------------------------
admin_cidrs = [
  "203.0.113.0/24", # HQ office
  "198.51.100.7/32" # CI runner egress
]

public_ingress_cidrs = ["0.0.0.0/0"]
public_ingress_ports = ["80", "443"]

# Workloads may only egress to the VPC plus DNS and HTTPS. Turn this on once
# the outbound dependencies are known -- it will break anything that talks to
# the internet on another port.
restrict_egress = true

# --- TKE --------------------------------------------------------------------
kubernetes_version = "1.30.0"
tke_network_type   = "VPC-CNI"
tke_service_cidr   = "172.21.0.0/18"
tke_cluster_level  = "L50"

# No public API server. Operators reach the cluster over VPN / CCN / bastion.
tke_enable_public_endpoint = false

node_pools = {
  system = {
    instance_types   = ["S5.LARGE8", "SA3.LARGE8"]
    min_size         = 3
    max_size         = 6
    desired_size     = 3
    system_disk_size = 100
    data_disk_size   = 200
    labels           = { "workload-class" = "system" }
    taints = [{
      key    = "dedicated"
      value  = "system"
      effect = "PreferNoSchedule"
    }]
  }

  general = {
    instance_types   = ["S5.2XLARGE16", "SA3.2XLARGE16", "S5.4XLARGE32"]
    min_size         = 3
    max_size         = 30
    desired_size     = 6
    system_disk_size = 100
    data_disk_size   = 400
    labels           = { "workload-class" = "general" }
  }
}

node_ssh_key_ids = []

tke_addons = {
  cbs = {}
}
