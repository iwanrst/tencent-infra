###############################################################################
# Security groups.
#
# Two phases on purpose: every group is created first, then the rule sets are
# applied. That is what lets one group reference another by key without a
# dependency cycle -- app -> data and data -> app can both be expressed.
#
# `tencentcloud_security_group_rule_set` owns the *entire* rule list for a
# group. Rules added by hand in the console are reverted on the next apply,
# which is the behaviour you want for an auditable baseline.
###############################################################################

resource "tencentcloud_security_group" "this" {
  for_each = var.security_groups

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.description
  project_id  = var.project_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

locals {
  # Resolve source_security_group keys / self references into real IDs.
  resolved = {
    for k, sg in var.security_groups : k => {
      ingress = [
        for r in sg.ingress : {
          action      = upper(r.action)
          protocol    = upper(r.protocol)
          port        = upper(r.port) == "ALL" ? "ALL" : r.port
          cidr_block  = r.cidr_block
          description = r.description
          source_security_id = (
            r.self ? tencentcloud_security_group.this[k].id :
            r.source_security_group != null ? tencentcloud_security_group.this[r.source_security_group].id :
            null
          )
        }
      ]
      egress = [
        for r in sg.egress : {
          action      = upper(r.action)
          protocol    = upper(r.protocol)
          port        = upper(r.port) == "ALL" ? "ALL" : r.port
          cidr_block  = r.cidr_block
          description = r.description
          source_security_id = (
            r.self ? tencentcloud_security_group.this[k].id :
            r.source_security_group != null ? tencentcloud_security_group.this[r.source_security_group].id :
            null
          )
        }
      ]
    }
  }
}

resource "tencentcloud_security_group_rule_set" "this" {
  for_each = var.security_groups

  security_group_id = tencentcloud_security_group.this[each.key].id

  dynamic "ingress" {
    for_each = local.resolved[each.key].ingress
    content {
      action             = ingress.value.action
      protocol           = ingress.value.protocol
      port               = ingress.value.port
      cidr_block         = ingress.value.cidr_block
      source_security_id = ingress.value.source_security_id
      description        = ingress.value.description
    }
  }

  dynamic "egress" {
    for_each = local.resolved[each.key].egress
    content {
      action             = egress.value.action
      protocol           = egress.value.protocol
      port               = egress.value.port
      cidr_block         = egress.value.cidr_block
      source_security_id = egress.value.source_security_id
      description        = egress.value.description
    }
  }
}
