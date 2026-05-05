#!/usr/bin/env bash

set -u
set -o pipefail

PROGRAM_NAME="openclawnurse"
PROGRAM_VERSION="0.1.0"

DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openclawnurse"
DEFAULT_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/openclawnurse"
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/openclawnurse"
DEFAULT_CONFIG_FILE="$DEFAULT_CONFIG_DIR/openclawnurse.env"

CONFIG_FILE="${OPENCLAWNURSE_CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
CONFIG_DIR="${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
DATA_DIR="${DATA_DIR:-$DEFAULT_DATA_DIR}"
STATE_DIR="${STATE_DIR:-$DEFAULT_STATE_DIR}"
DRY_RUN=0
RETRY_PENDING_ONLY=0
NO_NOTIFY=0
SELF_TEST=0

usage() {
  cat <<'EOF'
Usage: openclaw-doctor.sh [options]

Options:
  --config <path>       Override the env config file path.
  --dry-run             Skip state-changing actions like update, repair and restart.
  --retry-pending       Only retry pending notifications and exit.
  --no-notify           Skip notification delivery for this run.
  --self-test           Validate config, connectivity and OpenClaw access without maintenance.
  -h, --help            Show this help.
EOF
}

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
    --retry-pending)
      RETRY_PENDING_ONLY=1
      shift
      ;;
    --no-notify)
      NO_NOTIFY=1
      shift
      ;;
    --self-test)
      SELF_TEST=1
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

prepend_path() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  case ":${PATH:-}:" in
    *":$dir:"*) ;;
    *)
      if [[ -n "${PATH:-}" ]]; then
        PATH="$dir:$PATH"
      else
        PATH="$dir"
      fi
      ;;
  esac
}

bootstrap_path() {
  local extra_dir
  local default_pnpm_home="$HOME/.local/share/pnpm"
  local candidates=(
    "$default_pnpm_home"
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
    for extra_dir in "${extra_dirs[@]}"; do
      prepend_path "$extra_dir"
    done
  fi

  local dir
  for dir in "${candidates[@]}"; do
    prepend_path "$dir"
  done
  if [[ -z "${PNPM_HOME:-}" && -d "$default_pnpm_home" ]]; then
    PNPM_HOME="$default_pnpm_home"
    export PNPM_HOME
  fi
  export PATH
}

bootstrap_path

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-}"
OPENCLAW_STATE_HOME="${OPENCLAW_STATE_HOME:-$HOME/.openclaw}"
REPORT_CHANNEL="${REPORT_CHANNEL:-telegram}"
TELEGRAM_TARGET="${TELEGRAM_TARGET:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
AUTO_DETECT_TELEGRAM_TARGET="${AUTO_DETECT_TELEGRAM_TARGET:-true}"
TELEGRAM_API_BASE_URL="${TELEGRAM_API_BASE_URL:-https://api.telegram.org}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
UPDATE_CHANNEL="${UPDATE_CHANNEL:-stable}"
UPDATE_TAG="${UPDATE_TAG:-}"
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-900}"
STATUS_TIMEOUT="${STATUS_TIMEOUT:-10}"
DOCTOR_TIMEOUT="${DOCTOR_TIMEOUT:-300}"
GATEWAY_WAIT_TIMEOUT="${GATEWAY_WAIT_TIMEOUT:-180}"
GATEWAY_WAIT_INTERVAL="${GATEWAY_WAIT_INTERVAL:-5}"
HEALTH_TIMEOUT_MS="${HEALTH_TIMEOUT_MS:-10000}"
MAX_CONSECUTIVE_UPDATE_FAILURES="${MAX_CONSECUTIVE_UPDATE_FAILURES:-3}"
RETRY_NOTIFICATION_ON_NEXT_RUN="${RETRY_NOTIFICATION_ON_NEXT_RUN:-true}"
AUTO_REMEDIATE_MISSING_TRANSCRIPTS="${AUTO_REMEDIATE_MISSING_TRANSCRIPTS:-true}"
AUTO_REMEDIATE_ORPHAN_TRANSCRIPTS="${AUTO_REMEDIATE_ORPHAN_TRANSCRIPTS:-true}"
AUTO_REMEDIATE_ALL_AGENTS="${AUTO_REMEDIATE_ALL_AGENTS:-false}"
AUTO_RESTART_UNHEALTHY_GATEWAY="${AUTO_RESTART_UNHEALTHY_GATEWAY:-true}"
AUTO_REFRESH_STALE_GATEWAY_SERVICE="${AUTO_REFRESH_STALE_GATEWAY_SERVICE:-true}"
AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD="${AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD:-true}"
PM2_GATEWAY_APP_NAMES="${PM2_GATEWAY_APP_NAMES:-${PM2_GATEWAY_APP_NAME:-openclaw-gateway openclaw}}"
MAX_GATEWAY_RESTARTS_PER_DAY="${MAX_GATEWAY_RESTARTS_PER_DAY:-1}"
MAX_GATEWAY_RESTARTS_PER_WINDOW="${MAX_GATEWAY_RESTARTS_PER_WINDOW:-3}"
GATEWAY_RESTART_WINDOW_SECONDS="${GATEWAY_RESTART_WINDOW_SECONDS:-300}"
MAX_ORPHAN_TRANSCRIPTS_PER_RUN="${MAX_ORPHAN_TRANSCRIPTS_PER_RUN:-20}"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-$OPENCLAW_STATE_HOME/openclaw.json}"
CONFIG_BACKUP_ENABLED="${CONFIG_BACKUP_ENABLED:-true}"
CONFIG_BACKUP_DIR="${CONFIG_BACKUP_DIR:-$STATE_DIR/config-backups/openclaw}"
CONFIG_BACKUP_RETENTION="${CONFIG_BACKUP_RETENTION:-20}"
AUTO_RESTORE_BROKEN_CONFIG="${AUTO_RESTORE_BROKEN_CONFIG:-true}"
CONFIG_DIFF_MAX_CHARS="${CONFIG_DIFF_MAX_CHARS:-1200}"
DIAGNOSTIC_LOG_LINES="${DIAGNOSTIC_LOG_LINES:-20}"
ENABLE_RUNTIME_SANITY="${ENABLE_RUNTIME_SANITY:-true}"
ENABLE_TELEGRAM_SANITY="${ENABLE_TELEGRAM_SANITY:-true}"
ENABLE_GATEWAY_LOG_SCAN="${ENABLE_GATEWAY_LOG_SCAN:-true}"
EXPECTED_OPENCLAW_MODEL="${EXPECTED_OPENCLAW_MODEL:-}"
EXPECTED_TELEGRAM_COMMANDS="${EXPECTED_TELEGRAM_COMMANDS:-new reset}"
AUTO_REMEDIATE_TELEGRAM_COMMANDS="${AUTO_REMEDIATE_TELEGRAM_COMMANDS:-true}"
GATEWAY_LOG_SINCE="${GATEWAY_LOG_SINCE:-last-run}"
GATEWAY_LOG_FALLBACK_SINCE="${GATEWAY_LOG_FALLBACK_SINCE:-24 hours ago}"
GATEWAY_LOG_MAX_LINES="${GATEWAY_LOG_MAX_LINES:-4000}"
OPENCLAW_EXTRA_SCAN_PATHS="${OPENCLAW_EXTRA_SCAN_PATHS:-$HOME/openclaw/node_modules/.bin/openclaw $HOME/.local/share/pnpm/openclaw $HOME/.npm-global/bin/openclaw}"
CHECK_SHELL_ALIASES="${CHECK_SHELL_ALIASES:-true}"
AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS="${AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS:-true}"
OPENCLAW_REMEDIABLE_INSTALL_PATHS="${OPENCLAW_REMEDIABLE_INSTALL_PATHS:-$HOME/openclaw/node_modules/.bin/openclaw $HOME/.npm-global/bin/openclaw $HOME/.npm-global/lib/node_modules/openclaw $HOME/.local/share/pnpm/global/5/node_modules/openclaw}"
AUTO_REPAIR_OPENCLAW_LAUNCHER="${AUTO_REPAIR_OPENCLAW_LAUNCHER:-true}"
OPENCLAW_LAUNCHER_PATH="${OPENCLAW_LAUNCHER_PATH:-$HOME/.local/share/pnpm/openclaw}"
AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING="${AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING:-true}"
AUTO_REMEDIATE_CONFIG_VERSION_DRIFT="${AUTO_REMEDIATE_CONFIG_VERSION_DRIFT:-true}"
AUTO_REFRESH_GATEWAY_SERVICE_AFTER_UPDATE="${AUTO_REFRESH_GATEWAY_SERVICE_AFTER_UPDATE:-true}"
RESTART_MODE="${RESTART_MODE:-systemd_user}"
SYSTEMD_UNIT_NAME="${SYSTEMD_UNIT_NAME:-openclaw-gateway.service}"
RESTART_COMMAND="${RESTART_COMMAND:-}"
NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-}"
OPENCLAW_NO_RESPAWN="${OPENCLAW_NO_RESPAWN:-}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
REPORT_MAX_CHARS="${REPORT_MAX_CHARS:-3500}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOG_RETENTION_MB="${LOG_RETENTION_MB:-200}"
CONFIG_DIR="${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
DATA_DIR="${DATA_DIR:-$DEFAULT_DATA_DIR}"
STATE_DIR="${STATE_DIR:-$DEFAULT_STATE_DIR}"
LOG_DIR="${LOG_DIR:-$STATE_DIR/logs}"
LOCK_FILE="${LOCK_FILE:-$STATE_DIR/doctor.lock}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/doctor-state.json}"
GATEWAY_RESTART_STATE_FILE="${GATEWAY_RESTART_STATE_FILE:-$STATE_DIR/gateway-restart-state.json}"
PENDING_TEXT_FILE="${PENDING_TEXT_FILE:-$STATE_DIR/pending-report.txt}"
PENDING_JSON_FILE="${PENDING_JSON_FILE:-$STATE_DIR/pending-report.json}"

prepare_openclaw_env() {
  if [[ -n "$NODE_COMPILE_CACHE" ]]; then
    mkdir -p "$NODE_COMPILE_CACHE" >/dev/null 2>&1 || true
    export NODE_COMPILE_CACHE
  fi

  if [[ -n "$OPENCLAW_NO_RESPAWN" ]]; then
    export OPENCLAW_NO_RESPAWN
  fi
}

prepare_openclaw_env

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR" "$LOG_DIR"
if [[ "$CONFIG_BACKUP_ENABLED" == "true" ]]; then
  mkdir -p "$CONFIG_BACKUP_DIR"
fi

RUN_ID="$(TZ="$TIMEZONE" date '+%Y%m%d-%H%M%S')"
RUN_DATE="$(TZ="$TIMEZONE" date '+%Y-%m-%d %H:%M:%S %Z')"
RUN_ISO="$(TZ="$TIMEZONE" date --iso-8601=seconds)"
HOST_NAME="$(hostname)"
REPORT_INSTANCE_LABEL="${REPORT_INSTANCE_LABEL:-$HOST_NAME}"
RUN_LOG_FILE="$LOG_DIR/doctor-$RUN_ID.log"
RUN_JSON_FILE="$LOG_DIR/doctor-$RUN_ID.json"

