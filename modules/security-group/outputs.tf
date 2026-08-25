output "security_group_ids" {
  description = "Security group IDs keyed by short name."
  value       = { for k, sg in tencentcloud_security_group.this : k => sg.id }
}

output "security_group_names" {
  description = "Fully qualified security group names keyed by short name."
  value       = { for k, sg in tencentcloud_security_group.this : k => sg.name }
}
