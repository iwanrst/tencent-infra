###############################################################################
# Address plan
#
# The VPC CIDR is sliced into tiers, and each tier is split evenly across the
# availability zones. Everything is derived, so a client only ever supplies the
# VPC CIDR and the tier layout -- never individual subnet CIDRs.
###############################################################################

locals {
  az_index = { for idx, az in var.availability_zones : az => idx }

  # tier => az => cidr
  tier_az_cidrs = {
    for tier_key, tier in var.tiers : tier_key => {
      for az in var.availability_zones :
      az => lookup(tier.az_cidrs, az, cidrsubnet(tier.cidr_block, tier.az_newbits, local.az_index[az]))
    }
  }

  # Flattened "<tier>/<az>" => subnet spec, the key used by for_each everywhere.
  subnets = merge([
    for tier_key, tier in var.tiers : {
      for az, cidr in local.tier_az_cidrs[tier_key] :
      "${tier_key}/${az}" => {
        tier       = tier_key
        az         = az
        cidr_block = cidr
        public     = tier.public
        nat_egress = tier.nat_egress
      }
    }
  ]...)

  has_public   = length([for k, t in var.tiers : k if t.public]) > 0
  has_isolated = length([for k, t in var.tiers : k if !t.public && !t.nat_egress]) > 0

  create_nat = var.enable_nat_gateway && local.has_public

  # Which AZs host a NAT gateway.
  nat_zones = !local.create_nat ? [] : (
    var.nat_gateway_mode == "per_az" ? var.availability_zones : [var.availability_zones[0]]
  )

  # Private route tables: one per AZ under per_az, otherwise a single shared one.
  private_route_table_keys = var.nat_gateway_mode == "per_az" ? var.availability_zones : ["shared"]

  # EIP instances, keyed "<zone>/<index>", so adding capacity never churns existing IPs.
  nat_eips = local.create_nat ? merge([
    for zone in local.nat_zones : {
      for i in range(var.nat_gateway_eip_count) : "${zone}/${i}" => zone
    }
  ]...) : {}
}

###############################################################################
# VPC
###############################################################################

resource "tencentcloud_vpc" "this" {
  name         = "${var.name_prefix}-vpc"
  cidr_block   = var.cidr_block
  is_multicast = false
  dns_servers  = length(var.dns_servers) > 0 ? var.dns_servers : null

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })

  lifecycle {
    # The address plan is the hardest thing to change after the fact -- every
    # subnet, peering and on-prem route depends on it. Guard it explicitly.
    prevent_destroy = true
  }
}

###############################################################################
# Route tables
#
# Tencent VPCs give instances with a public IP/EIP direct internet access, so a
# public route table needs no default route -- only the implicit local route.
# Private tiers get an explicit 0.0.0.0/0 through their zone's NAT gateway.
# Isolated tiers get no default route at all.
###############################################################################

resource "tencentcloud_route_table" "public" {
  count = local.has_public ? 1 : 0

  vpc_id = tencentcloud_vpc.this.id
  name   = "${var.name_prefix}-rt-public"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-rt-public", Tier = "public" })
}

resource "tencentcloud_route_table" "private" {
  for_each = toset(local.private_route_table_keys)

  vpc_id = tencentcloud_vpc.this.id
  name   = "${var.name_prefix}-rt-private-${each.key}"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-rt-private-${each.key}", Tier = "private" })
}

resource "tencentcloud_route_table" "isolated" {
  count = local.has_isolated ? 1 : 0

  vpc_id = tencentcloud_vpc.this.id
  name   = "${var.name_prefix}-rt-isolated"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-rt-isolated", Tier = "isolated" })
}

###############################################################################
# Subnets
###############################################################################

