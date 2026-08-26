# bootstrap

Creates the COS buckets that hold Terraform state for every environment.

Run this **once per client**, before that client's stacks can be
initialised. After that it is touched only when adding an environment or
changing retention.

## Why it is a separate root

The client stacks under `clients/<client>/` all declare `backend "cos"`. That bucket has to
exist before their first `terraform init` — a root cannot create the bucket it
stores its own state in. Bootstrap breaks the cycle: it starts on **local
state**, creates the buckets, and then adopts one of them for itself.

## What it creates

| Resource | Per | Notes |
|---|---|---|
| COS bucket | environment | Versioned, encrypted, private, `prevent_destroy` |
| Lifecycle rule | bucket | Expires superseded versions; aborts stale multipart uploads |
| CAM policy | environment | Least-privilege state access, scoped to that one bucket |
| `backend.hcl` | environment | Written into `clients/<client>/<env>/` with the real bucket name |

One bucket **per environment**, not one shared bucket with prefixes: a
credential scoped to staging must have no path to production state, and the
bucket is the only boundary a COS policy can express cleanly.

## Permissions the operator needs

The sub-account running Terraform needs, at minimum:

| Policy | For | Needed from |
|---|---|---|
| `QcloudCOSFullAccess` | creating the bucket, reading/writing state | bootstrap |
| `QcloudCAMFullAccess` | creating the per-bucket state policies | bootstrap |
| **tag `CreateTag` / `DeleteTag` / `DescribeTags`** | **state locking** | bootstrap |
| `QcloudVPCFullAccess` | VPC, subnets, route tables, NAT gateways, EIPs | networking |
| **`QcloudCVMFullAccess`** | **security groups, and later the worker nodes** | networking |
| `QcloudTKEFullAccess` | the cluster and its node pools | `enable_tke = true` |
| `QcloudCLSFullAccess` | flow logs, cluster audit and event logs | prod / TKE |

Two of these are counter-intuitive and account for most first-run failures.

**Security groups are CVM resources, not VPC ones.** Creating one calls
`cvm:CreateSecurityGroup`, so `QcloudVPCFullAccess` does not cover it and
read-only CVM access is not enough. Symptom: the VPC, subnets and route tables
all create successfully, then every security group fails with
`UnauthorizedOperation ... (cvm:CreateSecurityGroup)`.

**The COS backend locks in the tag service**, not with a file beside the state.
It uses the tag key `tencentcloud-terraform-lock`, and no `Qcloud*FullAccess`
policy grants tag actions. Symptom: `Error acquiring the state lock ...
tag:CreateTag ... has no permission`. Convenient fix: once bootstrap has run,
attach the `<client>-tfstate-<env>` policy it generated to the same sub-account
— that policy already carries the three verbs. Until then, `-lock=false` gets a
one-off command through.

## First run

```bash
export TENCENTCLOUD_SECRET_ID=...
export TENCENTCLOUD_SECRET_KEY=...

# edit clients/<client>/bootstrap/terraform.tfvars: client, region, environments
make bootstrap CLIENT=training
```

This writes `clients/training/staging/backend.hcl` with the real bucket name — the account APPID is read from the API, so it never has to
be looked up by hand. Commit the result.

Then bring each environment up:

```bash
make init CLIENT=training ENV=staging && make plan CLIENT=training ENV=staging
```

## Second step: stop depending on a local state file

Bootstrap has now created a bucket it can live in. Move its own state there:

```bash
make bootstrap-adopt CLIENT=training
```

Its state lands under the `bootstrap/` prefix of the production bucket. Skip
this and `clients/<client>/bootstrap/terraform.tfstate` stays on one laptop — which is exactly
the failure mode this repo exists to avoid.

The target writes a small `backend.tf` into that client's directory first. It
has to: this root deliberately declares no backend so the first run can use
local state, and `-migrate-state` needs a backend block to migrate *into*.
Pointing `-backend-config` at a config with no backend block does nothing and
only prints a warning — so the local state file is kept until
`terraform state list` reads the remote state back. Commit the generated
`backend.tf` along with `backend.hcl`.

### If the local state was lost before it migrated

The resources still exist; only Terraform's record of them is gone. Recreate it
by importing, rather than re-running `bootstrap`, which would fail on names
that already exist:

```bash
cd clients/<client>/bootstrap
terraform init -backend-config=backend.hcl -reconfigure
terraform import 'tencentcloud_cos_bucket.state["staging"]'      <bucket-name>
terraform import 'tencentcloud_cam_policy.state_access["staging"]' <policy-id>
terraform plan   # expect only local_file to be re-created
```

`local_file.env_backend` needs no import — the next apply rewrites the same
content.

## Notes

- **Object lock is deliberately not enabled.** It would prevent Terraform from
  overwriting the state object. Versioning gives the recovery path without
  breaking writes.
- **`terraform destroy` will fail here, by design.** Buckets carry
  `prevent_destroy` and `force_clean = false`. Deleting a state bucket destroys
  the record of every resource in that environment. To genuinely remove a
  client, drop the guards in a separate, deliberate commit.
- **Recovering a bad apply**: the bucket keeps superseded versions for
  `noncurrent_expiry_days` (30 staging / 365 prod). Restore the previous version
  of `<prefix>/terraform.tfstate` in the COS console, then re-run `plan`.
- **CAM policies are created but not attached.** Attach them to the CI role
  yourself — binding identities is an account-level decision that does not
  belong in a per-client bootstrap.
