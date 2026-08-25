variable "client" {
  description = "Client / organisation slug. First element of every bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}$", var.client))
    error_message = "client must be lowercase alphanumeric with dashes, 2-21 chars."
  }
}

variable "region" {
  description = "Region the state buckets live in. Usually the same region as the workloads."
  type        = string
}

variable "assume_role_arn" {
  description = "CAM role to assume in the target account. Null uses the caller's own credentials."
  type        = string
  default     = null
}

variable "environments" {
  description = <<-EOT
    Environments to create a state bucket for. One bucket per environment, never
    one shared bucket with per-environment prefixes: a credential scoped to
    staging must not be able to read or corrupt production state, and bucket-level
    separation is the only boundary COS policies can express cleanly.

      state_prefix           - key prefix inside the bucket, matches the sibling directory name
      noncurrent_expiry_days - how long superseded state versions are retained
      multi_az               - replicate across AZs within the region
  EOT
  type = map(object({
    state_prefix           = optional(string)
    noncurrent_expiry_days = optional(number, 90)
    multi_az               = optional(bool)
  }))
  default = {
    staging = { noncurrent_expiry_days = 30 }
    prod    = { noncurrent_expiry_days = 365, multi_az = true }
  }

  nullable = false

  validation {
    condition     = length(var.environments) > 0
    error_message = "At least one environment is required."
  }

  validation {
    condition = alltrue([
      for k, e in var.environments : e.noncurrent_expiry_days >= 7
    ])
    error_message = "Retain superseded state versions for at least 7 days -- they are the only way back from a bad apply."
  }
}

variable "bucket_name_suffix" {
  description = "Optional discriminator appended to bucket names, for when a name is already taken globally."
  type        = string
  default     = ""
}

variable "kms_key_id" {
  description = <<-EOT
    KMS key for server-side encryption. Null uses COS-managed AES256, which is
    fine for most cases. Supply a CMK when the client needs to control the key
    or prove key rotation for an audit.
  EOT
  type        = string
  default     = null
}

variable "create_cam_policies" {
  description = <<-EOT
    Create one least-privilege CAM policy per environment granting exactly the
    COS actions the Terraform backend needs on that bucket, and nothing else.
    Attach these to your CI role rather than handing out broad COS access.
  EOT
  type        = bool
  default     = true
}

variable "state_lock_enabled" {
  description = <<-EOT
    Whether the COS backend's state locking will be used. Locking writes and
    deletes a .tflock object next to the state, so the generated CAM policy has
    to allow it. Leave true unless you have a specific reason.
  EOT
  type        = bool
  default     = true
}

variable "extra_tags" {
  description = "Tags merged onto every bucket."
  type        = map(string)
  default     = {}
}

variable "self_state_environment" {
  description = <<-EOT
    Which environment's bucket holds this bootstrap root's own state once it
    adopts a remote backend. Defaults to "prod" when present, otherwise the
    first environment alphabetically -- bootstrap state should sit in the most
    protected bucket, since it is what proves the others exist.
  EOT
  type        = string
  default     = null
}

variable "write_backend_files" {
  description = <<-EOT
    Write the generated backend config to the sibling clients/<client>/<env>/backend.hcl. Keeps the
    bucket name and APPID from drifting out of sync with reality.

    Set false when the environments live in a separate repository, and copy the
    `backend_hcl` output across instead.
  EOT
  type        = bool
  default     = true
}
