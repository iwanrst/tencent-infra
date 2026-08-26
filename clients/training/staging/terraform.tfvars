###############################################################################
# training -- staging
#
# Everything not listed here comes from modules/platform defaults, which are
# environment-aware: environment = "staging" already selects a single NAT
# gateway, no flow logs, no subnet ACLs, an L5 control plane and 14-day log
# retention. Only override what this client genuinely needs to differ on.
###############################################################################

client      = "training"
environment = "staging"
region      = "ap-singapore"

extra_tags = {
  CostCenter = "training"
  Owner      = "platform-team"
}

# --- Topology ---------------------------------------------------------------
# Two AZs, pinned so subnets can never move underneath us.
availability_zones = ["ap-singapore-1", "ap-singapore-2"]

# 10.10 and 10.20 belong to acme. Every client-environment pair gets a distinct
# /16 so any two of them can be peered later without renumbering.
vpc_cidr = "10.30.0.0/16"

tiers = {
  public = { cidr_block = "10.30.0.0/20", az_newbits = 2, public = true }
  app    = { cidr_block = "10.30.16.0/20", az_newbits = 2 }
  data   = { cidr_block = "10.30.32.0/20", az_newbits = 2, nat_egress = false }
  eni    = { cidr_block = "10.30.64.0/18", az_newbits = 2 }
}

# --- Cost -------------------------------------------------------------------
# The NAT gateway is the only resource here billed by the hour -- roughly
# $95/month in Singapore whether or not any traffic flows. Everything else in
# this stack (VPC, subnets, route tables, security groups) is free.
#
# Off while the address plan is being validated. Turning it on later adds three
# resources -- gateway, EIP, and the 0.0.0.0/0 route -- and replaces nothing,
# because the private route table is created either way.
enable_nat_gateway = false

# --- Access control ---------------------------------------------------------
# These gate SSH to the bastion and, since the public API endpoint is on below,
# access to the Kubernetes API too. Neither exists yet in phase 1.
#
# NOT a static office range: this is the ISP's shared NAT pool, observed
# handing out .9 and .80. It covers 256 addresses we do not control. Replace
# with a real office/VPN range before anything is actually exposed.
admin_cidrs = [
  "103.121.17.0/24", # ISP egress pool
]

public_ingress_cidrs = ["0.0.0.0/0"]
public_ingress_ports = ["80", "443"]

restrict_egress = false

# --- TKE --------------------------------------------------------------------
# PHASE 1: networking only. Builds the VPC, subnets, route tables and the
# security group baseline -- 25 resources, none of them billed.
#
# Flip to true (or delete this line) for phase 2 -- it is purely additive, so
# nothing built below is replaced when the cluster arrives.
enable_tke = false

kubernetes_version = "1.30.0"
tke_network_type   = "VPC-CNI"

# Distinct from acme staging (172.20.0.0/18) so the two clusters stay peerable.
tke_service_cidr = "172.22.0.0/18"

tke_enable_public_endpoint = true

# Deliberately small -- a training environment does not need acme's footprint.
node_pools = {
  general = {
    instance_types = ["S5.MEDIUM4", "SA3.MEDIUM4"]
    min_size       = 1
    max_size       = 3
    desired_size   = 2
    data_disk_size = 100
    labels         = { "workload-class" = "general" }
  }
}

node_ssh_key_ids = []

tke_addons = {
  cbs = {}
}
