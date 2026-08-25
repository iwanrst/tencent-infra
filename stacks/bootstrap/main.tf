###############################################################################
# Terraform state backend -- run once per client account.
#
# This root exists to solve the ordering problem: the client stacks declare `backend "cos"`,
# which must already exist before their first `terraform init`. Nothing else
# belongs here. Keep it boring and rarely touched.
###############################################################################

locals {
  app_id = data.tencentcloud_user_info.current.app_id

  suffix = var.bucket_name_suffix == "" ? "" : "-${var.bucket_name_suffix}"

  # COS requires the APPID as the final element of the bucket name.
  bucket_names = {
    for env, cfg in var.environments :
    env => "${var.client}-tfstate-${env}${local.suffix}-${local.app_id}"
  }

  state_prefixes = {
    for env, cfg in var.environments :
    env => coalesce(cfg.state_prefix, "platform/${env}")
  }

  tags = merge(
    {
      Client      = var.client
      ManagedBy   = "terraform"
      Module      = "bootstrap"
      Purpose     = "terraform-remote-state"
      DoNotDelete = "true"
    },
    var.extra_tags,
  )
}

resource "tencentcloud_cos_bucket" "state" {
  for_each = var.environments

  bucket = local.bucket_names[each.key]
  acl    = "private"

  # Non-negotiable. State is overwritten in place on every apply, so versioning
  # is the only thing standing between a bad apply and an unrecoverable stack.
  versioning_enable = true

  encryption_algorithm = var.kms_key_id == null ? "AES256" : "KMS"
  kms_id               = var.kms_key_id

  multi_az = coalesce(each.value.multi_az, false)

  # Refuse to delete a bucket that still holds state. `terraform destroy` here
  # should be an error, not a surprise.
  force_clean = false

  lifecycle_rules {
    id            = "expire-superseded-state"
    filter_prefix = ""

    # Prune superseded versions on a schedule rather than never: a busy stack
    # writes a new version on every apply and the bucket grows without bound.
    non_current_expiration {
      non_current_days = each.value.noncurrent_expiry_days
    }

    # Interrupted uploads are invisible in the console but still billed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  tags = merge(local.tags, {
    Name        = local.bucket_names[each.key]
    Environment = each.key
  })

  lifecycle {
    # Losing a state bucket means losing the record of every resource in that
    # environment. Removing this guard must be a deliberate, separate commit.
    prevent_destroy = true
  }
}

###############################################################################
# Least-privilege access policies
#
# One policy per environment, scoped to that bucket only. Attaching the staging
# policy to a CI role gives it no path to production state.
###############################################################################

locals {
  # qcs resource path for a COS bucket and everything under it.
  bucket_qcs = {
    for env, name in local.bucket_names :
    env => "qcs::cos:${var.region}:uid/${local.app_id}:${name}/*"
  }

  # Exactly what the COS backend does: read state, write state, and -- when
  # locking is on -- create and remove the .tflock object beside it.
  state_actions = concat(
    [
      "cos:GetObject",
      "cos:PutObject",
      "cos:HeadObject",
      "cos:ListParts",
    ],
    # Locking writes a .tflock object beside the state and removes it on
    # release, so unlocking needs delete. Without locking, nothing here should
    # ever delete an object.
    var.state_lock_enabled ? ["cos:DeleteObject"] : [],
  )
}

resource "tencentcloud_cam_policy" "state_access" {
  for_each = var.create_cam_policies ? var.environments : {}

  name        = "${var.client}-tfstate-${each.key}"
  description = "Least-privilege access to the ${each.key} Terraform state bucket. Managed by bootstrap/."

  document = jsonencode({
    version = "2.0"
    statement = [
      {
        effect   = "allow"
        action   = local.state_actions
        resource = [local.bucket_qcs[each.key]]
      },
      {
        # Listing is bucket-scoped, not object-scoped, so it needs its own
        # statement against the bucket resource itself.
        effect   = "allow"
        action   = ["cos:GetBucket", "cos:GetBucketObjectVersions"]
        resource = ["qcs::cos:${var.region}:uid/${local.app_id}:${local.bucket_names[each.key]}"]
      },
    ]
  })

  tags = merge(local.tags, { Environment = each.key })
}
