terraform {
  required_version = ">= 1.9.0"

  required_providers {
    tencentcloud = {
      source  = "tencentcloudstack/tencentcloud"
      version = ">= 1.81.0, < 2.0.0"
    }
  }
}
