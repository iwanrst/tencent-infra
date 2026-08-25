###############################################################################
# TKE managed cluster.
#
# The control plane is created bare: no `worker_config`, no inline endpoint
# config. Workers come from node pools (independently scalable, replaceable
# without touching the cluster) and endpoints come from a dedicated resource
# so API server exposure can be changed without a cluster diff.
###############################################################################

locals {
  is_vpc_cni = var.network_type == "VPC-CNI"

  # Node pools drive scaling; the cluster resource must not try to manage the
  # worker count or every autoscaler action shows up as Terraform drift.
  ignore_worker_drift = true
}

resource "tencentcloud_kubernetes_cluster" "this" {
  cluster_name = "${var.name_prefix}-tke"
  cluster_desc = var.cluster_description

  vpc_id              = var.vpc_id
  cluster_version     = var.kubernetes_version
  cluster_os          = var.cluster_os
  container_runtime   = var.container_runtime
  runtime_version     = var.runtime_version
  cluster_deploy_type = "MANAGED_CLUSTER"

  # Networking. VPC-CNI takes eni_subnet_ids and rejects cluster_cidr;
  # GlobalRouter is the mirror image.
  network_type   = var.network_type
  eni_subnet_ids = local.is_vpc_cni ? var.eni_subnet_ids : null
  cluster_cidr   = local.is_vpc_cni ? null : var.cluster_cidr
  service_cidr   = var.service_cidr

  cluster_max_pod_num     = var.cluster_max_pod_num
  cluster_max_service_num = var.cluster_max_service_num

  # Managed control plane sizing.
  cluster_level              = var.cluster_level
  auto_upgrade_cluster_level = var.auto_upgrade_cluster_level

  # Observability. Audit logs in particular are the only record of who did what
  # to the API server -- turning them off is not recoverable after the fact.
  cluster_audit {
    enabled                    = var.enable_cluster_audit
    delete_audit_log_and_topic = true
    log_set_id                 = var.enable_cluster_audit ? tencentcloud_cls_logset.tke[0].id : null
    topic_id                   = var.enable_cluster_audit ? tencentcloud_cls_topic.audit[0].id : null
  }

  event_persistence {
    enabled                    = var.enable_event_persistence
    delete_event_log_and_topic = true
    log_set_id                 = var.enable_event_persistence ? tencentcloud_cls_logset.tke[0].id : null
    topic_id                   = var.enable_event_persistence ? tencentcloud_cls_topic.event[0].id : null
  }

  log_agent {
    enabled = var.enable_log_agent
  }

  deletion_protection = var.deletion_protection

  tags = merge(var.tags, { Name = "${var.name_prefix}-tke" })

  lifecycle {
    ignore_changes = [
      # Node pools own the workers. Without this every autoscaler event is drift.
      worker_config,
      # TKE patches the control plane in place; only minor upgrades are ours.
      cluster_version,
    ]

    precondition {
      condition     = !local.is_vpc_cni || length(var.eni_subnet_ids) > 0
      error_message = "VPC-CNI clusters need at least one ENI subnet for pod IPs."
    }
  }
}

###############################################################################
# Cluster logging (audit + events)
###############################################################################

locals {
  needs_logset = var.enable_cluster_audit || var.enable_event_persistence
}

resource "tencentcloud_cls_logset" "tke" {
  count = local.needs_logset ? 1 : 0

  logset_name = "${var.name_prefix}-tke"
  tags        = merge(var.tags, { Name = "${var.name_prefix}-tke" })
}

resource "tencentcloud_cls_topic" "audit" {
  count = var.enable_cluster_audit ? 1 : 0

  logset_id       = tencentcloud_cls_logset.tke[0].id
  topic_name      = "${var.name_prefix}-tke-audit"
  period          = var.log_retention_days
  storage_type    = "hot"
  partition_count = 1
  auto_split      = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-tke-audit" })
}

resource "tencentcloud_cls_topic" "event" {
  count = var.enable_event_persistence ? 1 : 0

  logset_id       = tencentcloud_cls_logset.tke[0].id
  topic_name      = "${var.name_prefix}-tke-event"
  period          = var.log_retention_days
  storage_type    = "hot"
  partition_count = 1
  auto_split      = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-tke-event" })
}

###############################################################################
# API server endpoints
###############################################################################

