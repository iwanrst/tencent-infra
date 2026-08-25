###############################################################################
# Layer 2 -- network segmentation (stateless subnet ACLs)
#
# Security groups are the primary control. These ACLs are the second layer:
# they sit on the subnet, so they hold even if an instance is launched with the
# wrong security group. They encode invariants, not application policy:
#
#   * the data tier is unreachable from the internet, in either direction
#   * the app and pod tiers accept east-west traffic only from inside the VPC
#   * the public tier is the only place internet traffic terminates
#
# Disabled outside prod by default -- stateless rules make ad-hoc debugging
# noticeably slower, and non-prod trades that for iteration speed.
###############################################################################

locals {
  # Data-tier ingress is the cross product of (workload CIDR x service port),
  # closed off with an explicit default deny.
  data_tier_ingress = concat(
    flatten([
      for cidr in local.workload_cidrs : [
        for name, port in var.data_service_ports : {
          action      = "ACCEPT"
          cidr_block  = cidr
          protocol    = "TCP"
          port        = port
          description = "${name} from workload tier"
        }
      ]
    ]),
    [{
      action      = "DROP"
      cidr_block  = "0.0.0.0/0"
      protocol    = "ALL"
      port        = "ALL"
      description = "Default deny into the data tier"
    }],
  )

  acls = !local.enable_network_acls ? {} : merge(
    {
      # Internet-facing: load balancers, NAT gateways, bastion. Deliberately
      # open at the ACL layer -- security groups do the filtering here.
      public = {
        subnet_ids             = module.vpc.subnets_by_tier["public"]
        ephemeral_return_cidrs = ["0.0.0.0/0"]
        ingress = [
          { action = "ACCEPT", cidr_block = "0.0.0.0/0", description = "Internet ingress terminates in the public tier" },
        ]
        egress = [
          { action = "ACCEPT", cidr_block = "0.0.0.0/0", description = "Unrestricted egress" },
        ]
      }

      # Worker nodes.
      app = {
        subnet_ids = module.vpc.subnets_by_tier["app"]
        # Nodes pull images and call external APIs through NAT, so return
        # traffic can legitimately come from anywhere.
        ephemeral_return_cidrs = ["0.0.0.0/0"]
        ingress = [
          { action = "ACCEPT", cidr_block = var.vpc_cidr, description = "East-west traffic inside the VPC" },
          { action = "DROP", cidr_block = "0.0.0.0/0", description = "No direct inbound from the internet" },
        ]
        egress = [
          { action = "ACCEPT", cidr_block = "0.0.0.0/0", description = "Outbound via NAT" },
        ]
      }

      # Databases and caches. The tier already has no NAT route; the ACL makes
      # that isolation explicit instead of leaving it implicit in routing.
      data = {
        subnet_ids = module.vpc.subnets_by_tier["data"]
        # This tier has no internet route, so return traffic can only ever come
        # from inside the VPC. Scoping it here keeps the high ports closed.
        ephemeral_return_cidrs = [var.vpc_cidr]
        ingress                = local.data_tier_ingress
        egress = [
          { action = "ACCEPT", cidr_block = var.vpc_cidr, description = "Replication and responses inside the VPC" },
          { action = "DROP", cidr_block = "0.0.0.0/0", description = "The data tier never reaches the internet" },
        ]
      }
    },

    # Pod subnets only exist under VPC-CNI.
    local.eni_cidr == null ? {} : {
      eni = {
        subnet_ids             = module.vpc.subnets_by_tier["eni"]
        ephemeral_return_cidrs = ["0.0.0.0/0"]
        ingress = [
          { action = "ACCEPT", cidr_block = var.vpc_cidr, description = "Pod-to-pod and node-to-pod traffic" },
          { action = "DROP", cidr_block = "0.0.0.0/0", description = "No direct inbound to pods from the internet" },
        ]
        egress = [
          { action = "ACCEPT", cidr_block = "0.0.0.0/0", description = "Pod egress via NAT" },
        ]
      }
    },
  )
}

module "network_acl" {
  source = "../network-acl"

  name_prefix = local.name_prefix
  vpc_id      = module.vpc.vpc_id
  acls        = local.acls
  tags        = local.tags
}