resource "tencentcloud_subnet" "this" {
  for_each = local.subnets

  vpc_id            = tencentcloud_vpc.this.id
  availability_zone = each.value.az
  name              = "${var.name_prefix}-${each.value.tier}-${each.value.az}"
  cidr_block        = each.value.cidr_block
  is_multicast      = false

  route_table_id = (
    each.value.public ? tencentcloud_route_table.public[0].id :
    each.value.nat_egress ? tencentcloud_route_table.private[
      var.nat_gateway_mode == "per_az" ? each.value.az : "shared"
    ].id :
    tencentcloud_route_table.isolated[0].id
  )

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-${each.value.tier}-${each.value.az}"
    Tier = each.value.tier
  })
}

###############################################################################
# NAT gateways
###############################################################################

resource "tencentcloud_eip" "nat" {
  for_each = local.nat_eips

  name                 = "${var.name_prefix}-nat-${each.key}"
  type                 = "EIP"
  internet_charge_type = "TRAFFIC_POSTPAID_BY_HOUR"

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-${replace(each.key, "/", "-")}" })
}

resource "tencentcloud_nat_gateway" "this" {
  for_each = toset(local.nat_zones)

  name             = "${var.name_prefix}-nat-${each.key}"
  vpc_id           = tencentcloud_vpc.this.id
  zone             = each.key
  bandwidth        = var.nat_gateway_bandwidth
  max_concurrent   = var.nat_gateway_max_concurrent
  assigned_eip_set = [for k, zone in local.nat_eips : tencentcloud_eip.nat[k].public_ip if zone == each.key]

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-${each.key}" })
}

resource "tencentcloud_route_table_entry" "private_default" {
  for_each = local.create_nat ? tencentcloud_route_table.private : {}

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  next_type              = "NAT"
  next_hub = tencentcloud_nat_gateway.this[
    var.nat_gateway_mode == "per_az" ? each.key : local.nat_zones[0]
  ].id
  description = "Default egress via NAT gateway"
}

###############################################################################
# Operator supplied routes (CCN / Direct Connect / VPN / peering)
###############################################################################

locals {
  extra_route_targets = merge([
    for idx, r in var.extra_routes : merge(
      r.scope == "public" && local.has_public ? {
        "${idx}/public" = { rt = tencentcloud_route_table.public[0].id, route = r }
      } : {},
      r.scope == "private" ? {
        for k, rt in tencentcloud_route_table.private : "${idx}/private/${k}" => { rt = rt.id, route = r }
      } : {},
      r.scope == "isolated" && local.has_isolated ? {
        "${idx}/isolated" = { rt = tencentcloud_route_table.isolated[0].id, route = r }
      } : {},
    )
  ]...)
}

resource "tencentcloud_route_table_entry" "extra" {
  for_each = local.extra_route_targets

  route_table_id         = each.value.rt
  destination_cidr_block = each.value.route.destination_cidr_block
  next_type              = each.value.route.next_type
  next_hub               = each.value.route.next_hub
  description            = each.value.route.description
}

###############################################################################
# Flow logs
###############################################################################

resource "tencentcloud_cls_logset" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  logset_name = "${var.name_prefix}-vpc-flowlogs"
  tags        = merge(var.tags, { Name = "${var.name_prefix}-vpc-flowlogs" })
}

resource "tencentcloud_cls_topic" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  logset_id       = tencentcloud_cls_logset.flow_logs[0].id
  topic_name      = "${var.name_prefix}-vpc-flowlogs"
  period          = var.flow_log_retention_days
  storage_type    = "hot"
  partition_count = 1
  auto_split      = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc-flowlogs" })
}

resource "tencentcloud_vpc_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  flow_log_name        = "${var.name_prefix}-vpc-flowlog"
  flow_log_description = "VPC-wide flow log for ${var.name_prefix}"
  resource_type        = "VPC"
  resource_id          = tencentcloud_vpc.this.id
  vpc_id               = tencentcloud_vpc.this.id
  traffic_type         = var.flow_log_traffic_type
  storage_type         = "cls"
  cloud_log_id         = tencentcloud_cls_topic.flow_logs[0].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc-flowlog" })
}
