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

K8S_DIR          := k8s/awx
OVERLAY_FILE     := k8s/awx/generated/overlay-patch.yaml
CA_SECRET        := awx-custom-certs
ENV_FILE         := .env

# ── Targets ──────────────────────────────────────────────────────
.PHONY: help up down check \
        cluster-create cluster-delete \
        repo-add operator-install operator-uninstall \
        secrets-apply ca-apply overlay-generate awx-apply awx-delete \
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

cluster-create: ## Create the k3d cluster
	@mkdir -p data/postgres
	@if ! k3d cluster list 2>/dev/null | awk '{print $$1}' | grep -qx "$(CLUSTER_NAME)"; then \
		k3d cluster create --config $(K3D_CONFIG) \
			--volume "$$(pwd)/data/postgres:/var/lib/rancher/k3s/storage@server:0"; \
	else \
		echo "Cluster '$(CLUSTER_NAME)' already exists"; \
	fi

cluster-delete: ## Delete the k3d cluster
	@k3d cluster delete $(CLUSTER_NAME) 2>/dev/null || true

repo-add:
	@helm repo add $(HELM_REPO_NAME) $(HELM_REPO_URL) >/dev/null 2>&1 || true
	@helm repo update >/dev/null

operator-install: repo-add ## Install AWX operator via Helm
	@helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--version $(HELM_CHART_VER) \
		-f $(HELM_VALUES) \
		--wait \
		--timeout 10m

operator-uninstall: ## Uninstall AWX operator
	@helm uninstall $(HELM_RELEASE) -n $(NAMESPACE) || true

secrets-apply: ## Create K8s secrets from .env
	@test -f $(ENV_FILE) || { echo "Missing $(ENV_FILE) — copy .env.example to .env and edit it"; exit 1; }
	@set -a && . ./$(ENV_FILE) && set +a && \
		kubectl -n $(NAMESPACE) create secret generic awx-admin-password \
			--from-literal=password="$$AWX_ADMIN_PASSWORD" \
			--dry-run=client -o yaml | kubectl apply -f - && \
		kubectl -n $(NAMESPACE) create secret generic awx-secret-key \
			--from-literal=secret_key="$$AWX_SECRET_KEY" \
			--dry-run=client -o yaml | kubectl apply -f -

ca-apply: ## Create/refresh corporate CA bundle secret if AWX_CA_BUNDLE_FILE is set
	@test -f $(ENV_FILE) || { echo "Missing $(ENV_FILE) — copy .env.example to .env and edit it"; exit 1; }
	@set -a && . ./$(ENV_FILE) && set +a && \
		if [ -n "$${AWX_CA_BUNDLE_FILE:-}" ] && [ -s "$$AWX_CA_BUNDLE_FILE" ]; then \
			echo "Loading corporate CA bundle from $$AWX_CA_BUNDLE_FILE"; \
			kubectl -n $(NAMESPACE) create secret generic $(CA_SECRET) \
				--from-file=bundle-ca.crt="$$AWX_CA_BUNDLE_FILE" \
				--dry-run=client -o yaml | kubectl apply -f -; \
		else \
			echo "No corporate CA bundle configured — removing $(CA_SECRET) if present"; \
			kubectl -n $(NAMESPACE) delete secret $(CA_SECRET) --ignore-not-found=true >/dev/null; \
		fi

