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
TELEGRAM_MESSAGE_THREAD_ID="${TELEGRAM_MESSAGE_THREAD_ID:-}"
TELEGRAM_API_BASE_URL="${TELEGRAM_API_BASE_URL:-https://api.telegram.org}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
UPDATE_CHANNEL="${UPDATE_CHANNEL:-stable}"
UPDATE_TAG="${UPDATE_TAG:-}"
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-900}"
AUTO_SELF_UPDATE="${AUTO_SELF_UPDATE:-false}"
SELF_UPDATE_REPO_DIR="${SELF_UPDATE_REPO_DIR:-}"
SELF_UPDATE_REMOTE="${SELF_UPDATE_REMOTE:-origin}"
SELF_UPDATE_BRANCH="${SELF_UPDATE_BRANCH:-main}"
SELF_UPDATE_POLICY="${SELF_UPDATE_POLICY:-reset-to-remote}"
SELF_UPDATE_TIMEOUT="${SELF_UPDATE_TIMEOUT:-300}"
SELF_UPDATE_RUN_TESTS="${SELF_UPDATE_RUN_TESTS:-true}"
SELF_UPDATE_ROLLBACK_ON_FAILURE="${SELF_UPDATE_ROLLBACK_ON_FAILURE:-true}"
SELF_UPDATE_RESTART_GATEWAY="${SELF_UPDATE_RESTART_GATEWAY:-false}"
SELF_UPDATE_POST_SELF_TEST="${SELF_UPDATE_POST_SELF_TEST:-false}"
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
MAX_DOCTOR_REMEDIATION_PASSES="${MAX_DOCTOR_REMEDIATION_PASSES:-3}"
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
ENABLE_COMMITMENTS_SANITY="${ENABLE_COMMITMENTS_SANITY:-true}"
ENABLE_SECURITY_AUDIT="${ENABLE_SECURITY_AUDIT:-true}"
SECURITY_AUDIT_DEEP="${SECURITY_AUDIT_DEEP:-false}"
SECURITY_AUDIT_TIMEOUT="${SECURITY_AUDIT_TIMEOUT:-90}"
AUTO_FIX_SECURITY_FILE_PERMS="${AUTO_FIX_SECURITY_FILE_PERMS:-true}"
ENABLE_PACKAGE_DRIFT_SANITY="${ENABLE_PACKAGE_DRIFT_SANITY:-true}"
COMMITMENTS_TRACE_SCAN_DAYS="${COMMITMENTS_TRACE_SCAN_DAYS:-14}"
ENABLE_DISK_SANITY="${ENABLE_DISK_SANITY:-true}"
ENABLE_CRON_SANITY="${ENABLE_CRON_SANITY:-true}"
EXPECTED_OPENCLAW_MODEL="${EXPECTED_OPENCLAW_MODEL:-}"
EXPECTED_TELEGRAM_COMMANDS="${EXPECTED_TELEGRAM_COMMANDS:-new reset}"
AUTO_REMEDIATE_TELEGRAM_COMMANDS="${AUTO_REMEDIATE_TELEGRAM_COMMANDS:-true}"
AUTO_REMEDIATE_EXPECTED_OPENCLAW_MODEL="${AUTO_REMEDIATE_EXPECTED_OPENCLAW_MODEL:-true}"
GATEWAY_LOG_SINCE="${GATEWAY_LOG_SINCE:-last-run}"
GATEWAY_LOG_FALLBACK_SINCE="${GATEWAY_LOG_FALLBACK_SINCE:-24 hours ago}"
GATEWAY_LOG_MAX_LINES="${GATEWAY_LOG_MAX_LINES:-4000}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-90}"
DISK_CRITICAL_PERCENT="${DISK_CRITICAL_PERCENT:-97}"
DISK_WARN_MIN_FREE_MB="${DISK_WARN_MIN_FREE_MB:-1024}"
DISK_CRITICAL_MIN_FREE_MB="${DISK_CRITICAL_MIN_FREE_MB:-256}"
OPENCLAW_LOG_SQLITE_WARN_MB="${OPENCLAW_LOG_SQLITE_WARN_MB:-1024}"
DISK_TOP_OFFENDERS_LIMIT="${DISK_TOP_OFFENDERS_LIMIT:-8}"
CRON_ISOLATED_MIN_INTERVAL_SECONDS="${CRON_ISOLATED_MIN_INTERVAL_SECONDS:-300}"
ORPHAN_TRANSCRIPT_SAFETY_SECONDS="${ORPHAN_TRANSCRIPT_SAFETY_SECONDS:-300}"
ORPHAN_TRANSCRIPT_ARCHIVE_DIR="${ORPHAN_TRANSCRIPT_ARCHIVE_DIR:-$STATE_DIR/orphan-transcripts}"
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
  # shellcheck disable=SC2178 # nameref points at an array selected by name.
  local -n ref="$name"
  ref+=("$value")
}

