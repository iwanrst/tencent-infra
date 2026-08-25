###############################################################################
# Layer 4 -- TKE
###############################################################################

locals {
  # Pods draw IPs from the ENI tier under VPC-CNI. Spreading across every AZ
  # keeps pod scheduling from being bottlenecked on a single zone's free IPs.
  eni_subnet_ids = (
    var.tke_network_type == "VPC-CNI" && local.eni_cidr != null
    ? module.vpc.subnets_by_tier["eni"]
    : []
  )

  # The private API endpoint lands in the app tier's first subnet.
  private_endpoint_subnet_id = module.vpc.subnets_by_tier["app"][0]

  # Node security groups: the node group always, plus the pod group under
  # VPC-CNI so the ENIs attached to those nodes inherit pod policy.
  node_security_group_ids = compact([
    module.security_groups.security_group_ids["node"],
    try(module.security_groups.security_group_ids["pod"], null),
  ])

  node_pools = {
    for name, pool in var.node_pools : name => {
      subnet_ids         = module.vpc.subnets_by_tier[pool.subnet_tier]
      instance_types     = pool.instance_types
      min_size           = pool.min_size
      max_size           = pool.max_size
      desired_size       = pool.desired_size
      security_group_ids = local.node_security_group_ids

      system_disk_type = pool.system_disk_type
      system_disk_size = pool.system_disk_size

      # A dedicated data disk for the container runtime keeps image churn off
      # the root volume, where filling up takes the whole node down.
      data_disks = pool.data_disk_size > 0 ? [{
        disk_type             = "CLOUD_SSD"
        disk_size             = pool.data_disk_size
        delete_with_instance  = true
        encrypt               = true
        file_system           = "ext4"
        mount_target          = "/var/lib/containerd"
        auto_format_and_mount = true
      }] : []

      instance_charge_type = pool.spot ? "SPOTPAID" : "POSTPAID_BY_HOUR"
      spot                 = pool.spot
      spot_max_price       = "1"

      public_ip_assigned       = false
      enable_auto_scale        = pool.enable_auto_scale
      scaling_mode             = "classic"
      multi_zone_subnet_policy = "EQUALITY"

      labels          = pool.labels
      taints          = pool.taints
      desired_pod_num = null
      extra_args      = []
    }
  }
}

module "tke" {
  source = "../tke"

  name_prefix         = local.name_prefix
  cluster_description = "${var.client} ${var.environment} platform cluster"

  vpc_id             = module.vpc.vpc_id
  kubernetes_version = var.kubernetes_version

  network_type   = var.tke_network_type
  eni_subnet_ids = local.eni_subnet_ids
  cluster_cidr   = var.tke_network_type == "GR" ? var.tke_cluster_cidr : null
  service_cidr   = var.tke_service_cidr

  cluster_max_pod_num = var.tke_max_pods_per_node

  # Private endpoint always; public endpoint only where explicitly permitted,
  # and never without an allowlist -- the TKE module enforces that.
  enable_private_endpoint    = true
  private_endpoint_subnet_id = local.private_endpoint_subnet_id

  enable_public_endpoint            = local.enable_public_endpoint
  public_endpoint_allowed_cidrs     = var.admin_cidrs
  public_endpoint_security_group_id = local.enable_public_endpoint ? module.security_groups.security_group_ids["tke-api"] : null

  cluster_level              = local.cluster_level
  auto_upgrade_cluster_level = true
  deletion_protection        = local.defaults.deletion_protection

  enable_cluster_audit     = true
  enable_event_persistence = true
  enable_log_agent         = true
  log_retention_days       = local.log_retention_days

  node_pools         = local.node_pools
  node_ssh_key_ids   = var.node_ssh_key_ids
  node_cam_role_name = var.node_cam_role_name

  addons = var.tke_addons

  tags = local.tags

  depends_on = [module.network_acl]
}
