provider "tencentcloud" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [1]
    content {
      role_arn         = var.assume_role_arn
      session_name     = "terraform-bootstrap-${var.client}"
      session_duration = 3600
    }
  }
}

# COS bucket names are globally unique and must carry the account APPID as a
# suffix. Reading it here means the operator never has to look it up.
data "tencentcloud_user_info" "current" {}
