###############################################################################
# Environment defaults.
#
# Everything below is a *default per environment*, always overridable by an
# explicit variable. This is what keeps staging cheap and prod hardened while
# both call the identical module with the identical code.
###############################################################################

locals {
  is_prod = var.environment == "prod"

  defaults = {
    nat_gateway_mode    = local.is_prod ? "per_az" : "single"
    flow_logs           = local.is_prod
    network_acls        = local.is_prod
    cluster_level       = local.is_prod ? "L50" : "L5"
    public_endpoint     = !local.is_prod
    deletion_protection = local.is_prod
    log_retention       = local.is_prod ? 90 : 14
  }

  nat_gateway_mode    = coalesce(var.nat_gateway_mode, local.defaults.nat_gateway_mode)
  enable_flow_logs    = var.enable_flow_logs != null ? var.enable_flow_logs : local.defaults.flow_logs
  enable_network_acls = var.enable_network_acls != null ? var.enable_network_acls : local.defaults.network_acls
  cluster_level       = coalesce(var.tke_cluster_level, local.defaults.cluster_level)
  log_retention_days  = coalesce(var.log_retention_days, local.defaults.log_retention)

  enable_public_endpoint = (
    var.tke_enable_public_endpoint != null
    ? var.tke_enable_public_endpoint
    : local.defaults.public_endpoint
  ) && length(var.admin_cidrs) > 0

  ###############################################################################
  # Naming and tagging
  ###############################################################################

  name_prefix = "${var.client}-${var.environment}"

  tags = merge(
    {
      Client      = var.client
      Environment = var.environment
      Region      = var.region
      ManagedBy   = "terraform"
      Module      = "tencent-platform"
    },
    var.extra_tags,
  )

  ###############################################################################
  # Availability zones
  ###############################################################################

  available_zones = [
    for z in data.tencentcloud_availability_zones_by_product.this.zones : z.name
    if z.state == "AVAILABLE"
  ]

  availability_zones = (
    length(var.availability_zones) > 0
    ? var.availability_zones
    : slice(local.available_zones, 0, min(var.az_count, length(local.available_zones)))
  )

  ###############################################################################
  # Tier shorthands used by rules further down
  ###############################################################################

  tier_cidrs = { for k, t in var.tiers : k => t.cidr_block }
  app_cidr   = local.tier_cidrs["app"]
  eni_cidr   = try(local.tier_cidrs["eni"], null)

  # Where workload traffic originates: app nodes, plus pod IPs under VPC-CNI.
  workload_cidrs = compact([local.app_cidr, local.eni_cidr])
}

data "tencentcloud_availability_zones_by_product" "this" {
  product = "cvm"
}

# Fail fast on a misconfigured region/AZ combination rather than half way
# through creating subnets.
resource "terraform_data" "az_guard" {
  input = local.availability_zones

  lifecycle {
    precondition {
      condition     = length(local.availability_zones) >= (local.is_prod ? 2 : 1)
      error_message = "Production requires at least two availability zones; got ${length(local.availability_zones)} in ${var.region}."
    }

    precondition {
      condition = alltrue([
        for az in var.availability_zones : contains(local.available_zones, az)
      ])
      error_message = "One or more requested availability_zones are not available in ${var.region}."
    }
  }
}
