#!/usr/bin/env bash

set -euo pipefail

DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openclawnurse"
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/openclawnurse"
DEFAULT_CONFIG_FILE="$DEFAULT_CONFIG_DIR/openclawnurse.env"

CONFIG_FILE="$DEFAULT_CONFIG_FILE"

usage() {
  cat <<'EOF'
Usage: openclaw-fleet-dashboard-run.sh [--config <path>]

Run the fleet dashboard aggregator using values from openclawnurse.env.
EOF
}

while (($# > 0)); do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?missing value for --config}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

CONFIG_DIR="${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
STATE_DIR="${STATE_DIR:-$DEFAULT_STATE_DIR}"
FLEET_CONFIG="${FLEET_DASHBOARD_CONFIG_FILE:-$CONFIG_DIR/fleet-nodes.json}"
OUTPUT_DIR="${FLEET_DASHBOARD_OUTPUT_DIR:-$STATE_DIR/fleet-dashboard}"

args=(
  --config "$FLEET_CONFIG"
  --output-dir "$OUTPUT_DIR"
)

if [[ -n "${FLEET_DASHBOARD_PUBLISH_DIR:-}" ]]; then
  args+=(--publish-dir "$FLEET_DASHBOARD_PUBLISH_DIR")
fi
if [[ -n "${FLEET_DASHBOARD_HISTORY_DIR:-}" ]]; then
  args+=(--history-dir "$FLEET_DASHBOARD_HISTORY_DIR")
fi
if [[ "${FLEET_DASHBOARD_PUSH_KUMA:-false}" == "true" ]]; then
  args+=(--push-kuma)
fi

exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/openclaw-fleet-dashboard.sh" "${args[@]}"
