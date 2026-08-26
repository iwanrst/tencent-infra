terraform {
  required_version = ">= 1.9.0"

  required_providers {
    tencentcloud = {
      source  = "tencentcloudstack/tencentcloud"
      version = "~> 1.81"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # No backend block on purpose.
  #
  # This root creates the buckets that every other root stores its state in, so
  # on the very first run there is nowhere remote to put its own state. It
  # starts on local state and then adopts the bucket it just made.
  #
  # Adopting needs a backend block to migrate *into*, and this file is shared by
  # every client, so the block cannot live here -- adding it would break any
  # client that has not adopted yet. `make bootstrap-adopt` writes a per-client
  # backend.tf next to that client's terraform.tfvars instead. A second
  # `terraform` block holding only a backend is valid and merges with this one.
  #
  # Never delete the local terraform.tfstate until `terraform state list` reads
  # the remote state back. `-backend-config` against a config with no backend
  # block is a no-op that only emits a warning.
  #
  # See README.md in this directory.
}
