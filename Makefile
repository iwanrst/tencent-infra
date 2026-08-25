# Usage: make plan CLIENT=training ENV=staging
CLIENT  ?= acme
ENV     ?= staging
ENVDIR   = clients/$(CLIENT)/$(ENV)
BOOTDIR  = clients/$(CLIENT)/bootstrap
TFPLAN   = $(ENVDIR)/$(ENV).tfplan

# Fail early and clearly rather than with a confusing terraform error.
guard-env:
	@test -d $(ENVDIR) || { \
	  echo "No such stack: $(ENVDIR)"; \
	  echo "Known stacks:"; \
	  find clients -mindepth 2 -maxdepth 2 -type d ! -name bootstrap | sed 's|^|  make ... CLIENT=|;s|clients/||;s|/| ENV=|'; \
	  exit 1; }

.PHONY: help guard-env stacks fmt lint validate bootstrap bootstrap-plan bootstrap-adopt init plan apply destroy output kubeconfig clean

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s "$$(printf '\t')"

fmt: ## Rewrite all files to canonical format
	terraform fmt -recursive .

lint: ## Format check + tflint across modules and envs
	terraform fmt -check -recursive .
	tflint --recursive --config=$(CURDIR)/.tflint.hcl

validate: ## Validate the shared roots and every client stack, without remote state
	@for d in stacks/roots/environment stacks/roots/bootstrap $$(find clients -mindepth 2 -maxdepth 2 -type d); do \
	  echo "==> $$d"; \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && \
	  terraform -chdir=$$d validate || exit 1; \
	done

# --- one-time, per client account -------------------------------------------

bootstrap-plan: ## Preview this client's state buckets before creating them
	terraform -chdir=$(BOOTDIR) init -input=false
	terraform -chdir=$(BOOTDIR) plan -input=false

bootstrap: ## Create this client's state buckets and write its backend.hcl (run once per client)
	terraform -chdir=$(BOOTDIR) init -input=false
	terraform -chdir=$(BOOTDIR) apply -input=false
	@echo
	@echo "Backend config written to clients/$(CLIENT)/*/backend.hcl -- commit it, then:"
	@echo "  make init CLIENT=$(CLIENT) ENV=$(ENV)"
	@echo "  make bootstrap-adopt CLIENT=$(CLIENT)"

bootstrap-adopt: ## Migrate this client's bootstrap state off the local file into COS
	terraform -chdir=$(BOOTDIR) output -raw self_backend_hcl > $(BOOTDIR)/backend.hcl
	terraform -chdir=$(BOOTDIR) init -backend-config=backend.hcl -migrate-state
	@rm -f $(BOOTDIR)/terraform.tfstate $(BOOTDIR)/terraform.tfstate.backup
	@echo "$(CLIENT) bootstrap now stores its state in COS."

# --- per environment --------------------------------------------------------

init: guard-env ## Initialise the stack against its COS backend
	terraform -chdir=$(ENVDIR) init -backend-config=backend.hcl -input=false -reconfigure

plan: guard-env ## Write a plan file for review
	terraform -chdir=$(ENVDIR) plan -input=false -out=$(ENV).tfplan

apply: guard-env ## Apply the reviewed plan file -- never a bare apply
	@test -f $(TFPLAN) || { echo "No plan file. Run 'make plan ENV=$(ENV)' first."; exit 1; }
	terraform -chdir=$(ENVDIR) apply -input=false $(ENV).tfplan
	@rm -f $(TFPLAN)

destroy: guard-env ## Tear the stack down (blocked for prod)
	@test "$(ENV)" != "prod" || { echo "Refusing to destroy prod from make."; exit 1; }
	terraform -chdir=$(ENVDIR) destroy -input=false

output: ## Show environment outputs
	terraform -chdir=$(ENVDIR) output

kubeconfig: guard-env ## Write the cluster kubeconfig to ./kubeconfig-$(CLIENT)-$(ENV)
	terraform -chdir=$(ENVDIR) output -raw kube_config > kubeconfig-$(CLIENT)-$(ENV)
	@chmod 600 kubeconfig-$(CLIENT)-$(ENV)
	@echo "export KUBECONFIG=$(CURDIR)/kubeconfig-$(CLIENT)-$(ENV)"

stacks: ## List every client stack in the repo
	@find clients -mindepth 2 -maxdepth 2 -type d ! -name bootstrap \
	  | sed 's|clients/||;s|/| |' | awk '{printf "  CLIENT=%-10s ENV=%s\n", $$1, $$2}'

clean: ## Remove local plan files and kubeconfigs
	rm -f clients/*/*/*.tfplan kubeconfig-*
