#!/usr/bin/env bash

set -euo pipefail

DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openclawnurse"
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/openclawnurse"
DEFAULT_CONFIG_FILE="$DEFAULT_CONFIG_DIR/openclawnurse.env"
DEFAULT_STATE_FILE="$DEFAULT_STATE_DIR/doctor-state.json"

CONFIG_FILE="$DEFAULT_CONFIG_FILE"
STATE_FILE="$DEFAULT_STATE_FILE"
OUTPUT_FILE=""
NODE_ID="${HOSTNAME:-$(hostname)}"
NODE_NAME="$(hostname)"
PUBLIC_URL=""
STATUS_TIMEOUT="${STATUS_TIMEOUT:-10}"
INCLUDE_STATUS=1

usage() {
  cat <<'EOF'
Usage: openclaw-fleet-export.sh [options]

Options:
  --config <path>        OpenClawNurse env file.
  --state-file <path>    doctor-state.json file.
  --output <path>        Write the feed to this path instead of stdout.
  --node-id <id>         Stable node id for the fleet.
  --node-name <name>     Human-readable node name.
  --public-url <url>     Optional dashboard/login URL for this node.
  --status-timeout <s>   Timeout for `openclaw status --json`.
  --no-status            Skip `openclaw status --json`.
  -h, --help             Show this help.
EOF
}

while (($# > 0)); do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?missing value for --config}"
      shift 2
      ;;
    --state-file)
      STATE_FILE="${2:?missing value for --state-file}"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="${2:?missing value for --output}"
      shift 2
      ;;
    --node-id)
      NODE_ID="${2:?missing value for --node-id}"
      shift 2
      ;;
    --node-name)
      NODE_NAME="${2:?missing value for --node-name}"
      shift 2
      ;;
    --public-url)
      PUBLIC_URL="${2:?missing value for --public-url}"
      shift 2
      ;;
    --status-timeout)
      STATUS_TIMEOUT="${2:?missing value for --status-timeout}"
      shift 2
      ;;
    --no-status)
      INCLUDE_STATUS=0
      shift
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

STATE_FILE="${STATE_FILE:-${STATE_DIR:-$DEFAULT_STATE_DIR}/doctor-state.json}"

prepend_path() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  case ":${PATH:-}:" in
    *":$dir:"*) ;;
    *) PATH="$dir${PATH:+:$PATH}" ;;
  esac
}

