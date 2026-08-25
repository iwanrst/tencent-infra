###############################################################################
# Network ACLs -- the coarse, stateless boundary between tiers.
#
# Security groups are the primary control (stateful, instance level). ACLs are
# the second layer: they cannot be bypassed by a mis-tagged instance, which
# makes them the right place to express "the data tier is never reachable from
# the internet" as an invariant rather than a convention.
###############################################################################

locals {
  # Stateless return traffic. These must come FIRST: a tier that ends in a
  # catch-all DROP would otherwise shadow them and break every connection it
  # originated, because first match wins.
  ephemeral_rules = {
    for k, acl in var.acls : k => !acl.allow_ephemeral_return ? [] : flatten([
      for cidr in acl.ephemeral_return_cidrs : [
        format("ACCEPT#%s#%s#TCP", cidr, var.ephemeral_port_range),
        format("ACCEPT#%s#%s#UDP", cidr, var.ephemeral_port_range),
      ]
    ])
  }

  rule_string = {
    for k, acl in var.acls : k => {
      ingress = concat(
        local.ephemeral_rules[k],
        [for r in acl.ingress : format("%s#%s#%s#%s", upper(r.action), r.cidr_block, upper(r.port), upper(r.protocol))],
      )
      egress = concat(
        local.ephemeral_rules[k],
        [for r in acl.egress : format("%s#%s#%s#%s", upper(r.action), r.cidr_block, upper(r.port), upper(r.protocol))],
      )
    }
  }

  # "<acl>/<subnet>" => attachment, so adding a subnet does not reshuffle others.
  attachments = merge([
    for k, acl in var.acls : {
      for subnet_id in acl.subnet_ids : "${k}/${subnet_id}" => {
        acl_key   = k
        subnet_id = subnet_id
      }
    }
  ]...)
}

resource "tencentcloud_vpc_acl" "this" {
  for_each = var.acls

  vpc_id  = var.vpc_id
  name    = "${var.name_prefix}-acl-${each.key}"
  ingress = local.rule_string[each.key].ingress
  egress  = local.rule_string[each.key].egress

  tags = merge(var.tags, { Name = "${var.name_prefix}-acl-${each.key}", Tier = each.key })
}

resource "tencentcloud_vpc_acl_attachment" "this" {
  for_each = local.attachments

  acl_id    = tencentcloud_vpc_acl.this[each.value.acl_key].id
  subnet_id = each.value.subnet_id
}
