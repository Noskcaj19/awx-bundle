#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config false

description=${1:-Helm command}
shift || true
if [[ ${1:-} == -- ]]; then
  shift
fi
[[ $# -gt 0 ]] || { echo "Usage: $0 DESCRIPTION -- HELM_ARGS..." >&2; exit 2; }

on_error() {
  local status=$?
  printf 'ERROR: Helm phase failed: %s (exit %d)\n' "$description" "$status" >&2
  if ! debug_enabled; then
    echo 'Re-run with DEBUG_LOGGING=true in .env for client, context, and proxy diagnostics.' >&2
  fi
  exit "$status"
}
trap on_error ERR

debug_helm_context
debug_log "Helm phase: $description"
# Do not use Helm's --debug flag here: rendered values can contain proxy
# credentials. Phase and client diagnostics remain credential-safe.
helm "$@"
