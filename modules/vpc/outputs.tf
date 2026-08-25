output "vpc_id" {
  description = "ID of the VPC."
  value       = tencentcloud_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC."
  value       = tencentcloud_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "Every subnet ID keyed by \"<tier>/<az>\"."
  value       = { for k, s in tencentcloud_subnet.this : k => s.id }
}

output "subnets_by_tier" {
  description = "Subnet IDs grouped by tier, ordered by the availability_zones input."
  value = {
    for tier_key in keys(var.tiers) : tier_key => [
      for az in var.availability_zones : tencentcloud_subnet.this["${tier_key}/${az}"].id
    ]
  }
}

output "subnet_cidrs_by_tier" {
  description = "Subnet CIDRs grouped by tier. Feed these into security group and ACL rules."
  value = {
    for tier_key in keys(var.tiers) : tier_key => [
      for az in var.availability_zones : local.tier_az_cidrs[tier_key][az]
    ]
  }
}

output "tier_cidrs" {
  description = "The supernet owned by each tier. Prefer these over per-subnet CIDRs in rules."
  value       = { for k, t in var.tiers : k => t.cidr_block }
}

output "availability_zones" {
  description = "Availability zones this VPC spans."
  value       = var.availability_zones
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs keyed by availability zone."
  value       = { for k, n in tencentcloud_nat_gateway.this : k => n.id }
}

output "nat_public_ips" {
  description = "Public IPs used for SNAT. Hand these to partners that allowlist source IPs."
  value       = sort([for k, e in tencentcloud_eip.nat : e.public_ip])
}

output "route_table_ids" {
  description = "Route table IDs by class."
  value = {
    public   = try(tencentcloud_route_table.public[0].id, null)
    private  = { for k, rt in tencentcloud_route_table.private : k => rt.id }
    isolated = try(tencentcloud_route_table.isolated[0].id, null)
  }
}

output "flow_log_topic_id" {
  description = "CLS topic ID receiving VPC flow logs, if enabled."
  value       = try(tencentcloud_cls_topic.flow_logs[0].id, null)
}
