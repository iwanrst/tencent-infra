variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. \"acme-prod\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with dashes, 2-31 chars."
  }
}

variable "cidr_block" {
  description = "Primary CIDR block of the VPC. Must be a private (RFC1918) range."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR."
  }

  validation {
    condition     = tonumber(split("/", var.cidr_block)[1]) <= 24
    error_message = "cidr_block must be /24 or larger to leave room for tier segmentation."
  }
}

variable "availability_zones" {
  description = <<-EOT
    Ordered list of availability zones to spread subnets across. The order is
    significant: subnet CIDRs are derived from the index, so re-ordering this
    list forces subnet replacement. Append, never re-order.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 1
    error_message = "At least one availability zone is required."
  }
}

variable "tiers" {
  description = <<-EOT
    Network tiers (segments). Each tier owns a contiguous slice of the VPC CIDR
    which is then split evenly across `availability_zones`.

      cidr_block  - slice of the VPC CIDR owned by this tier.
      az_newbits  - bits borrowed from the tier CIDR to carve one subnet per AZ.
                    Must satisfy 2^az_newbits >= length(availability_zones).
      az_cidrs    - optional explicit per-AZ override, keyed by AZ name. Use when
                    migrating an existing network that does not follow the scheme.
      public      - subnets are internet facing (hold CLBs / NAT / bastion).
      nat_egress  - private tier reaches the internet through the NAT gateway.
                    Set false for fully isolated tiers (databases, PCI zones).
  EOT
  type = map(object({
    cidr_block = string
    az_newbits = optional(number, 2)
    az_cidrs   = optional(map(string), {})
    public     = optional(bool, false)
    nat_egress = optional(bool, true)
  }))

  validation {
    condition = alltrue([
      for k, t in var.tiers :
      pow(2, t.az_newbits) >= length(var.availability_zones)
    ])
    error_message = "Every tier needs az_newbits large enough to carve one subnet per availability zone."
  }

  validation {
    condition = alltrue([
      for k, t in var.tiers :
      cidrhost(format("%s/%s", cidrhost(t.cidr_block, 0), split("/", var.cidr_block)[1]), 0) == cidrhost(var.cidr_block, 0)
      && tonumber(split("/", t.cidr_block)[1]) >= tonumber(split("/", var.cidr_block)[1])
    ])
    error_message = "Every tier cidr_block must be contained within the VPC cidr_block."
  }

  validation {
    condition     = length([for k, t in var.tiers : k if t.public]) > 0 || !var.enable_nat_gateway
    error_message = "A NAT gateway requires at least one public tier to host it."
  }
}

variable "enable_nat_gateway" {
  description = "Provision NAT gateway(s) so private tiers can reach the internet outbound."
  type        = bool
  default     = true
}

variable "nat_gateway_mode" {
  description = <<-EOT
    "single" - one NAT gateway shared by every AZ. Cheaper, but a zone outage on
               the NAT's AZ takes down egress for the whole VPC. Use in non-prod.
    "per_az" - one NAT gateway per AZ, each private route table egressing through
               its own zone. Zone-fault isolated and avoids cross-AZ traffic cost.
  EOT
  type        = string
  default     = "per_az"

  validation {
    condition     = contains(["single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be either \"single\" or \"per_az\"."
  }
}

variable "nat_gateway_bandwidth" {
  description = "Outbound bandwidth cap per NAT gateway, in Mbps."
  type        = number
  default     = 100
}

variable "nat_gateway_max_concurrent" {
  description = "Concurrent connection cap per NAT gateway."
  type        = number
  default     = 1000000
}

variable "nat_gateway_eip_count" {
  description = "Number of elastic IPs attached to each NAT gateway. More EIPs = more SNAT source ports."
  type        = number
  default     = 1

  validation {
    condition     = var.nat_gateway_eip_count >= 1 && var.nat_gateway_eip_count <= 10
    error_message = "nat_gateway_eip_count must be between 1 and 10."
  }
}

variable "dns_servers" {
  description = "Custom DNS servers for the VPC. Empty list keeps the Tencent Cloud resolver."
  type        = list(string)
  default     = []
}

variable "extra_routes" {
  description = <<-EOT
    Additional routes injected into the generated route tables. `scope` selects
    which class of route table receives the route: public, private or isolated.
    Typical use: pointing on-prem CIDRs at a CCN, Direct Connect or VPN gateway.
  EOT
  type = list(object({
    scope                  = string
    destination_cidr_block = string
    next_type              = string
    next_hub               = string
    description            = optional(string, "Managed by Terraform")
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.extra_routes : contains(["public", "private", "isolated"], r.scope)
    ])
    error_message = "extra_routes[].scope must be one of: public, private, isolated."
  }
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to Cloud Log Service. Strongly recommended in production."
  type        = bool
  default     = false
}

variable "flow_log_traffic_type" {
  description = "Which traffic to capture in flow logs: ACCEPT, REJECT or ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "flow_log_retention_days" {
  description = "Retention of the CLS topic backing the flow logs, in days."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every taggable resource in this module."
  type        = map(string)
  default     = {}
}
