# Run everything from the repo root. Secrets come from 1Password via `op run`,
# so you need to be signed in (`op signin`) and, for state, logged in to AWS.
# in the aws cli.
#
# `make` with no target lists what's available.

.DEFAULT_GOAL := help

KUBECONFIG_FILE := $(HOME)/.kube/homelab.yaml
KUBECTL := kubectl --kubeconfig $(KUBECONFIG_FILE) --context homelab
HELM    := helm --kubeconfig $(KUBECONFIG_FILE) --kube-context homelab

# Argo CD chart. Argo CD is the one component installed by
# hand; everything else is deployed by it from kubernetes/argocd/applications.
ARGOCD_CHART_VERSION := 10.11.1

# Keeps `make lint` from touching the real .terraform/ used by plan and apply.
LINT_DATA_DIR := $(CURDIR)/.tofu-lint

.PHONY: help plan apply cluster kubeconfig argocd palworld-secret eso-token up destroy forget-hostkeys rebuild lint hooks

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

plan: ## Preview infrastructure changes (read-only)
	cd infra && op run --env-file=.env.tpl -- tofu plan

apply: ## Create or update the VMs (OpenTofu)
	cd infra && op run --env-file=.env.tpl -- tofu apply

cluster: ## Configure the nodes and install k3s (Ansible, idempotent)
	cd ansible && ansible-galaxy collection install -r requirements.yml
	cd ansible && op run --env-file=.env.tpl -- ansible-playbook playbooks/site.yml

kubeconfig: ## Refresh ~/.kube/homelab.yaml from the control plane
	cd ansible && op run --env-file=.env.tpl -- ansible-playbook playbooks/site.yml --tags kubeconfig

argocd: ## Install Argo CD; it then deploys MetalLB, Palworld and the rest from Git
	$(HELM) upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
		--version $(ARGOCD_CHART_VERSION) -n argocd --create-namespace \
		-f kubernetes/argocd/values.yaml
	@# No --wait: Argo CD's own LoadBalancer Service can't get an address until
	@# Argo CD has installed MetalLB, which is the next step. The repo is public,
	@# so Argo CD pulls it over HTTPS with no credentials.
	$(KUBECTL) -n argocd rollout status deploy/argocd-repo-server --timeout=300s
	$(KUBECTL) -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
	$(KUBECTL) apply -f kubernetes/argocd/root-app.yaml

palworld-secret: ## Create the Palworld passwords Secret from 1Password
	$(KUBECTL) create namespace palworld --dry-run=client -o yaml | $(KUBECTL) apply -f -
	op inject -i kubernetes/apps/palworld/.env.tpl \
	  | $(KUBECTL) -n palworld create secret generic palworld \
	      --from-env-file=/dev/stdin --dry-run=client -o yaml \
	  | $(KUBECTL) apply --server-side -f -

eso-token: ## Put the 1Password service account token in the cluster (for External Secrets)
	$(KUBECTL) create namespace external-secrets --dry-run=client -o yaml | $(KUBECTL) apply -f -
	op read op://homelab/homelab-eso-service-account/credential | tr -d '\n' \
	  | $(KUBECTL) -n external-secrets create secret generic onepassword-sa \
	      --from-file=token=/dev/stdin --dry-run=client -o yaml \
	  | $(KUBECTL) apply --server-side -f -

up: apply forget-hostkeys cluster palworld-secret eso-token argocd ## Build everything from nothing: VMs, k3s, Argo CD (which deploys the rest)

destroy: ## Delete all three VMs and their disks (asks first)
	cd infra && op run --env-file=.env.tpl -- tofu destroy

forget-hostkeys: ## Drop stale SSH host keys for the nodes (they change on every rebuild)
	@# The node list comes from the inventory OpenTofu renders from local.nodes
	@# (infra/nodes.tf), so there is no second copy to keep in sync. Each node
	@# is cleared by name, <name>.internal and IP. It's read here, not into a
	@# variable, so `make up` sees the inventory `apply` has just rewritten.
	@set -e; \
	hosts=$$(ansible-inventory -i ansible/inventory/hosts.yml --list \
	  | python3 -c 'import json,sys; v=json.load(sys.stdin)["_meta"]["hostvars"]; print(*[x for n,h in v.items() for x in (n, n+".internal", h["ansible_host"])])'); \
	test -n "$$hosts" || { echo "No hosts found in the inventory" >&2; exit 1; }; \
	for h in $$hosts; do ssh-keygen -R "$$h" >/dev/null 2>&1 || true; done; \
	echo "Cleared known_hosts entries for: $$hosts"

rebuild: destroy up ## Destroy, then rebuild from zero

lint: ## Run the same checks CI runs
	@for t in tofu tflint ansible-lint; do \
	  command -v $$t >/dev/null || { echo "Missing tool: $$t (see 'Run it' in the README)" >&2; exit 1; }; \
	done
	tofu fmt -check -recursive -diff infra
	cd infra && TF_DATA_DIR=$(LINT_DATA_DIR) TF_VAR_state_passphrase=local-validate-only-0000 tofu init -backend=false -input=false >/dev/null
	cd infra && TF_DATA_DIR=$(LINT_DATA_DIR) TF_VAR_state_passphrase=local-validate-only-0000 tofu validate
	cd infra && tflint --recursive --config $(CURDIR)/.tflint.hcl
	cd ansible && ansible-lint

hooks: ## Install the git pre-commit hooks (secret scan, formatting); once per clone
	@command -v pre-commit >/dev/null || { echo "Missing tool: pre-commit (pipx install pre-commit, or brew install pre-commit)" >&2; exit 1; }
	pre-commit install
