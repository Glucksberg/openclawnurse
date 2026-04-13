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

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-}"
OPENCLAW_STATE_HOME="${OPENCLAW_STATE_HOME:-$HOME/.openclaw}"
REPORT_CHANNEL="${REPORT_CHANNEL:-telegram}"
TELEGRAM_TARGET="${TELEGRAM_TARGET:-}"
AUTO_DETECT_TELEGRAM_TARGET="${AUTO_DETECT_TELEGRAM_TARGET:-true}"
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
AUTO_REMEDIATE_ALL_AGENTS="${AUTO_REMEDIATE_ALL_AGENTS:-false}"
RESTART_MODE="${RESTART_MODE:-systemd_user}"
SYSTEMD_UNIT_NAME="${SYSTEMD_UNIT_NAME:-openclaw-gateway.service}"
RESTART_COMMAND="${RESTART_COMMAND:-}"
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
PENDING_TEXT_FILE="${PENDING_TEXT_FILE:-$STATE_DIR/pending-report.txt}"
PENDING_JSON_FILE="${PENDING_JSON_FILE:-$STATE_DIR/pending-report.json}"

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR" "$LOG_DIR"

RUN_ID="$(TZ="$TIMEZONE" date '+%Y%m%d-%H%M%S')"
RUN_DATE="$(TZ="$TIMEZONE" date '+%Y-%m-%d %H:%M:%S %Z')"
RUN_ISO="$(TZ="$TIMEZONE" date --iso-8601=seconds)"
HOST_NAME="$(hostname)"
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
  local -n ref="$name"
  ref+=("$value")
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

  log INFO "$label"
  set +e
  captured_output="$("$@" 2>&1)"
  captured_status=$?
  set -e
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

ERRORS=()
FIXES=()
ACTIONS=()
PREVIOUS_PENDING_PRESENT=0
REMEDIATION_APPLIED=0

load_previous_state() {
  if [[ -f "$STATE_FILE" ]] && jq empty "$STATE_FILE" >/dev/null 2>&1; then
    CONSECUTIVE_FAILURES="$(jq -r '.consecutiveFailures // 0' "$STATE_FILE" 2>/dev/null)"
  fi
  [[ -f "$PENDING_TEXT_FILE" || -f "$PENDING_JSON_FILE" ]] && PREVIOUS_PENDING_PRESENT=1 || PREVIOUS_PENDING_PRESENT=0
}

