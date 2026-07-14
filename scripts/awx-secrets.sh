#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config true

phase='initializing AWX secrets'
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

phase='applying awx-admin-password secret'
kubectl -n awx create secret generic awx-admin-password \
  --from-literal=password="$AWX_ADMIN_PASSWORD" \
  --dry-run=client -o yaml |
  kube_apply_stdin "$phase" >/dev/null

phase='applying awx-secret-key secret'
kubectl -n awx create secret generic awx-secret-key \
  --from-literal=secret_key="$AWX_SECRET_KEY" \
  --dry-run=client -o yaml |
  kube_apply_stdin "$phase" >/dev/null

echo '✓ Applied AWX application secrets'
