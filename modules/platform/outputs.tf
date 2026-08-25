###############################################################################
# Networking
###############################################################################

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block."
  value       = module.vpc.vpc_cidr_block
}

output "availability_zones" {
  description = "Availability zones in use."
  value       = local.availability_zones
}

output "subnets_by_tier" {
  description = "Subnet IDs grouped by network tier."
  value       = module.vpc.subnets_by_tier
}

output "subnet_cidrs_by_tier" {
  description = "Subnet CIDRs grouped by network tier."
  value       = module.vpc.subnet_cidrs_by_tier
}

output "nat_public_ips" {
  description = "Egress IPs of the VPC. Give these to partners who allowlist source addresses."
  value       = module.vpc.nat_public_ips
}

output "route_table_ids" {
  description = "Route table IDs by class."
  value       = module.vpc.route_table_ids
}

###############################################################################
# Segmentation and access control
###############################################################################

output "network_acl_ids" {
  description = "Network ACL IDs by tier. Empty when ACLs are disabled for this environment."
  value       = module.network_acl.acl_ids
}

output "security_group_ids" {
  description = "Security group IDs by short name (lb, bastion, node, pod, data, tke-api)."
  value       = module.security_groups.security_group_ids
}

###############################################################################
# TKE
###############################################################################

output "cluster_id" {
  description = "TKE cluster ID."
  value       = module.tke.cluster_id
}

output "cluster_name" {
  description = "TKE cluster name."
  value       = module.tke.cluster_name
}

output "cluster_private_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.tke.private_endpoint
}

output "cluster_public_endpoint" {
  description = "Public Kubernetes API endpoint, null when disabled."
  value       = module.tke.public_endpoint
}

output "kube_config" {
  description = "Kubeconfig for the private endpoint."
  value       = module.tke.kube_config
  sensitive   = true
}

output "node_pool_ids" {
  description = "Node pool IDs by name."
  value       = module.tke.node_pool_ids
}

###############################################################################
# Convenience
###############################################################################

output "name_prefix" {
  description = "Naming prefix used for every resource in this stack."
  value       = local.name_prefix
}

output "tags" {
  description = "The standard tag set applied to resources."
  value       = local.tags
}

output "effective_defaults" {
  description = "Environment-derived settings actually in effect. Useful for reviewing a plan at a glance."
  value = {
    nat_gateway_mode     = local.nat_gateway_mode
    flow_logs_enabled    = local.enable_flow_logs
    network_acls_enabled = local.enable_network_acls
    cluster_level        = local.cluster_level
    public_api_endpoint  = local.enable_public_endpoint
    deletion_protection  = local.defaults.deletion_protection
    log_retention_days   = local.log_retention_days
    egress_restricted    = var.restrict_egress
  }
}
