# bootstrap

Creates the COS buckets that hold Terraform state for every environment.

Run this **once per client account**, before anything in `envs/` can be
initialised. After that it is touched only when adding an environment or
changing retention.

## Why it is a separate root

`envs/staging` and `envs/prod` both declare `backend "cos"`. That bucket has to
exist before their first `terraform init` — a root cannot create the bucket it
stores its own state in. Bootstrap breaks the cycle: it starts on **local
state**, creates the buckets, and then adopts one of them for itself.

## What it creates

| Resource | Per | Notes |
|---|---|---|
| COS bucket | environment | Versioned, encrypted, private, `prevent_destroy` |
| Lifecycle rule | bucket | Expires superseded versions; aborts stale multipart uploads |
| CAM policy | environment | Least-privilege state access, scoped to that one bucket |
| `backend.hcl` | environment | Written into `envs/<name>/` with the real bucket name |

One bucket **per environment**, not one shared bucket with prefixes: a
credential scoped to staging must have no path to production state, and the
bucket is the only boundary a COS policy can express cleanly.

## First run

```bash
cd bootstrap
export TENCENTCLOUD_SECRET_ID=...
export TENCENTCLOUD_SECRET_KEY=...

# edit terraform.tfvars: client, region, environments
terraform init
terraform apply
```

This writes `envs/staging/backend.hcl` and `envs/prod/backend.hcl` with the
real bucket names — the account APPID is read from the API, so it never has to
be looked up by hand. Commit the result.

Then bring each environment up:

```bash
make init ENV=staging && make plan ENV=staging
```

## Second step: stop depending on a local state file

Bootstrap has now created a bucket it can live in. Move its own state there:

```bash
cd bootstrap
terraform output -raw self_backend_hcl > backend.hcl
terraform init -backend-config=backend.hcl -migrate-state
rm -f terraform.tfstate terraform.tfstate.backup
```

Its state lands under the `bootstrap/` prefix of the production bucket. Skip
this and `bootstrap/terraform.tfstate` stays on one laptop — which is exactly
the failure mode this repo exists to avoid.

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
