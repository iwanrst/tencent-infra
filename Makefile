# Usage: make plan ENV=staging
ENV     ?= staging
ENVDIR   = envs/$(ENV)
TFPLAN   = $(ENVDIR)/$(ENV).tfplan

.PHONY: help fmt lint validate bootstrap bootstrap-plan bootstrap-adopt init plan apply destroy output kubeconfig clean

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s "$$(printf '\t')"

fmt: ## Rewrite all files to canonical format
	terraform fmt -recursive .

lint: ## Format check + tflint across modules and envs
	terraform fmt -check -recursive .
	tflint --recursive --config=$(CURDIR)/.tflint.hcl

validate: ## Validate bootstrap and every environment without touching remote state
	@for d in bootstrap envs/staging envs/prod; do \
	  echo "==> $$d"; \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && \
	  terraform -chdir=$$d validate || exit 1; \
	done

# --- one-time, per client account -------------------------------------------

bootstrap-plan: ## Preview the state buckets before creating them
	terraform -chdir=bootstrap init -input=false
	terraform -chdir=bootstrap plan -input=false

bootstrap: ## Create the state buckets and write envs/*/backend.hcl (run once)
	terraform -chdir=bootstrap init -input=false
	terraform -chdir=bootstrap apply -input=false
	@echo
	@echo "Backend config written to envs/*/backend.hcl -- commit it, then:"
	@echo "  make init ENV=staging"
	@echo "  make bootstrap-adopt   # move bootstrap off local state"

bootstrap-adopt: ## Migrate bootstrap's own state off the local file into COS
	terraform -chdir=bootstrap output -raw self_backend_hcl > bootstrap/backend.hcl
	terraform -chdir=bootstrap init -backend-config=backend.hcl -migrate-state
	@rm -f bootstrap/terraform.tfstate bootstrap/terraform.tfstate.backup
	@echo "bootstrap now stores its state in COS."

# --- per environment --------------------------------------------------------

init: ## Initialise the environment against its COS backend
	terraform -chdir=$(ENVDIR) init -backend-config=backend.hcl -input=false -reconfigure

plan: ## Write a plan file for review
	terraform -chdir=$(ENVDIR) plan -input=false -out=$(ENV).tfplan

apply: ## Apply the reviewed plan file -- never a bare apply
	@test -f $(TFPLAN) || { echo "No plan file. Run 'make plan ENV=$(ENV)' first."; exit 1; }
	terraform -chdir=$(ENVDIR) apply -input=false $(ENV).tfplan
	@rm -f $(TFPLAN)

destroy: ## Tear the environment down (blocked for prod)
	@test "$(ENV)" != "prod" || { echo "Refusing to destroy prod from make."; exit 1; }
	terraform -chdir=$(ENVDIR) destroy -input=false

output: ## Show environment outputs
	terraform -chdir=$(ENVDIR) output

kubeconfig: ## Write the cluster kubeconfig to ./kubeconfig-$(ENV)
	terraform -chdir=$(ENVDIR) output -raw kube_config > kubeconfig-$(ENV)
	@chmod 600 kubeconfig-$(ENV)
	@echo "export KUBECONFIG=$(CURDIR)/kubeconfig-$(ENV)"

clean: ## Remove local plan files and kubeconfigs
	rm -f envs/*/*.tfplan kubeconfig-*
