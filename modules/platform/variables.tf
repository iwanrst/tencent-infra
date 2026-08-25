###############################################################################
# Identity -- the three variables that change per client / per environment.
###############################################################################

variable "client" {
  description = "Short client or organisation slug. Becomes the first element of every resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.client))
    error_message = "client must be 2-12 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment name. Drives the hardening defaults below."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  description = "Tencent Cloud region, e.g. ap-singapore, ap-jakarta."
  type        = string
}

variable "availability_zones" {
  description = <<-EOT
    Explicit AZ list. Leave empty to auto-select the first `az_count` available
    zones in the region. Pin these before going to production: auto-selection
    can shift if Tencent changes zone availability, which would move subnets.
  EOT
  type        = list(string)
  default     = []
}

variable "az_count" {
  description = "How many AZs to spread across when availability_zones is empty."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4."
  }
}

variable "extra_tags" {
  description = "Client-specific tags merged on top of the standard tag set (cost centre, owner, ticket, ...)."
  type        = map(string)
  default     = {}
}

###############################################################################
# Address plan
###############################################################################

variable "vpc_cidr" {
  description = "VPC CIDR. Give every environment of every client a distinct range so they stay peerable."
  type        = string
  default     = "10.0.0.0/16"
}

variable "tiers" {
  description = <<-EOT
    Network tiers. The default layout for a /16:

      public   10.0.0.0/20   /22 per AZ   CLBs, NAT gateways, bastion
      app      10.0.16.0/20  /22 per AZ   TKE worker nodes
      data     10.0.32.0/20  /22 per AZ   databases, caches -- no internet egress
      eni      10.0.64.0/18  /20 per AZ   VPC-CNI pod IPs (~4000 pods per AZ)

    Override only when the client has an existing address plan to fit into.
  EOT
  type = map(object({
    cidr_block = string
    az_newbits = optional(number, 2)
    az_cidrs   = optional(map(string), {})
    public     = optional(bool, false)
    nat_egress = optional(bool, true)
  }))
  default = {
    public = { cidr_block = "10.0.0.0/20", az_newbits = 2, public = true }
    app    = { cidr_block = "10.0.16.0/20", az_newbits = 2 }
    data   = { cidr_block = "10.0.32.0/20", az_newbits = 2, nat_egress = false }
    eni    = { cidr_block = "10.0.64.0/18", az_newbits = 2 }
  }

  # nullable=false makes an explicit null from the caller fall back to the
  # default above, so a root module can pass var.tiers unconditionally.
  nullable = false

  validation {
    condition     = alltrue([for k in ["public", "app", "data"] : contains(keys(var.tiers), k)])
    error_message = "The tiers map must define at least public, app and data."
  }
}

variable "nat_gateway_mode" {
  description = "\"per_az\" for zone-isolated egress (prod), \"single\" to save cost (dev/staging). Defaults by environment."
  type        = string
  default     = null

  validation {
    condition     = var.nat_gateway_mode == null || contains(["single", "per_az"], coalesce(var.nat_gateway_mode, "per_az"))
    error_message = "nat_gateway_mode must be \"single\" or \"per_az\"."
  }
}

variable "nat_gateway_bandwidth" {
  description = "Outbound bandwidth cap per NAT gateway, in Mbps."
  type        = number
  default     = 100
}

variable "extra_routes" {
  description = "Additional routes (CCN, Direct Connect, VPN, peering) injected into the generated route tables."
  type = list(object({
    scope                  = string
    destination_cidr_block = string
    next_type              = string
    next_hub               = string
    description            = optional(string, "Managed by Terraform")
  }))
  default = []
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to CLS. Defaults to on in prod, off elsewhere."
  type        = bool
  default     = null
}

###############################################################################
# Access control inputs
###############################################################################

variable "admin_cidrs" {
  description = <<-EOT
    Trusted operator networks: office ranges, VPN concentrators, CI egress IPs.
    These are the only sources allowed to SSH to the bastion and, where the
    public API endpoint is enabled, to reach the Kubernetes API.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry in admin_cidrs must be a valid IPv4 CIDR."
  }

  validation {
    condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not an administrative network. List real office / VPN ranges."
  }
}

variable "public_ingress_cidrs" {
  description = "Sources allowed to hit the public load balancers on 80/443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "public_ingress_ports" {
  description = "Ports the public load balancer security group accepts."
  type        = list(string)
  default     = ["80", "443"]
}

