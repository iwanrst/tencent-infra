###############################################################################
# Generated backend configuration.
#
# The bucket name embeds the account APPID, which the operator would otherwise
# have to look up and paste into each environment by hand. Generating the files
# makes that impossible to get wrong, and any change shows up as a normal diff
# in clients/<client>/<env>/backend.hcl at review time.
#
# These files are inputs to `terraform init`, not to `terraform plan`, so
# writing them from Terraform does not create a cycle: the stacks read them long
# after bootstrap has finished.
###############################################################################

resource "local_file" "env_backend" {
  for_each = var.write_backend_files ? var.environments : {}

  filename        = "${path.module}/../${each.key}/backend.hcl"
  content         = local.backend_hcl[each.key]
  file_permission = "0644"
}
