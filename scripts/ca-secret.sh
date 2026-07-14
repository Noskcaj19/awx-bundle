#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config true

phase='initializing AWX CA secret'
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

if [[ -n $AWX_CA_BUNDLE_FILE ]]; then
  phase='applying awx-custom-certs secret'
  echo "Loading corporate CA bundle from $AWX_CA_BUNDLE_FILE"
  kubectl -n awx create secret generic awx-custom-certs \
    --from-file=bundle-ca.crt="$AWX_CA_BUNDLE_FILE" \
    --dry-run=client -o yaml |
    kube_apply_stdin "$phase" >/dev/null
else
  phase='removing stale awx-custom-certs secret'
  echo 'No corporate CA bundle configured — removing awx-custom-certs if present'
  kube "$phase" -n awx delete secret awx-custom-certs --ignore-not-found=true >/dev/null
fi

echo '✓ Reconciled AWX corporate CA secret'
