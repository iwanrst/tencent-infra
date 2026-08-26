variable "name_prefix" {
  description = "Prefix applied to the cluster and its node pools."
  type        = string
}

variable "cluster_description" {
  description = "Free-text description shown in the console."
  type        = string
  default     = "Managed by Terraform"
}

variable "vpc_id" {
  description = "VPC hosting the cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. \"1.30.0\". Pin it: leaving it unset lets Tencent pick, which makes plans non-deterministic."
  type        = string
}

variable "cluster_os" {
  description = "Node operating system image."
  type        = string
  default     = "tlinux3.1x86_64"
}

variable "container_runtime" {
  description = "Container runtime. containerd is the only sensible choice on modern Kubernetes."
  type        = string
  default     = "containerd"

  validation {
    condition     = contains(["containerd", "docker"], var.container_runtime)
    error_message = "container_runtime must be containerd or docker."
  }
}

variable "runtime_version" {
  description = "Container runtime version. Leave null to let TKE choose a compatible default."
  type        = string
  default     = null
}

###############################################################################
# Networking
###############################################################################

variable "network_type" {
  description = <<-EOT
    "VPC-CNI" - pods get real VPC IPs from dedicated ENI subnets. Pods are
                first-class network citizens: security groups apply to them,
                CLB targets them directly, and on-prem can route to them.
                Costs VPC address space. This is the production default.
    "GR"      - GlobalRouter overlay. Pods live in `cluster_cidr`, outside the
                VPC address plan. Cheaper on IPs, but pods are not directly
                addressable and cannot carry their own security groups.

    This cannot be changed after creation -- it forces cluster replacement.
  EOT
  type        = string
  default     = "VPC-CNI"

  validation {
    condition     = contains(["VPC-CNI", "GR"], var.network_type)
    error_message = "network_type must be VPC-CNI or GR."
  }
}

variable "eni_subnet_ids" {
  description = "Subnets pods draw IPs from. Required for VPC-CNI, ignored for GR."
  type        = list(string)
  default     = []

  validation {
    condition     = var.network_type != "VPC-CNI" || length(var.eni_subnet_ids) > 0
    error_message = "VPC-CNI requires at least one ENI subnet."
  }
}

variable "cluster_cidr" {
  description = "Pod CIDR for GlobalRouter mode. Must not overlap the VPC or any peered network. Ignored for VPC-CNI."
  type        = string
  default     = null

  validation {
    condition     = var.network_type != "GR" || var.cluster_cidr != null
    error_message = "GlobalRouter mode requires cluster_cidr."
  }
}

variable "service_cidr" {
  description = "ClusterIP service range. Must not overlap the VPC, the pod CIDR, or any peered network."
  type        = string
  default     = "172.20.0.0/18"

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "service_cidr must be a valid IPv4 CIDR."
  }
}

variable "cluster_max_pod_num" {
  description = "Maximum pods per node."
  type        = number
  default     = 64
}

variable "cluster_max_service_num" {
  description = "Maximum number of services in the cluster."
  type        = number
  default     = 1024
}

###############################################################################
# Control plane exposure
###############################################################################

variable "enable_private_endpoint" {
  description = "Expose the API server on a private VPC address. Keep this on."
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "Subnet hosting the private API server endpoint. Required when enable_private_endpoint is true."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_private_endpoint || var.private_endpoint_subnet_id != null
    error_message = "enable_private_endpoint requires private_endpoint_subnet_id."
  }
}

variable "enable_public_endpoint" {
  description = "Expose the API server on the public internet. Leave false in production and reach the cluster over VPN/CCN/bastion."
  type        = bool
  default     = false
}

variable "public_endpoint_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the public API server. Enforcement happens through
    `public_endpoint_security_group_id`, which the caller builds from this same
    list; this variable exists to make the guard below possible, so a public
    endpoint can never be enabled without someone naming who may reach it.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_public_endpoint || length(var.public_endpoint_allowed_cidrs) > 0
    error_message = "enable_public_endpoint requires an explicit allowlist in public_endpoint_allowed_cidrs."
  }
}

variable "public_endpoint_security_group_id" {
  description = "Security group applied to the public API server endpoint. Required when the public endpoint is enabled."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_public_endpoint || var.public_endpoint_security_group_id != null
    error_message = "enable_public_endpoint requires public_endpoint_security_group_id."
  }
}

###############################################################################
# Managed cluster sizing / lifecycle
###############################################################################

variable "cluster_level" {
  description = "Managed control plane size (L5, L20, L50, L100, L200, L500). Scale with node and pod count."
  type        = string
  default     = "L20"

  validation {
    condition     = can(regex("^L(5|20|50|100|200|500|1000|3000|5000)$", var.cluster_level))
    error_message = "cluster_level must look like L5, L20, L50, L100, ..."
  }
}