persist_json() {
  local report_text="$1"
  local report_json_tmp="$RUN_JSON_FILE.tmp"
  local state_json_tmp="$STATE_FILE.tmp"

  jq -n \
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
    --arg reportText "$report_text" \
    --argjson dryRun "$(json_bool "$DRY_RUN")" \
    --argjson updateAttempted "$(json_bool "$UPDATE_ATTEMPTED")" \
    --argjson updateSucceeded "$(json_bool "$UPDATE_SUCCEEDED")" \
    --argjson doctorAttempted "$(json_bool "$DOCTOR_ATTEMPTED")" \
    --argjson restartAttempted "$(json_bool "$RESTART_ATTEMPTED")" \
    --argjson restartSucceeded "$(json_bool "$RESTART_SUCCEEDED")" \
    --argjson gatewayHealthy "$(json_bool "$GATEWAY_HEALTHY")" \
    --argjson notificationDelivered "$(json_bool "$NOTIFICATION_DELIVERED")" \
    --argjson notificationPending "$(json_bool "$NOTIFICATION_PENDING")" \
    --argjson previousPendingPresent "$(json_bool "$PREVIOUS_PENDING_PRESENT")" \
    --argjson doctorExitCode "$DOCTOR_EXIT_CODE" \
    --argjson consecutiveFailures "$CONSECUTIVE_FAILURES" \
    --argjson durationSeconds "$DURATION_SECONDS" \
    --argjson errors "$(printf '%s\n' "${ERRORS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson fixes "$(printf '%s\n' "${FIXES[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson actions "$(printf '%s\n' "${ACTIONS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{
      timestamp: $timestamp,
      hostname: $hostname,
      status: $status,
      currentVersionBefore: $currentVersionBefore,
      currentVersionAfter: $currentVersionAfter,
      availableVersion: $availableVersion,
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
    }' >"$report_json_tmp"

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
  [[ "$REPORT_CHANNEL" == "telegram" && -z "$TELEGRAM_TARGET" ]] && return 0
  [[ -f "$PENDING_TEXT_FILE" ]] || return 0

  local pending_text
  pending_text="$(cat "$PENDING_TEXT_FILE")"
  pending_text="$(trim_report "$pending_text")"

  local send_output send_status
  local cmd
  build_openclaw_cmd cmd
  cmd+=(message send --channel "$REPORT_CHANNEL" --target "$TELEGRAM_TARGET" --message "$pending_text" --json)
  run_capture send_output send_status "Retrying pending notification" \
    "${cmd[@]}"

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
  build_openclaw_cmd health_cmd
  health_cmd+=(health --json --timeout "$HEALTH_TIMEOUT_MS")
  run_capture health_output health_status "Self-test health check" "${health_cmd[@]}"

  if [[ "$health_status" -ne 0 ]] || ! printf '%s' "$health_output" | jq -e '.ok == true' >/dev/null 2>&1; then
    printf 'SELF_TEST=FAILED\n'
    printf 'Reason: health check failed\n'
    return 1
  fi

  if [[ "$NO_NOTIFY" -eq 0 && -n "$TELEGRAM_TARGET" ]]; then
    local send_output send_status
    local send_cmd
    build_openclaw_cmd send_cmd
    send_cmd+=(message send --channel "$REPORT_CHANNEL" --target "$TELEGRAM_TARGET" --message "OpenClawNurse self-test" --dry-run --json)
    run_capture send_output send_status "Self-test notification dry-run" "${send_cmd[@]}"
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
    DOCTOR_CLASSIFICATION="needs_manual_attention"
    DOCTOR_SUMMARY="doctor exited with code $exit_code"
    append_array ACTIONS "Inspect the doctor output and run manual remediation."
    return
  fi

  if printf '%s' "$lowered" | grep -Eq 'missing transcripts|needs manual attention|lasterror|errors:[[:space:]]*[1-9]|warnings:[[:space:]]*[1-9]|failed|unhealthy|orphan|corrupt|broken'; then
    DOCTOR_CLASSIFICATION="needs_manual_attention"
    DOCTOR_SUMMARY="doctor found issues that still require intervention"
    append_array ACTIONS "Review the doctor recommendations that remain unresolved."
    return
  fi

  if printf '%s' "$lowered" | grep -Eq 'synced|repaired|fixed|migrated|normalized|generated and configured'; then
    DOCTOR_CLASSIFICATION="repaired"
    DOCTOR_SUMMARY="doctor applied at least one corrective action"
    append_array FIXES "Doctor reported corrective actions during the run."
    return
  fi

  if printf '%s' "$lowered" | grep -Eq 'no channel security warnings detected|doctor complete'; then
    DOCTOR_CLASSIFICATION="healthy"
    DOCTOR_SUMMARY="doctor completed without actionable findings"
    return
  fi

  DOCTOR_CLASSIFICATION="healthy"
  DOCTOR_SUMMARY="doctor did not report actionable problems"
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

  local preview_output preview_status missing_count would_mutate
  run_sessions_cleanup_preview preview_output preview_status
  if [[ "$preview_status" -ne 0 ]]; then
    append_array ERRORS "Unable to preview missing transcript cleanup."
    append_array ACTIONS "Run openclaw sessions cleanup --dry-run --fix-missing manually."
    return 1
  fi

  if ! printf '%s' "$preview_output" | jq empty >/dev/null 2>&1; then
    append_array ERRORS "Cleanup preview returned invalid JSON."
    return 1
  fi

  missing_count="$(printf '%s' "$preview_output" | jq -r '.missing // 0')"
  would_mutate="$(printf '%s' "$preview_output" | jq -r '.wouldMutate // false')"

  if [[ "$missing_count" == "0" || "$would_mutate" != "true" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    append_array FIXES "Dry-run: would prune $missing_count session entries with missing transcripts."
    append_array ACTIONS "Run without --dry-run to auto-prune session entries with missing transcripts."
    return 0
  fi

  local apply_output apply_status after_count
  run_sessions_cleanup_apply apply_output apply_status
  if [[ "$apply_status" -ne 0 ]]; then
    append_array ERRORS "Automatic cleanup of missing transcripts failed."
    append_array ACTIONS "Run openclaw sessions cleanup --enforce --fix-missing manually."
    return 1
  fi

  if printf '%s' "$apply_output" | jq empty >/dev/null 2>&1; then
    after_count="$(printf '%s' "$apply_output" | jq -r '.afterCount // empty')"
  else
    after_count=""
  fi

  REMEDIATION_APPLIED=1
  append_array FIXES "Pruned $missing_count session entries with missing transcripts${after_count:+; remaining entries: $after_count}."
  return 0
}

run_preflight_checks() {
  local missing=0
  local required=(jq flock timeout "$OPENCLAW_BIN")
  local cmd

  if [[ "$RESTART_MODE" == "systemd_user" ]]; then
    required+=(systemctl)
  fi

  for cmd in "${required[@]}"; do
    if ! command_exists "$cmd"; then
      append_array ERRORS "Missing required command: $cmd"
      missing=1
    fi
  done

  detect_telegram_target

  if [[ "$NO_NOTIFY" -eq 0 && "$REPORT_CHANNEL" == "telegram" && -z "$TELEGRAM_TARGET" ]]; then
    append_array ERRORS "TELEGRAM_TARGET is not configured."
    missing=1
  fi

  return "$missing"
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
  AVAILABLE_VERSION="$(printf '%s' "$output" | jq -r '.availability.latestVersion // .update.registry.latestVersion // empty')"
  CHANNEL_VALUE="$(printf '%s' "$output" | jq -r '.channel.value // empty')"
  return 0
}

should_attempt_update() {
  [[ "$AUTO_UPDATE" == "true" ]] || return 1
  [[ -n "$AVAILABLE_VERSION" ]] || return 1
  [[ "$CURRENT_VERSION_BEFORE" != "$AVAILABLE_VERSION" ]] || return 1
  (( CONSECUTIVE_FAILURES < MAX_CONSECUTIVE_UPDATE_FAILURES )) || return 1
  return 0
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
  run_capture output status "Applying update" "${cmd[@]}"
  UPDATE_OUTPUT="$output"

  if [[ "$status" -eq 0 ]]; then
    UPDATE_SUCCEEDED=1
    CONSECUTIVE_FAILURES=0
    CURRENT_VERSION_AFTER="$AVAILABLE_VERSION"
    append_array FIXES "OpenClaw update completed successfully."
    return 0
  fi

  UPDATE_ERROR="$output"
  append_array ERRORS "OpenClaw update failed on the first attempt."

  local doctor_repair_output doctor_repair_status
  local repair_cmd
  build_openclaw_cmd repair_cmd
  repair_cmd+=(doctor --repair --non-interactive)
  run_capture doctor_repair_output doctor_repair_status "Running doctor repair before retry" \
    "${repair_cmd[@]}"

  if [[ "$doctor_repair_status" -eq 0 ]]; then
    append_array FIXES "Doctor repair completed before the update retry."
  fi

  run_capture output status "Retrying update after repair" "${cmd[@]}"
  UPDATE_OUTPUT="${UPDATE_OUTPUT}"$'\n\n--- retry ---\n'"${output}"

  if [[ "$status" -eq 0 ]]; then
    UPDATE_SUCCEEDED=1
    CONSECUTIVE_FAILURES=0
    CURRENT_VERSION_AFTER="$AVAILABLE_VERSION"
    append_array FIXES "OpenClaw update succeeded on the retry."
    return 0
  fi

  UPDATE_ERROR="$output"
  CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
  append_array ERRORS "OpenClaw update failed after a single retry."
  append_array ACTIONS "Run openclaw update manually after reviewing the error output."
  return 1
}

run_doctor_phase() {
  DOCTOR_ATTEMPTED=1
  local output status

  if [[ "$DRY_RUN" -eq 1 ]]; then
    local cmd
    build_openclaw_cmd cmd
    cmd+=(doctor --non-interactive)
    run_capture output status "Running doctor in dry-run mode" \
      timeout "${DOCTOR_TIMEOUT}s" "${cmd[@]}"
  else
    local cmd
    build_openclaw_cmd cmd
    cmd+=(doctor --repair --non-interactive)
    run_capture output status "Running doctor repair" \
      timeout "${DOCTOR_TIMEOUT}s" "${cmd[@]}"
  fi

  DOCTOR_OUTPUT="$output"
  DOCTOR_EXIT_CODE="$status"
  classify_doctor "$output" "$status"
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
  build_openclaw_cmd cmd
  cmd+=(health --json --timeout "$HEALTH_TIMEOUT_MS")

  while (( $(date +%s) <= deadline )); do
    run_capture output status "Checking gateway health" \
      "${cmd[@]}"
    HEALTH_OUTPUT="$output"

    if [[ "$status" -eq 0 ]] && printf '%s' "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
      GATEWAY_HEALTHY=1
      return 0
    fi

    sleep "$GATEWAY_WAIT_INTERVAL"
  done

  HEALTH_ERROR="$HEALTH_OUTPUT"
  append_array ERRORS "Gateway health check did not become healthy within the timeout."
  return 1
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
Duration: ${DURATION_SECONDS}s
EOF

  if [[ -n "$summary_lines" ]]; then
    printf '\nDoctor highlights:\n%s\n' "$summary_lines"
  fi

  if ((${#FIXES[@]} > 0)); then
    printf '\nActions applied:\n'
    printf -- '- %s\n' "${FIXES[@]}"
  fi

  if ((${#ERRORS[@]} > 0)); then
    printf '\nErrors:\n'
    printf -- '- %s\n' "${ERRORS[@]}"
  fi

  if ((${#ACTIONS[@]} > 0)); then
    printf '\nManual follow-up:\n'
    printf -- '- %s\n' "${ACTIONS[@]}"
  fi
}

deliver_report() {
  local report_text="$1"
  [[ "$NO_NOTIFY" -eq 1 ]] && return 0

  if [[ "$REPORT_CHANNEL" == "telegram" && -z "$TELEGRAM_TARGET" ]]; then
    append_array ERRORS "Notification skipped because TELEGRAM_TARGET is empty."
    NOTIFICATION_PENDING=1
    return 1
  fi

  if [[ "$RETRY_NOTIFICATION_ON_NEXT_RUN" == "true" ]]; then
    retry_pending_report
  fi

  local send_output send_status
  local trimmed
  trimmed="$(trim_report "$report_text")"
  local cmd
  build_openclaw_cmd cmd
  cmd+=(message send --channel "$REPORT_CHANNEL" --target "$TELEGRAM_TARGET" --message "$trimmed" --json)

  run_capture send_output send_status "Delivering report" \
    "${cmd[@]}"

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

  if ((${#ERRORS[@]} > 0)); then
    STATUS="FAILED"
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
    persist_json "$preflight_report"
    persist_pending_report "$preflight_report"
    exit 1
  fi

  run_update_status || true

  if should_attempt_update; then
    run_update || true
  fi

  run_doctor_phase
  maybe_auto_remediate_missing_transcripts || true
  if [[ "$REMEDIATION_APPLIED" -eq 1 ]]; then
    run_doctor_phase
  fi

  if [[ "$UPDATE_SUCCEEDED" -eq 1 ]]; then
    restart_gateway || true
    wait_for_gateway_health || true
  else
    local health_output health_status
    local cmd
    build_openclaw_cmd cmd
    cmd+=(health --json --timeout "$HEALTH_TIMEOUT_MS")
    run_capture health_output health_status "Checking gateway health without restart" \
      "${cmd[@]}"
    HEALTH_OUTPUT="$health_output"
    if [[ "$health_status" -eq 0 ]] && printf '%s' "$health_output" | jq -e '.ok == true' >/dev/null 2>&1; then
      GATEWAY_HEALTHY=1
    fi
  fi

  finalize_status

  DURATION_SECONDS=$(( $(date +%s) - start_epoch ))
  local report_text
  report_text="$(build_report)"
  persist_json "$report_text"

  if ! deliver_report "$report_text"; then
    finalize_status
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
