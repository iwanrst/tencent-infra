###############################################################################
# Root variables. Identical in every environment -- values come from
# terraform.tfvars. Nulls mean "use the platform module's environment default".
###############################################################################

variable "client" {
  description = "Client / organisation slug."
  type        = string
}

variable "environment" {
  description = "Environment name: dev, staging or prod."
  type        = string
}

variable "region" {
  description = "Tencent Cloud region."
  type        = string
}

variable "assume_role_arn" {
  description = "CAM role to assume in the target account. Null uses the caller's own credentials."
  type        = string
  default     = null
}

variable "extra_tags" {
  description = "Client-specific tags (cost centre, owner, ...)."
  type        = map(string)
  default     = {}
}

# --- Topology ---------------------------------------------------------------

variable "availability_zones" {
  description = "Explicit AZ list. Empty auto-selects az_count zones."
  type        = list(string)
  default     = []
}

variable "az_count" {
  description = "Number of AZs when availability_zones is empty."
  type        = number
  default     = 3
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "tiers" {
  description = "Network tier layout. Leave unset to use the module default."
  type = map(object({
    cidr_block = string
    az_newbits = optional(number, 2)
    az_cidrs   = optional(map(string), {})
    public     = optional(bool, false)
    nat_egress = optional(bool, true)
  }))
  default  = null
  nullable = true
}

variable "extra_routes" {
  description = "Additional routes (CCN, Direct Connect, VPN, peering)."
  type = list(object({
    scope                  = string
    destination_cidr_block = string
    next_type              = string
    next_hub               = string
    description            = optional(string, "Managed by Terraform")
  }))
  default = []
}

# --- Cost / resilience ------------------------------------------------------

variable "nat_gateway_mode" {
  description = "\"single\" or \"per_az\". Null uses the environment default."
  type        = string
  default     = null
}

variable "nat_gateway_bandwidth" {
  description = "Outbound bandwidth cap per NAT gateway, in Mbps."
  type        = number
  default     = 100
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to CLS. Null uses the environment default."
  type        = bool
  default     = null
}

variable "enable_network_acls" {
  description = "Apply stateless tier ACLs. Null uses the environment default."
  type        = bool
  default     = null
}

variable "log_retention_days" {
  description = "CLS retention for flow, audit and event logs."
  type        = number
  default     = null
}

# --- Access control ---------------------------------------------------------

variable "admin_cidrs" {
  description = "Trusted operator networks (office, VPN, CI egress)."
  type        = list(string)
  default     = []
}

variable "public_ingress_cidrs" {
  description = "Sources allowed to reach the public load balancers."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "public_ingress_ports" {
  description = "Ports the public load balancer accepts."
  type        = list(string)
  default     = ["80", "443"]
}

variable "data_service_ports" {
  description = "Data tier ports opened to workloads, keyed by service name."
  type        = map(string)
  default = {
    mysql      = "3306"
    postgresql = "5432"
    redis      = "6379"
  }
}

variable "enable_bastion_security_group" {
  description = "Create the bastion security group."
  type        = bool
  default     = true
}

variable "extra_security_groups" {
  description = "Client-specific security groups merged into the baseline."
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

variable "restrict_egress" {
  description = "Restrict workload egress to the VPC plus DNS and HTTPS."
  type        = bool
  default     = false
}

# --- TKE --------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Kubernetes version to pin."
  type        = string
  default     = "1.30.0"
}

variable "tke_network_type" {
  description = "\"VPC-CNI\" or \"GR\"."
  type        = string
  default     = "VPC-CNI"
}

variable "tke_cluster_cidr" {
  description = "Pod CIDR for GlobalRouter mode."
  type        = string
  default     = "172.24.0.0/16"
}

variable "tke_service_cidr" {
  description = "ClusterIP service range."
  type        = string
  default     = "172.20.0.0/18"
}

variable "tke_cluster_level" {
  description = "Managed control plane size. Null uses the environment default."
  type        = string
  default     = null
}

variable "tke_enable_public_endpoint" {
  description = "Expose the Kubernetes API publicly. Null uses the environment default."
  type        = bool
  default     = null
}

variable "tke_max_pods_per_node" {
  description = "Maximum pods per node."
  type        = number
  default     = 64
}

variable "tke_addons" {
  description = "TKE addons to install."
  type = map(object({
    version    = optional(string)
    raw_values = optional(string)
  }))
  default = {}
}

variable "node_pools" {
  description = "Worker node pools."
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
  default  = null
  nullable = true
}

variable "node_ssh_key_ids" {
  description = "SSH key IDs for worker nodes. Empty disables SSH."
  type        = list(string)
  default     = []
}

variable "node_cam_role_name" {
  description = "CAM role bound to worker nodes."
  type        = string
  default     = null
}
