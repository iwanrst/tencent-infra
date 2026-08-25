output "cluster_id" {
  description = "TKE cluster ID."
  value       = tencentcloud_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "TKE cluster name."
  value       = tencentcloud_kubernetes_cluster.this.cluster_name
}

output "kubernetes_version" {
  description = "Kubernetes version running on the control plane."
  value       = tencentcloud_kubernetes_cluster.this.cluster_version
}

output "private_endpoint" {
  description = "Private (intranet) API server address."
  value       = try(tencentcloud_kubernetes_cluster_endpoint.this.cluster_intranet_domain, null)
}

output "public_endpoint" {
  description = "Public API server address, null when the public endpoint is disabled."
  value       = var.enable_public_endpoint ? try(tencentcloud_kubernetes_cluster_endpoint.this.cluster_internet_domain, null) : null
}

output "kube_config" {
  description = "Kubeconfig for the private endpoint. Contains cluster credentials."
  value       = try(tencentcloud_kubernetes_cluster_endpoint.this.kube_config_intranet, null)
  sensitive   = true
}

output "node_pool_ids" {
  description = "Node pool IDs keyed by pool name."
  value       = { for k, p in tencentcloud_kubernetes_node_pool.this : k => p.id }
}

output "node_pool_autoscaling_group_ids" {
  description = "Underlying autoscaling group IDs keyed by pool name."
  value       = { for k, p in tencentcloud_kubernetes_node_pool.this : k => p.auto_scaling_group_id }
}

output "log_topic_ids" {
  description = "CLS topic IDs for audit and event logs."
  value = {
    audit = try(tencentcloud_cls_topic.audit[0].id, null)
    event = try(tencentcloud_cls_topic.event[0].id, null)
  }
}
