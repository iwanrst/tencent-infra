# Tencent Cloud Platform — Terraform

Reusable Terraform for a Tencent Cloud landing zone: VPC, network segmentation,
security groups and a TKE cluster. One code path, many clients, many
environments — everything that varies is a variable.

## Layout

```
modules/             The reusable logic. Nothing client-specific.
  vpc/               VPC, tiered subnets, route tables, NAT gateways, flow logs
  network-acl/       Stateless subnet ACLs -- the segmentation boundary
  security-group/    Data-driven SGs with group-to-group references
  tke/               Managed TKE cluster, node pools, endpoints, addons
  platform/          Composition root + environment-aware defaults

stacks/roots/        The generic Terraform roots. One canonical copy each.
  environment/       Root for any client+environment
  bootstrap/         Root for a client's state buckets

clients/             Values only -- terraform.tfvars + backend.hcl per stack.
  acme/
    bootstrap/  staging/  prod/
  training/
    bootstrap/  staging/
```

Each directory under `clients/` holds **only** `terraform.tfvars` and
`backend.hcl`. The `.tf` files are symlinks to `stacks/`, so there is exactly
one copy of the root configuration in the repo and a fix lands for every client
at once. Terraform resolves relative module sources from the symlink's own
directory, which is what makes this work.

`stacks/roots/*` sits at the same depth as `clients/<client>/<env>/` on
purpose: `../../../modules/platform` has to resolve correctly both from the
symlink and from the canonical file. If the two depths disagree, Terraform
still works — it only ever runs from `clients/` — but terraform-ls reports
every attribute as unexpected for anyone editing the real file. `make validate`
checks both.

```bash
make stacks                              # list every client stack
make plan CLIENT=training ENV=staging
```

If you find yourself wanting to edit `main.tf` for one client only, that is a
design smell — add a variable to `modules/platform` instead.

## Architecture

```
                          internet
                             │
                    ┌────────▼────────┐
  public  /20       │  CLB · NAT · bastion        ACL: open
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
  app     /20       │  TKE worker nodes           ACL: VPC-only inbound
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
  eni     /18       │  Pod ENIs (VPC-CNI)         ACL: VPC-only inbound
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
  data    /20       │  Databases · caches         ACL: workload tiers only,
                    └─────────────────┘                no internet either way
                                                  Route: no NAT route at all
```

Each tier is one contiguous slice of the VPC CIDR, split evenly across the
availability zones. Nothing but `vpc_cidr` and the tier map needs to be
specified — subnet CIDRs are derived, so they cannot drift or collide.

### Defence in depth

Three independent controls, so no single mistake is sufficient:

| Layer | Control | Fails closed against |
|---|---|---|
| Routing | Data tier has no NAT route | Exfiltration to the internet |
| Subnet ACL | Stateless, per tier | An instance launched with the wrong security group |
| Security group | Stateful, group-to-group | Everything else; the primary policy surface |

Security group rules reference **other groups**, not addresses:

```hcl
{ action = "ACCEPT", protocol = "TCP", port = "3306", source_security_group = "node" }
```

The policy therefore survives any address-plan change and reads as an
architecture diagram.

## Environment-aware defaults

The platform module derives its posture from `environment`. Every one of these
is overridable; the default is what you get for free.

| Setting | staging / dev | prod |
|---|---|---|
| NAT gateways | one, shared | one per AZ |
| VPC flow logs | off | on |
| Subnet ACLs | off | on |
| TKE control plane | `L5` | `L50` |
| Public Kubernetes API | on, allowlisted | **off** |
| Cluster deletion protection | off | on |
| Log retention | 14 days | 90 days |

`terraform output effective_defaults` prints what is actually in effect.

## Onboarding a new client

Worked example: a client called `training`, staging only.

**1. Pick an address range.** Every client-environment pair needs a distinct
/16 so any two can be peered later without renumbering. `10.10` and `10.20`
belong to acme, so training staging takes `10.30.0.0/16`.

**2. Create the two value files.**

```
clients/training/bootstrap/terraform.tfvars   # client, region, environments
clients/training/staging/terraform.tfvars     # client, environment, region,
                                              # vpc_cidr, tiers, admin_cidrs,
                                              # node_pools
```

