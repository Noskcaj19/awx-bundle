#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "═══════════════════════════════════════════"
echo "  AWX in a Box — k3d deployment"
echo "═══════════════════════════════════════════"
echo

make check
echo

echo "▸ Creating k3d cluster..."
make cluster-create
echo

echo "▸ Installing AWX operator..."
make operator-install
echo

echo "▸ Applying AWX instance..."
make awx-apply
echo

echo "▸ Waiting for AWX to be ready..."
make wait
echo

echo "═══════════════════════════════════════════"
echo "  AWX is up!"
echo
make url
make password
echo "═══════════════════════════════════════════"
