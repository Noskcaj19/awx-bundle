SHELL := /usr/bin/env bash

# ── Pinned versions ──────────────────────────────────────────────
CLUSTER_NAME     := awx-dev
NAMESPACE        := awx
K3D_CONFIG       := k3d/awx-dev.yaml

HELM_REPO_NAME   := awx-operator
HELM_REPO_URL    := https://ansible-community.github.io/awx-operator-helm/
HELM_RELEASE     := awx-operator
HELM_CHART       := awx-operator/awx-operator
HELM_CHART_VER   := 3.2.1
HELM_VALUES      := helm/awx-operator-values.yaml
HELM_OVERRIDES   := helm/generated/awx-operator-overrides.yaml

K8S_DIR          := k8s/awx
OVERLAY_FILE     := k8s/awx/generated/overlay-patch.yaml
CA_SECRET        := awx-custom-certs
ENV_FILE         := .env
KUBE_RUN         := ENV_FILE=$(ENV_FILE) ./scripts/kube-with-config.sh
HELM_RUN         := ENV_FILE=$(ENV_FILE) ./scripts/helm-with-config.sh

# ── Targets ──────────────────────────────────────────────────────
.PHONY: help up down check diagnose config-validate config-generate test \
        cluster-create cluster-delete \
        repo-add operator-install operator-uninstall \
        registry-secrets-apply secrets-apply ca-apply overlay-generate awx-apply awx-delete \
        wait status password url \
        logs-operator logs-awx

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: ## Create cluster and deploy AWX end-to-end
	@./up.sh

down: ## Destroy the k3d cluster (deletes all data)
	@./down.sh

check: ## Verify required tools are installed
	@command -v docker  >/dev/null || { echo "docker not found";  exit 1; }
	@command -v k3d     >/dev/null || { echo "k3d not found";     exit 1; }
	@command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
	@command -v helm    >/dev/null || { echo "helm not found";    exit 1; }
	@docker info >/dev/null 2>&1   || { echo "docker not running"; exit 1; }
	@echo "✓ All prerequisites met"

diagnose: ## Print credential-safe Docker, Helm, and Kubernetes diagnostics
	@ENV_FILE=$(ENV_FILE) ./scripts/diagnose.sh

config-validate: ## Validate .env without changing the cluster
	@ENV_FILE=$(ENV_FILE) ./scripts/configure.sh validate

config-generate: ## Generate protected k3s, Helm, and AWX configuration
	@ENV_FILE=$(ENV_FILE) ./scripts/configure.sh render

test: ## Run offline configuration and manifest tests
	@./tests/test-config.sh

cluster-create: ## Create the k3d cluster
	@ENV_FILE=$(ENV_FILE) ./scripts/cluster-create.sh

cluster-delete: ## Delete the k3d cluster
	@k3d cluster delete $(CLUSTER_NAME) 2>/dev/null || true

repo-add:
	@$(HELM_RUN) "adding AWX Operator chart repository" -- repo add $(HELM_REPO_NAME) $(HELM_REPO_URL) --force-update
	@$(HELM_RUN) "updating Helm chart repositories" -- repo update

operator-install: config-generate registry-secrets-apply repo-add ## Install AWX operator via Helm
	@$(HELM_RUN) "installing AWX Operator release" -- upgrade --install $(HELM_RELEASE) $(HELM_CHART) \
		--namespace $(NAMESPACE) \
		--version $(HELM_CHART_VER) \
		-f $(HELM_VALUES) \
		-f $(HELM_OVERRIDES) \
		--wait \
		--timeout 10m

operator-uninstall: ## Uninstall AWX operator
	@$(HELM_RUN) "uninstalling AWX Operator release" -- uninstall $(HELM_RELEASE) -n $(NAMESPACE) || true

registry-secrets-apply: ## Create namespace and optional registry pull secrets
	@ENV_FILE=$(ENV_FILE) ./scripts/registry-secrets.sh

secrets-apply: registry-secrets-apply ## Create K8s secrets from .env
	@ENV_FILE=$(ENV_FILE) ./scripts/awx-secrets.sh

ca-apply: ## Create/refresh corporate CA bundle secret if AWX_CA_BUNDLE_FILE is set
	@ENV_FILE=$(ENV_FILE) ./scripts/ca-secret.sh

overlay-generate: config-generate ## Backward-compatible alias for config-generate

awx-apply: ## Apply AWX custom resource
	@echo "Waiting for AWX CRD to be established..."
	@$(KUBE_RUN) "waiting for the AWX CRD" -- wait --for=condition=Established crd/awxs.awx.ansible.com --timeout=180s
	@echo "Waiting for operator deployment to be ready..."
	@$(KUBE_RUN) "waiting for the AWX Operator deployment" -- -n $(NAMESPACE) rollout status deployment/awx-operator-controller-manager --timeout=300s
	@echo "Creating secrets from .env..."
	@$(MAKE) secrets-apply
	@echo "Loading corporate CA (if configured)..."
	@$(MAKE) ca-apply
	@echo "Generating deployment configuration..."
	@$(MAKE) config-generate
	@echo "Applying AWX manifests..."
	@$(KUBE_RUN) "applying the AWX Kustomize manifests" -- apply -k $(K8S_DIR)

awx-delete: config-generate ## Delete AWX instance (keeps operator)
	@$(KUBE_RUN) "deleting the AWX Kustomize manifests" -- delete -k $(K8S_DIR) --ignore-not-found=true

wait: ## Wait for AWX pods to become ready
	@echo "Waiting for AWX deployments (this can take 5-15 min on first run)..."
	@until kubectl -n $(NAMESPACE) get deployment awx-web >/dev/null 2>&1; do sleep 5; done
	@$(KUBE_RUN) "waiting for the AWX web deployment" -- -n $(NAMESPACE) rollout status deployment/awx-web --timeout=1200s
	@until kubectl -n $(NAMESPACE) get deployment awx-task >/dev/null 2>&1; do sleep 5; done
	@$(KUBE_RUN) "waiting for the AWX task deployment" -- -n $(NAMESPACE) rollout status deployment/awx-task --timeout=1200s
	@echo "✓ AWX is ready"

status: ## Show cluster resource status
	@$(KUBE_RUN) "reading AWX resource status" -- -n $(NAMESPACE) get awx,pods,svc,pvc

password: ## Print AWX admin credentials
	@echo "Username: admin"
	@printf "Password: "
	@$(KUBE_RUN) "reading the AWX admin password" -- -n $(NAMESPACE) get secret awx-admin-password -o jsonpath='{.data.password}' | base64 -d
	@echo

url: ## Print AWX URL
	@echo "http://localhost:8080"

logs-operator: ## Tail AWX operator logs
	@$(KUBE_RUN) "streaming AWX Operator logs" -- -n $(NAMESPACE) logs deployment/awx-operator-controller-manager -c awx-manager -f

logs-awx: ## Tail AWX web logs
	@$(KUBE_RUN) "streaming AWX web logs" -- -n $(NAMESPACE) logs deployment/awx-web -c awx-web -f
