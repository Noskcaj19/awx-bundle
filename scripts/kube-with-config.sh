#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config false

description=${1:-Kubernetes command}
shift || true
if [[ ${1:-} == -- ]]; then
  shift
fi
[[ $# -gt 0 ]] || { echo "Usage: $0 DESCRIPTION -- KUBECTL_ARGS..." >&2; exit 2; }

on_error() {
  local status=$?
  printf 'ERROR: Kubernetes phase failed: %s (exit %d)\n' "$description" "$status" >&2
  if ! debug_enabled; then
    echo 'Re-run with DEBUG_LOGGING=true in .env for context and authentication diagnostics.' >&2
  fi
  exit "$status"
}
trap on_error ERR

debug_kube_context
kube "$description" "$@"
