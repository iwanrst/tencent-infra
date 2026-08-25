###############################################################################
# This root is intentionally thin: it is the same file in every environment and
# for every client. All variation lives in terraform.tfvars and backend.hcl.
###############################################################################

module "platform" {
  source = "../../../modules/platform"

  # Identity
  client      = var.client
  environment = var.environment
  region      = var.region
  extra_tags  = var.extra_tags

  # Topology
  availability_zones = var.availability_zones
  az_count           = var.az_count
  vpc_cidr           = var.vpc_cidr
  tiers              = var.tiers
  extra_routes       = var.extra_routes

  # Cost / resilience knobs (null = environment default)
  nat_gateway_mode      = var.nat_gateway_mode
  nat_gateway_bandwidth = var.nat_gateway_bandwidth
  enable_flow_logs      = var.enable_flow_logs
  enable_network_acls   = var.enable_network_acls
  log_retention_days    = var.log_retention_days

  # Access control
  admin_cidrs                   = var.admin_cidrs
  public_ingress_cidrs          = var.public_ingress_cidrs
  public_ingress_ports          = var.public_ingress_ports
  data_service_ports            = var.data_service_ports
  enable_bastion_security_group = var.enable_bastion_security_group
  extra_security_groups         = var.extra_security_groups
  restrict_egress               = var.restrict_egress

  # TKE
  enable_tke                 = var.enable_tke
  kubernetes_version         = var.kubernetes_version
  tke_network_type           = var.tke_network_type
  tke_cluster_cidr           = var.tke_cluster_cidr
  tke_service_cidr           = var.tke_service_cidr
  tke_cluster_level          = var.tke_cluster_level
  tke_enable_public_endpoint = var.tke_enable_public_endpoint
  tke_max_pods_per_node      = var.tke_max_pods_per_node
  tke_addons                 = var.tke_addons

  node_pools         = var.node_pools
  node_ssh_key_ids   = var.node_ssh_key_ids
  node_cam_role_name = var.node_cam_role_name
}
