###############################################################################
# Credentials are never committed. Export them, or let the provider pick up an
# instance / CI role:
#
#   export TENCENTCLOUD_SECRET_ID=...
#   export TENCENTCLOUD_SECRET_KEY=...
#   export TENCENTCLOUD_REGION=...        # optional, var.region wins
#
# For multi-account setups, set assume_role_arn to have Terraform hop into the
# client's account with a scoped role instead of using long-lived root keys.
###############################################################################

provider "tencentcloud" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [1]
    content {
      role_arn         = var.assume_role_arn
      session_name     = "terraform-${var.client}-${var.environment}"
      session_duration = 3600
    }
  }
}
