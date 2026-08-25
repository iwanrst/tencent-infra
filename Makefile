# Usage: make plan ENV=staging
ENV     ?= staging
ENVDIR   = envs/$(ENV)
TFPLAN   = $(ENVDIR)/$(ENV).tfplan

.PHONY: help fmt lint validate init plan apply destroy output clean

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s "$$(printf '\t')"

fmt: ## Rewrite all files to canonical format
	terraform fmt -recursive .

lint: ## Format check + tflint across modules and envs
	terraform fmt -check -recursive .
	tflint --recursive --config=$(CURDIR)/.tflint.hcl

validate: ## Validate every environment without touching remote state
	@for e in staging prod; do \
	  echo "==> $$e"; \
	  terraform -chdir=envs/$$e init -backend=false -input=false >/dev/null && \
	  terraform -chdir=envs/$$e validate || exit 1; \
	done

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
