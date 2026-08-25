output "acl_ids" {
  description = "Network ACL IDs keyed by tier name."
  value       = { for k, a in tencentcloud_vpc_acl.this : k => a.id }
}

output "rendered_rules" {
  description = "Rules as sent to the API. Useful for reviewing segmentation in a plan diff."
  value       = local.rule_string
}
