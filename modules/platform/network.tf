###############################################################################
# Layer 1 -- VPC and subnets
###############################################################################

module "vpc" {
  source = "../vpc"

  name_prefix        = local.name_prefix
  cidr_block         = var.vpc_cidr
  availability_zones = local.availability_zones
  tiers              = var.tiers

  enable_nat_gateway    = true
  nat_gateway_mode      = local.nat_gateway_mode
  nat_gateway_bandwidth = var.nat_gateway_bandwidth

  extra_routes = var.extra_routes

  enable_flow_logs        = local.enable_flow_logs
  flow_log_traffic_type   = "ALL"
  flow_log_retention_days = local.log_retention_days

  tags = local.tags

  depends_on = [terraform_data.az_guard]
}
