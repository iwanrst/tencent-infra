# Tencent Cloud Platform — Terraform

Reusable Terraform for a Tencent Cloud landing zone: VPC, network segmentation,
security groups and a TKE cluster. One code path, many clients, many
environments — everything that varies is a variable.

## Layout

```
modules/
  vpc/               VPC, tiered subnets, route tables, NAT gateways, flow logs
  network-acl/       Stateless subnet ACLs — the segmentation boundary
  security-group/    Data-driven security groups with group-to-group references
  tke/               Managed TKE cluster, node pools, endpoints, addons
  platform/          Composition root: wires the four together, applies
                     environment-aware defaults
envs/
  staging/           Thin root — identical code to prod
  prod/              Thin root — identical code to staging
```

`envs/staging` and `envs/prod` contain the **same `.tf` files**. All divergence
lives in `terraform.tfvars` and `backend.hcl`. If you find yourself editing
`main.tf` in one environment only, that is a design smell — add a variable.

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

1. Copy `envs/` into the client's repo (or a new directory per client).
2. Change five things in `terraform.tfvars`:
   - `client` — the naming prefix for every resource
   - `region`
   - `vpc_cidr` and the matching `tiers` block
   - `admin_cidrs` — the client's real office / VPN / CI ranges
   - `node_pools` — sizing
3. Point `backend.hcl` at a COS bucket in the client's account.
4. `make init ENV=staging && make plan ENV=staging`

Keep every client-environment pair on a distinct VPC CIDR so they stay peerable
later. The convention used in the shipped example:

```
acme staging 10.10.0.0/16     acme prod 10.20.0.0/16
beta staging 10.30.0.0/16     beta prod 10.40.0.0/16
```

## Usage

```bash
export TENCENTCLOUD_SECRET_ID=...
export TENCENTCLOUD_SECRET_KEY=...

make init ENV=staging      # init against the COS backend
make plan ENV=staging      # writes staging.tfplan for review
make apply ENV=staging     # applies the reviewed plan file
make kubeconfig ENV=staging
```

`make apply` refuses to run without a plan file: what gets reviewed is what
gets applied.

For a multi-account setup, set `assume_role_arn` and let Terraform hop into the
client account with a scoped CAM role rather than holding long-lived keys per
client.

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

## Development

```bash
make fmt        # canonical formatting
make lint       # fmt check + tflint
make validate   # validate every environment, no backend, no credentials
pre-commit run --all-files
```

`terraform validate` and the linters run without cloud credentials, so they
belong in CI on every pull request. See `.github/workflows/terraform.yml`.
