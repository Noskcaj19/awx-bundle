#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config true
render_config
registry_config_file=${REGISTRIES_FILE:-"$ROOT/k3d/generated/registries.yaml"}

if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx awx-dev; then
  echo "Cluster 'awx-dev' already exists"
  echo 'Node proxy and registry changes require: make cluster-delete cluster-create'
  exit 0
fi

mkdir -p data/postgres
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