variable "auto_upgrade_cluster_level" {
  description = "Let TKE grow the control plane automatically as the cluster grows."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Block cluster deletion through the API. Always true in production."
  type        = bool
  default     = false
}

variable "enable_cluster_audit" {
  description = "Ship Kubernetes API audit logs to CLS."
  type        = bool
  default     = true
}

variable "enable_event_persistence" {
  description = "Persist Kubernetes events to CLS. Events expire after an hour otherwise."
  type        = bool
  default     = true
}

variable "enable_log_agent" {
  description = "Install the CLS log collection agent on nodes."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the audit / event CLS topics, in days."
  type        = number
  default     = 30
}

###############################################################################
# Node pools
###############################################################################

variable "node_pools" {
  description = <<-EOT
    Worker node pools, keyed by name. Separate pools let you isolate workload
    classes (system, general, spot, gpu) with their own scaling, labels and
    taints.

      subnet_ids     - subnets the ASG may launch into; use the private app tier
      instance_types - ordered preference list. Multiple types materially improve
                       the odds of a successful scale-out when a type is sold out
      min_size / max_size / desired_size - autoscaler bounds
      spot           - use spot instances; pair with taints so only tolerant
                       workloads land there
  EOT
  type = map(object({
    subnet_ids         = list(string)
    instance_types     = list(string)
    min_size           = number
    max_size           = number
    desired_size       = optional(number)
    security_group_ids = optional(list(string), [])

    system_disk_type = optional(string, "CLOUD_SSD")
    system_disk_size = optional(number, 50)
    data_disks = optional(list(object({
      disk_type             = optional(string, "CLOUD_SSD")
      disk_size             = optional(number, 100)
      delete_with_instance  = optional(bool, true)
      encrypt               = optional(bool, true)
      file_system           = optional(string, "ext4")
      mount_target          = optional(string, "/var/lib/containerd")
      auto_format_and_mount = optional(bool, true)
    })), [])

    instance_charge_type = optional(string, "POSTPAID_BY_HOUR")
    spot                 = optional(bool, false)
    spot_max_price       = optional(string, "1")

    public_ip_assigned       = optional(bool, false)
    enable_auto_scale        = optional(bool, true)
    scaling_mode             = optional(string, "classic")
    multi_zone_subnet_policy = optional(string, "EQUALITY")

    labels = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])

    desired_pod_num = optional(number)
    extra_args      = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, p in var.node_pools : p.min_size <= p.max_size
    ])
    error_message = "Every node pool needs min_size <= max_size."
  }

  validation {
    condition = alltrue([
      for k, p in var.node_pools :
      p.desired_size == null || (p.desired_size >= p.min_size && p.desired_size <= p.max_size)
    ])
    error_message = "desired_size must sit between min_size and max_size."
  }

  validation {
    condition = alltrue(flatten([
      for k, p in var.node_pools : [
        for t in p.taints : contains(["NoSchedule", "PreferNoSchedule", "NoExecute"], t.effect)
      ]
    ]))
    error_message = "Taint effect must be NoSchedule, PreferNoSchedule or NoExecute."
  }

  validation {
    condition     = alltrue([for k, p in var.node_pools : length(p.instance_types) > 0])
    error_message = "Every node pool needs at least one instance type."
  }
}

variable "node_ssh_key_ids" {
  description = "Tencent Cloud SSH key IDs injected into every node. Prefer keys over passwords; leave empty to disable SSH login entirely."
  type        = list(string)
  default     = []
}

variable "node_cam_role_name" {
  description = "CAM role bound to worker nodes. Grant it the narrowest policy the workload needs -- never a full-access role."
  type        = string
  default     = null
}

variable "node_delete_keep_instance" {
  description = "Keep CVM instances when a node pool is destroyed. Should be false so teardown is clean."
  type        = bool
  default     = false
}

###############################################################################
# Addons
###############################################################################

variable "addons" {
  description = <<-EOT
    TKE addons keyed by addon name (e.g. cbs, tcr, cls).

      version    - pin it; leaving it unset lets TKE pick, which makes the plan
                   non-deterministic and can upgrade the addon under you.
      raw_values - Helm values as a JSON string, e.g.
                   jsonencode({ controller = { replicas = 2 } }).
                   Null installs the addon with its defaults.
  EOT
  type = map(object({
    version    = optional(string)
    raw_values = optional(string)
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to the cluster and node pools."
  type        = map(string)
  default     = {}
}