**3. Symlink the shared roots in.**

```bash
for f in main.tf providers.tf variables.tf outputs.tf versions.tf; do
  ln -sf ../../../stacks/roots/environment/$f clients/training/staging/$f
done
for f in main.tf providers.tf variables.tf outputs.tf versions.tf backend_files.tf; do
  ln -sf ../../../stacks/roots/bootstrap/$f clients/training/bootstrap/$f
done
```

**4. Create the state bucket, then the infrastructure.**

```bash
make bootstrap CLIENT=training              # creates the COS bucket,
                                            # writes staging/backend.hcl
make bootstrap-adopt CLIENT=training        # bootstrap stops using local state
git add clients/training && git commit      # commit the generated backend.hcl

make init CLIENT=training ENV=staging
make plan CLIENT=training ENV=staging
make apply CLIENT=training ENV=staging
```

Everything else — the tier layout, the ACL and security group baseline, node
pool shape, TKE settings — comes from `modules/platform` defaults. Only override
what this client genuinely needs to differ on.

Adding `prod` for training later is a new key in its bootstrap `environments`
map plus a `clients/training/prod/` directory; re-running `make bootstrap
CLIENT=training` creates the second bucket.

## Usage

```bash
export TENCENTCLOUD_SECRET_ID=...
export TENCENTCLOUD_SECRET_KEY=...

make bootstrap  CLIENT=acme                  # once per client: state buckets
make init       CLIENT=acme ENV=staging      # init against the COS backend
make plan       CLIENT=acme ENV=staging      # writes a plan file for review
make apply      CLIENT=acme ENV=staging      # applies the reviewed plan file
make kubeconfig CLIENT=acme ENV=staging
```

`make apply` refuses to run without a plan file: what gets reviewed is what
gets applied.

For a multi-account setup, set `assume_role_arn` and let Terraform hop into the
client account with a scoped CAM role rather than holding long-lived keys per
client.

## Rolling out in phases

`enable_tke = false` builds networking only — VPC, subnets, route tables, NAT
and the security group baseline — and stops there. Useful when the address plan
needs sign-off, or when peering / Direct Connect has to land before any
workload exists.

```hcl
# clients/<client>/<env>/terraform.tfvars
enable_tke = false
```

Phase 2 is flipping it to `true`. That is purely additive: the cluster consumes
subnets and security groups rather than owning them, so nothing built in phase 1
is replaced.

## Things worth knowing before the first apply

- **`network_type` is permanent.** Switching between `VPC-CNI` and `GR` replaces
  the cluster. VPC-CNI is the default: pods get real VPC IPs, so security groups
  apply to them and CLBs target them directly. It costs address space — the
  default `/18` ENI tier gives ~4000 pod IPs per AZ.
- **`service_cidr` must not overlap** the VPC, the pod CIDR, or anything you
  will ever peer with. Staging and prod use different ranges here deliberately.
- **The VPC has `prevent_destroy`.** The address plan is the hardest thing to
  change after the fact. Removing the guard is a deliberate act.
- **`availability_zones` should be pinned** before production. Auto-selection
  reads live zone availability; if that shifts, subnets move.
- **`restrict_egress = true` will break** anything talking outbound on a port
  other than 443/53. It is on in prod in the shipped example — turn it off, or
  add the client's egress rules, until the workload's dependencies are known.
- **Node pool `desired_capacity` is ignored after creation.** The cluster
  autoscaler owns it; Terraform sets the seed value and stays out of the way.
- **State buckets carry `prevent_destroy` and never object lock.** Object lock
  would stop Terraform overwriting the state object; versioning gives the
  recovery path without breaking writes. `terraform destroy` in `bootstrap/`
  is meant to fail.

## Development

```bash
make fmt        # canonical formatting
make lint       # fmt check + tflint
make validate   # validate every environment, no backend, no credentials
pre-commit run --all-files
```

`terraform validate` and the linters run without cloud credentials, so they
belong in CI on every pull request. See `.github/workflows/terraform.yml`.