bootstrap_path() {
  local dir
  local candidates=(
    "$HOME/.npm-global/bin"
    "$HOME/.local/bin"
    "$HOME/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  )
  if [[ -n "${EXTRA_PATH:-}" ]]; then
    local old_ifs="$IFS"
    IFS=':'
    read -r -a extra_dirs <<<"${EXTRA_PATH}"
    IFS="$old_ifs"
    for dir in "${extra_dirs[@]}"; do
      prepend_path "$dir"
    done
  fi
  for dir in "${candidates[@]}"; do
    prepend_path "$dir"
  done
  export PATH
}

bootstrap_path

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Missing state file: $STATE_FILE" >&2
  exit 1
fi

if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
  echo "Invalid JSON state file: $STATE_FILE" >&2
  exit 1
fi

status_json='null'
status_fetch_ok=false
status_error=""

if [[ "$INCLUDE_STATUS" -eq 1 ]]; then
  if command -v openclaw >/dev/null 2>&1; then
    set +e
    status_output="$(timeout "${STATUS_TIMEOUT}s" openclaw status --json 2>&1)"
    status_code=$?
    set -e
    if [[ "$status_code" -eq 0 ]] && printf '%s' "$status_output" | jq empty >/dev/null 2>&1; then
      status_json="$(printf '%s' "$status_output" | jq '{
        runtimeVersion,
        gateway: {
          reachable: (.gateway.reachable // false),
          mode: (.gateway.mode // null),
          url: (.gateway.url // null),
          version: (.gateway.self.version // null),
          latencyMs: (.gateway.connectLatencyMs // null)
        },
        sessions: {
          count: (.sessions.count // null),
          defaultModel: (.sessions.defaults.model // null)
        },
        tasks: {
          total: (.tasks.total // null),
          failures: (.tasks.failures // null),
          active: (.tasks.active // null)
        },
        taskAudit: {
          warnings: (.taskAudit.warnings // null),
          errors: (.taskAudit.errors // null)
        }
      }')"
      status_fetch_ok=true
    else
      status_error="$(printf '%s' "$status_output" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-300)"
    fi
  else
    status_error="openclaw command not found"
  fi
fi

doctor_output="$(jq -r '.outputs.doctor // ""' "$STATE_FILE")"
doctor_summary="$(jq -r '.doctorSummary // ""' "$STATE_FILE")"
doctor_status="$(jq -r '.status // "UNKNOWN"' "$STATE_FILE")"
gateway_healthy="$(jq -r '.gatewayHealthy // false' "$STATE_FILE")"
notification_pending="$(jq -r '.notificationPending // false' "$STATE_FILE")"
current_version="$(jq -r '.currentVersionAfter // ""' "$STATE_FILE")"
available_version="$(jq -r '.availableVersion // ""' "$STATE_FILE")"

auth_state="unknown"
if printf '%s' "$doctor_output" | grep -qiE 'Model auth|OpenClaw auth profile: .*missing|OpenClaw auth profile: .*wired to provider|re-auth required|invalid token expires metadata|OAuth refresh failed|refresh failed|invalid refresh token|invalid_grant|expired \(0m\)'; then
  auth_state="issue"
elif printf '%s' "$doctor_output" | grep -qiE 'headless claude auth: ok|openclaw auth profile:'; then
  auth_state="ok"
elif [[ "$doctor_status" == "OK" || "$doctor_status" == "UPDATED" || "$doctor_status" == "UPDATED_WITH_REPAIRS" ]]; then
  auth_state="ok"
fi

update_state="unknown"
if [[ -n "$current_version" && -n "$available_version" ]]; then
  if [[ "$current_version" == "$available_version" ]]; then
    update_state="current"
  else
    update_state="outdated"
  fi
fi

doctor_state="ok"
case "$doctor_status" in
  FAILED|FAILED_NOTIFICATION_PENDING)
    doctor_state="issue"
    ;;
  DEGRADED|UPDATED_WITH_REPAIRS)
    doctor_state="warn"
    ;;
  UPDATED)
    doctor_state="ok"
    ;;
  OK)
    if [[ "$doctor_summary" == *"corrective action"* ]]; then
      doctor_state="repaired"
    fi
    ;;
  *)
    doctor_state="unknown"
    ;;
esac

payload="$(
  jq -n \
    --arg generatedAt "$(date --iso-8601=seconds)" \
    --arg nodeId "$NODE_ID" \
    --arg nodeName "$NODE_NAME" \
    --arg hostname "$(jq -r '.hostname // empty' "$STATE_FILE")" \
    --arg publicUrl "$PUBLIC_URL" \
    --arg stateFile "$STATE_FILE" \
    --arg configFile "$CONFIG_FILE" \
    --arg authState "$auth_state" \
    --arg updateState "$update_state" \
    --arg doctorState "$doctor_state" \
    --arg statusError "$status_error" \
    --argjson statusFetchOk "$status_fetch_ok" \
    --argjson nurse "$(jq '{timestamp, status, currentVersionBefore, currentVersionAfter, availableVersion, channel, dryRun, doctorAttempted, doctorExitCode, doctorSummary, gatewayHealthy, notificationPending, consecutiveFailures, durationSeconds, errors, fixes, actions}' "$STATE_FILE")" \
    --argjson statusSnapshot "$status_json" \
    '{
      schemaVersion: 1,
      generatedAt: $generatedAt,
      node: {
        id: $nodeId,
        name: $nodeName,
        hostname: $hostname,
        publicUrl: (if $publicUrl == "" then null else $publicUrl end),
        stateFile: $stateFile,
        configFile: $configFile
      },
      checks: {
        auth: $authState,
        update: $updateState,
        doctor: $doctorState,
        gateway: (if ($nurse.gatewayHealthy // false) then "ok" else "issue" end),
        notifications: (if ($nurse.notificationPending // false) then "pending" else "ok" end)
      },
      nurse: $nurse,
      openclaw: {
        statusFetchOk: $statusFetchOk,
        statusError: (if $statusError == "" then null else $statusError end),
        snapshot: $statusSnapshot
      }
    }'
)"

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  printf '%s\n' "$payload" >"$OUTPUT_FILE"
else
  printf '%s\n' "$payload"
fi
