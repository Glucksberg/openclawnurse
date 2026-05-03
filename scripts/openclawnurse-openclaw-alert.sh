#!/usr/bin/env bash

set -euo pipefail

DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openclawnurse"
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/openclawnurse"
CONFIG_FILE="${OPENCLAWNURSE_CONFIG_FILE:-$DEFAULT_CONFIG_DIR/openclawnurse.env}"

usage() {
  cat <<'EOF'
Usage: openclawnurse-openclaw-alert.sh [options]

Options:
  --config <path>  Override the env config file path.
  --dry-run        Print the message decision without sending.
  -h, --help       Show this help.
EOF
}

DRY_RUN=0
while (($# > 0)); do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?missing value for --config}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

STATE_DIR="${STATE_DIR:-$DEFAULT_STATE_DIR}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/doctor-state.json}"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
OPENCLAW_ALERT_CHANNEL="${OPENCLAW_ALERT_CHANNEL:-telegram}"
OPENCLAW_ALERT_TARGET="${OPENCLAW_ALERT_TARGET:-}"
OPENCLAW_ALERT_THREAD_ID="${OPENCLAW_ALERT_THREAD_ID:-}"
OPENCLAW_ALERT_STATE_FILE="${OPENCLAW_ALERT_STATE_FILE:-$STATE_DIR/openclaw-alert-state.json}"
OPENCLAW_ALERT_MIN_INTERVAL_SECONDS="${OPENCLAW_ALERT_MIN_INTERVAL_SECONDS:-21600}"
OPENCLAW_ALERT_RECOVERY="${OPENCLAW_ALERT_RECOVERY:-true}"
REPORT_INSTANCE_LABEL="${REPORT_INSTANCE_LABEL:-$(hostname)}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

json_get() {
  local filter="$1"
  jq -r "$filter" "$STATE_FILE" 2>/dev/null
}

truncate_line() {
  local max="$1"
  local value="$2"
  value="${value//$'\n'/; }"
  if ((${#value} > max)); then
    printf '%s...' "${value:0:max}"
  else
    printf '%s' "$value"
  fi
}

send_message() {
  local message="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY_RUN_SEND\n%s\n' "$message"
    return 0
  fi

  local cmd=("$OPENCLAW_BIN" message send --channel "$OPENCLAW_ALERT_CHANNEL" --target "$OPENCLAW_ALERT_TARGET" --message "$message" --json)
  if [[ -n "$OPENCLAW_ALERT_THREAD_ID" ]]; then
    cmd+=(--thread-id "$OPENCLAW_ALERT_THREAD_ID")
  fi
  "${cmd[@]}" >/dev/null
}

persist_alert_state() {
  local active="$1"
  local hash="$2"
  local now="$3"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY_RUN_STATE active=%s hash=%s lastSentAt=%s\n' "$active" "$hash" "$now"
    return 0
  fi
  mkdir -p "$(dirname "$OPENCLAW_ALERT_STATE_FILE")"
  jq -n \
    --argjson active "$active" \
    --arg hash "$hash" \
    --argjson lastSentAt "$now" \
    --arg timestamp "$(date --iso-8601=seconds)" \
    '{active:$active, hash:$hash, lastSentAt:$lastSentAt, timestamp:$timestamp}' \
    >"$OPENCLAW_ALERT_STATE_FILE.tmp"
  mv "$OPENCLAW_ALERT_STATE_FILE.tmp" "$OPENCLAW_ALERT_STATE_FILE"
}

require_cmd jq
if [[ "$OPENCLAW_BIN" == */* ]]; then
  [[ -x "$OPENCLAW_BIN" ]] || {
    echo "OPENCLAW_BIN is not executable: $OPENCLAW_BIN" >&2
    exit 1
  }
else
  require_cmd "$OPENCLAW_BIN"
fi

if [[ -z "$OPENCLAW_ALERT_TARGET" ]]; then
  echo "OPENCLAW_ALERT_TARGET is not configured; skipping"
  exit 0
fi

now="$(date +%s)"
previous_active="false"
previous_hash=""
previous_sent_at="0"
if [[ -f "$OPENCLAW_ALERT_STATE_FILE" ]] && jq empty "$OPENCLAW_ALERT_STATE_FILE" >/dev/null 2>&1; then
  previous_active="$(jq -r '.active // false' "$OPENCLAW_ALERT_STATE_FILE")"
  previous_hash="$(jq -r '.hash // empty' "$OPENCLAW_ALERT_STATE_FILE")"
  previous_sent_at="$(jq -r '.lastSentAt // 0' "$OPENCLAW_ALERT_STATE_FILE")"
fi

if [[ ! -f "$STATE_FILE" ]] || ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
  hash="missing-state"
  if [[ "$hash" == "$previous_hash" && $((now - previous_sent_at)) -lt "$OPENCLAW_ALERT_MIN_INTERVAL_SECONDS" ]]; then
    echo "No alert: missing state already reported recently"
    exit 0
  fi
  send_message "OpenClawNurse alerta em $REPORT_INSTANCE_LABEL
Status: FAILED
Problema: estado do Nurse ausente ou JSON invalido em $STATE_FILE"
  persist_alert_state true "$hash" "$now"
  echo "Alert sent: missing state"
  exit 0
fi

status="$(json_get '.status // "UNKNOWN"')"
activity_count="$(jq -r '
  [
    (select(.updateSucceeded == true) | "update"),
    (select(.configRestored == true) | "config-restored"),
    (select(.restartSucceeded == true) | "gateway-restart"),
    ((.remediations // [])[]? | select(.result == "applied") | "remediation:" + .code)
  ] | length
' "$STATE_FILE")"
activity_summary="$(jq -r '
  [
    (select(.updateSucceeded == true) | "update aplicado"),
    (select(.configRestored == true) | "config restaurada"),
    (select(.restartSucceeded == true) | "gateway reiniciado"),
    ((.remediations // [])[]? | select(.result == "applied") | "remediacao " + .code)
  ] | unique | join("; ")
' "$STATE_FILE")"

if [[ "$status" == "OK" && "${activity_count:-0}" == "0" ]]; then
  if [[ "$previous_active" == "true" && "$OPENCLAW_ALERT_RECOVERY" == "true" ]]; then
    version="$(json_get '.currentVersionAfter // "unknown"')"
    send_message "OpenClawNurse recuperado em $REPORT_INSTANCE_LABEL
Status: OK
OpenClaw: $version
Gateway: healthy"
    persist_alert_state false "ok" "$now"
    echo "Recovery alert sent"
    exit 0
  fi
  echo "No alert: status OK"
  exit 0
fi

hash="$(
  jq -c '{
    status,
    updateSucceeded,
    configRestored,
    restartSucceeded,
    remediations,
    fixes,
    errors,
    actions,
    sanityFindings: (.sanity.findings // []),
    gatewayHealthy,
    currentVersionAfter,
    availableVersion
  }' "$STATE_FILE" | sha256sum | awk '{print $1}'
)"

if [[ "$hash" == "$previous_hash" && $((now - previous_sent_at)) -lt "$OPENCLAW_ALERT_MIN_INTERVAL_SECONDS" ]]; then
  echo "No alert: same incident already reported recently"
  exit 0
fi

version="$(json_get '.currentVersionAfter // "unknown"')"
available="$(json_get '.availableVersion // "unknown"')"
gateway="$(json_get 'if .gatewayHealthy == true then "healthy" else "unhealthy" end')"
fixes="$(jq -r '(.fixes // [])[:3] | join("; ")' "$STATE_FILE")"
errors="$(jq -r '(.errors // [])[:3] | join("; ")' "$STATE_FILE")"
actions="$(jq -r '(.actions // [])[:3] | join("; ")' "$STATE_FILE")"
findings="$(jq -r '(.sanity.findings // [])[:3] | join("; ")' "$STATE_FILE")"
report_log="$(jq -r '.outputs.doctor // empty' "$STATE_FILE" >/dev/null 2>&1 && printf '%s' "$STATE_FILE")"

message="OpenClawNurse alerta em $REPORT_INSTANCE_LABEL
Status: $status
OpenClaw: $version (latest $available)
Gateway: $gateway"

if [[ -n "$activity_summary" ]]; then
  message="$message
Atividade: $(truncate_line 500 "$activity_summary")"
fi
if [[ -n "$fixes" ]]; then
  message="$message
Correcoes: $(truncate_line 500 "$fixes")"
fi
if [[ -n "$errors" ]]; then
  message="$message
Erros: $(truncate_line 500 "$errors")"
fi
if [[ -n "$findings" ]]; then
  message="$message
Sanidade: $(truncate_line 500 "$findings")"
fi
if [[ -n "$actions" ]]; then
  message="$message
Acoes: $(truncate_line 500 "$actions")"
fi
message="$message
Estado: $report_log"

send_message "$message"
persist_alert_state true "$hash" "$now"
echo "Alert sent: $status"
