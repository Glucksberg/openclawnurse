#!/usr/bin/env bash

set -euo pipefail

DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openclawnurse"
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/openclawnurse"
DEFAULT_CONFIG_FILE="$DEFAULT_CONFIG_DIR/openclawnurse.env"

CONFIG_FILE="$DEFAULT_CONFIG_FILE"

usage() {
  cat <<'EOF'
Usage: openclaw-fleet-export-run.sh [--config <path>]

Run the fleet exporter using values from openclawnurse.env.
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

STATE_DIR="${STATE_DIR:-$DEFAULT_STATE_DIR}"
OUTPUT_FILE="${FLEET_EXPORT_OUTPUT:-$STATE_DIR/fleet/node-feed.json}"
STATUS_TIMEOUT="${FLEET_EXPORT_STATUS_TIMEOUT:-${STATUS_TIMEOUT:-10}}"
INCLUDE_STATUS="${FLEET_EXPORT_INCLUDE_STATUS:-true}"

args=(
  --config "$CONFIG_FILE"
  --output "$OUTPUT_FILE"
  --status-timeout "$STATUS_TIMEOUT"
)

if [[ -n "${FLEET_EXPORT_NODE_ID:-}" ]]; then
  args+=(--node-id "$FLEET_EXPORT_NODE_ID")
fi
if [[ -n "${FLEET_EXPORT_NODE_NAME:-}" ]]; then
  args+=(--node-name "$FLEET_EXPORT_NODE_NAME")
fi
if [[ -n "${FLEET_EXPORT_PUBLIC_URL:-}" ]]; then
  args+=(--public-url "$FLEET_EXPORT_PUBLIC_URL")
fi
if [[ "$INCLUDE_STATUS" != "true" ]]; then
  args+=(--no-status)
fi

exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/openclaw-fleet-export.sh" "${args[@]}"
