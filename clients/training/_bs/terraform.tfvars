###############################################################################
# training -- state backend bootstrap.
#
# Run once for this client, before clients/training/staging can be initialised.
###############################################################################

client = "training"
region = "ap-singapore"

extra_tags = {
  CostCenter = "training"
  Owner      = "platform-team"
}

# Only staging exists for now. Adding prod later is a new key here plus a new
# clients/training/prod directory -- the bucket is created on the next apply.
environments = {
  staging = {
    noncurrent_expiry_days = 30
  }
}

kms_key_id          = null
create_cam_policies = true
