variable "name_prefix" {
  description = "Prefix applied to every ACL name."
  type        = string
}

variable "vpc_id" {
  description = "VPC the ACLs belong to."
  type        = string
}

variable "acls" {
  description = <<-EOT
    Network ACLs to create, keyed by name (normally one per network tier).

    ACLs are *stateless* and evaluated top-down, first match wins, with an
    implicit deny at the end of each direction. Order in the list is the
    evaluation order -- put the most specific rules first.

    Because they are stateless, a tier that initiates a TCP connection also
    needs an ingress rule for the return traffic on the ephemeral port range
    (32768-65535 on Linux). `allow_ephemeral_return` adds that for you, and
    `ephemeral_return_cidrs` scopes who may send it -- narrow it to the VPC for
    tiers that have no internet egress.

    The generated return rules are placed FIRST, ahead of your rules. They have
    to be: a tier ending in a catch-all DROP would otherwise shadow them and
    break every connection it originated.

    Rule fields:
      action      - ACCEPT or DROP
      cidr_block  - source CIDR for ingress, destination CIDR for egress
      protocol    - TCP, UDP, ICMP or ALL
      port        - "443", "80,443", "30000-32767" or "ALL" (must be ALL for ICMP/ALL)
      description - free text, shows up in the console
  EOT
  type = map(object({
    subnet_ids             = list(string)
    allow_ephemeral_return = optional(bool, true)
    ephemeral_return_cidrs = optional(list(string), ["0.0.0.0/0"])
    ingress = optional(list(object({
      action      = string
      cidr_block  = string
      protocol    = optional(string, "ALL")
      port        = optional(string, "ALL")
      description = optional(string, "")
    })), [])
    egress = optional(list(object({
      action      = string
      cidr_block  = string
      protocol    = optional(string, "ALL")
      port        = optional(string, "ALL")
      description = optional(string, "")
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue(flatten([
      for k, acl in var.acls : [
        for r in concat(acl.ingress, acl.egress) : contains(["ACCEPT", "DROP"], upper(r.action))
      ]
    ]))
    error_message = "Every ACL rule action must be ACCEPT or DROP."
  }

  validation {
    condition = alltrue(flatten([
      for k, acl in var.acls : [
        for r in concat(acl.ingress, acl.egress) : contains(["TCP", "UDP", "ICMP", "ALL"], upper(r.protocol))
      ]
    ]))
    error_message = "Every ACL rule protocol must be TCP, UDP, ICMP or ALL."
  }

  validation {
    condition = alltrue(flatten([
      for k, acl in var.acls : [
        for r in concat(acl.ingress, acl.egress) :
        upper(r.port) == "ALL" if contains(["ICMP", "ALL"], upper(r.protocol))
      ]
    ]))
    error_message = "Rules using protocol ICMP or ALL must set port to \"ALL\"."
  }
}

variable "ephemeral_port_range" {
  description = "Ephemeral port range opened for stateless return traffic."
  type        = string
  default     = "32768-65535"
}

variable "tags" {
  description = "Tags applied to every ACL."
  type        = map(string)
  default     = {}
}
