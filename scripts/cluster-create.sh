#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config true
render_config
registry_config_file=${REGISTRIES_FILE:-"$ROOT/k3d/generated/registries.yaml"}

phase='checking for an existing k3d cluster'
on_error() {
  local status=$?
  printf 'ERROR: %s failed (exit %d)\n' "$phase" "$status" >&2
  if ! debug_enabled; then
    echo 'Re-run with DEBUG_LOGGING=true in .env for k3d and Docker diagnostics.' >&2
  fi
  exit "$status"
}
trap on_error ERR

if debug_enabled; then
  debug_log "Docker server reachable: $(docker info >/dev/null 2>&1 && echo yes || echo no)"
  debug_log "k3d client: $(k3d version 2>/dev/null | awk '/k3d version/ {print $3; exit}' || echo unknown)"
  debug_log "custom k3s node image configured: $([[ -n $K3D_NODE_IMAGE ]] && echo yes || echo no)"
  debug_log "custom k3d proxy image configured: $([[ -n $K3D_PROXY_IMAGE ]] && echo yes || echo no)"
  debug_log "private registry configured: $([[ -n $REGISTRY_SERVER ]] && echo yes || echo no)"
  debug_log "registry authentication configured: $([[ -n $REGISTRY_USERNAME ]] && echo yes || echo no)"
  debug_log "node HTTP proxy configured: $([[ -n $HTTP_PROXY ]] && echo yes || echo no)"
  debug_log "node HTTPS proxy configured: $([[ -n $HTTPS_PROXY ]] && echo yes || echo no)"
fi

if { debug_enabled && k3d cluster list || k3d cluster list 2>/dev/null; } | awk '{print $1}' | grep -qx awx-dev; then
  echo "Cluster 'awx-dev' already exists"
  echo 'Node proxy and registry changes require: make cluster-delete cluster-create'
  exit 0
fi

mkdir -p data/postgres
phase='creating the awx-dev k3d cluster'
args=(cluster create --config k3d/awx-dev.yaml)
args+=(--volume "$ROOT/data/postgres:/var/lib/rancher/k3s/storage@server:0")

if [[ -n $K3D_NODE_IMAGE ]]; then
  echo "Using custom k3s node image: $K3D_NODE_IMAGE"
  args+=(--image "$K3D_NODE_IMAGE")
fi
if [[ -n $K3D_PROXY_IMAGE ]]; then
  echo "Using custom k3d proxy image: $K3D_PROXY_IMAGE"
  export K3D_IMAGE_LOADBALANCER=$K3D_PROXY_IMAGE
fi

if [[ -n $HTTP_PROXY || -n $HTTPS_PROXY ]]; then
  for name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    [[ -n ${!name} ]] && args+=(--env "$name=${!name}@server:0")
  done
fi

if [[ -n $REGISTRY_SERVER ]]; then
  args+=(--registry-config "$registry_config_file")
  if [[ -n $REGISTRY_CA_FILE ]]; then
    args+=(--volume "$REGISTRY_CA_FILE:/etc/rancher/k3s/registry-ca.crt@server:0")
  fi
fi
if [[ -n $K3S_SYSTEM_DEFAULT_REGISTRY ]]; then
  args+=(--k3s-arg "--system-default-registry=$K3S_SYSTEM_DEFAULT_REGISTRY@server:0")
fi

k3d "${args[@]}"
