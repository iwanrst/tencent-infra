output "vpc_id" {
  description = "VPC ID."
  value       = module.platform.vpc_id
}

output "subnets_by_tier" {
  description = "Subnet IDs grouped by network tier."
  value       = module.platform.subnets_by_tier
}

output "security_group_ids" {
  description = "Security group IDs by short name."
  value       = module.platform.security_group_ids
}

output "nat_public_ips" {
  description = "Egress IPs of this environment."
  value       = module.platform.nat_public_ips
}

output "cluster_id" {
  description = "TKE cluster ID."
  value       = module.platform.cluster_id
}

output "cluster_private_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = module.platform.cluster_private_endpoint
}

output "cluster_public_endpoint" {
  description = "Public Kubernetes API endpoint, null when disabled."
  value       = module.platform.cluster_public_endpoint
}

output "effective_defaults" {
  description = "Environment-derived settings actually in effect."
  value       = module.platform.effective_defaults
}

output "kube_config" {
  description = "Kubeconfig for the private endpoint. Read with: terraform output -raw kube_config"
  value       = module.platform.kube_config
  sensitive   = true
}
