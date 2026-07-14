#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config true

phase='initializing registry secrets'
on_error() {
  local status=$?
  printf 'ERROR: %s failed (exit %d)\n' "$phase" "$status" >&2
  if ! debug_enabled; then
    echo 'Re-run with DEBUG_LOGGING=true in .env for Kubernetes authentication diagnostics.' >&2
  fi
  exit "$status"
}
trap on_error ERR

debug_kube_context

phase='applying namespace awx'
kubectl create namespace awx --dry-run=client -o yaml |
  kube_apply_stdin "$phase" >/dev/null

if [[ -z $REGISTRY_USERNAME ]]; then
  echo 'No registry credentials configured'
  exit 0
fi

phase="applying registry pull secret $REGISTRY_PULL_SECRET_NAME"
kubectl -n awx create secret docker-registry "$REGISTRY_PULL_SECRET_NAME" \
  --docker-server="$REGISTRY_SERVER" \
  --docker-username="$REGISTRY_USERNAME" \
  --docker-password="$REGISTRY_PASSWORD" \
  --dry-run=client -o yaml |
  kube_apply_stdin "$phase" >/dev/null

phase='applying AWX EE registry credential secret'
kubectl -n awx create secret generic awx-ee-registry-credentials \
  --from-literal=url="$REGISTRY_SERVER" \
  --from-literal=username="$REGISTRY_USERNAME" \
  --from-literal=password="$REGISTRY_PASSWORD" \
  --from-literal=ssl_verify="$REGISTRY_TLS_VERIFY" \
  --dry-run=client -o yaml |
  kube_apply_stdin "$phase" >/dev/null

echo "✓ Applied registry pull secrets in namespace awx"
