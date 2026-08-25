###############################################################################
# ACME -- state backend bootstrap.
#
# Run once per client account, before anything in envs/ can be initialised.
###############################################################################

client = "acme"
region = "ap-singapore"

extra_tags = {
  CostCenter = "platform"
  Owner      = "platform-team"
}

environments = {
  staging = {
    noncurrent_expiry_days = 30
  }

  prod = {
    # A year of state history, replicated across AZs. This bucket is the record
    # of every production resource that exists.
    noncurrent_expiry_days = 365
    multi_az               = true
  }
}

# COS-managed AES256. Set a CMK id here if the client must control the key.
kms_key_id = null

create_cam_policies = true
