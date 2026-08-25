variable "name_prefix" {
  description = "Prefix applied to every security group name."
  type        = string
}

variable "project_id" {
  description = "Tencent Cloud project ID the security groups belong to. 0 is the default project."
  type        = number
  default     = 0
}

variable "security_groups" {
  description = <<-EOT
    Security groups to create, keyed by short name.

    A rule targets exactly one of:
      cidr_block            - literal CIDR, e.g. "10.0.0.0/16"
      source_security_group - key of another group *in this same map*; the module
                              resolves it to an ID, which is how you express
                              "the app tier may talk to the data tier" without
                              hardcoding addresses
      self                  - true to reference the group itself (intra-tier chatter)

    Rules are stateful: return traffic is implicitly allowed, and they are
    evaluated in list order with an implicit deny at the end.
  EOT
  type = map(object({
    description = optional(string, "Managed by Terraform")
    ingress = optional(list(object({
      action                = optional(string, "ACCEPT")
      protocol              = optional(string, "ALL")
      port                  = optional(string, "ALL")
      cidr_block            = optional(string)
      source_security_group = optional(string)
      self                  = optional(bool, false)
      description           = optional(string, "")
    })), [])
    egress = optional(list(object({
      action                = optional(string, "ACCEPT")
      protocol              = optional(string, "ALL")
      port                  = optional(string, "ALL")
      cidr_block            = optional(string)
      source_security_group = optional(string)
      self                  = optional(bool, false)
      description           = optional(string, "")
    })), [])
  }))

  validation {
    condition = alltrue(flatten([
      for k, sg in var.security_groups : [
        for r in concat(sg.ingress, sg.egress) :
        length(compact([r.cidr_block, r.source_security_group, r.self ? "self" : null])) == 1
      ]
    ]))
    error_message = "Each rule must set exactly one of cidr_block, source_security_group or self."
  }

  validation {
    condition = alltrue(flatten([
      for k, sg in var.security_groups : [
        for r in concat(sg.ingress, sg.egress) :
        contains(keys(var.security_groups), r.source_security_group) if r.source_security_group != null
      ]
    ]))
    error_message = "source_security_group must reference a key defined in this same security_groups map."
  }

  validation {
    condition = alltrue(flatten([
      for k, sg in var.security_groups : [
        for r in concat(sg.ingress, sg.egress) : contains(["ACCEPT", "DROP"], upper(r.action))
      ]
    ]))
    error_message = "Rule action must be ACCEPT or DROP."
  }

  validation {
    condition = alltrue(flatten([
      for k, sg in var.security_groups : [
        for r in concat(sg.ingress, sg.egress) : contains(["TCP", "UDP", "ICMP", "ICMPV6", "ALL"], upper(r.protocol))
      ]
    ]))
    error_message = "Rule protocol must be TCP, UDP, ICMP, ICMPV6 or ALL."
  }

  validation {
    condition = alltrue(flatten([
      for k, sg in var.security_groups : [
        for r in concat(sg.ingress, sg.egress) :
        upper(r.port) == "ALL" if contains(["ICMP", "ICMPV6", "ALL"], upper(r.protocol))
      ]
    ]))
    error_message = "Rules using protocol ICMP, ICMPV6 or ALL must set port to \"ALL\"."
  }
}

variable "tags" {
  description = "Tags applied to every security group."
  type        = map(string)
  default     = {}
}