variable "data_service_ports" {
  description = "Ports the data tier accepts from application workloads, keyed by service name."
  type        = map(string)
  default = {
    mysql      = "3306"
    postgresql = "5432"
    redis      = "6379"
  }
}

variable "enable_bastion_security_group" {
  description = "Create a bastion security group. Turn off when access is exclusively via VPN or CCN."
  type        = bool
  default     = true
}

variable "extra_security_groups" {
  description = <<-EOT
    Client-specific security groups merged into the baseline set. Rules may
    reference baseline group keys (lb, bastion, node, pod, data) in
    `source_security_group`.
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
  default = {}
}

variable "enable_network_acls" {
  description = "Apply the stateless tier ACLs. Defaults to on in prod, off elsewhere (they make ad-hoc debugging slower)."
  type        = bool
  default     = null
}

variable "restrict_egress" {
  description = <<-EOT
    When true, workload security groups may only egress to the VPC, plus 443 and
    DNS to the internet. Requires a proxy or VPC endpoints for anything else --
    turn it on deliberately, after the workload's egress needs are known.
  EOT
  type        = bool
  default     = false
}

###############################################################################
# TKE
###############################################################################

variable "kubernetes_version" {
  description = "Kubernetes minor version to pin the cluster to."
  type        = string
  default     = "1.30.0"
}

variable "tke_network_type" {
  description = "\"VPC-CNI\" (pods on VPC IPs) or \"GR\" (overlay). Cannot be changed after creation."
  type        = string
  default     = "VPC-CNI"
}

variable "tke_cluster_cidr" {
  description = "Pod CIDR for GlobalRouter mode. Must not overlap the VPC or any peered network."
  type        = string
  default     = "172.24.0.0/16"
}

variable "tke_service_cidr" {
  description = "ClusterIP service range. Must not overlap the VPC or the pod CIDR."
  type        = string
  default     = "172.20.0.0/18"
}

variable "tke_cluster_level" {
  description = "Managed control plane size. Defaults by environment (L5 non-prod, L50 prod)."
  type        = string
  default     = null
}

variable "tke_enable_public_endpoint" {
  description = "Expose the Kubernetes API on the internet, restricted to admin_cidrs. Defaults to off in prod."
  type        = bool
  default     = null
}

variable "tke_max_pods_per_node" {
  description = "Maximum pods per node."
  type        = number
  default     = 64
}

variable "node_pools" {
  description = <<-EOT
    Worker node pools. The default gives a small always-on `system` pool for
    platform components and a `general` pool for application workloads.
    `subnet_tier` names which network tier the pool launches into.
  EOT
  type = map(object({
    subnet_tier       = optional(string, "app")
    instance_types    = list(string)
    min_size          = number
    max_size          = number
    desired_size      = optional(number)
    system_disk_type  = optional(string, "CLOUD_SSD")
    system_disk_size  = optional(number, 50)
    data_disk_size    = optional(number, 0)
    spot              = optional(bool, false)
    enable_auto_scale = optional(bool, true)
    labels            = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  default = {
    system = {
      instance_types = ["S5.MEDIUM4", "SA3.MEDIUM4"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      data_disk_size = 100
      labels         = { "workload-class" = "system" }
      taints = [{
        key    = "dedicated"
        value  = "system"
        effect = "PreferNoSchedule"
      }]
    }
    general = {
      instance_types = ["S5.LARGE8", "SA3.LARGE8"]
      min_size       = 2
      max_size       = 10
      desired_size   = 2
      data_disk_size = 200
      labels         = { "workload-class" = "general" }
    }
  }

  nullable = false

  validation {
    condition     = length(var.node_pools) > 0
    error_message = "At least one node pool is required."
  }
}

variable "node_ssh_key_ids" {
  description = "SSH key IDs injected into worker nodes. Empty disables SSH login."
  type        = list(string)
  default     = []
}

variable "node_cam_role_name" {
  description = "CAM role bound to worker nodes."
  type        = string
  default     = null
}

variable "tke_addons" {
  description = "TKE addons to install, keyed by addon name."
  type = map(object({
    version    = optional(string)
    raw_values = optional(string)
  }))
  default = {}
}

variable "log_retention_days" {
  description = "Retention for flow log, audit log and event CLS topics."
  type        = number
  default     = null
}