resource "tencentcloud_kubernetes_cluster_endpoint" "this" {
  cluster_id = tencentcloud_kubernetes_cluster.this.id

  cluster_intranet           = var.enable_private_endpoint
  cluster_intranet_subnet_id = var.enable_private_endpoint ? var.private_endpoint_subnet_id : null

  cluster_internet                = var.enable_public_endpoint
  cluster_internet_security_group = var.enable_public_endpoint ? var.public_endpoint_security_group_id : null

  # Belt and braces: the security group above filters at the network layer, this
  # is TKE's own API-level allowlist. Both must permit the caller.
  managed_cluster_internet_security_policies = var.enable_public_endpoint ? var.public_endpoint_allowed_cidrs : null

  depends_on = [tencentcloud_kubernetes_node_pool.this]
}

###############################################################################
# Node pools
###############################################################################

resource "tencentcloud_kubernetes_node_pool" "this" {
  for_each = var.node_pools

  cluster_id = tencentcloud_kubernetes_cluster.this.id
  name       = "${var.name_prefix}-${each.key}"

  vpc_id     = var.vpc_id
  subnet_ids = each.value.subnet_ids

  min_size         = each.value.min_size
  max_size         = each.value.max_size
  desired_capacity = coalesce(each.value.desired_size, each.value.min_size)

  enable_auto_scale        = each.value.enable_auto_scale
  scaling_mode             = each.value.scaling_mode
  multi_zone_subnet_policy = each.value.multi_zone_subnet_policy
  retry_policy             = "INCREMENTAL_INTERVALS"

  node_os              = var.cluster_os
  delete_keep_instance = var.node_delete_keep_instance

  auto_scaling_config {
    # Ordered fallback list: if the first type is sold out in a zone the ASG
    # walks down the list instead of failing the scale-out.
    instance_type         = each.value.instance_types[0]
    backup_instance_types = slice(each.value.instance_types, 1, length(each.value.instance_types))

    system_disk_type = each.value.system_disk_type
    system_disk_size = each.value.system_disk_size

    dynamic "data_disk" {
      for_each = each.value.data_disks
      content {
        disk_type            = data_disk.value.disk_type
        disk_size            = data_disk.value.disk_size
        delete_with_instance = data_disk.value.delete_with_instance
        encrypt              = data_disk.value.encrypt
      }
    }

    instance_charge_type = each.value.instance_charge_type
    spot_instance_type   = each.value.spot ? "one-time" : null
    spot_max_price       = each.value.spot ? each.value.spot_max_price : null

    # Workers live in private subnets and egress through the NAT gateway.
    # A public IP on a node is an unnecessary inbound attack surface.
    public_ip_assigned = each.value.public_ip_assigned

    orderly_security_group_ids = each.value.security_group_ids

    key_ids       = var.node_ssh_key_ids
    cam_role_name = var.node_cam_role_name

    enhanced_security_service = true
    enhanced_monitor_service  = true
  }

  node_config {
    docker_graph_path = "/var/lib/containerd"
    desired_pod_num   = each.value.desired_pod_num
    extra_args        = each.value.extra_args

    dynamic "data_disk" {
      for_each = [for d in each.value.data_disks : d if d.auto_format_and_mount]
      content {
        disk_type             = data_disk.value.disk_type
        disk_size             = data_disk.value.disk_size
        file_system           = data_disk.value.file_system
        mount_target          = data_disk.value.mount_target
        auto_format_and_mount = true
        disk_partition        = null
      }
    }
  }

  labels = merge(each.value.labels, {
    "node-pool"                           = each.key
    "topology.tke.cloud.tencent.com/pool" = each.key
  })

  dynamic "taints" {
    for_each = each.value.taints
    content {
      key    = taints.value.key
      value  = taints.value.value
      effect = taints.value.effect
    }
  }

  tags = merge(var.tags, {
    Name     = "${var.name_prefix}-${each.key}"
    NodePool = each.key
  })

  lifecycle {
    # The cluster autoscaler moves desired_capacity at runtime. Terraform sets
    # the initial value and then stays out of the way.
    ignore_changes = [desired_capacity]
  }
}

###############################################################################
# Addons
###############################################################################

resource "tencentcloud_kubernetes_addon" "this" {
  for_each = var.addons

  cluster_id    = tencentcloud_kubernetes_cluster.this.id
  addon_name    = each.key
  addon_version = each.value.version

  raw_values = each.value.raw_values

  depends_on = [tencentcloud_kubernetes_node_pool.this]
}