remove_array_value() {
  local name="$1"
  local value="$2"
  # shellcheck disable=SC2178 # nameref points at an array selected by name.
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

remove_incident_code() {
  local value="$1"
  remove_array_value INCIDENT_CODES "$value"
}

append_unique_array() {
  local name="$1"
  shift
  local value="$*"
  [[ -n "$value" ]] || return 0
  # shellcheck disable=SC2178 # nameref points at an array selected by name.
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
  # shellcheck disable=SC2178 # nameref points at an array selected by name.
  local -n ref="$name"
  local item
  for item in "${ref[@]:-}"; do
    [[ -n "$item" ]] || continue
    printf -- '- %s\n' "$item"
  done
}

array_has_nonempty() {
  local name="$1"
  # shellcheck disable=SC2178 # nameref points at an array selected by name.
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
  # shellcheck disable=SC2178 # nameref points at an array selected by name.
  local -n ref="$name"
  ref=("$OPENCLAW_BIN")
  if [[ -n "$OPENCLAW_PROFILE" ]]; then
    ref+=(--profile "$OPENCLAW_PROFILE")
  fi
}

json_payload_from_output() {
  awk 'found || $0 ~ /^[[:space:]]*[\{\[]/ { found=1; print }'
}

count_fixed_lines() {
  local text="$1"
  local pattern="$2"
  awk -v pat="$pattern" 'index($0, pat) > 0 { count++ } END { print count + 0 }' <<<"$text"
}

count_regex_lines() {
  local text="$1"
  local pattern="$2"
  awk -v pat="$pattern" '$0 ~ pat { count++ } END { print count + 0 }' <<<"$text"
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
  # shellcheck disable=SC2178 # nameref points at an array selected by name.
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
      --arg thread_id "$TELEGRAM_MESSAGE_THREAD_ID" \
      --arg text "$message_text" \
      '{ok:true,dryRun:true,channel:$channel,target:$target,messageThreadId:($thread_id|if length==0 then empty else . end),messageLength:($text|length)}'
    return 0
  fi

  local response
  local http_code
  local -a curl_args
  curl_args=(
    -sS
    -X POST
    --connect-timeout 10
    --max-time 30
    -o /tmp/openclawnurse-telegram-response.$$
    -w '%{http_code}'
    --data-urlencode "chat_id=$TELEGRAM_TARGET"
    --data-urlencode "text=$message_text"
    --data-urlencode "disable_web_page_preview=true"
    --data-urlencode "parse_mode="
    "$TELEGRAM_API_BASE_URL/bot$TELEGRAM_BOT_TOKEN/sendMessage"
  )

  if [[ -n "$TELEGRAM_MESSAGE_THREAD_ID" ]]; then
    curl_args+=(--data-urlencode "message_thread_id=$TELEGRAM_MESSAGE_THREAD_ID")
  fi

  response="$(
    curl "${curl_args[@]}"
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
SELF_UPDATE_ATTEMPTED=0
SELF_UPDATE_AVAILABLE=0
SELF_UPDATE_APPLIED=0
SELF_UPDATE_ROLLED_BACK=0
SELF_UPDATE_FROM=""
SELF_UPDATE_TO=""
SELF_UPDATE_REPO_RESOLVED=""
SELF_UPDATE_SUMMARY=""
SELF_UPDATE_ERROR=""
DURATION_SECONDS=0
CONFIG_HEALTH="unknown"
CONFIG_RESTORED=0
CONFIG_BACKUP_CREATED=0
CONFIG_RESTORE_DIFF=""
DIAGNOSTICS_JSON="{}"

ERRORS=()
# shellcheck disable=SC2034 # read through nameref helpers and persisted dynamically.
FIXES=()
# shellcheck disable=SC2034 # read through nameref helpers and persisted dynamically.
ACTIONS=()
INCIDENT_CODES=()
REMEDIATIONS=()
SANITY_FINDINGS=()
DISK_FINDINGS_SUMMARY=""
CRON_FINDINGS_SUMMARY=""
MODEL_AUTH_SUMMARY=""
PREVIOUS_PENDING_PRESENT=0
PREVIOUS_STATE_TIMESTAMP=""
REMEDIATION_APPLIED=0
MODEL_CONFIG_REMEDIATED=0
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
COMMITMENTS_SUMMARY=""
SECURITY_AUDIT_SUMMARY=""
PACKAGE_DRIFT_SUMMARY=""
DOCTOR_WARNING_SUMMARY=""
PROVIDER_EMPTY_INPUT_COUNT=0
PROVIDER_AUTH_ERROR_COUNT=0
STUCK_SESSION_COUNT=0
CONFIG_INVALID_COUNT=0
UPDATE_PROVENANCE_WARNING_COUNT=0
COMMITMENTS_ERROR_COUNT=0
MODEL_ACCESS_ERROR_COUNT=0
SECURITY_AUDIT_CRITICAL_COUNT=0
SECURITY_AUDIT_WARN_COUNT=0
LOCAL_HOTFIX_COUNT=0
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
  # shellcheck disable=SC2178 # nameref points at an array selected by name.
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
  local errors_json fixes_json actions_json incident_codes_json remediations_json diagnostics_json sanity_findings_json status_reasons_json

  errors_json="$(json_array_from_name ERRORS)"
  fixes_json="$(json_array_from_name FIXES)"
  actions_json="$(json_array_from_name ACTIONS)"
  incident_codes_json="$(json_array_from_name INCIDENT_CODES)"
  remediations_json="$(json_remediations_from_name REMEDIATIONS)"
  sanity_findings_json="$(printf '%s\n' "${SANITY_FINDINGS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')"
  status_reasons_json="$(build_status_reasons | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]')"
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
    --arg selfUpdateFrom "$SELF_UPDATE_FROM" \
    --arg selfUpdateTo "$SELF_UPDATE_TO" \
    --arg selfUpdateRepo "$SELF_UPDATE_REPO_RESOLVED" \
    --arg selfUpdateRemote "$SELF_UPDATE_REMOTE" \
    --arg selfUpdateBranch "$SELF_UPDATE_BRANCH" \
    --arg selfUpdatePolicy "$SELF_UPDATE_POLICY" \
    --arg selfUpdateSummary "$SELF_UPDATE_SUMMARY" \
    --arg selfUpdateError "$SELF_UPDATE_ERROR" \
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
    --arg commitmentsSummary "$COMMITMENTS_SUMMARY" \
    --arg securityAuditSummary "$SECURITY_AUDIT_SUMMARY" \
    --arg packageDriftSummary "$PACKAGE_DRIFT_SUMMARY" \
    --arg doctorWarningSummary "$DOCTOR_WARNING_SUMMARY" \
    --arg diskSummary "$DISK_FINDINGS_SUMMARY" \
    --arg cronSummary "$CRON_FINDINGS_SUMMARY" \
    --arg modelAuthSummary "$MODEL_AUTH_SUMMARY" \
    --arg reportText "$report_text" \
    --argjson dryRun "$(json_bool "$DRY_RUN")" \
    --argjson updateAttempted "$(json_bool "$UPDATE_ATTEMPTED")" \
    --argjson updateAvailable "$(json_bool "$UPDATE_AVAILABLE")" \
    --argjson updateSucceeded "$(json_bool "$UPDATE_SUCCEEDED")" \
    --argjson selfUpdateAttempted "$(json_bool "$SELF_UPDATE_ATTEMPTED")" \
    --argjson selfUpdateAvailable "$(json_bool "$SELF_UPDATE_AVAILABLE")" \
    --argjson selfUpdateApplied "$(json_bool "$SELF_UPDATE_APPLIED")" \
    --argjson selfUpdateRolledBack "$(json_bool "$SELF_UPDATE_ROLLED_BACK")" \
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
    --argjson statusReasons "$status_reasons_json" \
    --argjson sanityAttempted "$(json_bool "$SANITY_ATTEMPTED")" \
    --argjson sanityDegraded "$(json_bool "$SANITY_DEGRADED")" \
    --argjson sanityCritical "$(json_bool "$SANITY_CRITICAL")" \
    --argjson providerEmptyInputCount "$(json_int "$PROVIDER_EMPTY_INPUT_COUNT")" \
    --argjson providerAuthErrorCount "$(json_int "$PROVIDER_AUTH_ERROR_COUNT")" \
    --argjson stuckSessionCount "$(json_int "$STUCK_SESSION_COUNT")" \
    --argjson configInvalidCount "$(json_int "$CONFIG_INVALID_COUNT")" \
    --argjson updateProvenanceWarningCount "$(json_int "$UPDATE_PROVENANCE_WARNING_COUNT")" \
    --argjson commitmentsErrorCount "$(json_int "$COMMITMENTS_ERROR_COUNT")" \
    --argjson modelAccessErrorCount "$(json_int "$MODEL_ACCESS_ERROR_COUNT")" \
    --argjson securityAuditCriticalCount "$(json_int "$SECURITY_AUDIT_CRITICAL_COUNT")" \
    --argjson securityAuditWarnCount "$(json_int "$SECURITY_AUDIT_WARN_COUNT")" \
    --argjson localHotfixCount "$(json_int "$LOCAL_HOTFIX_COUNT")" \
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
      selfUpdate: {
        attempted: $selfUpdateAttempted,
        available: $selfUpdateAvailable,
        applied: $selfUpdateApplied,
        rolledBack: $selfUpdateRolledBack,
        from: $selfUpdateFrom,
        to: $selfUpdateTo,
        repo: $selfUpdateRepo,
        remote: $selfUpdateRemote,
        branch: $selfUpdateBranch,
        policy: $selfUpdatePolicy,
        summary: $selfUpdateSummary,
        error: $selfUpdateError
      },
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
      statusReasons: $statusReasons,
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
        commitmentsSummary: $commitmentsSummary,
        securityAuditSummary: $securityAuditSummary,
        packageDriftSummary: $packageDriftSummary,
        doctorWarningSummary: $doctorWarningSummary,
        diskSummary: $diskSummary,
        cronSummary: $cronSummary,
        modelAuthSummary: $modelAuthSummary,
        providerEmptyInputCount: $providerEmptyInputCount,
        providerAuthErrorCount: $providerAuthErrorCount,
        stuckSessionCount: $stuckSessionCount,
        configInvalidCount: $configInvalidCount,
        updateProvenanceWarningCount: $updateProvenanceWarningCount,
        commitmentsErrorCount: $commitmentsErrorCount,
        modelAccessErrorCount: $modelAccessErrorCount,
        securityAuditCriticalCount: $securityAuditCriticalCount,
        securityAuditWarnCount: $securityAuditWarnCount,
        localHotfixCount: $localHotfixCount
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
    | grep -E 'Model auth|expired|missing transcripts|orphan transcript|No channel security warnings detected|Telegram:|Agents:|Session store|synced ' \
    | sed -E 's/[[:space:]]*│[[:space:]]*$//; s/^[[:space:][:punct:]]+//; s/[[:space:]]+/ /g' \
    | head -n 6)"
  printf '%s' "$extracted"
}

build_status_reasons() {
  if ((${#ERRORS[@]} > 0)); then
    printf -- '- Errors are present: %s\n' "${ERRORS[0]}"
  fi
  if [[ "$SANITY_CRITICAL" -eq 1 ]]; then
    printf -- '- Critical sanity finding is present.\n'
  elif [[ "$SANITY_DEGRADED" -eq 1 ]]; then
    printf -- '- Sanity findings require attention.\n'
  fi
  if [[ -n "$MODEL_AUTH_SUMMARY" ]]; then
    printf -- '- Model auth notice: %s\n' "$MODEL_AUTH_SUMMARY"
  fi
  if [[ "$DOCTOR_CLASSIFICATION" == "needs_manual_attention" ]]; then
    printf -- '- OpenClaw doctor found unresolved operational issues.\n'
  fi
  if [[ "$NOTIFICATION_PENDING" -eq 1 ]]; then
    printf -- '- Report delivery is pending.\n'
  fi
  if [[ -n "$SELF_UPDATE_ERROR" ]]; then
    printf -- '- Self-update issue: %s\n' "$SELF_UPDATE_ERROR"
  fi
  if [[ "$GATEWAY_HEALTHY" -eq 0 && "$RESTART_ATTEMPTED" -eq 1 ]]; then
    printf -- '- Gateway restart was attempted but health did not recover.\n'
  fi
  if ((${#INCIDENT_CODES[@]} > 0)); then
    printf -- '- Incident codes: %s\n' "${INCIDENT_CODES[*]}"
  fi
  if [[ "$STATUS" == "OK" ]]; then
    printf -- '- No active errors, critical sanity findings, or unresolved doctor findings.\n'
  fi
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
  # shellcheck disable=SC2034,SC2178 # populated through append_unique_array nameref calls below.
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

  local current_model
  current_model="$(jq -r '.agents.defaults.model.primary // .models.default // .model // empty' "$cfg_file" 2>/dev/null)"
  if [[ "$current_model" == openai/* ]] && config_has_codex_oauth "$cfg_file" && ! config_has_direct_openai_auth "$cfg_file"; then
    EXPECTED_OPENCLAW_MODEL="openai-codex/${current_model#openai/}"
    return 0
  fi

  EXPECTED_OPENCLAW_MODEL="$current_model"
}

config_has_codex_oauth() {
  local cfg_file="$1"
  jq -e '
    (.auth.profiles // {})
    | to_entries
    | any(.value.provider == "openai-codex" and ((.value.mode // "oauth") == "oauth"))
  ' "$cfg_file" >/dev/null 2>&1
}

config_has_direct_openai_auth() {
  local cfg_file="$1"
  [[ -n "${OPENAI_API_KEY:-}" ]] && return 0
  jq -e '
    (.auth.profiles // {})
    | to_entries
    | any(.value.provider == "openai")
  ' "$cfg_file" >/dev/null 2>&1
}

detect_openclaw_model_config_drift() {
  resolve_expected_model_from_config
  [[ -n "$EXPECTED_OPENCLAW_MODEL" ]] || return 0

  local cfg_file="$OPENCLAW_STATE_HOME/openclaw.json"
  [[ -f "$cfg_file" ]] || return 0
  jq empty "$cfg_file" >/dev/null 2>&1 || return 0

  local current_model runtime_id has_expected_model finding
  current_model="$(jq -r '.agents.defaults.model.primary // empty' "$cfg_file" 2>/dev/null)"
  runtime_id="$(jq -r '.agents.defaults.agentRuntime.id // empty' "$cfg_file" 2>/dev/null)"
  has_expected_model="$(jq -r --arg model "$EXPECTED_OPENCLAW_MODEL" '(.agents.defaults.models // {}) | has($model)' "$cfg_file" 2>/dev/null)"

  if [[ "$current_model" == "$EXPECTED_OPENCLAW_MODEL" && "$has_expected_model" == "true" ]]; then
    if [[ "$EXPECTED_OPENCLAW_MODEL" != openai-codex/* || -z "$runtime_id" ]]; then
      return 0
    fi
  fi

  add_incident_code "openclaw_model_config_drift"
  if [[ "$current_model" == openai/* && "$EXPECTED_OPENCLAW_MODEL" == openai-codex/* ]]; then
    finding="OpenClaw config uses direct OpenAI model $current_model, but this host is configured for Codex OAuth; expected $EXPECTED_OPENCLAW_MODEL."
  else
    finding="OpenClaw model config drift: primary=${current_model:-missing}, expected=$EXPECTED_OPENCLAW_MODEL."
  fi
  [[ -n "$runtime_id" && "$EXPECTED_OPENCLAW_MODEL" == openai-codex/* ]] && finding="$finding Runtime override agents.defaults.agentRuntime=$runtime_id is incompatible with the expected Codex OAuth model."
  append_sanity_finding "$finding"
  if [[ "$AUTO_REMEDIATE_EXPECTED_OPENCLAW_MODEL" == "true" ]]; then
    append_array ACTIONS "OpenClawNurse will restore the expected OpenClaw model config after doctor repair."
  else
    append_array ACTIONS "Set agents.defaults.model.primary to $EXPECTED_OPENCLAW_MODEL and remove incompatible runtime overrides manually."
  fi
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
  COMMITMENTS_SUMMARY=""
  SECURITY_AUDIT_SUMMARY=""
  PACKAGE_DRIFT_SUMMARY=""
  DOCTOR_WARNING_SUMMARY=""
  PROVIDER_EMPTY_INPUT_COUNT=0
  PROVIDER_AUTH_ERROR_COUNT=0
  STUCK_SESSION_COUNT=0
  CONFIG_INVALID_COUNT=0
  UPDATE_PROVENANCE_WARNING_COUNT=0
  COMMITMENTS_ERROR_COUNT=0
  MODEL_ACCESS_ERROR_COUNT=0
  SECURITY_AUDIT_CRITICAL_COUNT=0
  SECURITY_AUDIT_WARN_COUNT=0
  LOCAL_HOTFIX_COUNT=0

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
  remove_array_value ACTIONS "OpenClawNurse will restore the expected OpenClaw model config after doctor repair."
  remove_array_value ACTIONS "Set agents.defaults.model.primary to $EXPECTED_OPENCLAW_MODEL and remove incompatible runtime overrides manually."
  remove_array_value ACTIONS "Restore Codex OAuth model config or provide OPENAI_API_KEY for direct OpenAI models."
}

run_final_sanity_pass() {
  reset_sanity_state_for_final_pass
  run_runtime_sanity || true
  scan_openclaw_package_hotfixes || true
  run_commitments_sanity || true
  run_security_audit_sanity || true
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
  detect_openclaw_model_config_drift || true
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

  PROVIDER_EMPTY_INPUT_COUNT="$(count_fixed_lines "$logs" 'One of "input" or "previous_response_id"')"
  PROVIDER_AUTH_ERROR_COUNT="$(count_regex_lines "$logs" 'No API key found for provider "openai"|FailoverError:.*provider "openai"|reason=auth')"
  STUCK_SESSION_COUNT="$(count_fixed_lines "$logs" '[diagnostic] stuck session')"
  CONFIG_INVALID_COUNT="$(count_regex_lines "$logs" 'Config invalid|Invalid config')"
  UPDATE_PROVENANCE_WARNING_COUNT="$(count_regex_lines "$logs" 'not-git-install|Gateway restart update skipped|unknown update provenance')"
  GATEWAY_MODEL_DETECTED="$(printf '%s\n' "$logs" | grep -Eo 'agent model: [^[:space:]]+' | sed 's/^agent model: //' | tail -n 1)"
  GATEWAY_LOG_SUMMARY="since=$since; emptyInput=$PROVIDER_EMPTY_INPUT_COUNT; providerAuth=$PROVIDER_AUTH_ERROR_COUNT; stuckSessions=$STUCK_SESSION_COUNT; configInvalid=$CONFIG_INVALID_COUNT; updateProvenanceWarnings=$UPDATE_PROVENANCE_WARNING_COUNT"

  if (( PROVIDER_EMPTY_INPUT_COUNT > 0 )); then
    append_sanity_finding "Gateway logs contain $PROVIDER_EMPTY_INPUT_COUNT provider empty-input error(s) since $since."
    append_array ACTIONS "Inspect recent ingress commands; a command may be reaching OpenClaw but producing an empty provider prompt."
  fi

  if (( PROVIDER_AUTH_ERROR_COUNT > 0 )); then
    local latest_auth_line latest_ready_line
    latest_auth_line="$(printf '%s\n' "$logs" | awk 'BEGIN { IGNORECASE=1 } /No API key found for provider "openai"|FailoverError:.*provider "openai"|reason=auth/ { n=NR } END { print n + 0 }')"
    latest_ready_line="$(printf '%s\n' "$logs" | awk '/\\[gateway\\] ready|http server listening|agent model: openai-codex\// { n=NR } END { print n + 0 }')"
    resolve_expected_model_from_config
    if ! (( latest_ready_line > latest_auth_line )) || [[ "$EXPECTED_OPENCLAW_MODEL" != openai-codex/* ]]; then
      add_incident_code "provider_auth"
      append_sanity_finding "Gateway logs contain $PROVIDER_AUTH_ERROR_COUNT direct OpenAI auth error(s) since $since."
      append_array ACTIONS "Restore Codex OAuth model config or provide OPENAI_API_KEY for direct OpenAI models."
    fi
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

scan_openclaw_package_hotfixes() {
  [[ "$ENABLE_PACKAGE_DRIFT_SANITY" == "true" ]] || return 0
  SANITY_ATTEMPTED=1

  local roots=()
  local candidate root marker_count marker
  if [[ "$OPENCLAW_BIN" == */* ]]; then
    root="$(openclaw_package_root_from_path "$OPENCLAW_BIN" || true)"
    [[ -n "$root" ]] && append_unique_array roots "$root"
  else
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      root="$(openclaw_package_root_from_path "$candidate" || true)"
      [[ -n "$root" ]] && append_unique_array roots "$root"
    done < <(type -a -P "$OPENCLAW_BIN" 2>/dev/null || true)
  fi

  for candidate in $OPENCLAW_EXTRA_SCAN_PATHS; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    root="$(openclaw_package_root_from_path "$candidate" || true)"
    [[ -n "$root" ]] && append_unique_array roots "$root"
  done

  local hotfix_lines=()
  for root in "${roots[@]:-}"; do
    [[ -d "$root" ]] || continue
    marker_count="$(find "$root" -type f \( -name '*.bak-commitments-model-*' -o -name '*.openclawnurse-hotfix-*' \) 2>/dev/null | wc -l | tr -d ' ')"
    if (( marker_count > 0 )); then
      LOCAL_HOTFIX_COUNT=$((LOCAL_HOTFIX_COUNT + marker_count))
      hotfix_lines+=("$root:$marker_count")
      while IFS= read -r marker; do
        [[ -n "$marker" ]] || continue
        append_unique_array ACTIONS "Local OpenClaw package hotfix marker found at $marker; upstream or reapply this fix after package updates."
      done < <(find "$root" -type f \( -name '*.bak-commitments-model-*' -o -name '*.openclawnurse-hotfix-*' \) 2>/dev/null | head -n 5)
    fi
  done

  if (( LOCAL_HOTFIX_COUNT > 0 )); then
    add_incident_code "openclaw_package_local_hotfix"
    PACKAGE_DRIFT_SUMMARY="localHotfixMarkers=$LOCAL_HOTFIX_COUNT; roots=${hotfix_lines[*]}"
    append_sanity_finding "OpenClaw package has $LOCAL_HOTFIX_COUNT local hotfix marker(s); future updates may overwrite them."
  else
    PACKAGE_DRIFT_SUMMARY="localHotfixMarkers=0"
  fi
}

run_commitments_sanity() {
  [[ "$ENABLE_COMMITMENTS_SANITY" == "true" ]] || return 0
  SANITY_ATTEMPTED=1

  local enabled="false"
  if [[ -f "$OPENCLAW_CONFIG_FILE" ]] && jq empty "$OPENCLAW_CONFIG_FILE" >/dev/null 2>&1; then
    enabled="$(jq -r '.commitments.enabled // false' "$OPENCLAW_CONFIG_FILE" 2>/dev/null)"
  fi

  if [[ "$enabled" != "true" ]]; then
    COMMITMENTS_SUMMARY="disabled"
    return 0
  fi

  local output status cmd
  build_openclaw_cmd cmd
  cmd+=(commitments --all --json)
  run_capture_allow_fail output status "Checking commitments store" timeout "${STATUS_TIMEOUT}s" "${cmd[@]}"
  if [[ "$status" -ne 0 ]] || ! printf '%s' "$output" | jq empty >/dev/null 2>&1; then
    add_incident_code "commitments_cli_failed"
    COMMITMENTS_SUMMARY="enabled=true; cli=failed"
    append_sanity_finding "Commitments are enabled, but 'openclaw commitments --all --json' failed."
    append_unique_array ACTIONS "Verify the OpenClaw commitments command and current package version."
    return 0
  fi

  local count store_path max_per_day
  count="$(printf '%s' "$output" | jq -r '.count // (.commitments | length) // 0' 2>/dev/null)"
  store_path="$(printf '%s' "$output" | jq -r '.storePath // .store // empty' 2>/dev/null)"
  max_per_day="$(jq -r '.commitments.maxPerDay // empty' "$OPENCLAW_CONFIG_FILE" 2>/dev/null || true)"

  local trace_dir="$OPENCLAW_STATE_HOME/commitments/extractor-sessions"
  local trace_logs=""
  if [[ -d "$trace_dir" ]]; then
    trace_logs="$(find "$trace_dir" -type f -mtime "-$COMMITMENTS_TRACE_SCAN_DAYS" -print0 2>/dev/null \
      | xargs -0 grep -IhE 'errorMessage|does not have access to model|model_not_found|unsupported model|Unauthorized|provider|modelId|openai/gpt-5\.5' 2>/dev/null || true)"
  fi

  COMMITMENTS_ERROR_COUNT="$(printf '%s\n' "$trace_logs" | grep -Ei 'errorMessage|failed|error' | wc -l | tr -d ' ')"
  MODEL_ACCESS_ERROR_COUNT="$(printf '%s\n' "$trace_logs" | grep -Ei 'does not have access to model|model_not_found|unsupported model|unauthorized|permission denied' | wc -l | tr -d ' ')"

  resolve_expected_model_from_config
  local mismatch_count=0
  if [[ -n "$EXPECTED_OPENCLAW_MODEL" && -n "$trace_logs" ]]; then
    mismatch_count="$(printf '%s\n' "$trace_logs" | grep -E 'modelId|provider|openai/gpt-5\.5' | grep -Fv "$EXPECTED_OPENCLAW_MODEL" | wc -l | tr -d ' ')"
  fi

  COMMITMENTS_SUMMARY="enabled=true; count=${count:-0}; maxPerDay=${max_per_day:-unknown}; store=${store_path:-unknown}; traceErrors=$COMMITMENTS_ERROR_COUNT; modelAccessErrors=$MODEL_ACCESS_ERROR_COUNT"

  if (( MODEL_ACCESS_ERROR_COUNT > 0 )); then
    add_incident_code "commitments_extractor_model_access"
    append_sanity_finding "Commitments extractor traces contain $MODEL_ACCESS_ERROR_COUNT model access error(s) in the last $COMMITMENTS_TRACE_SCAN_DAYS day(s)."
    append_unique_array ACTIONS "Check commitments extractor provider/model routing; it may be using a model the account cannot access."
  elif (( COMMITMENTS_ERROR_COUNT > 0 )); then
    add_incident_code "commitments_extractor_failed"
    append_sanity_finding "Commitments extractor traces contain $COMMITMENTS_ERROR_COUNT error line(s) in the last $COMMITMENTS_TRACE_SCAN_DAYS day(s)."
    append_unique_array ACTIONS "Inspect recent files under $trace_dir for failed commitment extraction runs."
  fi

  if (( mismatch_count > 0 )); then
    add_incident_code "commitments_extractor_model_mismatch"
    append_sanity_finding "Commitments extractor traces mention model/provider values that differ from expected model $EXPECTED_OPENCLAW_MODEL."
    append_unique_array ACTIONS "Align commitments extraction model selection with the agent/default OpenClaw model."
  fi
}

fix_security_file_permissions() {
  [[ "$AUTO_FIX_SECURITY_FILE_PERMS" == "true" ]] || return 0

  local path
  for path in "$OPENCLAW_STATE_HOME/credentials"; do
    [[ -e "$path" ]] || continue
    if [[ -n "$(find "$path" -maxdepth 0 -perm /077 -print -quit 2>/dev/null)" ]]; then
      add_incident_code "security_file_permissions"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        append_array FIXES "Dry-run: would tighten permissions on $path."
        record_remediation "security_file_permissions" "would_apply" "chmod go-rwx $path"
      elif chmod go-rwx "$path" 2>/dev/null; then
        append_array FIXES "Tightened permissions on $path."
        record_remediation "security_file_permissions" "applied" "chmod go-rwx $path"
        REMEDIATION_APPLIED=1
      else
        append_sanity_finding "Security file permission fix failed for $path."
        record_remediation "security_file_permissions" "apply_failed" "chmod go-rwx $path failed"
      fi
    fi
  done
}

run_security_audit_sanity() {
  [[ "$ENABLE_SECURITY_AUDIT" == "true" ]] || return 0
  SANITY_ATTEMPTED=1

  fix_security_file_permissions || true

  local cmd output status
  build_openclaw_cmd cmd
  cmd+=(security audit --json)
  [[ "$SECURITY_AUDIT_DEEP" == "true" ]] && cmd+=(--deep)

  run_capture_allow_fail output status "Running OpenClaw security audit" timeout "${SECURITY_AUDIT_TIMEOUT}s" "${cmd[@]}"
  if [[ "$status" -ne 0 ]] || ! printf '%s' "$output" | jq empty >/dev/null 2>&1; then
    add_incident_code "security_audit_failed"
    SECURITY_AUDIT_SUMMARY="failed"
    append_sanity_finding "OpenClaw security audit failed or returned invalid JSON."
    append_unique_array ACTIONS "Run openclaw security audit --json manually and inspect stderr/output."
    return 0
  fi

  SECURITY_AUDIT_CRITICAL_COUNT="$(printf '%s' "$output" | jq -r '[.findings[]? | select(.severity == "critical")] | length' 2>/dev/null)"
  SECURITY_AUDIT_WARN_COUNT="$(printf '%s' "$output" | jq -r '[.findings[]? | select(.severity == "warn")] | length' 2>/dev/null)"
  local top_findings
  top_findings="$(printf '%s' "$output" | jq -r '.findings[]? | select(.severity == "critical" or .severity == "warn") | "\(.severity):\(.checkId)"' 2>/dev/null | head -n 5 | paste -sd ',' -)"
  SECURITY_AUDIT_SUMMARY="critical=$SECURITY_AUDIT_CRITICAL_COUNT; warn=$SECURITY_AUDIT_WARN_COUNT${top_findings:+; top=$top_findings}"

  if (( SECURITY_AUDIT_CRITICAL_COUNT > 0 )); then
    add_incident_code "security_audit_critical"
    append_sanity_critical "OpenClaw security audit reports $SECURITY_AUDIT_CRITICAL_COUNT critical finding(s)."
    append_unique_array ACTIONS "Review openclaw security audit findings before exposing channels, tools, or Control UI."
  elif (( SECURITY_AUDIT_WARN_COUNT > 0 )); then
    add_incident_code "security_audit_warn"
    append_sanity_finding "OpenClaw security audit reports $SECURITY_AUDIT_WARN_COUNT warning(s)."
    append_unique_array ACTIONS "Review openclaw security audit warnings and decide which policy changes are intentional."
  fi
}

parse_doctor_output_signals() {
  local output="$1"
  local lowered
  lowered="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  local signals=()

  if printf '%s' "$lowered" | grep -Eq 'system node.*below required|node.*below required'; then
    signals+=("system-node-below-required")
    append_sanity_finding "Doctor reports the system Node.js is below OpenClaw's required version."
    append_unique_array ACTIONS "Keep the gateway service pinned to the bundled supported Node.js runtime or update the system Node.js package."
  fi

  if printf '%s' "$lowered" | grep -Eq 'no active memory plugin'; then
    signals+=("memory-plugin-inactive")
    append_sanity_finding "Doctor reports no active memory plugin registered for the current config."
    append_unique_array ACTIONS "Verify whether claude-mem should provide OpenClaw memory search in this profile."
  fi

  if printf '%s' "$lowered" | grep -Eq 'missing requirements[[:space:]]+[1-9]|missing requirements'; then
    signals+=("skills-missing-requirements")
    append_sanity_finding "Doctor reports skills with missing requirements."
    append_unique_array ACTIONS "Review OpenClaw doctor skills output and install only the skill requirements that are actually needed."
  fi

  if printf '%s' "$lowered" | grep -Eq 'plugins.*errors:[[:space:]]*[1-9]|errors:[[:space:]]*[1-9]'; then
    signals+=("doctor-errors")
    append_sanity_finding "Doctor output contains non-zero error counters."
    append_unique_array ACTIONS "Inspect OpenClaw doctor output for plugin/runtime errors."
  fi

  if ((${#signals[@]} > 0)); then
    DOCTOR_WARNING_SUMMARY="$(printf '%s ' "${signals[@]}" | sed 's/[[:space:]]$//')"
    add_incident_code "doctor_warnings"
  else
    DOCTOR_WARNING_SUMMARY="none"
  fi
}

disk_metric_line() {
  local path="$1"
  df -Pm "$path" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $1 "|" $4 "|" $5 "|" $6 }'
}

disk_top_offenders() {
  local path="$1"
  local limit="$2"
  local scan_path="$path"
  [[ -d "$scan_path" ]] || scan_path="$(dirname "$path")"
  du -xh --max-depth=1 "$scan_path" 2>/dev/null | sort -h | tail -n "$limit"
}

run_disk_sanity() {
  [[ "$ENABLE_DISK_SANITY" == "true" ]] || return 0
  SANITY_ATTEMPTED=1

  local paths=("$OPENCLAW_STATE_HOME" "$HOME" "/tmp")
  local seen_mounts=()
  local path metric fs avail_mb used_pct mount offender_summary line
  local findings=()

  for path in "${paths[@]}"; do
    [[ -e "$path" ]] || continue
    metric="$(disk_metric_line "$path")"
    [[ -n "$metric" ]] || continue
    IFS='|' read -r fs avail_mb used_pct mount <<<"$metric"
    if [[ " ${seen_mounts[*]} " == *" $mount "* ]]; then
      continue
    fi
    seen_mounts+=("$mount")

    line="$mount used=${used_pct}% free=${avail_mb}MB fs=$fs"
    findings+=("$line")
    if (( used_pct >= DISK_CRITICAL_PERCENT || avail_mb <= DISK_CRITICAL_MIN_FREE_MB )); then
      add_incident_code "disk_pressure"
      offender_summary="$(disk_top_offenders "$path" "$DISK_TOP_OFFENDERS_LIMIT")"
      append_sanity_critical "Disk critically constrained on $line. Top usage near $path: ${offender_summary//$'\n'/; }"
      append_array ERRORS "Disk is critically constrained on $mount."
      append_array ACTIONS "Free disk space on $mount before OpenClaw writes, updates or reports fail."
    elif (( used_pct >= DISK_WARN_PERCENT || avail_mb <= DISK_WARN_MIN_FREE_MB )); then
      add_incident_code "disk_pressure"
      offender_summary="$(disk_top_offenders "$path" "$DISK_TOP_OFFENDERS_LIMIT")"
      append_sanity_finding "Disk pressure on $line. Top usage near $path: ${offender_summary//$'\n'/; }"
      append_array ACTIONS "Review disk usage and prune caches/logs before the filesystem fills."
    fi
  done

  DISK_FINDINGS_SUMMARY="$(printf '%s\n' "${findings[@]:-}" | sed '/^$/d')"

  local sqlite_path sqlite_size_mb
  while IFS= read -r sqlite_path; do
    [[ -n "$sqlite_path" ]] || continue
    sqlite_size_mb=$(( ($(stat -c '%s' "$sqlite_path" 2>/dev/null || printf 0) + 1048575) / 1048576 ))
    if (( sqlite_size_mb >= OPENCLAW_LOG_SQLITE_WARN_MB )); then
      add_incident_code "large_log_sqlite"
      append_sanity_finding "Large OpenClaw/Codex log database: $sqlite_path is ${sqlite_size_mb}MB."
      append_array ACTIONS "Rotate or remove oversized logs_*.sqlite after stopping the gateway/app-server."
    fi
  done < <(find "$OPENCLAW_STATE_HOME/agents" -type f -name 'logs_*.sqlite' 2>/dev/null)
}

run_cron_sanity() {
  [[ "$ENABLE_CRON_SANITY" == "true" ]] || return 0
  SANITY_ATTEMPTED=1

  local jobs_file="$OPENCLAW_STATE_HOME/cron/jobs.json"
  [[ -f "$jobs_file" ]] || return 0
  if ! jq empty "$jobs_file" >/dev/null 2>&1; then
    append_sanity_finding "Cron sanity skipped because $jobs_file is not valid JSON."
    return 0
  fi

  local threshold_ms=$((CRON_ISOLATED_MIN_INTERVAL_SECONDS * 1000))
  local risky
  risky="$(jq -r --argjson threshold "$threshold_ms" '
    .jobs[]?
    | select((if has("enabled") then .enabled else true end) == true)
    | select((.sessionTarget // "") == "isolated")
    | select((.schedule.everyMs // 0) > 0 and (.schedule.everyMs // 0) < $threshold)
    | "\(.id) \(.name // "unnamed") every=\((.schedule.everyMs / 1000)|floor)s"
  ' "$jobs_file")"

  CRON_FINDINGS_SUMMARY="$risky"
  if [[ -n "$risky" ]]; then
    add_incident_code "high_frequency_isolated_cron"
    append_sanity_finding "High-frequency isolated OpenClaw cron jobs can create session churn and orphan transcripts: ${risky//$'\n'/; }"
    append_array ACTIONS "Move very frequent isolated cron agent jobs to direct scripts/timers, or increase their interval above ${CRON_ISOLATED_MIN_INTERVAL_SECONDS}s."
  fi
}

default_openclaw_agent_id() {
  local agent_id=""
  if [[ -f "$OPENCLAW_CONFIG_FILE" ]] && jq empty "$OPENCLAW_CONFIG_FILE" >/dev/null 2>&1; then
    agent_id="$(jq -r '.session.defaultAgentId // .agents.defaultId // .agents.default // empty' "$OPENCLAW_CONFIG_FILE" 2>/dev/null || true)"
  fi
  printf '%s' "${agent_id:-main}"
}

session_store_paths() {
  if [[ "$AUTO_REMEDIATE_ALL_AGENTS" == "true" ]]; then
    find "$OPENCLAW_STATE_HOME/agents" -mindepth 3 -maxdepth 3 -type f -path '*/sessions/sessions.json' 2>/dev/null
    return 0
  fi

  local agent_id
  agent_id="$(default_openclaw_agent_id)"
  local store="$OPENCLAW_STATE_HOME/agents/$agent_id/sessions/sessions.json"
  if [[ -f "$store" ]]; then
    printf '%s\n' "$store"
  fi
}

is_safe_orphan_transcript_age() {
  local path="$1"
  local now mtime
  now="$(date +%s)"
  mtime="$(stat -c '%Y' "$path" 2>/dev/null || printf '%s' "$now")"
  (( now - mtime >= ORPHAN_TRANSCRIPT_SAFETY_SECONDS ))
}

inventory_orphan_transcript_paths() {
  local store session_dir protected_json transcript_path transcript_name
  while IFS= read -r store; do
    [[ -n "$store" && -f "$store" ]] || continue
    jq empty "$store" >/dev/null 2>&1 || continue
    session_dir="$(dirname "$store")"
    protected_json="$(jq -r '
      def rows:
        if type == "array" then .[]
        elif type == "object" then .[]
        else empty
        end;
      [rows | .sessionFile? // empty | select(length > 0) | split("/")[-1] | sub("\\.jsonl$"; "")]
      | unique
      | @json
    ' "$store" 2>/dev/null || printf '[]')"

    while IFS= read -r transcript_path; do
      [[ -n "$transcript_path" && -f "$transcript_path" ]] || continue
      is_safe_orphan_transcript_age "$transcript_path" || continue
      transcript_name="$(basename "$transcript_path")"
      if jq -n -e --arg name "$transcript_name" --argjson protected "$protected_json" '
        $protected
        | any(. as $stem | $name == ($stem + ".jsonl") or ($name | startswith($stem + ".")))
      ' >/dev/null 2>&1; then
        continue
      fi
      printf '%s\n' "$transcript_path"
    done < <(find "$session_dir" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null)
  done < <(session_store_paths)
}

archive_transcript_path() {
  local transcript_path="$1"
  local archive_root="$2"
  local relative="$transcript_path"
  if [[ "$relative" == "$OPENCLAW_STATE_HOME/"* ]]; then
    relative="${relative#"$OPENCLAW_STATE_HOME/"}"
  else
    relative="${relative#/}"
  fi
  local dest="$archive_root/$relative"
  mkdir -p "$(dirname "$dest")"
  mv "$transcript_path" "$dest"
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

  local health_output health_json health_status
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
    health_json="$(printf '%s\n' "$health_output" | json_payload_from_output)"
    if [[ "$health_status" -eq 0 ]] && printf '%s' "$health_json" | jq -e '.ok == true' >/dev/null 2>&1; then
      log INFO "Self-test health check succeeded"
      break
    fi
    log INFO "Self-test health not ready yet (attempt $attempt); retrying in ${GATEWAY_WAIT_INTERVAL}s"
    attempt=$((attempt + 1))
    sleep "$GATEWAY_WAIT_INTERVAL"
  done

  health_json="$(printf '%s\n' "$health_output" | json_payload_from_output)"
  if [[ "$health_status" -ne 0 ]] || ! printf '%s' "$health_json" | jq -e '.ok == true' >/dev/null 2>&1; then
    printf 'SELF_TEST=FAILED\n'
    printf 'Reason: health check failed\n'
    return 1
  fi

  run_runtime_sanity || true
  scan_openclaw_package_hotfixes || true
  run_commitments_sanity || true
  run_security_audit_sanity || true
  run_telegram_sanity || true
  local original_gateway_log_since="$GATEWAY_LOG_SINCE"
  GATEWAY_LOG_SINCE="10 minutes ago"
  run_gateway_log_scan || true
  GATEWAY_LOG_SINCE="$original_gateway_log_since"
  run_disk_sanity || true
  run_cron_sanity || true

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
  local actionable_lowered="$lowered"

  if printf '%s' "$lowered" | grep -Eq 'model auth|auth profile|openai-codex:.*expired|auth login|authentication.*expired'; then
    add_incident_code "model_auth_expired"
    MODEL_AUTH_SUMMARY="$(printf '%s\n' "$output" \
      | grep -Ei 'model auth|auth profile|openai-codex:.*expired|auth login|authentication.*expired' \
      | sed -E 's/^[[:space:][:punct:]]+//; s/[[:space:]]+/ /g' \
      | head -n 2 \
      | paste -sd '; ' -)"
    MODEL_AUTH_SUMMARY="${MODEL_AUTH_SUMMARY:-OpenClaw doctor reported an expired model auth profile.}"
    append_unique_array ACTIONS "Refresh the expired model auth profile when you next need that profile; this does not degrade the gateway if another valid profile is active."
    local warning_count
    warning_count="$(printf '%s\n' "$lowered" | sed -nE 's/.*warnings:[[:space:]]*([0-9]+).*/\1/p' | sort -nr | head -n 1)"
    warning_count="${warning_count:-0}"
    actionable_lowered="$(printf '%s\n' "$lowered" | grep -viE 'model auth|auth profile|openai-codex:.*expired|auth login|authentication.*expired' || true)"
    if (( warning_count <= 1 )); then
      actionable_lowered="$(printf '%s\n' "$actionable_lowered" | grep -viE 'warnings:[[:space:]]*[1-9]' || true)"
    fi
  fi

  if printf '%s' "$actionable_lowered" | grep -q 'orphan transcript'; then
    local eligible_orphan_count
    eligible_orphan_count="$(inventory_orphan_transcript_paths | sed '/^$/d' | head -n 1 | wc -l | tr -d ' ')"
    if [[ "$eligible_orphan_count" == "0" ]]; then
      append_unique_array ACTIONS "Fresh orphan transcripts, if any, are inside the ${ORPHAN_TRANSCRIPT_SAFETY_SECONDS}s safety window and will be rechecked automatically."
      actionable_lowered="$(printf '%s\n' "$actionable_lowered" \
        | grep -viE 'orphan|transcript|sessions\.json|\.jsonl|active session history|archive them safely|deleted\.<timestamp>|examples:' \
        || true)"
    fi
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    add_incident_code "doctor_failed"
    DOCTOR_CLASSIFICATION="needs_manual_attention"
    DOCTOR_SUMMARY="doctor exited with code $exit_code"
    append_array ACTIONS "Inspect the doctor output and run manual remediation."
    return
  fi

  if printf '%s' "$actionable_lowered" | grep -Eq 'doctor changes|synced|repaired|fixed|migrated|normalized|generated and configured|archived [0-9]+ orphan transcript|pruned [0-9]+'; then
    add_incident_code "doctor_repaired"
    DOCTOR_CLASSIFICATION="repaired"
    DOCTOR_SUMMARY="doctor applied at least one corrective action"
    append_array FIXES "Doctor reported corrective actions during the run."
    return
  fi

  if printf '%s' "$actionable_lowered" | grep -Eq 'missing transcripts|needs manual attention|lasterror|errors:[[:space:]]*[1-9]|warnings:[[:space:]]*[1-9]|failed|unhealthy|orphan|corrupt|broken'; then
    if printf '%s' "$actionable_lowered" | grep -q 'missing transcripts'; then
      add_incident_code "missing_transcripts"
    fi
    if printf '%s' "$actionable_lowered" | grep -q 'orphan transcript'; then
      add_incident_code "orphan_transcripts"
    fi
    if printf '%s' "$actionable_lowered" | grep -Eq 'unhealthy|gateway'; then
      add_incident_code "gateway_unhealthy"
    fi
    DOCTOR_CLASSIFICATION="needs_manual_attention"
    DOCTOR_SUMMARY="doctor found issues that still require intervention"
    append_array ACTIONS "Review the doctor recommendations that remain unresolved."
    return
  fi

  if printf '%s' "$actionable_lowered" | grep -Eq 'no channel security warnings detected|doctor complete'; then
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

  local transcript_paths=()
  local transcript_path
  while IFS= read -r transcript_path; do
    [[ -n "$transcript_path" ]] || continue
    append_unique_array transcript_paths "$transcript_path"
  done < <(inventory_orphan_transcript_paths | sort -u)

  local transcript_names=()
  while IFS= read -r transcript_name; do
    [[ -n "$transcript_name" ]] || continue
    transcript_names+=("$transcript_name")
  done < <(printf '%s' "$DOCTOR_OUTPUT" | grep -oE '[[:alnum:]_.-]+\.jsonl' | sort -u)

  if ((${#transcript_paths[@]} == 0 && ${#transcript_names[@]} > 0)); then
    local transcript_name
    for transcript_name in "${transcript_names[@]}"; do
      while IFS= read -r transcript_path; do
        [[ -n "$transcript_path" ]] || continue
        is_safe_orphan_transcript_age "$transcript_path" || continue
        append_unique_array transcript_paths "$transcript_path"
      done < <(find "$OPENCLAW_STATE_HOME/agents" -type f -name "$transcript_name" 2>/dev/null)
    done
  fi

  if ((${#transcript_paths[@]} == 0)); then
    if [[ "$DRY_RUN" -eq 0 ]]; then
      append_array FIXES "Doctor reported orphan transcripts, but no eligible files remained outside the ${ORPHAN_TRANSCRIPT_SAFETY_SECONDS}s safety window."
      record_remediation "orphan_transcripts" "deferred" "no eligible files outside safety window"
      return 0
    fi
    append_array ACTIONS "Doctor reported orphan transcripts, but no eligible files were found outside the ${ORPHAN_TRANSCRIPT_SAFETY_SECONDS}s safety window."
    record_remediation "orphan_transcripts" "deferred" "no eligible files outside safety window"
    return 0
  fi

  if ((${#transcript_paths[@]} > MAX_ORPHAN_TRANSCRIPTS_PER_RUN)); then
    append_array ACTIONS "Doctor reported ${#transcript_paths[@]} orphan transcripts, exceeding MAX_ORPHAN_TRANSCRIPTS_PER_RUN=$MAX_ORPHAN_TRANSCRIPTS_PER_RUN."
    record_remediation "orphan_transcripts" "blocked_by_limit" "${#transcript_paths[@]} files exceed per-run archive limit"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would archive ${#transcript_paths[@]} orphan transcript file(s)."
    append_array ACTIONS "Run without --dry-run to archive orphan transcript files automatically. Files newer than ${ORPHAN_TRANSCRIPT_SAFETY_SECONDS}s are left untouched."
    record_remediation "orphan_transcripts" "would_apply" "would archive ${#transcript_paths[@]} orphan transcript files"
    return 0
  fi

  local archived_count=0
  local ts
  ts="$(date --iso-8601=seconds | tr ':' '-')"
  local archive_root="$ORPHAN_TRANSCRIPT_ARCHIVE_DIR/$ts"
  for transcript_path in "${transcript_paths[@]}"; do
    [[ -f "$transcript_path" ]] || continue
    archive_transcript_path "$transcript_path" "$archive_root"
    archived_count=$((archived_count + 1))
  done

  if ((archived_count == 0)); then
    append_array FIXES "Doctor reported orphan transcripts, but no eligible files remained by the time remediation ran."
    record_remediation "orphan_transcripts" "deferred" "no eligible files remained by apply time"
    return 0
  fi

  REMEDIATION_APPLIED=1
  append_array FIXES "Archived $archived_count orphan transcript file(s) to $archive_root."
  record_remediation "orphan_transcripts" "applied" "archived $archived_count orphan transcript files to $archive_root"
  return 0
}

prepare_doctor_recheck_after_remediation() {
  remove_incident_code "missing_transcripts"
  remove_incident_code "orphan_transcripts"
  remove_incident_code "doctor_repaired"
  remove_array_value ACTIONS "Review the doctor recommendations that remain unresolved."
  remove_array_value ACTIONS "Run without --dry-run to archive orphan transcript files automatically. Files newer than ${ORPHAN_TRANSCRIPT_SAFETY_SECONDS}s are left untouched."
  remove_array_value ACTIONS "Run without --dry-run to auto-prune session entries with missing transcripts."
  DOCTOR_CLASSIFICATION="unknown"
  DOCTOR_SUMMARY="doctor will be rechecked after remediation"
}

resolve_self_update_repo_dir() {
  local candidate
  local script_dir
  local parent

  for candidate in "$SELF_UPDATE_REPO_DIR" "$HOME/projects/openclawnurse"; do
    [[ -n "$candidate" ]] || continue
    if [[ -d "$candidate/.git" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  parent="$script_dir"
  while [[ "$parent" != "/" ]]; do
    if [[ -d "$parent/.git" ]]; then
      printf '%s' "$parent"
      return 0
    fi
    parent="$(dirname "$parent")"
  done

  return 1
}

self_update_capture() {
  local output_var="$1"
  local status_var="$2"
  local label="$3"
  shift 3

  if command_exists timeout && [[ "$SELF_UPDATE_TIMEOUT" =~ ^[0-9]+$ ]] && (( SELF_UPDATE_TIMEOUT > 0 )); then
    run_capture_allow_fail "$output_var" "$status_var" "$label" timeout "${SELF_UPDATE_TIMEOUT}s" "$@"
  else
    run_capture_allow_fail "$output_var" "$status_var" "$label" "$@"
  fi
}

self_update_validation_error() {
  local detail="$1"
  SELF_UPDATE_ERROR="$detail"
  add_incident_code "self_update_failed"
  append_array ERRORS "$detail"
}

validate_self_update_tree() {
  local tree="$1"
  local output status script json_file

  for script in \
    "$tree/install.sh" \
    "$tree/scripts/openclaw-doctor.sh" \
    "$tree/scripts/openclawnurse-openclaw-alert.sh" \
    "$tree/scripts/install-doctor.sh" \
    "$tree/systemd/openclawnurse.service" \
    "$tree/systemd/openclawnurse.timer"; do
    if [[ ! -f "$script" ]]; then
      printf 'missing required file: %s\n' "$script"
      return 1
    fi
  done

  self_update_capture output status "Validating OpenClawNurse installer syntax" bash -n "$tree/install.sh"
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$output"
    return 1
  fi

  while IFS= read -r script; do
    [[ -n "$script" ]] || continue
    self_update_capture output status "Validating OpenClawNurse script syntax: $(basename "$script")" bash -n "$script"
    if [[ "$status" -ne 0 ]]; then
      printf '%s\n' "$output"
      return 1
    fi
  done < <(find "$tree/scripts" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)

  if command_exists jq; then
    while IFS= read -r json_file; do
      [[ -n "$json_file" ]] || continue
      self_update_capture output status "Validating OpenClawNurse JSON: $(basename "$json_file")" jq empty "$json_file"
      if [[ "$status" -ne 0 ]]; then
        printf '%s\n' "$output"
        return 1
      fi
    done < <(find "$tree/config" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort)
  fi

  if [[ "$SELF_UPDATE_RUN_TESTS" == "true" && -x "$tree/scripts/test-smoke.sh" ]]; then
    self_update_capture output status "Running OpenClawNurse smoke tests for self-update target" "$tree/scripts/test-smoke.sh"
    if [[ "$status" -ne 0 ]]; then
      printf '%s\n' "$output"
      return 1
    fi
  fi

  return 0
}

validate_self_update_candidate() {
  local repo="$1"
  local target="$2"
  local worktree="$STATE_DIR/self-update-worktree-$RUN_ID"
  local output status cleanup_status

  rm -rf "$worktree"
  self_update_capture output status "Preparing OpenClawNurse self-update validation worktree" \
    git -C "$repo" worktree add --detach "$worktree" "$target"
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$output"
    return 1
  fi

  validate_self_update_tree "$worktree"
  status=$?

  self_update_capture output cleanup_status "Removing OpenClawNurse self-update validation worktree" \
    git -C "$repo" worktree remove --force "$worktree"
  if [[ "$cleanup_status" -ne 0 ]]; then
    rm -rf "$worktree"
  fi

  return "$status"
}

install_self_update_runtime_files() {
  local repo="$1"
  mkdir -p "$DATA_DIR/bin" "$DATA_DIR/systemd"
  install -m 0755 "$repo/scripts/openclaw-doctor.sh" "$DATA_DIR/bin/openclaw-doctor.sh"
  install -m 0755 "$repo/scripts/openclawnurse-openclaw-alert.sh" "$DATA_DIR/bin/openclawnurse-openclaw-alert.sh"
  install -m 0644 "$repo/systemd/openclawnurse.service" "$DATA_DIR/systemd/openclawnurse.service.template"
  install -m 0644 "$repo/systemd/openclawnurse.timer" "$DATA_DIR/systemd/openclawnurse.timer.template"
  if command_exists systemctl; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}

post_validate_self_update_install() {
  local output status
  self_update_capture output status "Validating installed OpenClawNurse doctor syntax" bash -n "$DATA_DIR/bin/openclaw-doctor.sh"
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$output"
    return 1
  fi

  self_update_capture output status "Validating installed OpenClawNurse help" "$DATA_DIR/bin/openclaw-doctor.sh" --help
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$output"
    return 1
  fi

  if [[ "$SELF_UPDATE_POST_SELF_TEST" == "true" ]]; then
    AUTO_SELF_UPDATE=false \
      REPORT_CHANNEL=none \
      LOCK_FILE="$STATE_DIR/self-update-self-test-$RUN_ID.lock" \
      "$DATA_DIR/bin/openclaw-doctor.sh" --config "$CONFIG_FILE" --self-test --no-notify >/dev/null
  fi
}

rollback_self_update() {
  local repo="$1"
  local backup_ref="$2"
  local output status

  self_update_capture output status "Rolling back OpenClawNurse self-update" git -C "$repo" reset --hard "$backup_ref"
  if [[ "$status" -ne 0 ]]; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update rollback failed."
    add_incident_code "self_update_rollback_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    append_array ACTIONS "Inspect $repo and backup ref $backup_ref before the next Nurse run."
    return 1
  fi

  if ! install_self_update_runtime_files "$repo"; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update rollback restored git but failed to reinstall runtime files."
    add_incident_code "self_update_rollback_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    return 1
  fi

  SELF_UPDATE_ROLLED_BACK=1
  append_array FIXES "Rolled OpenClawNurse back to ${SELF_UPDATE_FROM:0:12} after failed post-update validation."
  record_remediation "openclawnurse_self_update" "rolled_back" "restored $backup_ref"
  return 0
}

maybe_self_update() {
  [[ "$AUTO_SELF_UPDATE" == "true" ]] || {
    SELF_UPDATE_SUMMARY="disabled"
    return 0
  }
  [[ "$DRY_RUN" -eq 0 && "$SELF_TEST" -eq 0 && "$RETRY_PENDING_ONLY" -eq 0 ]] || {
    SELF_UPDATE_SUMMARY="skipped in non-maintenance mode"
    return 0
  }

  SELF_UPDATE_ATTEMPTED=1

  if ! command_exists git; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update is enabled but git is not available."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    return 1
  fi
  if ! command_exists install; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update is enabled but install is not available."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    return 1
  fi

  local repo
  if ! repo="$(resolve_self_update_repo_dir)"; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update is enabled but SELF_UPDATE_REPO_DIR does not point to a git repo."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    append_array ACTIONS "Set SELF_UPDATE_REPO_DIR to the OpenClawNurse git checkout."
    return 1
  fi
  SELF_UPDATE_REPO_RESOLVED="$repo"

  local dirty
  dirty="$(git -C "$repo" status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    SELF_UPDATE_SUMMARY="skipped because repo has local changes"
    SELF_UPDATE_ERROR="OpenClawNurse self-update skipped because $repo has uncommitted changes."
    add_incident_code "self_update_dirty_worktree"
    append_sanity_finding "$SELF_UPDATE_ERROR"
    append_array ACTIONS "Commit, stash or remove local OpenClawNurse changes so self-update can safely reset to upstream."
    record_remediation "openclawnurse_self_update" "blocked_by_dirty_worktree" "$repo"
    return 0
  fi

  local output status current target
  self_update_capture output status "Fetching OpenClawNurse upstream" \
    git -C "$repo" fetch "$SELF_UPDATE_REMOTE" "+refs/heads/$SELF_UPDATE_BRANCH:refs/remotes/$SELF_UPDATE_REMOTE/$SELF_UPDATE_BRANCH"
  if [[ "$status" -ne 0 ]]; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update fetch failed."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    append_array ACTIONS "Check network access and remote $SELF_UPDATE_REMOTE/$SELF_UPDATE_BRANCH for $repo."
    record_remediation "openclawnurse_self_update" "fetch_failed" "$SELF_UPDATE_REMOTE/$SELF_UPDATE_BRANCH"
    return 1
  fi

  current="$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null || true)"
  target="$(git -C "$repo" rev-parse --verify "refs/remotes/$SELF_UPDATE_REMOTE/$SELF_UPDATE_BRANCH^{commit}" 2>/dev/null || true)"
  SELF_UPDATE_FROM="$current"
  SELF_UPDATE_TO="$target"
  if [[ -z "$current" || -z "$target" ]]; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update could not resolve current or target revision."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    return 1
  fi

  if [[ "$current" == "$target" ]]; then
    SELF_UPDATE_SUMMARY="already up to date"
    record_remediation "openclawnurse_self_update" "not_needed" "$current"
    return 0
  fi
  SELF_UPDATE_AVAILABLE=1

  if ! output="$(validate_self_update_candidate "$repo" "$target" 2>&1)"; then
    self_update_validation_error "OpenClawNurse self-update target failed validation."
    append_array ACTIONS "Review upstream OpenClawNurse tests before applying $target."
    record_remediation "openclawnurse_self_update" "validation_failed" "${target:0:12}"
    return 1
  fi

  local backup_ref="refs/heads/backup/openclawnurse-self-update-$RUN_ID"
  self_update_capture output status "Creating OpenClawNurse self-update backup ref" \
    git -C "$repo" update-ref "$backup_ref" "$current"
  if [[ "$status" -ne 0 ]]; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update could not create backup ref."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    return 1
  fi

  case "$SELF_UPDATE_POLICY" in
    reset-to-remote)
      self_update_capture output status "Applying OpenClawNurse self-update by reset-to-remote" git -C "$repo" reset --hard "$target"
      ;;
    fast-forward)
      if ! git -C "$repo" merge-base --is-ancestor "$current" "$target"; then
        SELF_UPDATE_ERROR="OpenClawNurse self-update target is not a fast-forward from current HEAD."
        add_incident_code "self_update_failed"
        append_array ERRORS "$SELF_UPDATE_ERROR"
        append_array ACTIONS "Use SELF_UPDATE_POLICY=reset-to-remote or reconcile local branch history manually."
        return 1
      fi
      self_update_capture output status "Applying OpenClawNurse self-update by fast-forward" git -C "$repo" merge --ff-only "$target"
      ;;
    *)
      SELF_UPDATE_ERROR="Unsupported SELF_UPDATE_POLICY=$SELF_UPDATE_POLICY."
      add_incident_code "self_update_failed"
      append_array ERRORS "$SELF_UPDATE_ERROR"
      return 1
      ;;
  esac

  if [[ "$status" -ne 0 ]]; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update apply failed."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    append_array ACTIONS "Inspect $repo and backup ref ${backup_ref#refs/heads/}."
    return 1
  fi

  if ! install_self_update_runtime_files "$repo"; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update applied git revision but failed to install runtime files."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    if [[ "$SELF_UPDATE_ROLLBACK_ON_FAILURE" == "true" ]]; then
      rollback_self_update "$repo" "$backup_ref" || true
    fi
    return 1
  fi

  if ! output="$(post_validate_self_update_install 2>&1)"; then
    SELF_UPDATE_ERROR="OpenClawNurse self-update post-install validation failed."
    add_incident_code "self_update_failed"
    append_array ERRORS "$SELF_UPDATE_ERROR"
    record_remediation "openclawnurse_self_update" "post_validation_failed" "${target:0:12}"
    if [[ "$SELF_UPDATE_ROLLBACK_ON_FAILURE" == "true" ]]; then
      rollback_self_update "$repo" "$backup_ref" || true
    fi
    return 1
  fi

  SELF_UPDATE_APPLIED=1
  SELF_UPDATE_SUMMARY="updated to ${target:0:12}; new script takes over on the next run"
  append_array FIXES "OpenClawNurse self-updated from ${current:0:12} to ${target:0:12}."
  record_remediation "openclawnurse_self_update" "applied" "${current:0:12} -> ${target:0:12}"

  if [[ "$SELF_UPDATE_RESTART_GATEWAY" == "true" ]]; then
    restart_gateway && record_gateway_restart && wait_for_gateway_health || true
  fi

  return 0
}

run_preflight_checks() {
  local missing_required=0
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
      missing_required=1
    fi
  done

  if [[ "$NO_NOTIFY" -eq 0 && "$REPORT_CHANNEL" == "telegram" && -z "$TELEGRAM_TARGET" ]]; then
    append_unique_array ACTIONS "Configure TELEGRAM_TARGET so OpenClawNurse can deliver reports."
  fi

  if [[ "$NO_NOTIFY" -eq 0 && "$REPORT_CHANNEL" == "telegram" && -z "$TELEGRAM_BOT_TOKEN" ]]; then
    append_unique_array ACTIONS "Configure TELEGRAM_BOT_TOKEN so OpenClawNurse can deliver reports."
  fi

  return "$missing_required"
}


pm2_gateway_app_names_json() {
  local app_names=()
  read -r -a app_names <<<"$PM2_GATEWAY_APP_NAMES"
  printf '%s\n' "${app_names[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
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
  local output status json_output
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

  json_output="$(printf '%s\n' "$output" | json_payload_from_output)"
  if ! printf '%s' "$json_output" | jq empty >/dev/null 2>&1; then
    UPDATE_ERROR="$output"
    append_array ERRORS "Update status returned invalid JSON."
    return 1
  fi

  CURRENT_VERSION_BEFORE="$("$OPENCLAW_BIN" --version 2>/dev/null | sed -E 's/.* ([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n 1)"
  CURRENT_VERSION_AFTER="$CURRENT_VERSION_BEFORE"
  UPDATE_AVAILABLE=0
  if printf '%s' "$json_output" | jq -e '.availability.available == true' >/dev/null 2>&1; then
    UPDATE_AVAILABLE=1
    AVAILABLE_VERSION="$(printf '%s' "$json_output" | jq -r '.availability.latestVersion // .update.registry.latestVersion // empty')"
  else
    AVAILABLE_VERSION="$(printf '%s' "$json_output" | jq -r '.availability.latestVersion // empty')"
  fi
  CHANNEL_VALUE="$(printf '%s' "$json_output" | jq -r '.channel.value // empty')"
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

  # shellcheck disable=SC2034 # run_capture_with_heartbeat writes the captured output by nameref.
  local doctor_repair_output
  local doctor_repair_status
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
  parse_doctor_output_signals "$output"
}

remediate_expected_openclaw_model_config() {
  [[ "$AUTO_REMEDIATE_EXPECTED_OPENCLAW_MODEL" == "true" ]] || return 0
  [[ -n "$EXPECTED_OPENCLAW_MODEL" ]] || return 0
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0
  jq empty "$OPENCLAW_CONFIG_FILE" >/dev/null 2>&1 || return 0

  local current_model runtime_id has_expected_model should_fix=0
  current_model="$(jq -r '.agents.defaults.model.primary // empty' "$OPENCLAW_CONFIG_FILE" 2>/dev/null)"
  runtime_id="$(jq -r '.agents.defaults.agentRuntime.id // empty' "$OPENCLAW_CONFIG_FILE" 2>/dev/null)"
  has_expected_model="$(jq -r --arg model "$EXPECTED_OPENCLAW_MODEL" '(.agents.defaults.models // {}) | has($model)' "$OPENCLAW_CONFIG_FILE" 2>/dev/null)"

  [[ "$current_model" != "$EXPECTED_OPENCLAW_MODEL" ]] && should_fix=1
  [[ "$has_expected_model" != "true" ]] && should_fix=1
  if [[ "$EXPECTED_OPENCLAW_MODEL" == openai-codex/* && -n "$runtime_id" ]]; then
    should_fix=1
  fi
  [[ "$should_fix" -eq 1 ]] || return 0

  add_incident_code "openclaw_model_config_drift"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would restore OpenClaw model config to $EXPECTED_OPENCLAW_MODEL."
    record_remediation "openclaw_model_config_drift" "would_apply" "would set agents.defaults.model.primary"
    return 0
  fi

  local models_json output status
  models_json="$(jq -c --arg model "$EXPECTED_OPENCLAW_MODEL" '
    ((.agents.defaults.models // {}) + {($model): {}})
    | if ($model | startswith("openai-codex/")) then
        with_entries(select(.key | startswith("openai/") | not))
      else
        .
      end
  ' "$OPENCLAW_CONFIG_FILE")"

  local cmd
  build_openclaw_cmd cmd
  run_capture output status "Restoring expected OpenClaw primary model" \
    "${cmd[@]}" config set agents.defaults.model.primary "$EXPECTED_OPENCLAW_MODEL"
  if [[ "$status" -ne 0 ]]; then
    append_array ERRORS "Failed to restore expected OpenClaw primary model."
    append_array ACTIONS "Set agents.defaults.model.primary to $EXPECTED_OPENCLAW_MODEL manually."
    record_remediation "openclaw_model_config_drift" "apply_failed" "$output"
    return 1
  fi

  build_openclaw_cmd cmd
  run_capture output status "Restoring expected OpenClaw model registry" \
    "${cmd[@]}" config set agents.defaults.models "$models_json" --strict-json --replace
  if [[ "$status" -ne 0 ]]; then
    append_array ERRORS "Failed to restore expected OpenClaw model registry."
    append_array ACTIONS "Remove incompatible direct OpenAI model entries from agents.defaults.models manually."
    record_remediation "openclaw_model_config_drift" "apply_failed" "$output"
    return 1
  fi

  if [[ "$EXPECTED_OPENCLAW_MODEL" == openai-codex/* && -n "$runtime_id" ]]; then
    build_openclaw_cmd cmd
    run_capture output status "Removing incompatible OpenClaw agent runtime override" \
      "${cmd[@]}" config unset agents.defaults.agentRuntime
    if [[ "$status" -ne 0 ]]; then
      append_array ERRORS "Failed to remove incompatible OpenClaw agent runtime override."
      append_array ACTIONS "Remove agents.defaults.agentRuntime manually."
      record_remediation "openclaw_model_config_drift" "apply_failed" "$output"
      return 1
    fi
  fi

  REMEDIATION_APPLIED=1
  MODEL_CONFIG_REMEDIATED=1
  append_array FIXES "Restored OpenClaw model config to $EXPECTED_OPENCLAW_MODEL."
  record_remediation "openclaw_model_config_drift" "applied" "set expected OpenClaw model config"
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
  local output status json_output
  local cmd
  local attempt=1
  build_openclaw_cmd cmd
  cmd+=(health --json --timeout "$HEALTH_TIMEOUT_MS")

  while (( $(date +%s) <= deadline )); do
    log INFO "Checking gateway health"
    output="$("${cmd[@]}" 2>&1)"
    status=$?
    HEALTH_OUTPUT="$output"
    json_output="$(printf '%s\n' "$output" | json_payload_from_output)"

    if [[ "$status" -eq 0 ]] && printf '%s' "$json_output" | jq -e '.ok == true' >/dev/null 2>&1; then
      GATEWAY_HEALTHY=1
      remove_incident_code "gateway_unhealthy"
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
  local output status json_output
  local cmd
  build_openclaw_cmd cmd
  cmd+=(health --json --timeout "$HEALTH_TIMEOUT_MS")
  run_capture output status "Checking gateway health without restart" "${cmd[@]}"
  HEALTH_OUTPUT="$output"
  json_output="$(printf '%s\n' "$output" | json_payload_from_output)"

  if [[ "$status" -eq 0 ]] && printf '%s' "$json_output" | jq -e '.ok == true' >/dev/null 2>&1; then
    GATEWAY_HEALTHY=1
    remove_incident_code "gateway_unhealthy"
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
      --arg openclawStatusJson "$openclaw_status" \
      'def json_or($raw; $fallback): try ($raw | fromjson) catch $fallback;
      (json_or($openclawStatusJson; null)) as $openclawStatus
      | {
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

  local self_update_line="not attempted"
  if [[ "$SELF_UPDATE_ATTEMPTED" -eq 1 && "$SELF_UPDATE_APPLIED" -eq 1 ]]; then
    self_update_line="applied ${SELF_UPDATE_FROM:0:12} -> ${SELF_UPDATE_TO:0:12}"
  elif [[ "$SELF_UPDATE_ATTEMPTED" -eq 1 && "$SELF_UPDATE_ROLLED_BACK" -eq 1 ]]; then
    self_update_line="rolled back after failed validation"
  elif [[ "$SELF_UPDATE_ATTEMPTED" -eq 1 && "$SELF_UPDATE_AVAILABLE" -eq 1 && -n "$SELF_UPDATE_ERROR" ]]; then
    self_update_line="failed before apply"
  elif [[ "$SELF_UPDATE_ATTEMPTED" -eq 1 && -n "$SELF_UPDATE_SUMMARY" ]]; then
    self_update_line="$SELF_UPDATE_SUMMARY"
  elif [[ "$AUTO_SELF_UPDATE" != "true" ]]; then
    self_update_line="disabled"
  fi

  local restart_line="not required"
  [[ "$RESTART_ATTEMPTED" -eq 1 && "$RESTART_SUCCEEDED" -eq 1 ]] && restart_line="completed"
  [[ "$RESTART_ATTEMPTED" -eq 1 && "$RESTART_SUCCEEDED" -eq 0 ]] && restart_line="failed"

  local health_line="not checked"
  [[ "$GATEWAY_HEALTHY" -eq 1 ]] && health_line="gateway healthy"
  [[ "$RESTART_ATTEMPTED" -eq 1 && "$GATEWAY_HEALTHY" -eq 0 ]] && health_line="gateway did not become healthy in time"

  local summary_lines
  summary_lines="$(build_summary_from_output "$DOCTOR_OUTPUT")"
  local status_reason_lines
  status_reason_lines="$(build_status_reasons)"

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
Self-update: $self_update_line
Doctor: $DOCTOR_SUMMARY
Restart: $restart_line
Health check: $health_line
Config: $CONFIG_HEALTH
Duration: ${DURATION_SECONDS}s
EOF

  if [[ -n "$status_reason_lines" ]]; then
    printf '\nStatus reasons:\n%s\n' "$status_reason_lines"
  fi

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

  if [[ -n "$COMMITMENTS_SUMMARY" || -n "$SECURITY_AUDIT_SUMMARY" || -n "$PACKAGE_DRIFT_SUMMARY" || -n "$DOCTOR_WARNING_SUMMARY" ]]; then
    printf '\nSanity probes:\n'
    [[ -n "$COMMITMENTS_SUMMARY" ]] && printf -- '- commitments: %s\n' "$COMMITMENTS_SUMMARY"
    [[ -n "$SECURITY_AUDIT_SUMMARY" ]] && printf -- '- security audit: %s\n' "$SECURITY_AUDIT_SUMMARY"
    [[ -n "$PACKAGE_DRIFT_SUMMARY" ]] && printf -- '- package drift: %s\n' "$PACKAGE_DRIFT_SUMMARY"
    [[ -n "$DOCTOR_WARNING_SUMMARY" ]] && printf -- '- doctor warnings: %s\n' "$DOCTOR_WARNING_SUMMARY"
  fi

  if [[ -n "$MODEL_AUTH_SUMMARY" ]]; then
    printf '\nModel auth:\n%s\n' "$MODEL_AUTH_SUMMARY"
  fi

  if [[ -n "$DISK_FINDINGS_SUMMARY" || -n "$CRON_FINDINGS_SUMMARY" || -n "$GATEWAY_LOG_SUMMARY" ]]; then
    printf '\nSanity summaries:\n'
    [[ -n "$DISK_FINDINGS_SUMMARY" ]] && printf -- '- Disk: %s\n' "${DISK_FINDINGS_SUMMARY//$'\n'/; }"
    [[ -n "$CRON_FINDINGS_SUMMARY" ]] && printf -- '- Cron: %s\n' "${CRON_FINDINGS_SUMMARY//$'\n'/; }"
    [[ -n "$GATEWAY_LOG_SUMMARY" ]] && printf -- '- Gateway logs: %s\n' "$GATEWAY_LOG_SUMMARY"
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

  # shellcheck disable=SC2034 # run_capture writes the captured output by nameref; only status is needed here.
  local send_output
  local send_status
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

  maybe_self_update || true

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
  scan_openclaw_package_hotfixes || true
  run_commitments_sanity || true
  run_security_audit_sanity || true
  run_telegram_sanity || true
  run_gateway_log_scan || true
  run_disk_sanity || true
  run_cron_sanity || true

  if should_attempt_update; then
    run_update || true
  fi
  if [[ "$UPDATE_SUCCEEDED" -eq 1 ]]; then
    refresh_gateway_service_after_update || true
  else
    refresh_stale_gateway_service || true
  fi

  run_doctor_phase
  local doctor_pass=0
  while (( doctor_pass < MAX_DOCTOR_REMEDIATION_PASSES )); do
    REMEDIATION_APPLIED=0
    remediate_expected_openclaw_model_config || true
    maybe_auto_archive_orphan_transcripts || true
    maybe_auto_remediate_missing_transcripts || true
    if [[ "$REMEDIATION_APPLIED" -ne 1 ]]; then
      break
    fi
    prepare_doctor_recheck_after_remediation
    run_doctor_phase
    doctor_pass=$((doctor_pass + 1))
  done
  remediate_expected_openclaw_model_config || true

  if [[ "$UPDATE_SUCCEEDED" -eq 1 || "$CONFIG_RESTORED" -eq 1 || "$MODEL_CONFIG_REMEDIATED" -eq 1 ]]; then
    if restart_gateway; then
      record_gateway_restart
      wait_for_gateway_health || true
    fi
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
