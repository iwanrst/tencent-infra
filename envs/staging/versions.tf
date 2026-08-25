terraform {
  required_version = ">= 1.9.0"

  required_providers {
    tencentcloud = {
      source  = "tencentcloudstack/tencentcloud"
      version = "~> 1.81"
    }
  }

  # Remote state on COS. Bucket, region and prefix are environment specific and
  # supplied at init time so this file stays identical across environments:
  #
  #   terraform init -backend-config=backend.hcl
  #
  backend "cos" {}
}
