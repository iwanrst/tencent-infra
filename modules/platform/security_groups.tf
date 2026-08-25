###############################################################################
# Layer 3 -- security groups (stateful, the primary control)
#
# The baseline expresses the intended traffic graph by *group reference*, not
# by address:
#
#   internet --> lb --> node --> pod --> data
#   admin    --> bastion --> node
#
# Referencing groups instead of CIDRs means the policy survives any address
# plan change, and reads as an architecture diagram in code.
###############################################################################

locals {
  # Egress policy. Allow-all is the pragmatic default; restrict_egress swaps it
  # for VPC-only plus DNS and HTTPS, which is what you want once the workload's
  # outbound dependencies are actually known.
  egress_open = [
    { action = "ACCEPT", protocol = "ALL", port = "ALL", cidr_block = "0.0.0.0/0", description = "Unrestricted egress" },
  ]

  egress_restricted = [
    { action = "ACCEPT", protocol = "ALL", port = "ALL", cidr_block = var.vpc_cidr, description = "East-west inside the VPC" },
    { action = "ACCEPT", protocol = "TCP", port = "443", cidr_block = "0.0.0.0/0", description = "HTTPS to the internet (registries, APIs)" },
    { action = "ACCEPT", protocol = "UDP", port = "53", cidr_block = "0.0.0.0/0", description = "DNS" },
    { action = "ACCEPT", protocol = "TCP", port = "53", cidr_block = "0.0.0.0/0", description = "DNS over TCP" },
    { action = "DROP", protocol = "ALL", port = "ALL", cidr_block = "0.0.0.0/0", description = "Default deny egress" },
  ]

  workload_egress = var.restrict_egress ? local.egress_restricted : local.egress_open

  ###############################################################################
  # Baseline groups
  ###############################################################################

  # public_ingress_cidrs may hold several ranges, so build the cross product.
  lb_ingress = flatten([
    for cidr in var.public_ingress_cidrs : [
      for port in var.public_ingress_ports : {
        action      = "ACCEPT"
        protocol    = "TCP"
        port        = port
        cidr_block  = cidr
        description = "Public ingress on ${port}"
      }
    ]
  ])

  bastion_ingress = [
    for cidr in var.admin_cidrs : {
      action      = "ACCEPT"
      protocol    = "TCP"
      port        = "22"
      cidr_block  = cidr
      description = "SSH from administrative network"
    }
  ]

  # TKE health checks and NodePort traffic arrive from the CLB address range.
  # 10.0.0.0/8-scoped: the CLB probe range Tencent documents is 10.0.0.0/8 plus
  # the VPC itself, and the ACLs already keep the internet out of this tier.
  node_ingress = concat(
    [
      { action = "ACCEPT", protocol = "ALL", port = "ALL", self = true, description = "Node-to-node (kubelet, CNI, service mesh)" },
      { action = "ACCEPT", protocol = "TCP", port = "30000-32767", source_security_group = "lb", description = "NodePort traffic from load balancers" },
      { action = "ACCEPT", protocol = "TCP", port = "30000-32767", cidr_block = "10.0.0.0/8", description = "CLB health checks" },
      { action = "ACCEPT", protocol = "ALL", port = "ALL", cidr_block = var.vpc_cidr, description = "In-VPC control traffic (kubelet, metrics-server, webhooks)" },
    ],
    var.enable_bastion_security_group ? [
      { action = "ACCEPT", protocol = "TCP", port = "22", source_security_group = "bastion", description = "SSH from the bastion only" },
    ] : [],
    local.eni_cidr == null ? [] : [
      { action = "ACCEPT", protocol = "ALL", port = "ALL", source_security_group = "pod", description = "Pod-to-node traffic" },
    ],
  )

  pod_ingress = [
    { action = "ACCEPT", protocol = "ALL", port = "ALL", self = true, description = "Pod-to-pod" },
    { action = "ACCEPT", protocol = "ALL", port = "ALL", source_security_group = "node", description = "Node-to-pod (kubelet probes, DNS)" },
    { action = "ACCEPT", protocol = "ALL", port = "ALL", source_security_group = "lb", description = "Direct CLB-to-pod targeting" },
  ]

  data_ingress = concat(
    flatten([
      for name, port in var.data_service_ports : concat(
        [{
          action                = "ACCEPT"
          protocol              = "TCP"
          port                  = port
          source_security_group = "node"
          description           = "${name} from worker nodes"
        }],
        local.eni_cidr == null ? [] : [{
          action                = "ACCEPT"
          protocol              = "TCP"
          port                  = port
          source_security_group = "pod"
          description           = "${name} from pods"
        }],
        var.enable_bastion_security_group ? [{
          action                = "ACCEPT"
          protocol              = "TCP"
          port                  = port
          source_security_group = "bastion"
          description           = "${name} from the bastion for operator access"
        }] : [],
      )
    ]),
    [{ action = "ACCEPT", protocol = "ALL", port = "ALL", self = true, description = "Cluster replication between data nodes" }],
  )

  # Guards the public Kubernetes API endpoint when it is enabled at all.
  api_ingress = [
    for cidr in var.admin_cidrs : {
      action      = "ACCEPT"
      protocol    = "TCP"
      port        = "443"
      cidr_block  = cidr
      description = "Kubernetes API from administrative network"
    }
  ]

  baseline_security_groups = merge(
    {
      lb = {
        description = "Public load balancers -- the only internet-facing entry point"
        ingress     = local.lb_ingress
        egress      = local.egress_open
      }

      node = {
        description = "TKE worker nodes"
        ingress     = local.node_ingress
        egress      = local.workload_egress
      }

      data = {
        description = "Databases, caches and other stateful services"
        ingress     = local.data_ingress
        # The data tier has no NAT route; egress stays inside the VPC.
        egress = [
          { action = "ACCEPT", protocol = "ALL", port = "ALL", cidr_block = var.vpc_cidr, description = "East-west inside the VPC" },
          { action = "DROP", protocol = "ALL", port = "ALL", cidr_block = "0.0.0.0/0", description = "No internet egress from the data tier" },
        ]
      }
    },

    var.enable_bastion_security_group ? {
      bastion = {
        description = "Jump host -- the only SSH entry point into the VPC"
        ingress     = local.bastion_ingress
        egress      = local.egress_open
      }
    } : {},

    local.eni_cidr == null ? {} : {
      pod = {
        description = "VPC-CNI pod ENIs"
        ingress     = local.pod_ingress
        egress      = local.workload_egress
      }
    },

    local.enable_public_endpoint ? {
      tke-api = {
        description = "Public Kubernetes API server endpoint"
        ingress     = local.api_ingress
        egress      = local.egress_open
      }
    } : {},
  )
}

module "security_groups" {
  source = "../security-group"

  name_prefix     = local.name_prefix
  security_groups = merge(local.baseline_security_groups, var.extra_security_groups)
  tags            = local.tags
}
