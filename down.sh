#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Destroying k3d cluster (all AWX data will be lost)..."
make cluster-delete
echo "✓ Done"
