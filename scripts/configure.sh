#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=scripts/lib/config.sh
source "$ROOT/scripts/lib/config.sh"

case ${1:-} in
  validate)
    load_config true
    echo '✓ Configuration is valid'
    ;;
  render)
    load_config true
    render_config
    echo '✓ Generated protected k3d, Helm, and AWX configuration'
    ;;
  *)
    echo "Usage: $0 {validate|render}" >&2
    exit 2
    ;;
esac
