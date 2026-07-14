#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"
load_config true

kubectl create namespace awx --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [[ -z $REGISTRY_USERNAME ]]; then
  echo 'No registry credentials configured'
  exit 0
fi

kubectl -n awx create secret docker-registry "$REGISTRY_PULL_SECRET_NAME" \
  --docker-server="$REGISTRY_SERVER" \
  --docker-username="$REGISTRY_USERNAME" \
  --docker-password="$REGISTRY_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n awx create secret generic awx-ee-registry-credentials \
  --from-literal=url="$REGISTRY_SERVER" \
  --from-literal=username="$REGISTRY_USERNAME" \
  --from-literal=password="$REGISTRY_PASSWORD" \
  --from-literal=ssl_verify="$REGISTRY_TLS_VERIFY" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "✓ Applied registry pull secrets in namespace awx"