exec > >(tee -a "$RUN_LOG_FILE") 2>&1

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(TZ="$TIMEZONE" date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

append_array() {
  local name="$1"
  shift
  local value="$*"
  [[ -n "$value" ]] || return 0
  local -n ref="$name"
  ref+=("$value")
}

remove_array_value() {
  local name="$1"
  local value="$2"
  local -n ref="$name"
  local filtered=()
  local item
  for item in "${ref[@]:-}"; do
    if [[ "$item" != "$value" ]]; then
      filtered+=("$item")
    fi
  done
  ref=("${filtered[@]}")
}

append_unique_array() {
  local name="$1"
  shift
  local value="$*"
  [[ -n "$value" ]] || return 0
  local -n ref="$name"
  local item
  for item in "${ref[@]:-}"; do
    [[ "$item" == "$value" ]] && return 0
  done
  ref+=("$value")
}

append_sanity_finding() {
  SANITY_DEGRADED=1
  append_array SANITY_FINDINGS "$*"
}

append_sanity_critical() {
  SANITY_DEGRADED=1
  SANITY_CRITICAL=1
  append_array SANITY_FINDINGS "$*"
}

print_bullets_from_array() {
  local name="$1"
  local -n ref="$name"
  local item
  for item in "${ref[@]:-}"; do
    [[ -n "$item" ]] || continue
    printf -- '- %s\n' "$item"
  done
}

array_has_nonempty() {
  local name="$1"
  local -n ref="$name"
  local item
  for item in "${ref[@]:-}"; do
    [[ -n "$item" ]] && return 0
  done
  return 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_capture() {
  local output_var="$1"
  local status_var="$2"
  local label="$3"
  shift 3
  local captured_output
  local captured_status

  log INFO "$label"
  captured_output="$("$@" 2>&1)"
  captured_status=$?
  printf -v "$output_var" '%s' "$captured_output"
  printf -v "$status_var" '%s' "$captured_status"
  if [[ "$captured_status" -eq 0 ]]; then
    log INFO "$label succeeded"
  else
    log ERROR "$label failed with exit $captured_status"
  fi
}

run_capture_allow_fail() {
  local output_var="$1"
  local status_var="$2"
  local label="$3"
  shift 3
  local captured_output
  local captured_status
  local had_errexit=0

  log INFO "$label"
  case $- in
    *e*) had_errexit=1 ;;
  esac
  set +e
  captured_output="$("$@" 2>&1)"
  captured_status=$?
  if [[ "$had_errexit" -eq 1 ]]; then
    set -e
  fi
  printf -v "$output_var" '%s' "$captured_output"
  printf -v "$status_var" '%s' "$captured_status"
  if [[ "$captured_status" -eq 0 ]]; then
    log INFO "$label succeeded"
  else
    log ERROR "$label failed with exit $captured_status"
  fi
}

run_capture_with_heartbeat() {
  local output_var="$1"
  local status_var="$2"
  local label="$3"
  local heartbeat_seconds="$4"
  shift 4
  local captured_output
  local captured_status
  local capture_file
  local pid
  local start_epoch
  local next_heartbeat
  local elapsed
  local pid_stat

  capture_file="$(mktemp "$STATE_DIR/capture.XXXXXX")" || {
    printf -v "$output_var" '%s' "mktemp failed"
    printf -v "$status_var" '%s' 1
    log ERROR "$label failed before start: mktemp failed"
    return 0
  }

  log INFO "$label"
  start_epoch="$(date +%s)"
  next_heartbeat="$heartbeat_seconds"
  "$@" >"$capture_file" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    pid_stat="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
    [[ -z "$pid_stat" || "${pid_stat:0:1}" == "Z" ]] && break
    sleep 1
    elapsed=$(( $(date +%s) - start_epoch ))
    if (( elapsed >= next_heartbeat )); then
      log INFO "$label still running (${elapsed}s elapsed)"
      next_heartbeat=$((next_heartbeat + heartbeat_seconds))
    fi
  done

  wait "$pid"
  captured_status=$?
  captured_output="$(cat "$capture_file" 2>/dev/null || true)"
  rm -f "$capture_file"

  printf -v "$output_var" '%s' "$captured_output"
  printf -v "$status_var" '%s' "$captured_status"
  if [[ "$captured_status" -eq 0 ]]; then
    log INFO "$label succeeded"
  else
    log ERROR "$label failed with exit $captured_status"
  fi
}

build_openclaw_cmd() {
  local name="$1"
  local -n ref="$name"
  ref=("$OPENCLAW_BIN")
  if [[ -n "$OPENCLAW_PROFILE" ]]; then
    ref+=(--profile "$OPENCLAW_PROFILE")
  fi
}

json_bool() {
  if [[ "$1" == "1" || "$1" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

json_int() {
  if [[ "$1" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$1"
  else
    printf '0'
  fi
}

json_array_from_name() {
  local name="$1"
  local -n ref="$name"
  if ((${#ref[@]} == 0)); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${ref[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]'
}

trim_report() {
  local text="$1"
  if ((${#text} <= REPORT_MAX_CHARS)); then
    printf '%s' "$text"
  else
    printf '%s\n\n[report truncated to %s characters]' "${text:0:REPORT_MAX_CHARS}" "$REPORT_MAX_CHARS"
  fi
}

detect_telegram_target() {
  if [[ -n "$TELEGRAM_TARGET" || "$AUTO_DETECT_TELEGRAM_TARGET" != "true" ]]; then
    return 0
  fi

  local cron_jobs="$OPENCLAW_STATE_HOME/cron/jobs.json"
  if [[ -f "$cron_jobs" ]]; then
    local detected
    detected="$(jq -r '.jobs[]? | .delivery.to // empty' "$cron_jobs" 2>/dev/null | head -n 1)"
    if [[ -n "$detected" ]]; then
      TELEGRAM_TARGET="$detected"
      log INFO "Auto-detected TELEGRAM_TARGET from $cron_jobs: $TELEGRAM_TARGET"
    fi
  fi
}

detect_telegram_bot_token() {
  [[ -z "$TELEGRAM_BOT_TOKEN" ]] || return 0
  [[ "$REPORT_CHANNEL" == "telegram" ]] || return 0
  command_exists jq || return 0

  local cfg_file="$OPENCLAW_CONFIG_FILE"
  [[ -f "$cfg_file" ]] || return 0

  local detected
  detected="$(jq -r '.channels.telegram.botToken // empty' "$cfg_file" 2>/dev/null || true)"
  if [[ -n "$detected" && "$detected" != "null" ]]; then
    TELEGRAM_BOT_TOKEN="$detected"
    log INFO "Auto-detected TELEGRAM_BOT_TOKEN from $cfg_file"
  fi
}

send_telegram_message() {
  local message_text="$1"
  local dry_run="${2:-false}"

  detect_telegram_bot_token
  detect_telegram_target

  if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    printf '{"ok":false,"error":"missing TELEGRAM_BOT_TOKEN"}\n'
    return 1
  fi

  if [[ -z "$TELEGRAM_TARGET" ]]; then
    printf '{"ok":false,"error":"missing TELEGRAM_TARGET"}\n'
    return 1
  fi

  if [[ "$dry_run" == "true" ]]; then
    jq -n \
      --arg channel "telegram" \
      --arg target "$TELEGRAM_TARGET" \
      --arg text "$message_text" \
      '{ok:true,dryRun:true,channel:$channel,target:$target,messageLength:($text|length)}'
    return 0
  fi

  local response
  local http_code
  response="$(
    curl -sS \
      -X POST \
      --connect-timeout 10 \
      --max-time 30 \
      -o /tmp/openclawnurse-telegram-response.$$ \
      -w '%{http_code}' \
      --data-urlencode "chat_id=$TELEGRAM_TARGET" \
      --data-urlencode "text=$message_text" \
      --data-urlencode "disable_web_page_preview=true" \
      --data-urlencode "parse_mode=" \
      "$TELEGRAM_API_BASE_URL/bot$TELEGRAM_BOT_TOKEN/sendMessage"
  )"
  http_code="$response"

  if [[ -f /tmp/openclawnurse-telegram-response.$$ ]]; then
    cat /tmp/openclawnurse-telegram-response.$$
    rm -f /tmp/openclawnurse-telegram-response.$$
  fi

  [[ "$http_code" =~ ^2 ]] || return 1
  return 0
}

rotate_logs() {
  if [[ -d "$LOG_DIR" ]]; then
    find "$LOG_DIR" -type f -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  fi

  local current_mb
  current_mb="$(du -sm "$LOG_DIR" 2>/dev/null | awk '{print $1}')"
  current_mb="${current_mb:-0}"

  while (( current_mb > LOG_RETENTION_MB )); do
    local oldest
    oldest="$(find "$LOG_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n 1 | cut -d' ' -f2-)"
    [[ -n "$oldest" ]] || break
    rm -f "$oldest"
    current_mb="$(du -sm "$LOG_DIR" 2>/dev/null | awk '{print $1}')"
    current_mb="${current_mb:-0}"
  done
}

CURRENT_VERSION_BEFORE=""
CURRENT_VERSION_AFTER=""
AVAILABLE_VERSION=""
UPDATE_AVAILABLE=0
CHANNEL_VALUE=""
UPDATE_ATTEMPTED=0
UPDATE_SUCCEEDED=0
DOCTOR_ATTEMPTED=0
DOCTOR_EXIT_CODE=0
DOCTOR_CLASSIFICATION="unknown"
DOCTOR_SUMMARY=""
RESTART_ATTEMPTED=0
RESTART_SUCCEEDED=0
GATEWAY_HEALTHY=0
NOTIFICATION_DELIVERED=0
NOTIFICATION_PENDING=0
CONSECUTIVE_FAILURES=0
STATUS="FAILED"
UPDATE_OUTPUT=""
DOCTOR_OUTPUT=""
HEALTH_OUTPUT=""
UPDATE_ERROR=""
RESTART_ERROR=""
HEALTH_ERROR=""
DURATION_SECONDS=0
CONFIG_HEALTH="unknown"
CONFIG_RESTORED=0
CONFIG_BACKUP_CREATED=0
CONFIG_RESTORE_DIFF=""
DIAGNOSTICS_JSON="{}"

ERRORS=()
FIXES=()
ACTIONS=()
INCIDENT_CODES=()
REMEDIATIONS=()
SANITY_FINDINGS=()
PREVIOUS_PENDING_PRESENT=0
PREVIOUS_STATE_TIMESTAMP=""
REMEDIATION_APPLIED=0
GATEWAY_RESTARTS_TODAY=0
GATEWAY_RESTARTS_IN_WINDOW=0
SANITY_ATTEMPTED=0
SANITY_DEGRADED=0
SANITY_CRITICAL=0
OPENCLAW_INSTALLATIONS_SUMMARY=""
GATEWAY_EXECSTART=""
GATEWAY_SERVICE_VERSION=""
GATEWAY_PACKAGE_VERSION=""
GATEWAY_MODEL_DETECTED=""
TELEGRAM_COMMANDS_SUMMARY=""
GATEWAY_LOG_SUMMARY=""
PROVIDER_EMPTY_INPUT_COUNT=0
STUCK_SESSION_COUNT=0
CONFIG_INVALID_COUNT=0
UPDATE_PROVENANCE_WARNING_COUNT=0
CONFIG_LAST_TOUCHED_VERSION=""
CONFIG_VERSION_DRIFT=0
CONFIG_VERSION_DRIFT_FINDING=""
CONFIG_VERSION_DRIFT_ACTION=""

load_previous_state() {
  if [[ -f "$STATE_FILE" ]] && jq empty "$STATE_FILE" >/dev/null 2>&1; then
    CONSECUTIVE_FAILURES="$(jq -r '.consecutiveFailures // 0' "$STATE_FILE" 2>/dev/null)"
    PREVIOUS_STATE_TIMESTAMP="$(jq -r '.timestamp // empty' "$STATE_FILE" 2>/dev/null)"
  fi
  load_gateway_restart_state
  [[ -f "$PENDING_TEXT_FILE" || -f "$PENDING_JSON_FILE" ]] && PREVIOUS_PENDING_PRESENT=1 || PREVIOUS_PENDING_PRESENT=0
}

today_key() {
  TZ="$TIMEZONE" date '+%Y-%m-%d'
}

add_incident_code() {
  local code="$1"
  local existing
  for existing in "${INCIDENT_CODES[@]}"; do
    [[ "$existing" == "$code" ]] && return 0
  done
  INCIDENT_CODES+=("$code")
}

record_remediation() {
  local code="$1"
  local result="$2"
  local detail="$3"
  REMEDIATIONS+=("$code|$result|$detail")
}

json_remediations_from_name() {
  local name="$1"
  local -n ref="$name"
  if ((${#ref[@]} == 0)); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${ref[@]}" | jq -Rsc '
    split("\n")
    | map(select(length > 0))
    | map(split("|") | {
        code: .[0],
        result: (.[1] // "unknown"),
        detail: (.[2:] | join("|"))
      })' 2>/dev/null || printf '[]'
}

load_gateway_restart_state() {
  GATEWAY_RESTARTS_TODAY=0
  GATEWAY_RESTARTS_IN_WINDOW=0
  [[ -f "$GATEWAY_RESTART_STATE_FILE" ]] || return 0
  jq empty "$GATEWAY_RESTART_STATE_FILE" >/dev/null 2>&1 || return 0
  local stored_day
  stored_day="$(jq -r '.day // empty' "$GATEWAY_RESTART_STATE_FILE" 2>/dev/null)"
  if [[ "$stored_day" == "$(today_key)" ]]; then
    GATEWAY_RESTARTS_TODAY="$(jq -r '.count // 0' "$GATEWAY_RESTART_STATE_FILE" 2>/dev/null)"
  fi
  local now
  now="$(date +%s)"
  GATEWAY_RESTARTS_IN_WINDOW="$(jq -r \
    --argjson now "$now" \
    --argjson window "$(json_int "$GATEWAY_RESTART_WINDOW_SECONDS")" \
    '[.history[]? | select(($now - .) < $window)] | length' \
    "$GATEWAY_RESTART_STATE_FILE" 2>/dev/null)"
  GATEWAY_RESTARTS_IN_WINDOW="${GATEWAY_RESTARTS_IN_WINDOW:-0}"
}

record_gateway_restart() {
  local tmp="$GATEWAY_RESTART_STATE_FILE.tmp"
  local now
  local previous_file
  now="$(date +%s)"
  previous_file="$GATEWAY_RESTART_STATE_FILE"
  [[ -f "$previous_file" ]] || previous_file="/dev/null"
  GATEWAY_RESTARTS_TODAY=$((GATEWAY_RESTARTS_TODAY + 1))
  GATEWAY_RESTARTS_IN_WINDOW=$((GATEWAY_RESTARTS_IN_WINDOW + 1))
  jq -n \
    --arg day "$(today_key)" \
    --arg timestamp "$(TZ="$TIMEZONE" date --iso-8601=seconds)" \
    --argjson count "$(json_int "$GATEWAY_RESTARTS_TODAY")" \
    --argjson now "$now" \
    --argjson window "$(json_int "$GATEWAY_RESTART_WINDOW_SECONDS")" \
    --slurpfile previous "$previous_file" \
    '{
      day: $day,
      count: $count,
      lastRestartAt: $timestamp,
      history: (((($previous[0].history // []) + [$now]) | map(select(($now - .) < $window))))
    }' >"$tmp"
  mv "$tmp" "$GATEWAY_RESTART_STATE_FILE"
}

persist_json() {
  local report_text="$1"
  local report_json_tmp="$RUN_JSON_FILE.tmp"
  local state_json_tmp="$STATE_FILE.tmp"
  local errors_json fixes_json actions_json incident_codes_json remediations_json diagnostics_json sanity_findings_json

  errors_json="$(json_array_from_name ERRORS)"
  fixes_json="$(json_array_from_name FIXES)"
  actions_json="$(json_array_from_name ACTIONS)"
  incident_codes_json="$(json_array_from_name INCIDENT_CODES)"
  remediations_json="$(json_remediations_from_name REMEDIATIONS)"
  sanity_findings_json="$(printf '%s\n' "${SANITY_FINDINGS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')"
  if printf '%s' "$DIAGNOSTICS_JSON" | jq empty >/dev/null 2>&1; then
    diagnostics_json="$DIAGNOSTICS_JSON"
  else
    diagnostics_json="{}"
  fi

  if ! jq -n \
    --arg timestamp "$RUN_ISO" \
    --arg hostname "$HOST_NAME" \
    --arg status "$STATUS" \
    --arg currentVersionBefore "$CURRENT_VERSION_BEFORE" \
    --arg currentVersionAfter "$CURRENT_VERSION_AFTER" \
    --arg availableVersion "$AVAILABLE_VERSION" \
    --arg channel "$CHANNEL_VALUE" \
    --arg doctorSummary "$DOCTOR_SUMMARY" \
    --arg updateOutput "$UPDATE_OUTPUT" \
    --arg doctorOutput "$DOCTOR_OUTPUT" \
    --arg healthOutput "$HEALTH_OUTPUT" \
    --arg updateError "$UPDATE_ERROR" \
    --arg restartError "$RESTART_ERROR" \
    --arg healthError "$HEALTH_ERROR" \
    --arg configHealth "$CONFIG_HEALTH" \
    --arg configLastTouchedVersion "$CONFIG_LAST_TOUCHED_VERSION" \
    --arg configRestoreDiff "$CONFIG_RESTORE_DIFF" \
    --arg openclawInstallations "$OPENCLAW_INSTALLATIONS_SUMMARY" \
    --arg gatewayExecStart "$GATEWAY_EXECSTART" \
    --arg gatewayServiceVersion "$GATEWAY_SERVICE_VERSION" \
    --arg gatewayPackageVersion "$GATEWAY_PACKAGE_VERSION" \
    --arg gatewayModelDetected "$GATEWAY_MODEL_DETECTED" \
    --arg expectedOpenclawModel "$EXPECTED_OPENCLAW_MODEL" \
    --arg telegramCommands "$TELEGRAM_COMMANDS_SUMMARY" \
    --arg gatewayLogSummary "$GATEWAY_LOG_SUMMARY" \
    --arg reportText "$report_text" \
    --argjson dryRun "$(json_bool "$DRY_RUN")" \
    --argjson updateAttempted "$(json_bool "$UPDATE_ATTEMPTED")" \
    --argjson updateAvailable "$(json_bool "$UPDATE_AVAILABLE")" \
    --argjson updateSucceeded "$(json_bool "$UPDATE_SUCCEEDED")" \
    --argjson doctorAttempted "$(json_bool "$DOCTOR_ATTEMPTED")" \
    --argjson restartAttempted "$(json_bool "$RESTART_ATTEMPTED")" \
    --argjson restartSucceeded "$(json_bool "$RESTART_SUCCEEDED")" \
    --argjson gatewayHealthy "$(json_bool "$GATEWAY_HEALTHY")" \
    --argjson notificationDelivered "$(json_bool "$NOTIFICATION_DELIVERED")" \
    --argjson notificationPending "$(json_bool "$NOTIFICATION_PENDING")" \
    --argjson previousPendingPresent "$(json_bool "$PREVIOUS_PENDING_PRESENT")" \
    --argjson doctorExitCode "$(json_int "$DOCTOR_EXIT_CODE")" \
    --argjson consecutiveFailures "$(json_int "$CONSECUTIVE_FAILURES")" \
    --argjson durationSeconds "$(json_int "$DURATION_SECONDS")" \
    --argjson errors "$errors_json" \
    --argjson fixes "$fixes_json" \
    --argjson actions "$actions_json" \
    --argjson incidentCodes "$incident_codes_json" \
    --argjson remediations "$remediations_json" \
    --argjson gatewayRestartsToday "$(json_int "$GATEWAY_RESTARTS_TODAY")" \
    --argjson gatewayRestartsInWindow "$(json_int "$GATEWAY_RESTARTS_IN_WINDOW")" \
    --argjson configRestored "$(json_bool "$CONFIG_RESTORED")" \
    --argjson configBackupCreated "$(json_bool "$CONFIG_BACKUP_CREATED")" \
    --argjson configVersionDrift "$(json_bool "$CONFIG_VERSION_DRIFT")" \
    --argjson diagnostics "$diagnostics_json" \
    --argjson sanityAttempted "$(json_bool "$SANITY_ATTEMPTED")" \
    --argjson sanityDegraded "$(json_bool "$SANITY_DEGRADED")" \
    --argjson sanityCritical "$(json_bool "$SANITY_CRITICAL")" \
    --argjson providerEmptyInputCount "$(json_int "$PROVIDER_EMPTY_INPUT_COUNT")" \
    --argjson stuckSessionCount "$(json_int "$STUCK_SESSION_COUNT")" \
    --argjson configInvalidCount "$(json_int "$CONFIG_INVALID_COUNT")" \
    --argjson updateProvenanceWarningCount "$(json_int "$UPDATE_PROVENANCE_WARNING_COUNT")" \
    --argjson sanityFindings "$sanity_findings_json" \
    '{
      timestamp: $timestamp,
      hostname: $hostname,
      status: $status,
      currentVersionBefore: $currentVersionBefore,
      currentVersionAfter: $currentVersionAfter,
      availableVersion: $availableVersion,
      updateAvailable: $updateAvailable,
      channel: $channel,
      dryRun: $dryRun,
      updateAttempted: $updateAttempted,
      updateSucceeded: $updateSucceeded,
      doctorAttempted: $doctorAttempted,
      doctorExitCode: $doctorExitCode,
      doctorSummary: $doctorSummary,
      restartAttempted: $restartAttempted,
      restartSucceeded: $restartSucceeded,
      gatewayHealthy: $gatewayHealthy,
      notificationDelivered: $notificationDelivered,
      notificationPending: $notificationPending,
      previousPendingPresent: $previousPendingPresent,
      consecutiveFailures: $consecutiveFailures,
      durationSeconds: $durationSeconds,
      errors: $errors,
      fixes: $fixes,
      actions: $actions,
      incidentCodes: $incidentCodes,
      remediations: $remediations,
      gatewayRestartsToday: $gatewayRestartsToday,
      gatewayRestartsInWindow: $gatewayRestartsInWindow,
      config: {
        health: $configHealth,
        lastTouchedVersion: $configLastTouchedVersion,
        versionDrift: $configVersionDrift,
        restored: $configRestored,
        backupCreated: $configBackupCreated,
        restoreDiff: $configRestoreDiff
      },
      diagnostics: $diagnostics,
      sanity: {
        attempted: $sanityAttempted,
        degraded: $sanityDegraded,
        critical: $sanityCritical,
        findings: $sanityFindings,
        openclawInstallations: $openclawInstallations,
        gatewayExecStart: $gatewayExecStart,
        gatewayServiceVersion: $gatewayServiceVersion,
        gatewayPackageVersion: $gatewayPackageVersion,
        expectedOpenclawModel: $expectedOpenclawModel,
        gatewayModelDetected: $gatewayModelDetected,
        telegramCommands: $telegramCommands,
        gatewayLogSummary: $gatewayLogSummary,
        providerEmptyInputCount: $providerEmptyInputCount,
        stuckSessionCount: $stuckSessionCount,
        configInvalidCount: $configInvalidCount,
        updateProvenanceWarningCount: $updateProvenanceWarningCount
      },
      outputs: {
        update: $updateOutput,
        doctor: $doctorOutput,
        health: $healthOutput
      },
      errorsByPhase: {
        update: $updateError,
        restart: $restartError,
        health: $healthError
      },
      reportText: $reportText
    }' >"$report_json_tmp"; then
    rm -f "$report_json_tmp" "$state_json_tmp"
    log ERROR "Failed to persist run JSON; keeping previous state file intact"
    return 1
  fi

  if ! jq empty "$report_json_tmp" >/dev/null 2>&1; then
    rm -f "$report_json_tmp" "$state_json_tmp"
    log ERROR "Generated run JSON is invalid; keeping previous state file intact"
    return 1
  fi

  mv "$report_json_tmp" "$RUN_JSON_FILE"
  cp "$RUN_JSON_FILE" "$state_json_tmp"
  mv "$state_json_tmp" "$STATE_FILE"
}

persist_pending_report() {
  local report_text="$1"
  cp "$RUN_JSON_FILE" "$PENDING_JSON_FILE"
  printf '%s\n' "$report_text" >"$PENDING_TEXT_FILE"
  NOTIFICATION_PENDING=1
}

clear_pending_report() {
  rm -f "$PENDING_TEXT_FILE" "$PENDING_JSON_FILE"
}

retry_pending_report() {
  [[ "$NO_NOTIFY" -eq 1 ]] && return 0
  [[ "$REPORT_CHANNEL" == "none" || "$REPORT_CHANNEL" == "off" || "$REPORT_CHANNEL" == "disabled" ]] && return 0
  [[ "$REPORT_CHANNEL" == "telegram" && -z "$TELEGRAM_TARGET" ]] && return 0
  [[ "$REPORT_CHANNEL" == "telegram" ]] || return 0
  [[ -f "$PENDING_TEXT_FILE" ]] || return 0

  local pending_text
  pending_text="$(cat "$PENDING_TEXT_FILE")"
  pending_text="$(trim_report "$pending_text")"

  local send_output send_status
  run_capture send_output send_status "Retrying pending notification" \
    send_telegram_message "$pending_text" false

  if [[ "$send_status" -eq 0 ]]; then
    log INFO "Pending notification delivered"
    clear_pending_report
    return 0
  fi

  log ERROR "Pending notification delivery failed"
  return 1
}

build_summary_from_output() {
  local output="$1"
  local extracted
  extracted="$(printf '%s\n' "$output" \
    | grep -E 'missing transcripts|No channel security warnings detected|Telegram:|Agents:|Session store|synced ' \
    | sed -E 's/[[:space:]]*│[[:space:]]*$//; s/^[[:space:][:punct:]]+//; s/[[:space:]]+/ /g' \
    | head -n 6)"
  printf '%s' "$extracted"
}

is_valid_json_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  jq empty "$path" >/dev/null 2>&1
}

latest_valid_config_backup() {
  [[ -d "$CONFIG_BACKUP_DIR" ]] || return 1
  local backup
  while IFS= read -r backup; do
    [[ -n "$backup" ]] || continue
    if is_valid_json_file "$backup"; then
      printf '%s' "$backup"
      return 0
    fi
  done < <(find "$CONFIG_BACKUP_DIR" -type f -name "$(basename "$OPENCLAW_CONFIG_FILE").*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  return 1
}

trim_diff() {
  local text="$1"
  if ((${#text} <= CONFIG_DIFF_MAX_CHARS)); then
    printf '%s' "$text"
  else
    printf '%s\n\n[diff truncated to %s characters]' "${text:0:CONFIG_DIFF_MAX_CHARS}" "$CONFIG_DIFF_MAX_CHARS"
  fi
}

config_diff_against_backup() {
  local backup="$1"
  [[ -f "$OPENCLAW_CONFIG_FILE" && -f "$backup" ]] || return 0
  command_exists diff || return 0
  local diff_output
  diff_output="$(diff -u "$OPENCLAW_CONFIG_FILE" "$backup" 2>/dev/null || true)"
  trim_diff "$diff_output"
}

rotate_config_backups() {
  [[ -d "$CONFIG_BACKUP_DIR" ]] || return 0
  local retention
  retention="$(json_int "$CONFIG_BACKUP_RETENTION")"
  ((retention > 0)) || retention=20
  find "$CONFIG_BACKUP_DIR" -type f -name "$(basename "$OPENCLAW_CONFIG_FILE").*" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn \
    | tail -n "+$((retention + 1))" \
    | cut -d' ' -f2- \
    | while IFS= read -r old_backup; do
        [[ -n "$old_backup" ]] && rm -f "$old_backup"
      done
}

backup_openclaw_config_if_changed() {
  [[ "$CONFIG_BACKUP_ENABLED" == "true" ]] || return 0
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0
  is_valid_json_file "$OPENCLAW_CONFIG_FILE" || return 0

  CONFIG_HEALTH="valid"

  local latest
  latest="$(latest_valid_config_backup || true)"
  if [[ -n "$latest" ]] && cmp -s "$OPENCLAW_CONFIG_FILE" "$latest"; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would snapshot OpenClaw config before maintenance."
    record_remediation "config_backup" "would_apply" "would back up $OPENCLAW_CONFIG_FILE"
    return 0
  fi

  mkdir -p "$CONFIG_BACKUP_DIR"
  local ts dest
  ts="$(TZ="$TIMEZONE" date '+%Y%m%d-%H%M%S')"
  dest="$CONFIG_BACKUP_DIR/$(basename "$OPENCLAW_CONFIG_FILE").$ts"
  cp -p "$OPENCLAW_CONFIG_FILE" "$dest"
  CONFIG_BACKUP_CREATED=1
  append_array FIXES "Backed up OpenClaw config to $dest."
  record_remediation "config_backup" "applied" "$dest"
  rotate_config_backups
}

maybe_restore_broken_config() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || {
    CONFIG_HEALTH="missing"
    add_incident_code "config_missing"
    append_array ACTIONS "OpenClaw config file was not found at $OPENCLAW_CONFIG_FILE."
    return 0
  }

  if is_valid_json_file "$OPENCLAW_CONFIG_FILE"; then
    CONFIG_HEALTH="valid"
    backup_openclaw_config_if_changed
    return 0
  fi

  CONFIG_HEALTH="invalid"
  add_incident_code "config_invalid"

  local backup
  backup="$(latest_valid_config_backup || true)"
  if [[ -z "$backup" ]]; then
    append_array ERRORS "OpenClaw config is invalid JSON and no valid backup exists."
    append_array ACTIONS "Fix $OPENCLAW_CONFIG_FILE manually or provide a valid backup."
    record_remediation "config_restore" "blocked_no_backup" "no valid backup found"
    return 1
  fi

  CONFIG_RESTORE_DIFF="$(config_diff_against_backup "$backup")"

  if [[ "$AUTO_RESTORE_BROKEN_CONFIG" != "true" ]]; then
    append_array ACTIONS "OpenClaw config is invalid; latest valid backup is $backup, but auto-restore is disabled."
    record_remediation "config_restore" "blocked_by_policy" "$backup"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would restore invalid OpenClaw config from $backup."
    record_remediation "config_restore" "would_apply" "$backup"
    return 0
  fi

  cp -p "$OPENCLAW_CONFIG_FILE" "$OPENCLAW_CONFIG_FILE.broken.$RUN_ID" 2>/dev/null || true
  cp -p "$backup" "$OPENCLAW_CONFIG_FILE"
  CONFIG_HEALTH="restored"
  CONFIG_RESTORED=1
  REMEDIATION_APPLIED=1
  append_array FIXES "Restored invalid OpenClaw config from $backup."
  record_remediation "config_restore" "applied" "$backup"
  return 0
}

extract_openclaw_version() {
  sed -nE 's/.*([0-9]{4}\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?).*/\1/p' | head -n 1
}

detect_openclaw_path_version() {
  local path="$1"
  local version_line=""

  if [[ -x "$path" && ! -d "$path" ]]; then
    version_line="$(timeout 5s "$path" --version 2>/dev/null | head -n 1 || true)"
  elif [[ -f "$path/package.json" ]]; then
    version_line="$(jq -r '.version // empty' "$path/package.json" 2>/dev/null)"
  elif [[ -x "$path/openclaw.mjs" ]]; then
    version_line="$(timeout 5s "$path/openclaw.mjs" --version 2>/dev/null | head -n 1 || true)"
  fi

  printf '%s' "$version_line" | extract_openclaw_version
}

version_less() {
  local left="$1"
  local right="$2"
  [[ -n "$left" && -n "$right" && "$left" != "$right" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -n 1)" == "$left" ]]
}

canonical_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

path_is_same_or_inside() {
  local path="$1"
  local root="$2"
  [[ -n "$path" && -n "$root" ]] || return 1
  [[ "$path" == "$root" || "$path" == "$root"/* ]]
}

openclaw_package_root_from_path() {
  local path="$1"
  local real
  real="$(canonical_path "$path")"

  if [[ -d "$real" && -f "$real/package.json" ]]; then
    if [[ "$(jq -r '.name // empty' "$real/package.json" 2>/dev/null)" == "openclaw" ]]; then
      printf '%s\n' "$real"
      return 0
    fi
  fi

  case "$real" in
    */node_modules/openclaw/*)
      printf '%s\n' "${real%/node_modules/openclaw/*}/node_modules/openclaw"
      return 0
      ;;
    */node_modules/openclaw)
      printf '%s\n' "$real"
      return 0
      ;;
  esac

  if [[ -f "$real" ]]; then
    local embedded
    embedded="$(grep -oE '/[^"]*/node_modules/\.pnpm/openclaw@[^"]*/node_modules/openclaw/openclaw\.mjs' "$real" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$embedded" ]]; then
      printf '%s\n' "${embedded%/openclaw.mjs}"
      return 0
    fi
  fi
}

collect_protected_openclaw_paths() {
  local -n protected_ref="$1"
  local path real root unit_text exec_start entrypoint

  if [[ "$OPENCLAW_BIN" == */* ]]; then
    path="$OPENCLAW_BIN"
  else
    path="$(command -v "$OPENCLAW_BIN" 2>/dev/null || true)"
  fi

  if [[ -n "$path" ]]; then
    real="$(canonical_path "$path")"
    append_unique_array protected_ref "$path"
    append_unique_array protected_ref "$real"
    root="$(openclaw_package_root_from_path "$path")"
    append_unique_array protected_ref "$root"
  fi

  if [[ "$RESTART_MODE" == "systemd_user" && -n "$SYSTEMD_UNIT_NAME" ]] && command_exists systemctl; then
    unit_text="$(systemctl --user cat "$SYSTEMD_UNIT_NAME" 2>/dev/null || true)"
    exec_start="$(printf '%s\n' "$unit_text" | sed -n 's/^ExecStart=//p' | head -n 1)"
    if [[ -n "$exec_start" ]]; then
      entrypoint="$(printf '%s\n' "$exec_start" | awk '{for (i=1; i<=NF; i++) if (index($i, "openclaw/dist/") > 0) {print $i; exit}}')"
      if [[ -n "$entrypoint" ]]; then
        real="$(canonical_path "$entrypoint")"
        append_unique_array protected_ref "$entrypoint"
        append_unique_array protected_ref "$real"
        root="$(openclaw_package_root_from_path "$entrypoint")"
        append_unique_array protected_ref "$root"
      fi
    fi
  fi
}

path_is_protected_openclaw() {
  local path="$1"
  shift
  local real protected protected_real
  real="$(canonical_path "$path")"
  for protected in "$@"; do
    [[ -n "$protected" ]] || continue
    protected_real="$(canonical_path "$protected")"
    path_is_same_or_inside "$real" "$protected_real" && return 0
    path_is_same_or_inside "$protected_real" "$real" && return 0
  done
  return 1
}

read_config_last_touched_version() {
  CONFIG_LAST_TOUCHED_VERSION=""
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0
  jq empty "$OPENCLAW_CONFIG_FILE" >/dev/null 2>&1 || return 0

  local raw
  raw="$(jq -r '.meta.lastTouchedVersion // .wizard.lastRunVersion // empty' "$OPENCLAW_CONFIG_FILE" 2>/dev/null)"
  CONFIG_LAST_TOUCHED_VERSION="$(printf '%s' "$raw" | extract_openclaw_version)"
}

detect_config_version_drift() {
  read_config_last_touched_version
  CONFIG_VERSION_DRIFT=0
  [[ -n "$CONFIG_LAST_TOUCHED_VERSION" ]] || return 0

  local current_version="$CURRENT_VERSION_AFTER"
  [[ -n "$current_version" ]] || current_version="$CURRENT_VERSION_BEFORE"
  if [[ -z "$current_version" ]]; then
    current_version="$("$OPENCLAW_BIN" --version 2>/dev/null | extract_openclaw_version)"
  fi
  [[ -n "$current_version" ]] || return 0

  if version_less "$current_version" "$CONFIG_LAST_TOUCHED_VERSION"; then
    CONFIG_VERSION_DRIFT=1
    add_incident_code "openclaw_config_version_drift"
    CONFIG_VERSION_DRIFT_FINDING="OpenClaw config was last written by $CONFIG_LAST_TOUCHED_VERSION, but active CLI reports $current_version."
    if [[ "$AUTO_REMEDIATE_CONFIG_VERSION_DRIFT" == "true" ]]; then
      CONFIG_VERSION_DRIFT_ACTION="Update the canonical OpenClaw runtime and refresh the gateway service before starting the gateway."
      append_sanity_finding "$CONFIG_VERSION_DRIFT_FINDING"
      append_array ACTIONS "$CONFIG_VERSION_DRIFT_ACTION"
    else
      append_sanity_critical "$CONFIG_VERSION_DRIFT_FINDING"
      append_array ACTIONS "AUTO_REMEDIATE_CONFIG_VERSION_DRIFT is disabled; update the canonical OpenClaw runtime manually."
      record_remediation "openclaw_config_version_drift" "blocked_by_policy" "auto remediation disabled"
    fi
  fi
}

mark_config_version_drift_remediated_if_current() {
  [[ "$CONFIG_VERSION_DRIFT" -eq 1 ]] || return 0
  [[ -n "$CONFIG_LAST_TOUCHED_VERSION" ]] || return 0

  local current_version="$CURRENT_VERSION_AFTER"
  if [[ -z "$current_version" ]]; then
    current_version="$("$OPENCLAW_BIN" --version 2>/dev/null | extract_openclaw_version)"
  fi
  [[ -n "$current_version" ]] || return 0
  version_less "$current_version" "$CONFIG_LAST_TOUCHED_VERSION" && return 0

  CONFIG_VERSION_DRIFT=0
  [[ -n "$CONFIG_VERSION_DRIFT_FINDING" ]] && remove_array_value SANITY_FINDINGS "$CONFIG_VERSION_DRIFT_FINDING"
  [[ -n "$CONFIG_VERSION_DRIFT_ACTION" ]] && remove_array_value ACTIONS "$CONFIG_VERSION_DRIFT_ACTION"
  if ((${#SANITY_FINDINGS[@]} == 0)); then
    SANITY_DEGRADED=0
  fi
}

resolve_expected_model_from_config() {
  [[ -n "$EXPECTED_OPENCLAW_MODEL" ]] && return 0
  local cfg_file="$OPENCLAW_STATE_HOME/openclaw.json"
  [[ -f "$cfg_file" ]] || return 0
  EXPECTED_OPENCLAW_MODEL="$(jq -r '.agents.defaults.model.primary // .models.default // .model // empty' "$cfg_file" 2>/dev/null)"
}

validate_openclaw_config_contracts() {
  local cfg_file="$OPENCLAW_STATE_HOME/openclaw.json"
  [[ -f "$cfg_file" ]] || return 0

  if ! jq empty "$cfg_file" >/dev/null 2>&1; then
    append_sanity_critical "OpenClaw config is not valid JSON: $cfg_file"
    append_array ERRORS "OpenClaw config is not valid JSON."
    return 1
  fi

  local streaming_value
  streaming_value="$(jq -r '
    if (.channels.telegram.streaming? | type) == "object" then
      .channels.telegram.streaming.mode // empty
    else
      .channels.telegram.streaming // empty
    end
  ' "$cfg_file" 2>/dev/null)"

  case "$streaming_value" in
    ""|true|false|off|partial|block|progress) ;;
    *)
      append_sanity_critical "Invalid OpenClaw config: channels.telegram.streaming=$streaming_value"
      append_array ERRORS "Invalid OpenClaw config value for channels.telegram.streaming."
      ;;
  esac

  local native_value
  native_value="$(jq -r '.channels.telegram.commands.native // empty' "$cfg_file" 2>/dev/null)"
  case "$native_value" in
    ""|true|false|auto) ;;
    *)
      append_sanity_critical "Invalid OpenClaw config: channels.telegram.commands.native=$native_value"
      append_array ERRORS "Invalid OpenClaw config value for channels.telegram.commands.native."
      ;;
  esac
}

scan_shell_openclaw_aliases() {
  [[ "$CHECK_SHELL_ALIASES" == "true" ]] || return 0
  local rc_file
  local hits=""
  for rc_file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc"; do
    [[ -f "$rc_file" ]] || continue
    local rc_hits
    rc_hits="$(grep -HnE '^[[:space:]]*alias[[:space:]]+openclaw=' "$rc_file" 2>/dev/null || true)"
    if ! grep -Fq 'openclawnurse disabled shell function shadowing: openclaw' "$rc_file"; then
      local fn_hits
      fn_hits="$(grep -HnE '^[[:space:]]*(openclaw[[:space:]]*\(\)|function[[:space:]]+openclaw)' "$rc_file" 2>/dev/null || true)"
      [[ -n "$fn_hits" ]] && rc_hits="${rc_hits}${rc_hits:+$'\n'}${fn_hits}"
    fi
    [[ -n "$rc_hits" ]] && hits="${hits}${hits:+$'\n'}${rc_hits}"
  done

  if [[ -n "$hits" ]]; then
    if [[ "$AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING" == "true" ]]; then
      append_sanity_finding "Shell startup files still define openclaw aliases/functions after automatic remediation."
      append_array ACTIONS "Inspect shell openclaw aliases/functions if CLI and gateway versions diverge."
    else
      append_sanity_finding "Shell startup files define openclaw aliases/functions; verify they do not shadow the installed CLI."
      append_array ACTIONS "Inspect shell openclaw aliases/functions if CLI and gateway versions diverge."
    fi
  fi
}

reset_sanity_state_for_final_pass() {
  SANITY_FINDINGS=()
  SANITY_DEGRADED=0
  SANITY_CRITICAL=0
  OPENCLAW_INSTALLATIONS_SUMMARY=""
  GATEWAY_EXECSTART=""
  GATEWAY_SERVICE_VERSION=""
  GATEWAY_PACKAGE_VERSION=""
  GATEWAY_MODEL_DETECTED=""
  TELEGRAM_COMMANDS_SUMMARY=""
  GATEWAY_LOG_SUMMARY=""
  PROVIDER_EMPTY_INPUT_COUNT=0
  STUCK_SESSION_COUNT=0
  CONFIG_INVALID_COUNT=0
  UPDATE_PROVENANCE_WARNING_COUNT=0

  remove_array_value ACTIONS "Inspect shell openclaw aliases/functions if CLI and gateway versions diverge."
  remove_array_value ACTIONS "Remove or update stale OpenClaw installations that can shadow the current CLI."
  remove_array_value ACTIONS "Converge OpenClaw binaries to a single version in PATH and service definitions."
  remove_array_value ACTIONS "Reinstall or refresh the gateway service so it points to the current OpenClaw runtime."
  remove_array_value ACTIONS "Restart/reinstall the OpenClaw gateway from the active OpenClaw installation."
  remove_array_value ACTIONS "Configure the OpenClaw Telegram bot token or disable the Telegram channel."
  remove_array_value ACTIONS "Check Telegram network connectivity and the OpenClaw bot token."
  remove_array_value ACTIONS "Restart the gateway or re-enable native Telegram commands so required slash commands are registered."
  remove_array_value ACTIONS "Inspect recent ingress commands; a command may be reaching OpenClaw but producing an empty provider prompt."
  remove_array_value ACTIONS "Inspect active Telegram/OpenClaw sessions if stuck session diagnostics continue."
  remove_array_value ACTIONS "Review OpenClaw install provenance if updates or gateway restarts are skipped."
  remove_array_value ACTIONS "Restart the gateway or update the OpenClaw default model configuration."
}

run_final_sanity_pass() {
  reset_sanity_state_for_final_pass
  run_runtime_sanity || true
  run_telegram_sanity || true
  run_gateway_log_scan || true
}

is_configured_remediable_openclaw_path() {
  local path="$1"
  local remediable
  for remediable in $OPENCLAW_REMEDIABLE_INSTALL_PATHS; do
    [[ "$path" == "$remediable" ]] && return 0
  done
  return 1
}

quarantine_openclaw_path() {
  local path="$1"
  local quarantine_root="$STATE_DIR/quarantine/openclaw-installations/$RUN_ID"
  local dest="$quarantine_root${path}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would quarantine stale OpenClaw path $path."
    return 0
  fi
  [[ -e "$path" || -L "$path" ]] || return 0
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" || -L "$dest" ]]; then
    dest="${dest}.$(date +%s)"
  fi
  mv "$path" "$dest"
  append_array FIXES "Quarantined stale OpenClaw path $path."
}

write_openclaw_launcher() {
  [[ "$AUTO_REPAIR_OPENCLAW_LAUNCHER" == "true" ]] || return 0
  [[ "$OPENCLAW_BIN" == */* ]] || return 0
  [[ -x "$OPENCLAW_BIN" ]] || return 0

  local output status
  if [[ -x "$OPENCLAW_LAUNCHER_PATH" ]]; then
    run_capture_allow_fail output status "Checking OpenClaw launcher" "$OPENCLAW_LAUNCHER_PATH" --version
    [[ "$status" -eq 0 ]] && return 0
  fi

  add_incident_code "openclaw_launcher_broken"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would repair OpenClaw launcher $OPENCLAW_LAUNCHER_PATH to exec $OPENCLAW_BIN."
    record_remediation "openclaw_launcher_broken" "would_apply" "would write launcher $OPENCLAW_LAUNCHER_PATH"
    return 0
  fi

  mkdir -p "$(dirname "$OPENCLAW_LAUNCHER_PATH")"
  if [[ -e "$OPENCLAW_LAUNCHER_PATH" || -L "$OPENCLAW_LAUNCHER_PATH" ]]; then
    quarantine_openclaw_path "$OPENCLAW_LAUNCHER_PATH"
  fi
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec %q "$@"\n' "$OPENCLAW_BIN"
  } >"$OPENCLAW_LAUNCHER_PATH"
  chmod 0755 "$OPENCLAW_LAUNCHER_PATH"
  REMEDIATION_APPLIED=1
  append_array FIXES "Repaired OpenClaw launcher $OPENCLAW_LAUNCHER_PATH."
  record_remediation "openclaw_launcher_broken" "applied" "wrote launcher $OPENCLAW_LAUNCHER_PATH"
}

maybe_auto_remediate_openclaw_installations() {
  [[ "$AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS" == "true" ]] || return 0

  local current_version="$CURRENT_VERSION_AFTER"
  [[ -n "$current_version" ]] || current_version="$CURRENT_VERSION_BEFORE"
  if [[ -z "$current_version" && -x "$OPENCLAW_BIN" ]]; then
    current_version="$("$OPENCLAW_BIN" --version 2>/dev/null | extract_openclaw_version)"
  fi
  [[ -n "$current_version" ]] || return 0

  local protected_paths=()
  collect_protected_openclaw_paths protected_paths

  local candidates=()
  local candidate
  if [[ "$OPENCLAW_BIN" != */* ]]; then
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] && append_unique_array candidates "$candidate"
    done < <(type -a -P "$OPENCLAW_BIN" 2>/dev/null || true)
  fi
  for candidate in $OPENCLAW_EXTRA_SCAN_PATHS $OPENCLAW_REMEDIABLE_INSTALL_PATHS; do
    [[ -e "$candidate" || -L "$candidate" ]] && append_unique_array candidates "$candidate"
  done

  local path version package_root quarantine_targets=() target stale_found=0 remediated_count=0
  for path in "${candidates[@]:-}"; do
    is_configured_remediable_openclaw_path "$path" || continue
    path_is_protected_openclaw "$path" "${protected_paths[@]:-}" && continue

    if [[ -e "$path" || -L "$path" ]]; then
      version="$(detect_openclaw_path_version "$path")"
      if [[ -n "$version" && "$version" == "$current_version" ]]; then
        continue
      fi
      [[ -z "$version" ]] && version="unknown"
      quarantine_targets=("$path")
      package_root="$(openclaw_package_root_from_path "$path")"
      if [[ -n "$package_root" && "$package_root" != "$path" ]]; then
        append_unique_array quarantine_targets "$package_root"
      fi

      if [[ "$DRY_RUN" -eq 1 ]]; then
        append_sanity_finding "OpenClaw stale installation would be remediated: $path reports $version while active CLI reports $current_version."
      else
        append_array FIXES "Remediated OpenClaw stale installation: $path reported $version while active CLI reports $current_version."
      fi
    else
      if [[ "$DRY_RUN" -eq 1 ]]; then
        append_sanity_finding "OpenClaw stale installation path would be remediated: $path is present but is not the active CLI."
      else
        append_array FIXES "Remediated OpenClaw stale installation path: $path was present but was not the active CLI."
      fi
      quarantine_targets=("$path")
    fi

    stale_found=1
    add_incident_code "openclaw_installation_drift"
    for target in "${quarantine_targets[@]:-}"; do
      [[ -n "$target" ]] || continue
      path_is_protected_openclaw "$target" "${protected_paths[@]:-}" && continue
      if [[ -e "$target" || -L "$target" ]]; then
        quarantine_openclaw_path "$target"
        remediated_count=$((remediated_count + 1))
      fi
    done
  done

  if [[ "$stale_found" -eq 1 ]]; then
    [[ "$DRY_RUN" -eq 1 || "$remediated_count" -gt 0 ]] && REMEDIATION_APPLIED=1
    record_remediation "openclaw_installation_drift" "$([[ "$DRY_RUN" -eq 1 ]] && printf would_apply || printf applied)" "quarantined $remediated_count configured stale OpenClaw install path(s)"
  fi

  write_openclaw_launcher
}

maybe_auto_remediate_shell_openclaw_shadowing() {
  [[ "$CHECK_SHELL_ALIASES" == "true" ]] || return 0
  [[ "$AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING" == "true" ]] || return 0

  local rc_file changed=0
  for rc_file in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc"; do
    [[ -f "$rc_file" ]] || continue
    local has_alias=0 has_function=0
    grep -Eq '^[[:space:]]*alias[[:space:]]+openclaw=' "$rc_file" && has_alias=1
    if ! grep -Fq 'openclawnurse disabled shell function shadowing: openclaw' "$rc_file" &&
      grep -Eq '^[[:space:]]*(openclaw[[:space:]]*\(\)|function[[:space:]]+openclaw)' "$rc_file"; then
      has_function=1
    fi
    [[ "$has_alias" -eq 1 || "$has_function" -eq 1 ]] || continue

    add_incident_code "openclaw_shell_shadowing"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      append_array FIXES "Dry-run: would disable OpenClaw shell shadowing in $rc_file."
      record_remediation "openclaw_shell_shadowing" "would_apply" "would neutralize openclaw alias/function in $rc_file"
      continue
    fi
    cp "$rc_file" "$rc_file.openclawnurse-$RUN_ID.bak"
    if [[ "$has_alias" -eq 1 ]]; then
      awk '
        /^[[:space:]]*alias[[:space:]]+openclaw=/ {
          print "# openclawnurse disabled shell alias shadowing: " $0
          next
        }
        { print }
      ' "$rc_file" >"$rc_file.tmp.$RUN_ID"
      mv "$rc_file.tmp.$RUN_ID" "$rc_file"
    fi
    if [[ "$has_function" -eq 1 ]]; then
      {
        printf '\n# openclawnurse disabled shell function shadowing: openclaw\n'
        printf 'unset -f openclaw 2>/dev/null || true\n'
      } >>"$rc_file"
    fi
    changed=1
    append_array FIXES "Disabled OpenClaw shell shadowing in $rc_file."
  done

  if [[ "$changed" -eq 1 ]]; then
    REMEDIATION_APPLIED=1
    record_remediation "openclaw_shell_shadowing" "applied" "neutralized openclaw alias/function in shell startup files"
  fi
}

run_runtime_sanity() {
  [[ "$ENABLE_RUNTIME_SANITY" == "true" ]] || return 0
  SANITY_ATTEMPTED=1
  detect_config_version_drift || true
  resolve_expected_model_from_config
  validate_openclaw_config_contracts || true
  scan_shell_openclaw_aliases || true

  local current_version
  current_version="$CURRENT_VERSION_AFTER"
  [[ -n "$current_version" ]] || current_version="$CURRENT_VERSION_BEFORE"
  if [[ -z "$current_version" ]]; then
    current_version="$("$OPENCLAW_BIN" --version 2>/dev/null | extract_openclaw_version)"
  fi

  local paths=()
  local candidate
  if [[ "$OPENCLAW_BIN" == */* ]]; then
    [[ -x "$OPENCLAW_BIN" ]] && append_unique_array paths "$OPENCLAW_BIN"
  else
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] && append_unique_array paths "$candidate"
    done < <(type -a -P "$OPENCLAW_BIN" 2>/dev/null || true)
  fi

  for candidate in $OPENCLAW_EXTRA_SCAN_PATHS; do
    [[ -x "$candidate" ]] && append_unique_array paths "$candidate"
  done

  local install_lines=()
  local versions=()
  local path version_line version
  for path in "${paths[@]:-}"; do
    version_line="$(timeout 5s "$path" --version 2>/dev/null | head -n 1 || true)"
    version="$(printf '%s' "$version_line" | extract_openclaw_version)"
    [[ -n "$version" ]] && append_unique_array versions "$version"
    install_lines+=("$path -> ${version_line:-unknown}")
    if [[ -n "$current_version" && -n "$version" && "$version" != "$current_version" ]]; then
      append_sanity_finding "OpenClaw binary version drift: $path reports $version while active CLI reports $current_version."
      append_array ACTIONS "Remove or update stale OpenClaw installations that can shadow the current CLI."
    fi
  done
  OPENCLAW_INSTALLATIONS_SUMMARY="$(printf '%s\n' "${install_lines[@]:-}" | sed '/^$/d')"

  if ((${#versions[@]} > 1)); then
    append_sanity_finding "Multiple OpenClaw versions are installed: ${versions[*]}."
    append_array ACTIONS "Converge OpenClaw binaries to a single version in PATH and service definitions."
  fi

  if [[ "$RESTART_MODE" == "systemd_user" && -n "$SYSTEMD_UNIT_NAME" ]] && command_exists systemctl; then
    local unit_text
    unit_text="$(systemctl --user cat "$SYSTEMD_UNIT_NAME" 2>/dev/null || true)"
    GATEWAY_EXECSTART="$(printf '%s\n' "$unit_text" | sed -n 's/^ExecStart=//p' | head -n 1)"
    GATEWAY_SERVICE_VERSION="$(printf '%s\n' "$unit_text" | sed -nE 's/^Description=.*\(v([^)]*)\).*/\1/p' | head -n 1)"
    GATEWAY_PACKAGE_VERSION="$(printf '%s\n' "$GATEWAY_EXECSTART" | sed -nE 's/.*openclaw@([0-9]{4}\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?).*/\1/p' | head -n 1)"

    if [[ -n "$current_version" && -n "$GATEWAY_SERVICE_VERSION" && "$GATEWAY_SERVICE_VERSION" != "$current_version" ]]; then
      append_sanity_finding "Gateway service description version is $GATEWAY_SERVICE_VERSION, but CLI reports $current_version."
      append_array ACTIONS "Reinstall or refresh the gateway service so it points to the current OpenClaw runtime."
    fi

    if [[ -n "$current_version" && -n "$GATEWAY_PACKAGE_VERSION" && "$GATEWAY_PACKAGE_VERSION" != "$current_version" ]]; then
      append_sanity_finding "Gateway ExecStart uses OpenClaw package $GATEWAY_PACKAGE_VERSION, but CLI reports $current_version."
      append_array ACTIONS "Restart/reinstall the OpenClaw gateway from the active OpenClaw installation."
    fi
  fi
}

run_telegram_sanity() {
  [[ "$ENABLE_TELEGRAM_SANITY" == "true" ]] || return 0
  SANITY_ATTEMPTED=1

  local cfg_file="$OPENCLAW_STATE_HOME/openclaw.json"
  [[ -f "$cfg_file" ]] || return 0
  local telegram_enabled token
  telegram_enabled="$(jq -r '.channels.telegram.enabled // empty' "$cfg_file" 2>/dev/null)"
  token="$(jq -r '.channels.telegram.botToken // empty' "$cfg_file" 2>/dev/null)"
  [[ "$telegram_enabled" != "false" || -n "$token" ]] || return 0

  if ! command_exists curl; then
    append_sanity_finding "Telegram sanity check skipped because curl is missing."
    return 0
  fi

  if [[ -z "$token" ]]; then
    append_sanity_finding "Telegram channel is enabled, but channels.telegram.botToken is empty."
    append_array ACTIONS "Configure the OpenClaw Telegram bot token or disable the Telegram channel."
    return 0
  fi

  local response status
  response="$(curl -sS --connect-timeout 10 --max-time 30 -X POST -H 'content-type: application/json' -d '{}' "$TELEGRAM_API_BASE_URL/bot$token/getMyCommands" 2>&1)"
  status=$?
  if [[ "$status" -ne 0 ]] || ! printf '%s' "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    TELEGRAM_COMMANDS_SUMMARY="getMyCommands failed"
    append_sanity_finding "Telegram getMyCommands failed for the configured OpenClaw bot."
    append_array ACTIONS "Check Telegram network connectivity and the OpenClaw bot token."
    return 0
  fi

  local commands
  commands="$(printf '%s' "$response" | jq -r '.result[]?.command' | sort)"
  local count
  count="$(printf '%s\n' "$commands" | sed '/^$/d' | wc -l | tr -d ' ')"
  TELEGRAM_COMMANDS_SUMMARY="count=$count"

  local missing=()
  local required
  for required in $EXPECTED_TELEGRAM_COMMANDS; do
    if ! printf '%s\n' "$commands" | grep -qx "$required"; then
      missing+=("$required")
    fi
  done

  if ((${#missing[@]} > 0)); then
    TELEGRAM_COMMANDS_SUMMARY="$TELEGRAM_COMMANDS_SUMMARY; missing=${missing[*]}"
    if [[ "$AUTO_REMEDIATE_TELEGRAM_COMMANDS" == "true" ]]; then
      local desired_commands set_payload set_response set_status
      desired_commands="$(printf '%s' "$response" | jq -c --arg required "$EXPECTED_TELEGRAM_COMMANDS" '
        def desc($command):
          if $command == "new" then "Start a new OpenClaw conversation"
          elif $command == "reset" then "Reset the current OpenClaw conversation"
          else "Run OpenClaw " + $command
          end;
        (.result // []) as $existing
        | ($required | split(" ") | map(select(length > 0))) as $requiredCommands
        | reduce $requiredCommands[] as $command
            ($existing | map({command, description: (.description // desc(.command))});
             if any(.[]; .command == $command) then .
             else . + [{command: $command, description: desc($command)}]
             end)
      ' 2>/dev/null || printf '[]')"
      set_payload="$(jq -cn --argjson commands "$desired_commands" '{commands: $commands}' 2>/dev/null || printf '')"

      if [[ "$DRY_RUN" -eq 1 ]]; then
        append_array FIXES "Dry-run: would register Telegram native commands: ${missing[*]}."
        record_remediation "telegram_native_commands" "would_apply" "would call setMyCommands for ${missing[*]}"
        return 0
      fi

      if [[ -n "$set_payload" ]]; then
        set_response="$(curl -sS --connect-timeout 10 --max-time 30 -X POST -H 'content-type: application/json' -d "$set_payload" "$TELEGRAM_API_BASE_URL/bot$token/setMyCommands" 2>&1)"
        set_status=$?
        if [[ "$set_status" -eq 0 ]] && printf '%s' "$set_response" | jq -e '.ok == true' >/dev/null 2>&1; then
          REMEDIATION_APPLIED=1
          append_array FIXES "Registered Telegram native commands: ${missing[*]}."
          record_remediation "telegram_native_commands" "applied" "setMyCommands registered ${missing[*]}"
          TELEGRAM_COMMANDS_SUMMARY="$TELEGRAM_COMMANDS_SUMMARY; remediated=${missing[*]}"
          return 0
        fi
      fi

      record_remediation "telegram_native_commands" "apply_failed" "setMyCommands failed"
    fi
    append_sanity_finding "Telegram native command menu is missing required commands: ${missing[*]}."
    append_array ACTIONS "Restart the gateway or re-enable native Telegram commands so required slash commands are registered."
  else
    TELEGRAM_COMMANDS_SUMMARY="$TELEGRAM_COMMANDS_SUMMARY; required-present=$EXPECTED_TELEGRAM_COMMANDS"
  fi
}

run_gateway_log_scan() {
  [[ "$ENABLE_GATEWAY_LOG_SCAN" == "true" ]] || return 0
  SANITY_ATTEMPTED=1

  if ! command_exists journalctl; then
    append_sanity_finding "Gateway log scan skipped because journalctl is missing."
    return 0
  fi

  local since="$GATEWAY_LOG_SINCE"
  if [[ "$since" == "last-run" ]]; then
    since="${PREVIOUS_STATE_TIMESTAMP:-$GATEWAY_LOG_FALLBACK_SINCE}"
    [[ -n "$since" ]] || since="$GATEWAY_LOG_FALLBACK_SINCE"
  fi

  local logs status
  logs="$(journalctl --user -u "$SYSTEMD_UNIT_NAME" --since "$since" -n "$GATEWAY_LOG_MAX_LINES" --no-pager 2>&1)"
  status=$?
  if [[ "$status" -ne 0 ]]; then
    GATEWAY_LOG_SUMMARY="journalctl failed"
    append_sanity_finding "Unable to scan gateway logs for recent runtime symptoms."
    return 0
  fi

  PROVIDER_EMPTY_INPUT_COUNT="$(printf '%s\n' "$logs" | grep -F 'One of "input" or "previous_response_id"' | wc -l | tr -d ' ')"
  STUCK_SESSION_COUNT="$(printf '%s\n' "$logs" | grep -F '[diagnostic] stuck session' | wc -l | tr -d ' ')"
  CONFIG_INVALID_COUNT="$(printf '%s\n' "$logs" | grep -Ei 'Config invalid|Invalid config' | wc -l | tr -d ' ')"
  UPDATE_PROVENANCE_WARNING_COUNT="$(printf '%s\n' "$logs" | grep -Ei 'not-git-install|Gateway restart update skipped|unknown update provenance' | wc -l | tr -d ' ')"
  GATEWAY_MODEL_DETECTED="$(printf '%s\n' "$logs" | grep -Eo 'agent model: [^[:space:]]+' | sed 's/^agent model: //' | tail -n 1)"
  GATEWAY_LOG_SUMMARY="since=$since; emptyInput=$PROVIDER_EMPTY_INPUT_COUNT; stuckSessions=$STUCK_SESSION_COUNT; configInvalid=$CONFIG_INVALID_COUNT; updateProvenanceWarnings=$UPDATE_PROVENANCE_WARNING_COUNT"

  if (( PROVIDER_EMPTY_INPUT_COUNT > 0 )); then
    append_sanity_finding "Gateway logs contain $PROVIDER_EMPTY_INPUT_COUNT provider empty-input error(s) since $since."
    append_array ACTIONS "Inspect recent ingress commands; a command may be reaching OpenClaw but producing an empty provider prompt."
  fi

  if (( STUCK_SESSION_COUNT > 0 )); then
    append_sanity_finding "Gateway logs contain $STUCK_SESSION_COUNT stuck session diagnostic(s) since $since."
    append_array ACTIONS "Inspect active Telegram/OpenClaw sessions if stuck session diagnostics continue."
  fi

  if (( CONFIG_INVALID_COUNT > 0 )); then
    local latest_invalid_line latest_ready_line
    latest_invalid_line="$(printf '%s\n' "$logs" | awk 'BEGIN { IGNORECASE=1 } /Config invalid|Invalid config/ { n=NR } END { print n + 0 }')"
    latest_ready_line="$(printf '%s\n' "$logs" | awk '/\\[gateway\\] ready|http server listening/ { n=NR } END { print n + 0 }')"
    if (( latest_ready_line > latest_invalid_line )); then
      append_sanity_finding "Gateway logs contain $CONFIG_INVALID_COUNT invalid config error(s) since $since, but the gateway became ready afterward."
    else
      append_sanity_critical "Gateway logs contain $CONFIG_INVALID_COUNT invalid config error(s) since $since."
      append_array ERRORS "Gateway logs show invalid OpenClaw config."
    fi
  fi

  if (( UPDATE_PROVENANCE_WARNING_COUNT > 0 )); then
    append_sanity_finding "Gateway logs contain $UPDATE_PROVENANCE_WARNING_COUNT update provenance warning(s) since $since."
    append_array ACTIONS "Review OpenClaw install provenance if updates or gateway restarts are skipped."
  fi

  resolve_expected_model_from_config
  if [[ -n "$EXPECTED_OPENCLAW_MODEL" && -n "$GATEWAY_MODEL_DETECTED" && "$GATEWAY_MODEL_DETECTED" != "$EXPECTED_OPENCLAW_MODEL" ]]; then
    append_sanity_finding "Gateway model is $GATEWAY_MODEL_DETECTED, expected $EXPECTED_OPENCLAW_MODEL."
    append_array ACTIONS "Restart the gateway or update the OpenClaw default model configuration."
  fi
}

run_self_test() {
  log INFO "Running self-test"

  if ! run_preflight_checks; then
    printf 'SELF_TEST=FAILED\n'
    printf 'Reason: preflight checks failed\n'
    printf 'Errors:\n'
    printf -- '- %s\n' "${ERRORS[@]}"
    return 1
  fi

  if ! run_update_status; then
    printf 'SELF_TEST=FAILED\n'
    printf 'Reason: update status failed\n'
    return 1
  fi

  local health_output health_status
  local health_cmd
  local deadline attempt
  build_openclaw_cmd health_cmd
  health_cmd+=(health --json --timeout "$HEALTH_TIMEOUT_MS")
  deadline=$(( $(date +%s) + GATEWAY_WAIT_TIMEOUT ))
  attempt=1

  while (( $(date +%s) <= deadline )); do
    log INFO "Self-test health check"
    health_output="$("${health_cmd[@]}" 2>&1)"
    health_status=$?
    if [[ "$health_status" -eq 0 ]] && printf '%s' "$health_output" | jq -e '.ok == true' >/dev/null 2>&1; then
      log INFO "Self-test health check succeeded"
      break
    fi
    log INFO "Self-test health not ready yet (attempt $attempt); retrying in ${GATEWAY_WAIT_INTERVAL}s"
    attempt=$((attempt + 1))
    sleep "$GATEWAY_WAIT_INTERVAL"
  done

  if [[ "$health_status" -ne 0 ]] || ! printf '%s' "$health_output" | jq -e '.ok == true' >/dev/null 2>&1; then
    printf 'SELF_TEST=FAILED\n'
    printf 'Reason: health check failed\n'
    return 1
  fi

  run_runtime_sanity || true
  run_telegram_sanity || true
  local original_gateway_log_since="$GATEWAY_LOG_SINCE"
  GATEWAY_LOG_SINCE="10 minutes ago"
  run_gateway_log_scan || true
  GATEWAY_LOG_SINCE="$original_gateway_log_since"

  if [[ "$SANITY_CRITICAL" -eq 1 ]]; then
    printf 'SELF_TEST=FAILED\n'
    printf 'Reason: sanity checks found critical issues\n'
    printf 'Sanity findings:\n'
    printf -- '- %s\n' "${SANITY_FINDINGS[@]}"
    return 1
  fi

  if [[ "$NO_NOTIFY" -eq 0 && -n "$TELEGRAM_TARGET" ]]; then
    local send_output send_status
    run_capture send_output send_status "Self-test notification dry-run" \
      send_telegram_message "OpenClawNurse self-test" true
    if [[ "$send_status" -ne 0 ]]; then
      printf 'SELF_TEST=FAILED\n'
      printf 'Reason: notification dry-run failed\n'
      return 1
    fi
  fi

  printf 'SELF_TEST=OK\n'
  printf 'Current version: %s\n' "${CURRENT_VERSION_BEFORE:-unknown}"
  printf 'Available version: %s\n' "${AVAILABLE_VERSION:-unknown}"
  printf 'Channel: %s\n' "${CHANNEL_VALUE:-unknown}"
  printf 'Health: ok\n'
  if ((${#SANITY_FINDINGS[@]} > 0)); then
    printf 'Sanity findings:\n'
    printf -- '- %s\n' "${SANITY_FINDINGS[@]}"
  else
    printf 'Sanity: ok\n'
  fi
  if [[ -n "$TELEGRAM_TARGET" ]]; then
    printf 'Notification dry-run: ok (%s)\n' "$TELEGRAM_TARGET"
  else
    printf 'Notification dry-run: skipped (no target configured)\n'
  fi
  return 0
}

classify_doctor() {
  local output="$1"
  local exit_code="$2"
  local lowered
  lowered="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"

  if [[ "$exit_code" -ne 0 ]]; then
    add_incident_code "doctor_failed"
    DOCTOR_CLASSIFICATION="needs_manual_attention"
    DOCTOR_SUMMARY="doctor exited with code $exit_code"
    append_array ACTIONS "Inspect the doctor output and run manual remediation."
    return
  fi

  if printf '%s' "$lowered" | grep -Eq 'doctor changes|synced|repaired|fixed|migrated|normalized|generated and configured|archived [0-9]+ orphan transcript|pruned [0-9]+'; then
    add_incident_code "doctor_repaired"
    DOCTOR_CLASSIFICATION="repaired"
    DOCTOR_SUMMARY="doctor applied at least one corrective action"
    append_array FIXES "Doctor reported corrective actions during the run."
    return
  fi

  if printf '%s' "$lowered" | grep -Eq 'missing transcripts|needs manual attention|lasterror|errors:[[:space:]]*[1-9]|warnings:[[:space:]]*[1-9]|failed|unhealthy|orphan|corrupt|broken'; then
    if printf '%s' "$lowered" | grep -q 'missing transcripts'; then
      add_incident_code "missing_transcripts"
    fi
    if printf '%s' "$lowered" | grep -q 'orphan transcript'; then
      add_incident_code "orphan_transcripts"
    fi
    if printf '%s' "$lowered" | grep -Eq 'unhealthy|gateway'; then
      add_incident_code "gateway_unhealthy"
    fi
    DOCTOR_CLASSIFICATION="needs_manual_attention"
    DOCTOR_SUMMARY="doctor found issues that still require intervention"
    append_array ACTIONS "Review the doctor recommendations that remain unresolved."
    return
  fi

  if printf '%s' "$lowered" | grep -Eq 'no channel security warnings detected|doctor complete'; then
    DOCTOR_CLASSIFICATION="healthy"
    DOCTOR_SUMMARY="doctor completed without actionable findings"
    if [[ "$REMEDIATION_APPLIED" -eq 1 ]]; then
      remove_array_value ACTIONS "Review the doctor recommendations that remain unresolved."
    fi
    return
  fi

  DOCTOR_CLASSIFICATION="healthy"
  DOCTOR_SUMMARY="doctor did not report actionable problems"
  if [[ "$REMEDIATION_APPLIED" -eq 1 ]]; then
    remove_array_value ACTIONS "Review the doctor recommendations that remain unresolved."
  fi
}

run_sessions_cleanup_preview() {
  local output_var="$1"
  local status_var="$2"
  local cmd
  build_openclaw_cmd cmd
  cmd+=(sessions cleanup --dry-run --fix-missing --json)
  if [[ "$AUTO_REMEDIATE_ALL_AGENTS" == "true" ]]; then
    cmd+=(--all-agents)
  fi
  run_capture_allow_fail "$output_var" "$status_var" "Previewing missing transcript cleanup" "${cmd[@]}"
}

run_sessions_cleanup_apply() {
  local output_var="$1"
  local status_var="$2"
  local cmd
  build_openclaw_cmd cmd
  cmd+=(sessions cleanup --enforce --fix-missing --json)
  if [[ "$AUTO_REMEDIATE_ALL_AGENTS" == "true" ]]; then
    cmd+=(--all-agents)
  fi
  run_capture_allow_fail "$output_var" "$status_var" "Applying missing transcript cleanup" "${cmd[@]}"
}

maybe_auto_remediate_missing_transcripts() {
  [[ "$AUTO_REMEDIATE_MISSING_TRANSCRIPTS" == "true" ]] || return 0
  printf '%s' "$DOCTOR_OUTPUT" | grep -qi 'missing transcripts' || return 0
  add_incident_code "missing_transcripts"

  local preview_output preview_status missing_count would_mutate
  run_sessions_cleanup_preview preview_output preview_status
  if [[ "$preview_status" -ne 0 ]]; then
    append_array ERRORS "Unable to preview missing transcript cleanup."
    append_array ACTIONS "Run openclaw sessions cleanup --dry-run --fix-missing manually."
    record_remediation "missing_transcripts" "preview_failed" "sessions cleanup preview failed"
    return 1
  fi

  if ! printf '%s' "$preview_output" | jq empty >/dev/null 2>&1; then
    append_array ERRORS "Cleanup preview returned invalid JSON."
    record_remediation "missing_transcripts" "preview_failed" "sessions cleanup preview returned invalid JSON"
    return 1
  fi

  missing_count="$(printf '%s' "$preview_output" | jq -r '.missing // 0')"
  would_mutate="$(printf '%s' "$preview_output" | jq -r '.wouldMutate // false')"

  if [[ "$missing_count" == "0" || "$would_mutate" != "true" ]]; then
    record_remediation "missing_transcripts" "not_needed" "cleanup preview found no missing transcripts to prune"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would prune $missing_count session entries with missing transcripts."
    append_array ACTIONS "Run without --dry-run to auto-prune session entries with missing transcripts."
    record_remediation "missing_transcripts" "would_apply" "would prune $missing_count session entries"
    return 0
  fi

  local apply_output apply_status after_count
  run_sessions_cleanup_apply apply_output apply_status
  if [[ "$apply_status" -ne 0 ]]; then
    append_array ERRORS "Automatic cleanup of missing transcripts failed."
    append_array ACTIONS "Run openclaw sessions cleanup --enforce --fix-missing manually."
    record_remediation "missing_transcripts" "apply_failed" "sessions cleanup enforce failed"
    return 1
  fi

  if printf '%s' "$apply_output" | jq empty >/dev/null 2>&1; then
    after_count="$(printf '%s' "$apply_output" | jq -r '.afterCount // empty')"
  else
    after_count=""
  fi

  REMEDIATION_APPLIED=1
  append_array FIXES "Pruned $missing_count session entries with missing transcripts${after_count:+; remaining entries: $after_count}."
  record_remediation "missing_transcripts" "applied" "pruned $missing_count session entries"
  return 0
}

maybe_auto_archive_orphan_transcripts() {
  [[ "$AUTO_REMEDIATE_ORPHAN_TRANSCRIPTS" == "true" ]] || return 0
  printf '%s' "$DOCTOR_OUTPUT" | grep -qi 'orphan transcript file' || return 0
  add_incident_code "orphan_transcripts"

  local transcript_names=()
  while IFS= read -r transcript_name; do
    [[ -n "$transcript_name" ]] || continue
    transcript_names+=("$transcript_name")
  done < <(printf '%s' "$DOCTOR_OUTPUT" | grep -oE '[[:alnum:]_.-]+\.trajectory\.jsonl' | sort -u)

  if ((${#transcript_names[@]} == 0)); then
    append_array ACTIONS "Doctor reported orphan transcripts, but no transcript filenames could be extracted automatically."
    record_remediation "orphan_transcripts" "preview_failed" "no transcript filenames could be extracted"
    return 1
  fi

  local transcript_paths=()
  local transcript_name transcript_path
  for transcript_name in "${transcript_names[@]}"; do
    while IFS= read -r transcript_path; do
      [[ -n "$transcript_path" ]] || continue
      transcript_paths+=("$transcript_path")
    done < <(find "$OPENCLAW_STATE_HOME/agents" -type f -name "$transcript_name" 2>/dev/null)
  done

  if ((${#transcript_paths[@]} == 0)); then
    if [[ "$DRY_RUN" -eq 0 ]]; then
      append_array FIXES "Doctor reported orphan transcripts, but no matching files remained after doctor repair."
      record_remediation "orphan_transcripts" "not_needed" "no matching files remained after doctor repair"
      return 0
    fi
    append_array ACTIONS "Doctor reported orphan transcripts, but no matching files were found under $OPENCLAW_STATE_HOME/agents."
    record_remediation "orphan_transcripts" "preview_failed" "no matching files found under agent state"
    return 1
  fi

  if ((${#transcript_paths[@]} > MAX_ORPHAN_TRANSCRIPTS_PER_RUN)); then
    append_array ACTIONS "Doctor reported ${#transcript_paths[@]} orphan transcripts, exceeding MAX_ORPHAN_TRANSCRIPTS_PER_RUN=$MAX_ORPHAN_TRANSCRIPTS_PER_RUN."
    record_remediation "orphan_transcripts" "blocked_by_limit" "${#transcript_paths[@]} files exceed per-run archive limit"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would archive ${#transcript_paths[@]} orphan transcript file(s)."
    append_array ACTIONS "Run without --dry-run to archive orphan transcript files automatically."
    record_remediation "orphan_transcripts" "would_apply" "would archive ${#transcript_paths[@]} orphan transcript files"
    return 0
  fi

  local archived_count=0
  local ts
  ts="$(date --iso-8601=seconds | tr ':' '-')"
  for transcript_path in "${transcript_paths[@]}"; do
    [[ -f "$transcript_path" ]] || continue
    mv "$transcript_path" "$transcript_path.deleted.$ts"
    archived_count=$((archived_count + 1))
  done

  if ((archived_count == 0)); then
    append_array ACTIONS "Doctor reported orphan transcripts, but no matching files remained by the time remediation ran."
    record_remediation "orphan_transcripts" "not_needed" "no matching files remained by apply time"
    return 1
  fi

  REMEDIATION_APPLIED=1
  append_array FIXES "Archived $archived_count orphan transcript file(s)."
  record_remediation "orphan_transcripts" "applied" "archived $archived_count orphan transcript files"
  return 0
}

run_preflight_checks() {
  local missing=0
  local required=(jq flock timeout "$OPENCLAW_BIN")
  local cmd

  if command_exists jq; then
    detect_telegram_target
    detect_telegram_bot_token
  fi

  if [[ "$RESTART_MODE" == "systemd_user" ]]; then
    append_unique_array required systemctl
  fi

  if [[ "$NO_NOTIFY" -eq 0 && "$REPORT_CHANNEL" == "telegram" && -n "$TELEGRAM_TARGET" && -n "$TELEGRAM_BOT_TOKEN" ]]; then
    append_unique_array required curl
  fi

  if [[ "$ENABLE_TELEGRAM_SANITY" == "true" ]]; then
    append_unique_array required curl
  fi

  for cmd in "${required[@]}"; do
    if ! command_exists "$cmd"; then
      append_array ERRORS "Missing required command: $cmd"
      missing=1
    fi
  done

  if [[ "$NO_NOTIFY" -eq 0 && "$REPORT_CHANNEL" == "telegram" && -z "$TELEGRAM_TARGET" ]]; then
    append_unique_array ACTIONS "Configure TELEGRAM_TARGET so OpenClawNurse can deliver reports."
  fi

  if [[ "$NO_NOTIFY" -eq 0 && "$REPORT_CHANNEL" == "telegram" && -z "$TELEGRAM_BOT_TOKEN" ]]; then
    append_unique_array ACTIONS "Configure TELEGRAM_BOT_TOKEN so OpenClawNurse can deliver reports."
  fi

  return "$missing"
}


pm2_gateway_app_names_json() {
  printf '%s\n' $PM2_GATEWAY_APP_NAMES | jq -Rsc 'split("\n") | map(select(length > 0))'
}

pm2_gateway_apps_json() {
  command_exists pm2 || return 1

  local output status names_json
  names_json="$(pm2_gateway_app_names_json)"
  run_capture_allow_fail output status "Inspecting PM2 for legacy OpenClaw gateway app" pm2 jlist
  [[ "$status" -eq 0 ]] || return 1

  printf '%s' "$output" | jq -c --argjson names "$names_json" '
    [.[]? | select(.name as $name | $names | index($name)) | .name] | unique
  ' 2>/dev/null
}

pm2_gateway_app_exists() {
  local apps_json
  apps_json="$(pm2_gateway_apps_json 2>/dev/null || printf '[]')"
  printf '%s' "$apps_json" | jq -e 'length > 0' >/dev/null 2>&1
}

ensure_systemd_gateway_enabled() {
  local output status

  run_capture output status "Enabling systemd user gateway service" systemctl --user enable "$SYSTEMD_UNIT_NAME"
  if [[ "$status" -ne 0 ]]; then
    RESTART_ERROR="$output"
    append_array ERRORS "Could not enable systemd user gateway service."
    return 1
  fi

  run_capture output status "Starting systemd user gateway service" systemctl --user start "$SYSTEMD_UNIT_NAME"
  if [[ "$status" -ne 0 ]]; then
    RESTART_ERROR="$output"
    append_array ERRORS "Could not start systemd user gateway service."
    return 1
  fi

  return 0
}

maybe_migrate_pm2_gateway_to_systemd() {
  [[ "$AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD" == "true" ]] || return 0

  local pm2_apps_json pm2_apps_text pm2_app
  pm2_apps_json="$(pm2_gateway_apps_json 2>/dev/null || printf '[]')"
  if ! printf '%s' "$pm2_apps_json" | jq -e 'length > 0' >/dev/null 2>&1; then
    return 0
  fi
  pm2_apps_text="$(printf '%s' "$pm2_apps_json" | jq -r 'join(", ")')"

  add_incident_code "pm2_gateway_legacy"

  if [[ "$RESTART_MODE" != "systemd_user" ]]; then
    append_array ACTIONS "PM2 has an OpenClaw gateway app, but RESTART_MODE=$RESTART_MODE; set RESTART_MODE=systemd_user before automatic PM2 migration."
    record_remediation "pm2_gateway_legacy" "blocked_by_policy" "restart mode is not systemd_user"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would remove PM2 gateway app(s) '$pm2_apps_text' and ensure systemd user gateway service is enabled/running."
    record_remediation "pm2_gateway_legacy" "would_apply" "would delete exact PM2 app(s) $pm2_apps_text and start $SYSTEMD_UNIT_NAME"
    return 0
  fi

  local output status
  while IFS= read -r pm2_app; do
    [[ -n "$pm2_app" ]] || continue
    run_capture output status "Removing legacy PM2 gateway app '$pm2_app'" pm2 delete "$pm2_app"
    if [[ "$status" -ne 0 ]]; then
      RESTART_ERROR="$output"
      append_array ERRORS "Failed to remove legacy PM2 gateway app '$pm2_app'."
      record_remediation "pm2_gateway_legacy" "apply_failed" "pm2 delete failed for exact app $pm2_app"
      return 1
    fi
  done < <(printf '%s' "$pm2_apps_json" | jq -r '.[]')

  if pm2 save >/dev/null 2>&1; then
    append_array FIXES "PM2 process list saved after removing legacy OpenClaw gateway app."
  else
    append_array ACTIONS "Legacy PM2 gateway app was removed, but 'pm2 save' failed; verify PM2 startup state manually if PM2 is used for other apps."
  fi

  if ! ensure_systemd_gateway_enabled; then
    record_remediation "pm2_gateway_legacy" "apply_failed" "systemd user gateway service could not be enabled or started"
    return 1
  fi

  REMEDIATION_APPLIED=1
  append_array FIXES "Removed legacy PM2 OpenClaw gateway app(s) and ensured systemd user gateway service is enabled/running."
  record_remediation "pm2_gateway_legacy" "applied" "deleted exact PM2 app(s) $pm2_apps_text and started $SYSTEMD_UNIT_NAME"
  return 0
}

run_update_status() {
  local output status
  local cmd
  build_openclaw_cmd cmd
  cmd+=(update status --json --timeout "$STATUS_TIMEOUT")
  run_capture output status "Checking update status" \
    "${cmd[@]}"

  if [[ "$status" -ne 0 ]]; then
    UPDATE_ERROR="$output"
    append_array ERRORS "Unable to read openclaw update status."
    return 1
  fi

  if ! printf '%s' "$output" | jq empty >/dev/null 2>&1; then
    UPDATE_ERROR="$output"
    append_array ERRORS "Update status returned invalid JSON."
    return 1
  fi

  CURRENT_VERSION_BEFORE="$("$OPENCLAW_BIN" --version 2>/dev/null | sed -E 's/.* ([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n 1)"
  CURRENT_VERSION_AFTER="$CURRENT_VERSION_BEFORE"
  UPDATE_AVAILABLE=0
  if printf '%s' "$output" | jq -e '.availability.available == true' >/dev/null 2>&1; then
    UPDATE_AVAILABLE=1
    AVAILABLE_VERSION="$(printf '%s' "$output" | jq -r '.availability.latestVersion // .update.registry.latestVersion // empty')"
  else
    AVAILABLE_VERSION="$(printf '%s' "$output" | jq -r '.availability.latestVersion // empty')"
  fi
  CHANNEL_VALUE="$(printf '%s' "$output" | jq -r '.channel.value // empty')"
  return 0
}

should_attempt_update() {
  [[ "$AUTO_UPDATE" == "true" ]] || return 1
  [[ "$CONFIG_HEALTH" != "invalid" ]] || return 1
  (( CONSECUTIVE_FAILURES < MAX_CONSECUTIVE_UPDATE_FAILURES )) || return 1

  if [[ "$CONFIG_VERSION_DRIFT" -eq 1 && "$AUTO_REMEDIATE_CONFIG_VERSION_DRIFT" == "true" ]]; then
    return 0
  fi

  [[ "$UPDATE_AVAILABLE" -eq 1 ]] || return 1
  [[ -n "$AVAILABLE_VERSION" ]] || return 1
  [[ "$CURRENT_VERSION_BEFORE" != "$AVAILABLE_VERSION" ]] || return 1
  return 0
}

classify_update_failure() {
  local output="$1"
  local lowered
  lowered="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"

  add_incident_code "update_failed"

  if printf '%s' "$lowered" | grep -Eq 'timed out|timeout|etimedout'; then
    add_incident_code "update_timeout"
    append_array ACTIONS "Update timed out; check registry/network latency or increase UPDATE_TIMEOUT for the next run."
    return 0
  fi

  if printf '%s' "$lowered" | grep -Eq 'eai_again|enotfound|econnreset|econnrefused|network|registry|fetch failed|could not resolve|temporary failure'; then
    add_incident_code "update_network"
    append_array ACTIONS "Update appears blocked by network or registry access; verify DNS, outbound HTTPS and package registry reachability."
    return 0
  fi

  if printf '%s' "$lowered" | grep -Eq 'no space left|enospc|disk full'; then
    add_incident_code "update_disk_full"
    append_array ACTIONS "Update failed because disk space is exhausted; free disk space before the next automatic attempt."
    return 0
  fi

  if printf '%s' "$lowered" | grep -Eq 'permission denied|eacces|operation not permitted|eperm'; then
    add_incident_code "update_permission"
    append_array ACTIONS "Update failed due to permissions; check ownership of the OpenClaw install and cache directories."
    return 0
  fi

  if printf '%s' "$lowered" | grep -Eq 'lock|already running|resource busy|ebusy'; then
    add_incident_code "update_lock"
    append_array ACTIONS "Update appears blocked by a lock or concurrent process; check for another OpenClaw maintenance process."
    return 0
  fi

  if printf '%s' "$lowered" | grep -Eq 'command not found|npm err|node:|cannot find module|module not found'; then
    add_incident_code "update_dependency"
    append_array ACTIONS "Update failed in the runtime/package toolchain; verify node/npm/openclaw binaries and PATH."
    return 0
  fi

  append_array ACTIONS "Run openclaw update manually after reviewing the error output."
}

run_update() {
  UPDATE_ATTEMPTED=1

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run active: update was evaluated but not applied."
    UPDATE_SUCCEEDED=0
    return 0
  fi

  local cmd=("$OPENCLAW_BIN")
  [[ -n "$OPENCLAW_PROFILE" ]] && cmd+=(--profile "$OPENCLAW_PROFILE")
  cmd+=(update --json --yes --no-restart --timeout "$UPDATE_TIMEOUT")

  if [[ -n "$UPDATE_TAG" ]]; then
    cmd+=(--tag "$UPDATE_TAG")
  elif [[ -n "$UPDATE_CHANNEL" && "$UPDATE_CHANNEL" != "$CHANNEL_VALUE" ]]; then
    cmd+=(--channel "$UPDATE_CHANNEL")
  fi

  local output status
  run_capture_with_heartbeat output status "Applying update" 30 "${cmd[@]}"
  UPDATE_OUTPUT="$output"

  if [[ "$status" -eq 0 ]]; then
    UPDATE_SUCCEEDED=1
    CONSECUTIVE_FAILURES=0
    CURRENT_VERSION_AFTER="$("$OPENCLAW_BIN" --version 2>/dev/null | extract_openclaw_version)"
    [[ -n "$CURRENT_VERSION_AFTER" ]] || CURRENT_VERSION_AFTER="${AVAILABLE_VERSION:-$CONFIG_LAST_TOUCHED_VERSION}"
    append_array FIXES "OpenClaw update completed successfully."
    if [[ "$CONFIG_VERSION_DRIFT" -eq 1 ]]; then
      record_remediation "openclaw_config_version_drift" "applied" "updated canonical OpenClaw runtime after config version drift"
      mark_config_version_drift_remediated_if_current
    fi
    return 0
  fi

  UPDATE_ERROR="$output"

  local doctor_repair_output doctor_repair_status
  local repair_cmd
  build_openclaw_cmd repair_cmd
  repair_cmd+=(doctor --repair --non-interactive)
  run_capture_with_heartbeat doctor_repair_output doctor_repair_status "Running doctor repair before retry" 30 \
    "${repair_cmd[@]}"

  if [[ "$doctor_repair_status" -eq 0 ]]; then
    append_array FIXES "Doctor repair completed before the update retry."
  fi

  run_capture_with_heartbeat output status "Retrying update after repair" 30 "${cmd[@]}"
  UPDATE_OUTPUT="${UPDATE_OUTPUT}"$'\n\n--- retry ---\n'"${output}"

  if [[ "$status" -eq 0 ]]; then
    UPDATE_SUCCEEDED=1
    CONSECUTIVE_FAILURES=0
    UPDATE_ERROR=""
    CURRENT_VERSION_AFTER="$("$OPENCLAW_BIN" --version 2>/dev/null | extract_openclaw_version)"
    [[ -n "$CURRENT_VERSION_AFTER" ]] || CURRENT_VERSION_AFTER="${AVAILABLE_VERSION:-$CONFIG_LAST_TOUCHED_VERSION}"
    append_array FIXES "OpenClaw update failed on the first attempt, then succeeded after doctor repair."
    if [[ "$CONFIG_VERSION_DRIFT" -eq 1 ]]; then
      record_remediation "openclaw_config_version_drift" "applied" "updated canonical OpenClaw runtime after config version drift"
      mark_config_version_drift_remediated_if_current
    fi
    return 0
  fi

  UPDATE_ERROR="$output"
  CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
  append_array ERRORS "OpenClaw update failed after a single retry."
  classify_update_failure "$UPDATE_OUTPUT"$'\n'"$output"
  return 1
}

refresh_stale_gateway_service() {
  [[ "$AUTO_REFRESH_STALE_GATEWAY_SERVICE" == "true" ]] || return 0
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  [[ "$RESTART_MODE" == "systemd_user" && -n "$SYSTEMD_UNIT_NAME" ]] || return 0
  command_exists systemctl || return 0

  local active_version="$CURRENT_VERSION_AFTER"
  [[ -n "$active_version" ]] || active_version="$("$OPENCLAW_BIN" --version 2>/dev/null | extract_openclaw_version)"
  [[ -n "$active_version" ]] || return 0

  local unit_text service_version output status
  unit_text="$(systemctl --user cat "$SYSTEMD_UNIT_NAME" 2>/dev/null || true)"
  service_version="$(printf '%s\n' "$unit_text" | sed -nE 's/^Description=.*\(v([^)]*)\).*/\1/p' | head -n 1)"

  [[ -n "$service_version" && "$service_version" != "$active_version" ]] || return 0

  local cmd
  build_openclaw_cmd cmd
  cmd+=(gateway install --force --json)
  run_capture output status "Refreshing stale gateway service metadata" "${cmd[@]}"

  if [[ "$status" -eq 0 ]]; then
    append_array FIXES "Refreshed gateway systemd service metadata from version $service_version to $active_version."
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    return 0
  fi

  append_array ERRORS "Could not refresh stale gateway service metadata."
  append_array ACTIONS "Run openclaw gateway install --force and restart $SYSTEMD_UNIT_NAME."
  return 1
}

run_doctor_phase() {
  DOCTOR_ATTEMPTED=1
  local output status

  if [[ "$DRY_RUN" -eq 1 ]]; then
    local cmd
    build_openclaw_cmd cmd
    cmd+=(doctor --non-interactive)
    run_capture_with_heartbeat output status "Running doctor in dry-run mode" 30 \
      timeout "${DOCTOR_TIMEOUT}s" "${cmd[@]}"
  else
    local cmd
    build_openclaw_cmd cmd
    cmd+=(doctor --repair --non-interactive)
    run_capture_with_heartbeat output status "Running doctor repair" 30 \
      timeout "${DOCTOR_TIMEOUT}s" "${cmd[@]}"
  fi

  DOCTOR_OUTPUT="$output"
  DOCTOR_EXIT_CODE="$status"
  classify_doctor "$output" "$status"
}

refresh_gateway_service_after_update() {
  [[ "$AUTO_REFRESH_GATEWAY_SERVICE_AFTER_UPDATE" == "true" ]] || return 0
  [[ "$RESTART_MODE" == "systemd_user" ]] || return 0
  command_exists systemctl || return 0

  local port
  port="$(jq -r '.gateway.port // empty' "$OPENCLAW_CONFIG_FILE" 2>/dev/null)"
  [[ "$port" =~ ^[0-9]+$ ]] || port="${OPENCLAW_GATEWAY_PORT:-18789}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would refresh OpenClaw gateway service install on port $port."
    record_remediation "gateway_service_refresh" "would_apply" "would run gateway install --force"
    return 0
  fi

  local output status
  local cmd
  build_openclaw_cmd cmd
  cmd+=(gateway install --force --port "$port" --json)
  run_capture output status "Refreshing gateway service install" "${cmd[@]}"

  if [[ "$status" -eq 0 ]]; then
    REMEDIATION_APPLIED=1
    append_array FIXES "Refreshed OpenClaw gateway service install after update."
    record_remediation "gateway_service_refresh" "applied" "ran gateway install --force on port $port"
    return 0
  fi

  append_array ERRORS "Failed to refresh OpenClaw gateway service install after update."
  append_array ACTIONS "Run openclaw gateway install --force --port $port manually and restart $SYSTEMD_UNIT_NAME."
  record_remediation "gateway_service_refresh" "apply_failed" "$output"
  return 1
}

restart_gateway() {
  RESTART_ATTEMPTED=1

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run active: gateway restart was skipped."
    return 0
  fi

  local output status
  if [[ "$RESTART_MODE" == "systemd_user" ]]; then
    run_capture output status "Restarting gateway service" systemctl --user restart "$SYSTEMD_UNIT_NAME"
  elif [[ "$RESTART_MODE" == "custom" && -n "$RESTART_COMMAND" ]]; then
    run_capture output status "Restarting gateway with custom command" bash -lc "$RESTART_COMMAND"
  else
    RESTART_ERROR="Unsupported RESTART_MODE=$RESTART_MODE"
    append_array ERRORS "$RESTART_ERROR"
    return 1
  fi

  if [[ "$status" -eq 0 ]]; then
    RESTART_SUCCEEDED=1
    append_array FIXES "Gateway restart completed successfully."
    return 0
  fi

  RESTART_ERROR="$output"
  append_array ERRORS "Gateway restart failed."
  append_array ACTIONS "Check the gateway service status before the next run."
  return 1
}

wait_for_gateway_health() {
  local deadline=$(( $(date +%s) + GATEWAY_WAIT_TIMEOUT ))
  local output status
  local cmd
  local attempt=1
  build_openclaw_cmd cmd
  cmd+=(health --json --timeout "$HEALTH_TIMEOUT_MS")

  while (( $(date +%s) <= deadline )); do
    log INFO "Checking gateway health"
    output="$("${cmd[@]}" 2>&1)"
    status=$?
    HEALTH_OUTPUT="$output"

    if [[ "$status" -eq 0 ]] && printf '%s' "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
      GATEWAY_HEALTHY=1
      log INFO "Checking gateway health succeeded"
      return 0
    fi

    log INFO "Gateway health not ready yet after restart (attempt $attempt); retrying in ${GATEWAY_WAIT_INTERVAL}s"
    attempt=$((attempt + 1))
    sleep "$GATEWAY_WAIT_INTERVAL"
  done

  HEALTH_ERROR="$HEALTH_OUTPUT"
  append_array ERRORS "Gateway health check did not become healthy within the timeout."
  return 1
}

check_gateway_health_once() {
  local output status
  local cmd
  build_openclaw_cmd cmd
  cmd+=(health --json --timeout "$HEALTH_TIMEOUT_MS")
  run_capture output status "Checking gateway health without restart" "${cmd[@]}"
  HEALTH_OUTPUT="$output"

  if [[ "$status" -eq 0 ]] && printf '%s' "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    GATEWAY_HEALTHY=1
    return 0
  fi

  GATEWAY_HEALTHY=0
  HEALTH_ERROR="$output"
  add_incident_code "gateway_unhealthy"
  return 1
}

should_auto_restart_unhealthy_gateway() {
  [[ "$AUTO_RESTART_UNHEALTHY_GATEWAY" == "true" ]] || return 1
  [[ "$DRY_RUN" -eq 0 ]] || return 1
  (( GATEWAY_RESTARTS_TODAY < MAX_GATEWAY_RESTARTS_PER_DAY )) || return 1
  (( GATEWAY_RESTARTS_IN_WINDOW < MAX_GATEWAY_RESTARTS_PER_WINDOW )) || return 1
  return 0
}

maybe_auto_restart_unhealthy_gateway() {
  if check_gateway_health_once; then
    return 0
  fi

  if ! should_auto_restart_unhealthy_gateway; then
    append_array ACTIONS "Gateway is unhealthy; automatic restart skipped by policy, daily limit or short-window loop guard."
    record_remediation "gateway_unhealthy" "blocked_by_policy" "restart disabled, daily limit reached, or restart loop guard active"
    return 1
  fi

  append_array FIXES "Gateway health failed; attempting one policy-limited restart."
  if restart_gateway; then
    record_gateway_restart
    record_remediation "gateway_unhealthy" "applied" "gateway restart attempted after failed health check"
    wait_for_gateway_health || return 1
    return 0
  fi

  record_remediation "gateway_unhealthy" "apply_failed" "gateway restart command failed"
  return 1
}

diag_capture() {
  local timeout_seconds="$1"
  shift
  local output status
  local had_errexit=0
  case $- in
    *e*) had_errexit=1 ;;
  esac
  set +e
  output="$(timeout "${timeout_seconds}s" "$@" 2>&1)"
  status=$?
  if [[ "$had_errexit" -eq 1 ]]; then
    set -e
  fi
  if [[ "$status" -eq 0 ]]; then
    printf '%s' "$output"
  else
    printf ''
  fi
}

diag_shell_capture() {
  local timeout_seconds="$1"
  local command_string="$2"
  local output status
  local had_errexit=0
  case $- in
    *e*) had_errexit=1 ;;
  esac
  set +e
  output="$(timeout "${timeout_seconds}s" bash -lc "$command_string" 2>&1)"
  status=$?
  if [[ "$had_errexit" -eq 1 ]]; then
    set -e
  fi
  if [[ "$status" -eq 0 ]]; then
    printf '%s' "$output"
  else
    printf ''
  fi
}

collect_diagnostics() {
  local version process_snapshot disk_snapshot mem_snapshot config_error gateway_log gateway_err openclaw_status
  version="$(diag_capture 5 "$OPENCLAW_BIN" --version)"
  process_snapshot="$(diag_shell_capture 5 "ps -eo pid,pcpu,pmem,args 2>/dev/null | grep -i '[o]penclaw' | head -5")"
  disk_snapshot="$(diag_shell_capture 5 "df -h \"${OPENCLAW_STATE_HOME}\" 2>/dev/null | tail -1 || df -h / | tail -1")"
  mem_snapshot="$(diag_shell_capture 5 "free -h 2>/dev/null | awk '/Mem:/{print \$3\"/\"\$2}'")"
  gateway_log="$(diag_shell_capture 5 "tail -n \"${DIAGNOSTIC_LOG_LINES}\" \"${OPENCLAW_STATE_HOME}/logs/gateway.log\" 2>/dev/null")"
  gateway_err="$(diag_shell_capture 5 "tail -n \"${DIAGNOSTIC_LOG_LINES}\" \"${OPENCLAW_STATE_HOME}/logs/gateway.err.log\" 2>/dev/null")"

  if [[ -f "$OPENCLAW_CONFIG_FILE" ]] && ! is_valid_json_file "$OPENCLAW_CONFIG_FILE"; then
    config_error="$(jq empty "$OPENCLAW_CONFIG_FILE" 2>&1 || true)"
  else
    config_error=""
  fi

  if command_exists timeout; then
    local status_cmd
    build_openclaw_cmd status_cmd
    status_cmd+=(status --json)
    openclaw_status="$(diag_capture "$STATUS_TIMEOUT" "${status_cmd[@]}")"
    if ! printf '%s' "$openclaw_status" | jq empty >/dev/null 2>&1; then
      openclaw_status="null"
    fi
  else
    openclaw_status="null"
  fi

  DIAGNOSTICS_JSON="$(
    jq -n \
      --arg collectedAt "$(TZ="$TIMEZONE" date --iso-8601=seconds)" \
      --arg version "$version" \
      --arg processSnapshot "$process_snapshot" \
      --arg diskSnapshot "$disk_snapshot" \
      --arg memorySnapshot "$mem_snapshot" \
      --arg configFile "$OPENCLAW_CONFIG_FILE" \
      --arg configHealth "$CONFIG_HEALTH" \
      --arg configError "$config_error" \
      --arg gatewayLog "$gateway_log" \
      --arg gatewayErr "$gateway_err" \
      --argjson openclawStatus "$openclaw_status" \
      '{
        collectedAt: $collectedAt,
        openclawVersion: $version,
        processSnapshot: $processSnapshot,
        diskSnapshot: $diskSnapshot,
        memorySnapshot: $memorySnapshot,
        config: {
          file: $configFile,
          health: $configHealth,
          error: (if $configError == "" then null else $configError end)
        },
        logs: {
          gateway: $gatewayLog,
          gatewayErr: $gatewayErr
        },
        openclawStatus: $openclawStatus
      }'
  )"
}

build_report() {
  local mode_text="live"
  [[ "$DRY_RUN" -eq 1 ]] && mode_text="dry-run"

  local update_line="not attempted"
  if [[ "$UPDATE_ATTEMPTED" -eq 1 && "$UPDATE_SUCCEEDED" -eq 1 ]]; then
    update_line="applied successfully"
  elif [[ "$UPDATE_ATTEMPTED" -eq 1 && "$DRY_RUN" -eq 1 ]]; then
    update_line="eligible but skipped because dry-run is active"
  elif [[ "$UPDATE_ATTEMPTED" -eq 1 ]]; then
    update_line="failed"
  elif [[ "$CURRENT_VERSION_BEFORE" == "$AVAILABLE_VERSION" && -n "$CURRENT_VERSION_BEFORE" ]]; then
    update_line="already on the latest version"
  fi

  local restart_line="not required"
  [[ "$RESTART_ATTEMPTED" -eq 1 && "$RESTART_SUCCEEDED" -eq 1 ]] && restart_line="completed"
  [[ "$RESTART_ATTEMPTED" -eq 1 && "$RESTART_SUCCEEDED" -eq 0 ]] && restart_line="failed"

  local health_line="not checked"
  [[ "$GATEWAY_HEALTHY" -eq 1 ]] && health_line="gateway healthy"
  [[ "$RESTART_ATTEMPTED" -eq 1 && "$GATEWAY_HEALTHY" -eq 0 ]] && health_line="gateway did not become healthy in time"

  local summary_lines
  summary_lines="$(build_summary_from_output "$DOCTOR_OUTPUT")"

  cat <<EOF
OpenClawNurse Daily Report
Date: $RUN_DATE
Host: $HOST_NAME
Instance: $REPORT_INSTANCE_LABEL
Mode: $mode_text
Status: $STATUS

Version before: ${CURRENT_VERSION_BEFORE:-unknown}
Version after: ${CURRENT_VERSION_AFTER:-unknown}
Version available: ${AVAILABLE_VERSION:-unknown}
Channel: ${CHANNEL_VALUE:-unknown}

Update: $update_line
Doctor: $DOCTOR_SUMMARY
Restart: $restart_line
Health check: $health_line
Config: $CONFIG_HEALTH
Duration: ${DURATION_SECONDS}s
EOF

  if [[ "$CONFIG_BACKUP_CREATED" -eq 1 ]]; then
    printf '\nConfig backup: created\n'
  fi

  if [[ "$CONFIG_RESTORED" -eq 1 ]]; then
    printf '\nConfig restore: applied\n'
  fi

  if [[ -n "$CONFIG_RESTORE_DIFF" ]]; then
    printf '\nConfig restore diff preview:\n%s\n' "$CONFIG_RESTORE_DIFF"
  fi

  if [[ "$SANITY_ATTEMPTED" -eq 1 ]]; then
    if [[ "$SANITY_CRITICAL" -eq 1 ]]; then
      printf '\nSanity: critical findings\n'
    elif [[ "$SANITY_DEGRADED" -eq 1 ]]; then
      printf '\nSanity: findings need attention\n'
    else
      printf '\nSanity: ok\n'
    fi
  fi

  if [[ -n "$summary_lines" ]]; then
    printf '\nDoctor highlights:\n%s\n' "$summary_lines"
  fi

  if array_has_nonempty SANITY_FINDINGS; then
    printf '\nSanity findings:\n'
    print_bullets_from_array SANITY_FINDINGS
  fi

  if array_has_nonempty FIXES; then
    printf '\nActions applied:\n'
    print_bullets_from_array FIXES
  fi

  if array_has_nonempty INCIDENT_CODES; then
    printf '\nIncident codes:\n'
    print_bullets_from_array INCIDENT_CODES
  fi

  if ((${#REMEDIATIONS[@]} > 0)); then
    printf '\nRemediation registry:\n'
    local remediation_entry
    for remediation_entry in "${REMEDIATIONS[@]}"; do
      IFS='|' read -r remediation_code remediation_result remediation_detail <<<"$remediation_entry"
      printf -- '- %s: %s%s\n' "$remediation_code" "$remediation_result" "${remediation_detail:+ - $remediation_detail}"
    done
  fi

  if array_has_nonempty ERRORS; then
    printf '\nErrors:\n'
    print_bullets_from_array ERRORS
  fi

  if array_has_nonempty ACTIONS; then
    printf '\nManual follow-up:\n'
    print_bullets_from_array ACTIONS
  fi
}

deliver_report() {
  local report_text="$1"
  [[ "$NO_NOTIFY" -eq 1 ]] && return 0
  if [[ "$REPORT_CHANNEL" == "none" || "$REPORT_CHANNEL" == "off" || "$REPORT_CHANNEL" == "disabled" ]]; then
    clear_pending_report
    return 0
  fi

  if [[ "$REPORT_CHANNEL" != "telegram" ]]; then
    append_array ERRORS "Notification skipped because REPORT_CHANNEL=$REPORT_CHANNEL is unsupported."
    NOTIFICATION_PENDING=1
    return 1
  fi

  if [[ -z "$TELEGRAM_TARGET" ]]; then
    append_array ERRORS "Notification skipped because TELEGRAM_TARGET is empty."
    NOTIFICATION_PENDING=1
    return 1
  fi

  if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    append_array ERRORS "Notification skipped because TELEGRAM_BOT_TOKEN is empty."
    NOTIFICATION_PENDING=1
    return 1
  fi

  if [[ "$RETRY_NOTIFICATION_ON_NEXT_RUN" == "true" ]]; then
    retry_pending_report
  fi

  local send_output send_status
  local trimmed
  trimmed="$(trim_report "$report_text")"
  run_capture send_output send_status "Delivering report" \
    send_telegram_message "$trimmed" false

  if [[ "$send_status" -eq 0 ]]; then
    NOTIFICATION_DELIVERED=1
    clear_pending_report
    return 0
  fi

  append_array ERRORS "Report delivery failed."
  NOTIFICATION_PENDING=1
  return 1
}

finalize_status() {
  if [[ "$NOTIFICATION_PENDING" -eq 1 ]]; then
    STATUS="FAILED_NOTIFICATION_PENDING"
    return
  fi

  if [[ "$SANITY_CRITICAL" -eq 1 ]]; then
    STATUS="FAILED"
    return
  fi

  if ((${#ERRORS[@]} > 0)); then
    STATUS="FAILED"
    return
  fi

  if [[ "$SANITY_DEGRADED" -eq 1 ]]; then
    STATUS="DEGRADED"
    return
  fi

  if [[ "$UPDATE_ATTEMPTED" -eq 1 && "$UPDATE_SUCCEEDED" -eq 1 && "$DOCTOR_CLASSIFICATION" == "repaired" ]]; then
    STATUS="UPDATED_WITH_REPAIRS"
    return
  fi

  if [[ "$UPDATE_ATTEMPTED" -eq 1 && "$UPDATE_SUCCEEDED" -eq 1 ]]; then
    STATUS="UPDATED"
    return
  fi

  if [[ "$DOCTOR_CLASSIFICATION" == "needs_manual_attention" || "$GATEWAY_HEALTHY" -eq 0 && "$RESTART_ATTEMPTED" -eq 1 ]]; then
    STATUS="DEGRADED"
    return
  fi

  STATUS="OK"
}

main() {
  local start_epoch
  start_epoch="$(date +%s)"

  log INFO "$PROGRAM_NAME $PROGRAM_VERSION starting"
  log INFO "Using config file $CONFIG_FILE"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log WARN "Another run is already in progress"
    if [[ "$SELF_TEST" -eq 1 || "$RETRY_PENDING_ONLY" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
      exit 75
    fi
    exit 0
  fi

  load_previous_state

  if [[ "$SELF_TEST" -eq 1 ]]; then
    if run_self_test; then
      exit 0
    fi
    exit 1
  fi

  if [[ "$RETRY_PENDING_ONLY" -eq 1 ]]; then
    if retry_pending_report; then
      exit 0
    fi
    exit 1
  fi

  if ! run_preflight_checks; then
    STATUS="FAILED"
    DURATION_SECONDS=$(( $(date +%s) - start_epoch ))
    local preflight_report
    preflight_report="$(build_report)"
    if command_exists jq; then
      persist_json "$preflight_report"
      persist_pending_report "$preflight_report"
    else
      log ERROR "jq is unavailable; skipping JSON persistence for the failed preflight report"
      printf '%s\n' "$preflight_report"
    fi
    exit 1
  fi

  maybe_restore_broken_config || true
  maybe_migrate_pm2_gateway_to_systemd || true

  run_update_status || true
  maybe_auto_remediate_openclaw_installations || true
  maybe_auto_remediate_shell_openclaw_shadowing || true
  run_runtime_sanity || true
  run_telegram_sanity || true
  run_gateway_log_scan || true

  if should_attempt_update; then
    run_update || true
  fi
  if [[ "$UPDATE_SUCCEEDED" -eq 1 ]]; then
    refresh_gateway_service_after_update || true
  else
    refresh_stale_gateway_service || true
  fi

  run_doctor_phase
  maybe_auto_archive_orphan_transcripts || true
  maybe_auto_remediate_missing_transcripts || true
  if [[ "$REMEDIATION_APPLIED" -eq 1 ]]; then
    run_doctor_phase
  fi

  if [[ "$UPDATE_SUCCEEDED" -eq 1 || "$CONFIG_RESTORED" -eq 1 ]]; then
    restart_gateway || true
    wait_for_gateway_health || true
  else
    maybe_auto_restart_unhealthy_gateway || true
  fi

  run_final_sanity_pass
  collect_diagnostics
  finalize_status

  DURATION_SECONDS=$(( $(date +%s) - start_epoch ))
  local report_text
  report_text="$(build_report)"
  persist_json "$report_text"

  if ! deliver_report "$report_text"; then
    finalize_status
    report_text="$(build_report)"
    persist_json "$report_text"
    persist_pending_report "$report_text"
  else
    finalize_status
    persist_json "$report_text"
  fi

  rotate_logs
  log INFO "$PROGRAM_NAME finished with status $STATUS in ${DURATION_SECONDS}s"
}

main "$@"
