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
  # starts on local state and then adopts the bucket it just made:
  #
  #   1. terraform init && terraform apply        # local state, buckets created
  #   2. terraform output -raw self_backend_hcl > backend.hcl
  #   3. terraform init -backend-config=backend.hcl -migrate-state
  #
  # After step 3 this root is self-hosting like the others and terraform.tfstate
  # can be deleted. See README.md in this directory.
}