overlay-generate: ## Render generated kustomize patch from .env (proxy + CA)
	@test -f $(ENV_FILE) || { echo "Missing $(ENV_FILE) — copy .env.example to .env and edit it"; exit 1; }
	@mkdir -p $(dir $(OVERLAY_FILE))
	@set -a && . ./$(ENV_FILE) && set +a && \
		BODY=$$(mktemp) && \
		if [ -n "$${AWX_CA_BUNDLE_FILE:-}" ] && [ -s "$${AWX_CA_BUNDLE_FILE:-}" ]; then \
			echo "  bundle_cacert_secret: $(CA_SECRET)" >> $$BODY; \
		fi; \
		if [ -n "$${HTTP_PROXY:-}$${HTTPS_PROXY:-}" ]; then \
			for key in ee_extra_env task_extra_env web_extra_env; do \
				echo "  $$key: |" >> $$BODY; \
				[ -n "$${HTTP_PROXY:-}"  ] && printf '    - name: HTTP_PROXY\n      value: "%s"\n'  "$$HTTP_PROXY"  >> $$BODY; \
				[ -n "$${HTTPS_PROXY:-}" ] && printf '    - name: HTTPS_PROXY\n      value: "%s"\n' "$$HTTPS_PROXY" >> $$BODY; \
				[ -n "$${NO_PROXY:-}"    ] && printf '    - name: NO_PROXY\n      value: "%s"\n'    "$$NO_PROXY"    >> $$BODY; \
				[ -n "$${HTTP_PROXY:-}"  ] && printf '    - name: http_proxy\n      value: "%s"\n'  "$$HTTP_PROXY"  >> $$BODY; \
				[ -n "$${HTTPS_PROXY:-}" ] && printf '    - name: https_proxy\n      value: "%s"\n' "$$HTTPS_PROXY" >> $$BODY; \
				[ -n "$${NO_PROXY:-}"    ] && printf '    - name: no_proxy\n      value: "%s"\n'    "$$NO_PROXY"    >> $$BODY; \
			done; \
		fi; \
		{ \
			echo "# Auto-generated by 'make overlay-generate' — do not edit by hand."; \
			echo "apiVersion: awx.ansible.com/v1beta1"; \
			echo "kind: AWX"; \
			echo "metadata:"; \
			echo "  name: awx"; \
			if [ -s $$BODY ]; then \
				echo "spec:"; \
				cat $$BODY; \
			else \
				echo "spec: {}"; \
			fi; \
		} > $(OVERLAY_FILE); \
		rm -f $$BODY
	@echo "✓ Wrote $(OVERLAY_FILE)"

awx-apply: ## Apply AWX custom resource
	@echo "Waiting for AWX CRD to be established..."
	@kubectl wait --for=condition=Established crd/awxs.awx.ansible.com --timeout=180s
	@echo "Waiting for operator deployment to be ready..."
	@kubectl -n $(NAMESPACE) rollout status deployment/awx-operator-controller-manager --timeout=300s
	@echo "Creating secrets from .env..."
	@$(MAKE) secrets-apply
	@echo "Loading corporate CA (if configured)..."
	@$(MAKE) ca-apply
	@echo "Generating proxy/CA overlay patch..."
	@$(MAKE) overlay-generate
	@echo "Applying AWX manifests..."
	@kubectl apply -k $(K8S_DIR)

awx-delete: ## Delete AWX instance (keeps operator)
	@kubectl delete -k $(K8S_DIR) --ignore-not-found=true

wait: ## Wait for AWX pods to become ready
	@echo "Waiting for AWX deployments (this can take 5-15 min on first run)..."
	@until kubectl -n $(NAMESPACE) get deployment awx-web >/dev/null 2>&1; do sleep 5; done
	@kubectl -n $(NAMESPACE) rollout status deployment/awx-web --timeout=1200s
	@until kubectl -n $(NAMESPACE) get deployment awx-task >/dev/null 2>&1; do sleep 5; done
	@kubectl -n $(NAMESPACE) rollout status deployment/awx-task --timeout=1200s
	@echo "✓ AWX is ready"

status: ## Show cluster resource status
	@kubectl -n $(NAMESPACE) get awx,pods,svc,pvc

password: ## Print AWX admin credentials
	@echo "Username: admin"
	@printf "Password: "
	@kubectl -n $(NAMESPACE) get secret awx-admin-password -o jsonpath='{.data.password}' | base64 -d
	@echo

url: ## Print AWX URL
	@echo "http://localhost:8080"

logs-operator: ## Tail AWX operator logs
	@kubectl -n $(NAMESPACE) logs deployment/awx-operator-controller-manager -c awx-manager -f

logs-awx: ## Tail AWX web logs
	@kubectl -n $(NAMESPACE) logs deployment/awx-web -c awx-web -f
