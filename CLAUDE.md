# tencent-infra

Terraform landing zone for Tencent Cloud: VPC, network segmentation, security
groups, TKE. One codebase, many clients, many environments.

Terraform >= 1.9. Provider `tencentcloudstack/tencentcloud ~> 1.81`.

## Layout

```
modules/       reusable logic — nothing client-specific
stacks/roots/  the generic Terraform roots, one canonical copy each
clients/       values only — terraform.tfvars + backend.hcl per stack
```

`clients/<client>/<env>/*.tf` are **symlinks** into `stacks/roots/`. Each client
directory contains only its two value files.

## Rules that are easy to get wrong

**Never edit `stacks/roots/*` to change one client.** Three stacks share those
files. Removing a block there hits every client on their next apply. To vary
behaviour per client, add a variable to `modules/platform` and set it in that
client's `terraform.tfvars`. `enable_tke` is the worked example.

**`stacks/roots/*` must stay exactly three levels deep.** The shared
`source = "../../../modules/platform"` has to resolve from both the canonical
file and the symlink. If the depths disagree, `terraform validate` still passes
(Terraform only runs from `clients/`) but terraform-ls reports every attribute
in the module block as unexpected. `make validate` checks both.

**Network ACLs are stateless and first-match-wins.** Ephemeral return rules are
emitted *before* user rules in `modules/network-acl`. Appending them after a
catch-all DROP silently breaks every connection the tier originated.

**`prevent_destroy` is set on the VPC and on the state buckets.** `terraform
destroy` failing there is intended, not a bug. Removing a guard is a separate,
deliberate commit.

**The COS backend locks via the tag service, not a lock file.** It takes the
tag key `tencentcloud-terraform-lock`, so any role running Terraform needs
`tag:CreateTag`, `tag:DeleteTag` and `tag:DescribeTags` on top of COS access.
`stacks/roots/bootstrap` grants these. Missing them shows up as apply hanging
until lock timeout, not as a permission error.

**`terraform output -raw` takes an output name, not an index expression.** Use
`terraform output -json <name> | jq -r '.<key>'` for a map output.

## Address allocation

Every client-environment pair needs a distinct range so any two stay peerable.

| Stack | VPC | Service CIDR |
|---|---|---|
| acme staging | `10.10.0.0/16` | `172.20.0.0/18` |
| acme prod | `10.20.0.0/16` | `172.21.0.0/18` |
| training staging | `10.30.0.0/16` | `172.22.0.0/18` |
| *next free* | `10.40.0.0/16` | `172.23.0.0/18` |

Within a VPC the tiers are `public` /20, `app` /20, `data` /20 (no NAT route at
all), `eni` /18 (VPC-CNI pod IPs, ~4000 per AZ).

## Workflow

```bash
make stacks                              # list every client stack
make bootstrap CLIENT=x                  # once per client: COS state buckets
make bootstrap-adopt CLIENT=x            # move bootstrap off local state
make init  CLIENT=x ENV=staging
make plan  CLIENT=x ENV=staging          # writes a plan file
make apply CLIENT=x ENV=staging          # applies that file; no bare applies
make validate                            # all roots, no credentials needed
```

Environment drives posture: `environment = "prod"` turns on per-AZ NAT, flow
logs, subnet ACLs, `L50`, deletion protection, and turns *off* the public
Kubernetes API endpoint. Non-prod trades those for cost. All overridable;
`terraform output effective_defaults` shows what is in effect.

`enable_tke = false` deploys networking only. Flipping it to true later is
purely additive — the cluster consumes subnets and security groups rather than
owning them.

## Notes

- `clients/acme/` is **placeholder demo data**, not a real client. It holds the
  only `prod` stack, so it doubles as the production reference.
- Tencent has no internet gateway resource. Public subnets need no `0.0.0.0/0`
  route; instances reach the internet via public IP or EIP. The public route
  table carrying only a local route is correct.
- terraform-ls resolves modules through `.terraform/modules/modules.json`. If
  the editor claims valid attributes are unexpected, the index is missing —
  `make validate` regenerates it for every root.
