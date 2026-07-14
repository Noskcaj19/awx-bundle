#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config false || exit $?

DEBUG_LOGGING=true
export DEBUG_LOGGING

echo 'Credential-safe deployment diagnostics'
echo '======================================'
debug_log "Docker client: $(docker version --format '{{.Client.Version}}' 2>/dev/null || echo unavailable)"
debug_log "Docker server reachable: $(docker info >/dev/null 2>&1 && echo yes || echo no)"
debug_log "k3d client: $(k3d version 2>/dev/null | awk '/k3d version/ {print $3; exit}' || echo unavailable)"
debug_helm_context
debug_kube_context

debug_log 'Known k3d clusters:'
k3d cluster list >&2 || true
debug_log 'Kubernetes API /version probe:'
kubectl --v="$KUBECTL_VERBOSITY" get --raw=/version >&2 || true

cat <<'EOF'

Diagnostics complete. No secret values or rendered manifests were printed.
If authentication failed, confirm that the current context is the k3d context
created for this cluster and refresh it with:
  k3d kubeconfig merge awx-dev --kubeconfig-switch-context
EOF
