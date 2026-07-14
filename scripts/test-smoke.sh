#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
JQ_BIN="${JQ_BIN:-$(command -v jq 2>/dev/null || printf jq)}"
SMOKE_TMP_ROOT="$(mktemp -d)"

# Keep smoke runs hermetic even when they are launched by a live Nurse process
# during self-update validation.
unset CONFIG_DIR DATA_DIR STATE_DIR LOG_DIR LOCK_FILE STATE_FILE
unset GATEWAY_RESTART_STATE_FILE PENDING_TEXT_FILE PENDING_JSON_FILE
unset CONFIG_BACKUP_DIR ORPHAN_TRANSCRIPT_ARCHIVE_DIR
unset OPENCLAW_CONFIG_FILE OPENCLAW_STATE_HOME
unset TELEGRAM_BOT_TOKEN OPENCLAW_GATEWAY_TOKEN OPENCLAW_SERVICE_KIND
unset OPENCLAW_SERVICE_MARKER OPENCLAW_SERVICE_VERSION OPENCLAW_SYSTEMD_UNIT
unset OPENCLAW_GATEWAY_SERVICE_PID

cleanup_smoke_tmp() {
  local pids
  pids="$(
    ps -eo pid=,cmd= |
      awk -v root="$SMOKE_TMP_ROOT" 'index($0, "PM2 v") && index($0, root) { print $1 }'
  )"
  if [[ -n "$pids" ]]; then
    printf '%s\n' "$pids" | xargs -r kill 2>/dev/null || true
    sleep 1
    pids="$(
      ps -eo pid=,cmd= |
        awk -v root="$SMOKE_TMP_ROOT" 'index($0, "PM2 v") && index($0, root) { print $1 }'
    )"
    [[ -z "$pids" ]] || printf '%s\n' "$pids" | xargs -r kill -9 2>/dev/null || true
  fi
  rm -rf "$SMOKE_TMP_ROOT"
}

terminate_smoke_tmp() {
  cleanup_smoke_tmp
  trap - EXIT HUP INT TERM
  exit 124
}

trap cleanup_smoke_tmp EXIT
trap terminate_smoke_tmp HUP INT TERM
export RUN_PROFILE=heavy
# Most legacy smoke fixtures use standalone fake CLIs without a package root or
# registry metadata. Runtime-selection tests opt in explicitly below.
export AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE=false

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

pass() {
  printf '[smoke] ok: %s\n' "$*"
}

fail() {
  printf '[smoke] failed: %s\n' "$*" >&2
  exit 1
}

make_fake_openclaw() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash

if [[ "${1:-}" == "--profile" ]]; then
  shift 2
fi

case "${1:-}" in
  --version)
    printf 'OpenClaw 2026.1.0\n'
    ;;
  update)
    case "${2:-}" in
      status)
        printf '{"availability":{"available":true,"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  message)
    printf 'send failed\n' >&2
    exit 42
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$path"
}

make_fake_node_runtime() {
  local root="$1"
  local version="$2"
  local engine_status="$3"
  mkdir -p "$root/bin" "$root/lib/node_modules/npm/node_modules/semver"
  printf '{"name":"semver"}\n' >"$root/lib/node_modules/npm/node_modules/semver/package.json"
  cat >"$root/bin/node" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  printf 'v%s\\n' "$version"
  exit 0
fi
if [[ "\${1:-}" == "-e" ]]; then
  if [[ "$engine_status" == "broad-only" ]]; then
    [[ "\${4:-}" == ">=22" ]] && exit 0
    exit 1
  fi
  exit $engine_status
fi
export FAKE_NODE_VERSION="$version"
exec "\$@"
EOF
  chmod +x "$root/bin/node"
}

make_hanging_node_runtime() {
  local root="$1"
  mkdir -p "$root/bin"
  cat >"$root/bin/node" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
while true; do
  sleep 1
done
EOF
  chmod +x "$root/bin/node"
}

smoke_doctor_without_complete_config() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/doctor-defaults.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/home"
  make_fake_openclaw "$tmp/bin/openclaw"

  HOME="$tmp/home" \
    OPENCLAW_BIN="$tmp/bin/openclaw" \
    ENABLE_RUNTIME_SANITY="false" \
    ENABLE_TELEGRAM_SANITY="false" \
    ENABLE_GATEWAY_LOG_SCAN="false" \
    "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/missing.env" --no-notify --dry-run >/dev/null

  [[ -f "$tmp/home/.local/state/openclawnurse/doctor-state.json" ]] || fail "doctor did not write default state"
  "$JQ_BIN" -e '.status == "OK"' "$tmp/home/.local/state/openclawnurse/doctor-state.json" >/dev/null ||
    fail "doctor did not complete with default dirs"

  pass "doctor handles missing config/default dirs"
}

smoke_pending_report_after_notification_failure() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/pending-report.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
STATE_DIR="$tmp/state"
TELEGRAM_TARGET="chat"
TELEGRAM_BOT_TOKEN="fake-token"
TELEGRAM_API_BASE_URL="http://127.0.0.1:9"
REPORT_CHANNEL="telegram"
CONFIG_BACKUP_ENABLED="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" >/dev/null

  "$JQ_BIN" -e '.status == "FAILED_NOTIFICATION_PENDING" and .notificationPending == true' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "pending notification status was not persisted"

  grep -Fq 'Status: FAILED_NOTIFICATION_PENDING' "$tmp/state/pending-report.txt" ||
    fail "pending report text has stale status"
  grep -Fq 'Report delivery failed.' "$tmp/state/pending-report.txt" ||
    fail "pending report text is missing delivery error"

  pass "pending report is rebuilt after notification failure"
}

smoke_report_channel_none_skips_delivery() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/report-none.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
CONFIG_BACKUP_ENABLED="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" >/dev/null

  "$JQ_BIN" -e '.status == "OK" and .notificationPending == false and .notificationDelivered == false' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "REPORT_CHANNEL=none did not skip direct notification cleanly"
  [[ ! -e "$tmp/state/pending-report.txt" ]] ||
    fail "REPORT_CHANNEL=none left a pending report"

  pass "report channel none skips direct notification"
}

smoke_light_profile_skips_heavy_maintenance() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/light-profile.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  cat >"$tmp/bin/openclaw" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --version)
    printf 'OpenClaw 2026.1.0\n'
    ;;
  update)
    if [[ "\${2:-}" == "status" ]]; then
      printf '{"availability":{"available":false,"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
    else
      printf '{"ok":true}\n'
    fi
    ;;
  doctor|security)
    printf 'heavy command should not run in light profile\n' >>"$tmp/heavy-called"
    exit 99
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
RUN_PROFILE="light"
AUTO_UPDATE="false"
ENABLE_SECURITY_AUDIT="true"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
EOF

  RUN_PROFILE=light HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ ! -f "$tmp/heavy-called" ]] || fail "light profile ran doctor/security audit"
  "$JQ_BIN" -e '
    .status == "OK"
    and .runProfile == "light"
    and .doctorAttempted == false
    and .doctorSummary == "skipped in light profile"
    and .sanity.securityAuditSummary == "skipped in light profile"
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "light profile did not persist a clean lightweight run"

  pass "light profile skips heavy maintenance"
}

smoke_missing_telegram_token_does_not_block_maintenance() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/missing-token.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
TELEGRAM_TARGET="chat"
REPORT_CHANNEL="telegram"
AUTO_UPDATE="false"
CONFIG_BACKUP_ENABLED="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" >/dev/null

  "$JQ_BIN" -e '
    .status == "FAILED_NOTIFICATION_PENDING"
    and .doctorAttempted == true
    and .notificationPending == true
    and (.errors[] | contains("TELEGRAM_BOT_TOKEN"))
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "missing Telegram token blocked maintenance instead of only notification"

  pass "missing Telegram token does not block maintenance"
}

smoke_self_test_uses_openclaw_telegram_token() {
  local tmp output
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/selftest-openclaw-token.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"channels":{"telegram":{"botToken":"fake-token"}}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
TELEGRAM_TARGET="chat"
REPORT_CHANNEL="telegram"
AUTO_UPDATE="false"
CONFIG_BACKUP_ENABLED="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
EOF

  output="$(HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --self-test)"

  printf '%s\n' "$output" | grep -Fq 'SELF_TEST=OK' ||
    fail "self-test did not use OpenClaw Telegram token"
  printf '%s\n' "$output" | grep -Fq 'Notification dry-run: ok (chat)' ||
    fail "self-test notification dry-run did not succeed with OpenClaw Telegram token"

  pass "self-test uses OpenClaw Telegram token when nurse token is empty"
}

smoke_sanity_overrides_updated_status() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/sanity-status.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  cat >"$tmp/bin/openclaw" <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in
  --version)
    printf 'OpenClaw 2026.0.9\n'
    ;;
  update)
    case "${2:-}" in
      status)
        printf '{"availability":{"available":true,"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/bin/stale-openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'OpenClaw 2026.0.8\n'
EOF
  chmod +x "$tmp/bin/stale-openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
OPENCLAW_EXTRA_SCAN_PATHS="$tmp/bin/stale-openclaw"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '.status == "DEGRADED" and .updateAttempted == true and .updateSucceeded == true and .sanity.degraded == true' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "sanity degraded status did not override successful update status"

  pass "sanity findings override successful update status"
}

smoke_telegram_sanity_uses_implicit_bot_token() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/telegram-implicit.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"channels":{"telegram":{"botToken":"fake-token"}}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="true"
ENABLE_GATEWAY_LOG_SCAN="false"
TELEGRAM_API_BASE_URL="http://127.0.0.1:9"
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify --dry-run >/dev/null

  "$JQ_BIN" -e '.sanity.telegramCommands == "getMyCommands failed" and (.sanity.findings[] | contains("Telegram getMyCommands failed"))' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "telegram sanity did not run when bot token was present without enabled=true"

  pass "telegram sanity runs for implicit bot token configs"
}

smoke_telegram_sanity_resolves_env_bot_token_from_systemd() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/telegram-envref.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "show" && "${4:-}" == "-p" && "${5:-}" == "Environment" && "${6:-}" == "--value" ]]; then
  printf 'TELEGRAM_BOT_TOKEN=fake-token OPENCLAW_GATEWAY_TOKEN=fake-gateway-token\n'
fi
exit 0
EOF
  chmod +x "$tmp/bin/systemctl"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"channels":{"telegram":{"enabled":true,"botToken":{"source":"env","provider":"default","id":"TELEGRAM_BOT_TOKEN"}}}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
SYSTEMCTL_BIN="$tmp/bin/systemctl"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="true"
ENABLE_GATEWAY_LOG_SCAN="false"
TELEGRAM_API_BASE_URL="http://127.0.0.1:9"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify --dry-run >/dev/null

  "$JQ_BIN" -e '
    .sanity.telegramCommands == "getMyCommands failed"
    and (.sanity.findings[] | contains("Telegram getMyCommands failed"))
    and all(.actions[]?; contains("Configure the OpenClaw Telegram bot token") | not)
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "telegram sanity did not resolve env bot token from systemd service"

  pass "telegram sanity resolves env bot tokens from systemd"
}

smoke_disabled_high_frequency_cron_is_ignored() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/cron-disabled.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw/cron"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/cron/jobs.json" <<'EOF'
{"jobs":[{"id":"disabled-fast","name":"disabled fast isolated","enabled":false,"sessionTarget":"isolated","schedule":{"everyMs":30000}}]}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="true"
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '.status == "OK" and .sanity.cronSummary == "" and (.incidentCodes | index("high_frequency_isolated_cron") | not)' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "disabled high-frequency cron job was treated as enabled"

  pass "disabled high-frequency cron jobs are ignored"
}

smoke_array_cron_jobs_are_supported() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/cron-array.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw/cron"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/cron/jobs.json" <<'EOF'
[{"id":"fast","name":"fast isolated","enabled":true,"sessionTarget":"isolated","schedule":{"everyMs":30000}}]
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="true"
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '.sanity.cronSummary | contains("fast fast isolated every=30s")' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "array-form cron jobs were not inspected"

  pass "array-form cron jobs are supported"
}

smoke_model_auth_notice_does_not_degrade() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/model-auth.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/bin/openclaw-auth-warning" <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in
  --version)
    printf 'OpenClaw 2026.1.0\n'
    ;;
  update)
    printf '{"availability":{"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
    ;;
  doctor)
    printf 'Model auth\n'
    printf 'openai-codex:default: expired (0m)\n'
    printf 'Warnings: 1\n'
    printf 'Doctor complete.\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw-auth-warning"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw-auth-warning"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '.status == "OK" and (.incidentCodes | index("model_auth_expired")) and (.actions[] | contains("Refresh the expired model auth profile"))' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "model auth notice degraded an otherwise healthy run"

  pass "model auth notice does not degrade healthy runs"
}

smoke_commitments_trace_model_access_is_reported() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/commitments.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw/commitments/extractor-sessions/main/run"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"commitments":{"enabled":true,"maxPerDay":2},"agents":{"defaults":{"model":{"primary":"openai-codex/gpt-5.5"}}}}
EOF
  cat >"$tmp/home/.openclaw/commitments/extractor-sessions/main/run/trace.json" <<'EOF'
{"provider":"openai","modelId":"gpt-5.5","errorMessage":"Project does not have access to model openai/gpt-5.5"}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_COMMITMENTS_SANITY="true"
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify --dry-run >/dev/null

  "$JQ_BIN" -e '.status == "DEGRADED" and any(.incidentCodes[]; . == "commitments_extractor_model_access") and .sanity.modelAccessErrorCount >= 1' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "commitments model access trace was not reported"

  pass "commitments trace model access errors are reported"
}

smoke_commitments_successful_traces_do_not_degrade() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/commitments-success.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw/commitments/extractor-sessions/main"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"commitments":{"enabled":true,"maxPerDay":2},"agents":{"defaults":{"model":{"primary":"openai/gpt-5.5"}}}}
EOF
  cat >"$tmp/home/.openclaw/commitments/extractor-sessions/main/success.trajectory.jsonl" <<'EOF'
{"traceSchema":"openclaw-trajectory","type":"session.started","ts":"2026-01-01T00:00:00Z","provider":"openai-codex","modelId":"gpt-5.5","data":{"status":""}}
{"traceSchema":"openclaw-trajectory","type":"model.completed","ts":"2026-01-01T00:00:01Z","provider":"openai-codex","modelId":"gpt-5.5","data":{"timedOut":false,"aborted":false,"promptError":null,"assistantTexts":["{\"candidates\":[],\"note\":\"user mentioned error 226\"}"]}}
{"traceSchema":"openclaw-trajectory","type":"session.ended","ts":"2026-01-01T00:00:02Z","provider":"openai-codex","modelId":"gpt-5.5","data":{"status":"success","promptError":null}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_COMMITMENTS_SANITY="true"
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify --dry-run >/dev/null

  "$JQ_BIN" -e '
    .status == "OK"
    and .sanity.commitmentsErrorCount == 0
    and .sanity.modelAccessErrorCount == 0
    and (.incidentCodes | index("commitments_extractor_failed") | not)
    and (.incidentCodes | index("commitments_extractor_model_mismatch") | not)
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "successful commitments traces degraded the run"

  pass "successful commitments traces do not degrade sanity"
}

smoke_security_audit_critical_is_reported() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/security.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  cat >"$tmp/bin/openclaw" <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in
  --version)
    printf 'OpenClaw 2026.1.0\n'
    ;;
  update)
    printf '{"availability":{"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  security)
    printf '{"findings":[{"severity":"critical","checkId":"security.exposure.open_groups_with_runtime_or_fs","title":"unsafe"}],"summary":{"critical":1,"warn":0,"info":0}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="true"
RUN_PROFILE="heavy"
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify --dry-run >/dev/null

  "$JQ_BIN" -e '.status == "FAILED" and any(.incidentCodes[]; . == "security_audit_critical") and .sanity.securityAuditCriticalCount == 1' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "security audit critical finding was not reported"

  pass "security audit critical findings are reported"
}

smoke_security_audit_json_with_stderr_preamble_is_accepted() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/security-preamble.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  cat >"$tmp/bin/openclaw" <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in
  --version)
    printf 'OpenClaw 2026.1.0\n'
    ;;
  update)
    printf '{"availability":{"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  security)
    printf '[state-migrations] Legacy state migration warnings:\n' >&2
    printf '{"findings":[{"severity":"warn","checkId":"plugins.installs_unpinned_npm_specs","title":"unpinned"}],"summary":{"critical":0,"warn":1,"info":0}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="true"
RUN_PROFILE="heavy"
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify --dry-run >/dev/null

  "$JQ_BIN" -e '
    .status == "DEGRADED"
    and (.incidentCodes | index("security_audit_failed") | not)
    and any(.incidentCodes[]; . == "security_audit_warn")
    and .sanity.securityAuditWarnCount == 1
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "security audit JSON with stderr preamble was not accepted"

  pass "security audit JSON with stderr preamble is accepted"
}

smoke_telegram_commands_are_remediated() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/telegram-commands.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
payload=""
url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -d)
      payload="\${2:-}"
      shift 2
      ;;
    http*)
      url="\$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "\$url" == *getMyCommands ]]; then
  if [[ -f "$tmp/commands-set" ]]; then
    printf '{"ok":true,"result":[{"command":"new","description":"Start a new OpenClaw conversation"},{"command":"reset","description":"Reset the current OpenClaw conversation"}]}\n'
  else
    printf '{"ok":true,"result":[]}\n'
  fi
  exit 0
fi

if [[ "\$url" == *setMyCommands ]]; then
  printf '%s\n' "\$payload" >"$tmp/set-payload.json"
  touch "$tmp/commands-set"
  printf '{"ok":true,"result":true}\n'
  exit 0
fi

printf '{"ok":false}\n'
exit 1
EOF
  chmod +x "$tmp/bin/curl"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"channels":{"telegram":{"botToken":"fake-token"}}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="true"
ENABLE_GATEWAY_LOG_SCAN="false"
TELEGRAM_API_BASE_URL="http://telegram.test"
CONFIG_BACKUP_ENABLED="false"
EOF

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .status == "OK"
    and (.sanity.findings | length) == 0
    and any(.fixes[]; contains("Registered Telegram native commands"))
    and any(.remediations[]; .code == "telegram_native_commands" and .result == "applied")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "telegram native commands were not remediated"
  # shellcheck disable=SC2016 # jq expression is intentionally single-quoted.
  "$JQ_BIN" -e '[.commands[].command] as $commands | ($commands | index("new")) and ($commands | index("reset"))' \
    "$tmp/set-payload.json" >/dev/null ||
    fail "setMyCommands payload did not include required commands"

  pass "telegram native commands are remediated"
}

smoke_config_version_drift_forces_update() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/config-version-drift.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  printf '2026.0.9\n' >"$tmp/version"
  cat >"$tmp/bin/openclaw" <<EOF
#!/usr/bin/env bash

if [[ "\${1:-}" == "--version" ]]; then
  printf 'OpenClaw %s\n' "\$(cat "$tmp/version")"
  exit 0
fi

case "\${1:-}" in
  update)
    case "\${2:-}" in
      status)
        printf '{"availability":{"available":false,"latestVersion":null},"update":{"registry":{"latestVersion":"2026.1.0"}},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf '2026.1.0\n' >"$tmp/version"
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"meta":{"lastTouchedVersion":"2026.1.0"},"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .status == "UPDATED"
    and .updateAttempted == true
    and .updateSucceeded == true
    and .updateAvailable == false
    and .config.lastTouchedVersion == "2026.1.0"
    and .config.versionDrift == false
    and (.sanity.findings | length) == 0
    and any(.remediations[]; .code == "openclaw_config_version_drift" and .result == "applied")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "config version drift did not force and clear update remediation"

  pass "config version drift forces update and clears after remediation"
}

smoke_config_version_drift_update_failure_is_failed() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/config-version-drift-failure.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  cat >"$tmp/bin/openclaw" <<'EOF'
#!/usr/bin/env bash

if [[ "${1:-}" == "--version" ]]; then
  printf 'OpenClaw 2026.0.9\n'
  exit 0
fi

case "${1:-}" in
  update)
    case "${2:-}" in
      status)
        printf '{"availability":{"available":false,"latestVersion":null},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf 'update failed\n' >&2
        exit 42
        ;;
    esac
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"meta":{"lastTouchedVersion":"2026.1.0"}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .status == "FAILED"
    and .updateAttempted == true
    and .updateSucceeded == false
    and .config.versionDrift == true
    and (.errors | length) > 0
    and any(.incidentCodes[]; . == "openclaw_config_version_drift")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "config version drift update failure did not fail the run"

  pass "config version drift update failure is failed"
}

smoke_openclaw_user_plugin_drift_is_remediated() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/plugin-drift.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw/npm/node_modules/@openclaw/codex"
  cat >"$tmp/bin/openclaw" <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in
  --version)
    printf 'OpenClaw 2026.1.0\n'
    ;;
  update)
    if [[ "${2:-}" == "status" ]]; then
      printf '{"availability":{"available":false,"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
    else
      printf '{"ok":true}\n'
    fi
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/bin/npm" <<EOF
#!/usr/bin/env bash
prefix=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --prefix)
      prefix="\${2:-}"
      shift 2
      ;;
    install|--save-exact)
      shift
      ;;
    @openclaw/*@*|openclaw@*)
      spec="\$1"
      pkg="\${spec%@*}"
      version="\${spec##*@}"
      mkdir -p "\$prefix/node_modules/\$pkg"
      printf '{"name":"%s","version":"%s"}\n' "\$pkg" "\$version" >"\$prefix/node_modules/\$pkg/package.json"
      "$JQ_BIN" --arg pkg "\$pkg" --arg version "\$version" '.dependencies[\$pkg] = \$version' "\$prefix/package.json" >"\$prefix/package.json.tmp"
      mv "\$prefix/package.json.tmp" "\$prefix/package.json"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
printf 'fake npm ok\n'
EOF
  chmod +x "$tmp/bin/npm"
  cat >"$tmp/home/.openclaw/npm/package.json" <<'EOF'
{"dependencies":{"@openclaw/codex":"2026.0.9"}}
EOF
  cat >"$tmp/home/.openclaw/npm/node_modules/@openclaw/codex/package.json" <<'EOF'
{"name":"@openclaw/codex","version":"2026.0.9","peerDependencies":{"openclaw":">=2026.0.9"}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="true"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .status == "OK"
    and .restartAttempted == true
    and .sanity.openclawUserPluginDriftCount == 0
    and .sanity.openclawUserPluginAlignAttempted == true
    and .sanity.openclawUserPluginAlignSucceeded == true
    and (.sanity.openclawUserPluginsSummary | contains("@openclaw/codex=2026.1.0"))
    and (.sanity.openclawUserPluginsSummary | contains("openclaw=2026.1.0"))
    and any(.remediations[]; .code == "openclaw_user_plugin_drift" and .result == "applied")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "OpenClaw user plugin drift was not remediated"

  "$JQ_BIN" -e '.version == "2026.1.0"' "$tmp/home/.openclaw/npm/node_modules/@openclaw/codex/package.json" >/dev/null ||
    fail "plugin package was not aligned"
  "$JQ_BIN" -e '.version == "2026.1.0"' "$tmp/home/.openclaw/npm/node_modules/openclaw/package.json" >/dev/null ||
    fail "openclaw peer package was not aligned"

  pass "OpenClaw user plugin drift is remediated"
}

smoke_model_config_drift_after_doctor_is_remediated() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/model-config-drift.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{
  "auth": {
    "profiles": {
      "openai-codex:test@example.com": {
        "provider": "openai-codex",
        "mode": "oauth"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openai-codex/gpt-5.5",
        "fallbacks": [
          "claude-cli/claude-opus-4-6"
        ]
      },
      "models": {
        "claude-cli/claude-opus-4-6": {
          "alias": "opus"
        },
        "openai-codex/gpt-5.5": {}
      },
      "agentRuntime": {
        "id": "pi"
      }
    }
  },
  "gateway": {
    "port": 18789
  }
}
EOF
  cat >"$tmp/bin/openclaw" <<EOF
#!/usr/bin/env bash
cfg="$tmp/home/.openclaw/openclaw.json"

if [[ "\${1:-}" == "--version" ]]; then
  printf 'OpenClaw 2026.1.0\n'
  exit 0
fi

case "\${1:-}" in
  update)
    case "\${2:-}" in
      status)
        printf '{"availability":{"available":false,"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  doctor)
    tmp_cfg="\$cfg.tmp"
    jq '.agents.defaults.model.primary = "openai/gpt-5.5"
      | .agents.defaults.models = {
          "claude-cli/claude-opus-4-6": {"alias":"opus"},
          "openai/gpt-5.4": {},
          "openai/gpt-5.5": {}
        }
      | .agents.defaults.agentRuntime = {"id":"pi"}' "\$cfg" >"\$tmp_cfg"
    mv "\$tmp_cfg" "\$cfg"
    printf 'doctor complete\n'
    ;;
  config)
    case "\${2:-}" in
      set)
        path="\${3:-}"
        value="\${4:-}"
        tmp_cfg="\$cfg.tmp"
        case "\$path" in
          agents.defaults.model.primary)
            jq --arg value "\$value" '.agents.defaults.model.primary = \$value' "\$cfg" >"\$tmp_cfg"
            ;;
          agents.defaults.models)
            jq --argjson value "\$value" '.agents.defaults.models = \$value' "\$cfg" >"\$tmp_cfg"
            ;;
          *)
            printf 'unsupported config set path: %s\n' "\$path" >&2
            exit 2
            ;;
        esac
        mv "\$tmp_cfg" "\$cfg"
        printf '{"ok":true}\n'
        ;;
      unset)
        path="\${3:-}"
        tmp_cfg="\$cfg.tmp"
        case "\$path" in
          agents.defaults.agentRuntime)
            jq 'del(.agents.defaults.agentRuntime)' "\$cfg" >"\$tmp_cfg"
            ;;
          *)
            printf 'unsupported config unset path: %s\n' "\$path" >&2
            exit 2
            ;;
        esac
        mv "\$tmp_cfg" "\$cfg"
        printf '{"ok":true}\n'
        ;;
      *)
        printf '{}\n'
        ;;
    esac
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
OPENCLAW_CONFIG_FILE="$tmp/home/.openclaw/openclaw.json"
OPENAI_API_KEY=""
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
AUTO_REMEDIATE_MISSING_TRANSCRIPTS="false"
AUTO_REMEDIATE_ORPHAN_TRANSCRIPTS="false"
RESTART_MODE="custom"
RESTART_COMMAND="printf restarted >> '$tmp/restarts'"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .agents.defaults.model.primary == "openai/gpt-5.5"
    and .agents.defaults.agentRuntime.id == "pi"
    and (.agents.defaults.models | has("openai/gpt-5.5"))
    and (.agents.defaults.models | has("openai-codex/gpt-5.5") | not)
  ' "$tmp/home/.openclaw/openclaw.json" >/dev/null ||
    fail "OpenClaw doctor model route repair was not preserved"
  [[ ! -f "$tmp/restarts" ]] ||
    fail "canonical OpenAI model route should not force a gateway restart"
  "$JQ_BIN" -e '
    .status == "OK"
    and .restartAttempted == false
    and .gatewayHealthy == true
    and all(.incidentCodes[]; . != "openclaw_model_config_drift")
    and all(.remediations[]; .code != "openclaw_model_config_drift")
    and .sanity.expectedOpenclawModel == "openai/gpt-5.5"
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "canonical OpenAI model route was not recorded cleanly"

  pass "canonical OpenAI model route after doctor is preserved"
}

smoke_json_preamble_is_accepted() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/json-preamble.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  cat >"$tmp/bin/openclaw" <<'EOF'
#!/usr/bin/env bash

if [[ "${1:-}" == "--version" ]]; then
  printf 'OpenClaw 2026.1.0\n'
  exit 0
fi

case "${1:-}" in
  update)
    case "${2:-}" in
      status)
        printf 'Config was last written by a newer OpenClaw.\n'
        printf '{"availability":{"available":false,"latestVersion":null},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf 'Gateway emitted a warning before JSON.\n'
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
CONFIG_BACKUP_ENABLED="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .status == "OK"
    and .updateAvailable == false
    and .gatewayHealthy == true
    and (.errors | length) == 0
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "doctor did not accept JSON output with a warning preamble"

  pass "json preamble before OpenClaw JSON is accepted"
}

smoke_update_retry_success_is_not_failed() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/update-retry.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  printf '2026.1.0\n' >"$tmp/version"
  printf '0\n' >"$tmp/update-attempts"
  cat >"$tmp/bin/openclaw" <<EOF
#!/usr/bin/env bash

if [[ "\${1:-}" == "--version" ]]; then
  printf 'OpenClaw %s\n' "\$(cat "$tmp/version")"
  exit 0
fi

case "\${1:-}" in
  update)
    case "\${2:-}" in
      status)
        printf '{"availability":{"available":true,"latestVersion":"2026.1.1-1"},"channel":{"value":"stable"}}\n'
        ;;
      *)
        attempts="\$(cat "$tmp/update-attempts")"
        attempts=\$((attempts + 1))
        printf '%s\n' "\$attempts" >"$tmp/update-attempts"
        if [[ "\$attempts" -eq 1 ]]; then
          printf 'transient registry failure\n' >&2
          exit 1
        fi
        printf '2026.1.1-1\n' >"$tmp/version"
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  doctor)
    printf 'doctor complete\n'
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .status == "UPDATED"
    and .updateAttempted == true
    and .updateSucceeded == true
    and .currentVersionAfter == "2026.1.1-1"
    and (.errors | length) == 0
    and .errorsByPhase.update == ""
    and any(.fixes[]; contains("failed on the first attempt, then succeeded"))
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "successful update retry was still reported as failed"

  pass "successful update retry is not reported as failed"
}

smoke_update_selects_compatible_node_runtime() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/node-runtime-preflight.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw" \
    "$tmp/node_modules/openclaw" "$tmp/node_modules/.bin"
  printf '2026.1.0\n' >"$tmp/version"
  cat >"$tmp/node_modules/openclaw/package.json" <<'EOF'
{"name":"openclaw","version":"2026.1.0","engines":{"node":">=22"}}
EOF
  cat >"$tmp/node_modules/openclaw/openclaw.mjs" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--profile" ]]; then shift 2; fi
case "\${1:-}" in
  --version)
    printf 'OpenClaw %s\\n' "\$(cat "$tmp/version")"
    ;;
  update)
    if [[ "\${2:-}" == "status" ]]; then
      printf '{"availability":{"available":true,"latestVersion":"2026.1.1"},"update":{"registry":{"latestVersion":"2026.1.1"}},"channel":{"value":"stable"}}\\n'
    else
      printf '%s\\n' "\$*" >"$tmp/update-args"
      printf '%s\\n' "\${FAKE_NODE_VERSION:-wrapper}" >"$tmp/update-node"
      command -v node >"$tmp/update-child-node"
      node --version >"$tmp/update-child-node-version"
      printf '2026.1.1\\n' >"$tmp/version"
      printf '{"ok":true}\\n'
    fi
    ;;
  health) printf '{"ok":true}\\n' ;;
  status) printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\\n' ;;
  *) printf '{}\\n' ;;
esac
EOF
  chmod +x "$tmp/node_modules/openclaw/openclaw.mjs"
  ln -s ../openclaw/openclaw.mjs "$tmp/node_modules/.bin/openclaw"
  printf '">=24.15.0 <25"\n' >"$tmp/engine"
  : >"$tmp/reject-primary-npm"
  cat >"$tmp/bin/npm" <<EOF
#!/usr/bin/env bash
if [[ -f "$tmp/reject-primary-npm" ]]; then
  cat "$tmp/engine"
  exit 1
fi
if [[ "\${3:-}" == "version" ]]; then
  printf '"2026.1.1"\n'
else
  cat "$tmp/engine"
fi
EOF
  chmod +x "$tmp/bin/npm"
  make_hanging_node_runtime "$tmp/node-hang"
  make_fake_node_runtime "$tmp/node25" "25.8.2" 1
  make_fake_node_runtime "$tmp/node24" "24.18.0" 0
  mv "$tmp/node24/bin/node" "$tmp/node24/bin/node24"
  rm -rf "$tmp/node24/lib/node_modules/npm/node_modules/semver"
  cat >"$tmp/node24/bin/npm" <<EOF
#!/usr/bin/env bash
printf 'fallback\n' >"$tmp/npm-fallback-used"
if [[ "\${3:-}" == "version" ]]; then
  printf '"2026.1.1"\n'
else
  cat "$tmp/engine"
fi
EOF
  chmod +x "$tmp/node24/bin/npm"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/node_modules/.bin/openclaw"
OPENCLAW_NODE_CANDIDATES="$tmp/node-hang/bin/node $tmp/node25/bin/node $tmp/node24/bin/node24"
AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"
STATE_DIR="$tmp/state"
STATUS_TIMEOUT="1"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
AUTO_ALIGN_OPENCLAW_USER_PLUGINS="false"
AUTO_RESTART_UNHEALTHY_GATEWAY="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="command -v node > $tmp/restart-child-node"
EOF

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ "$(cat "$tmp/update-node")" == "24.18.0" ]] ||
    fail "update did not run with the compatible Node candidate"
  [[ "$(readlink -f "$(cat "$tmp/update-child-node")")" == "$tmp/node24/bin/node24" ]] ||
    fail "update subprocess PATH did not prefer the compatible Node candidate"
  [[ "$(cat "$tmp/update-child-node-version")" == "v24.18.0" ]] ||
    fail "update subprocess did not execute with the compatible Node candidate"
  grep -Fq -- '--tag 2026.1.1' "$tmp/update-args" ||
    fail "package update was not pinned to the version whose Node engine was validated"
  [[ "$(readlink -f "$(cat "$tmp/restart-child-node")")" == "$tmp/node24/bin/node24" ]] ||
    fail "custom restart command did not inherit the compatible Node candidate"
  [[ -f "$tmp/npm-fallback-used" ]] ||
    fail "target engine discovery trusted output from a failed npm probe"
  "$JQ_BIN" -e '
    .status == "UPDATED"
    and .updateSucceeded == true
    and any(.remediations[]; .code == "openclaw_node_runtime" and .result == "selected")
    and any(.fixes[]; contains("Selected Node 24.18.0"))
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "compatible Node runtime selection was not reported"

  rm -f "$tmp/reject-primary-npm"
  printf '">=99"\n' >"$tmp/engine"
  printf '2026.1.0\n' >"$tmp/version"
  rm -f "$tmp/update-node"
  sed \
    -e "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/blocked-state\"|" \
    -e "s|OPENCLAW_NODE_CANDIDATES=.*|OPENCLAW_NODE_CANDIDATES=\"$tmp/node25/bin/node\"|" \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/blocked.env"
  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/blocked.env" --no-notify >/dev/null

  [[ ! -f "$tmp/update-node" ]] ||
    fail "update ran without an installed Node satisfying the target engine"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and .updateAttempted == false
    and any(.incidentCodes[]; . == "openclaw_node_runtime_incompatible")
    and any(.remediations[]; .code == "openclaw_node_runtime" and .result == "blocked_missing_compatible_runtime")
  ' "$tmp/blocked-state/doctor-state.json" >/dev/null ||
    fail "missing compatible Node runtime did not block the update safely"

  : >"$tmp/engine"
  printf '2026.1.0\n' >"$tmp/version"
  rm -f "$tmp/update-node" "$tmp/update-child-node" "$tmp/update-child-node-version"
  sed "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/metadata-state\"|" \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/metadata.env"
  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/metadata.env" --no-notify >/dev/null

  [[ ! -f "$tmp/update-node" ]] ||
    fail "update ran without trustworthy target Node engine metadata"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and .updateAttempted == false
    and any(.incidentCodes[]; . == "openclaw_node_runtime_preflight_failed")
    and any(.remediations[]; .code == "openclaw_node_runtime" and .result == "blocked_engine_metadata_unavailable")
  ' "$tmp/metadata-state/doctor-state.json" >/dev/null ||
    fail "missing target Node engine metadata did not block the update safely"

  pass "update propagates compatible Node and blocks unsafe mutations"
}

smoke_update_recovers_after_node_runtime_failure() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/node-runtime-recovery.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw" \
    "$tmp/node_modules/openclaw" "$tmp/node_modules/.bin"
  printf '2026.1.0\n' >"$tmp/version"
  cat >"$tmp/node_modules/openclaw/package.json" <<'EOF'
{"name":"openclaw","version":"2026.1.0","engines":{"node":">=22"}}
EOF
  cat >"$tmp/node_modules/openclaw/openclaw.mjs" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--profile" ]]; then shift 2; fi
if [[ -f "$tmp/stranded" && "\${FAKE_NODE_VERSION:-}" != "24.18.0" ]]; then
  printf 'openclaw requires Node >=24.15.0 <25; Detected: node 25.8.2\\n' >&2
  exit 1
fi
case "\${1:-}" in
  --version)
    printf 'OpenClaw %s\\n' "\$(cat "$tmp/version")"
    ;;
  update)
    if [[ "\${2:-}" == "status" ]]; then
      printf '{"availability":{"available":true,"latestVersion":"2026.1.1"},"update":{"registry":{"latestVersion":"2026.1.1"}},"channel":{"value":"stable"}}\\n'
    elif [[ "\${FAKE_NODE_VERSION:-}" != "24.18.0" ]]; then
      printf '{"name":"openclaw","version":"2026.1.1","engines":{"node":">=24.15.0 <25"}}\\n' >"$tmp/node_modules/openclaw/package.json"
      : >"$tmp/stranded"
      printf 'openclaw requires Node >=24.15.0 <25; Detected: node 25.8.2\\n' >&2
      exit 1
    else
      printf '%s\\n' "\${FAKE_NODE_VERSION}" >"$tmp/retry-node"
      printf '2026.1.1\\n' >"$tmp/version"
      printf '{"ok":true}\\n'
    fi
    ;;
  doctor) printf 'doctor complete\\n' ;;
  health) printf '{"ok":true}\\n' ;;
  status) printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\\n' ;;
  *) printf '{}\\n' ;;
esac
EOF
  chmod +x "$tmp/node_modules/openclaw/openclaw.mjs"
  ln -s ../openclaw/openclaw.mjs "$tmp/node_modules/.bin/openclaw"
  printf '">=22"\n' >"$tmp/target-engine"
  cat >"$tmp/bin/npm" <<EOF
#!/usr/bin/env bash
if [[ "\${3:-}" == "version" ]]; then
  printf '"2026.1.1"\n'
else
  cat "$tmp/target-engine"
fi
EOF
  chmod +x "$tmp/bin/npm"
  make_fake_node_runtime "$tmp/node25" "25.8.2" 0
  make_fake_node_runtime "$tmp/node24" "24.18.0" 0
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/node_modules/.bin/openclaw"
OPENCLAW_NODE_CANDIDATES="$tmp/node25/bin/node $tmp/node24/bin/node"
AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
AUTO_ALIGN_OPENCLAW_USER_PLUGINS="false"
AUTO_RESTART_UNHEALTHY_GATEWAY="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  printf '{"name":"openclaw","version":"2026.1.1","engines":{"node":">=24.15.0 <25"}}\n' >"$tmp/node_modules/openclaw/package.json"
  : >"$tmp/stranded"
  sed "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/startup-state\"|" \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/startup.env"
  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/startup.env" --no-notify >/dev/null
  "$JQ_BIN" -e '
    .updateSucceeded == true
    and any(.remediations[]; .code == "openclaw_node_runtime" and .result == "recovered_before_maintenance")
  ' "$tmp/startup-state/doctor-state.json" >/dev/null ||
    fail "Nurse did not bootstrap a compatible Node for an already-stranded CLI"

  rm -f "$tmp/stranded" "$tmp/retry-node"
  printf '2026.1.0\n' >"$tmp/version"
  printf '{"name":"openclaw","version":"2026.1.0","engines":{"node":">=22"}}\n' >"$tmp/node_modules/openclaw/package.json"
  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ "$(cat "$tmp/retry-node")" == "24.18.0" ]] ||
    fail "stranded update retry did not use the recovered Node runtime"
  "$JQ_BIN" -e '
    .status == "UPDATED"
    and .updateSucceeded == true
    and any(.remediations[]; .code == "openclaw_node_runtime" and .result == "recovered_after_update_failure")
    and any(.fixes[]; contains("Recovered OpenClaw maintenance with Node 24.18.0"))
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "post-update Node runtime recovery was not reported"

  pass "Nurse bootstraps and recovers when the original Node cannot run OpenClaw"
}

smoke_startup_runtime_failure_is_bounded_and_notified() {
  local tmp status
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/node-runtime-startup-failure.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw" \
    "$tmp/node_modules/openclaw" "$tmp/node_modules/.bin"
  cat >"$tmp/node_modules/openclaw/package.json" <<'EOF'
{"name":"openclaw","version":"2026.1.0","engines":{"node":">=99"}}
EOF
  cat >"$tmp/node_modules/openclaw/openclaw.mjs" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  trap '' TERM
  while true; do
    sleep 1
  done
fi
printf '{}\n'
EOF
  chmod +x "$tmp/node_modules/openclaw/openclaw.mjs"
  ln -s ../openclaw/openclaw.mjs "$tmp/node_modules/.bin/openclaw"
  cat >"$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
output_file=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o)
      output_file="\${2:-}"
      shift 2
      ;;
    -w)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf '{"ok":true}\\n' >"\$output_file"
: >"$tmp/telegram-called"
printf '200'
EOF
  chmod +x "$tmp/bin/curl"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/node_modules/.bin/openclaw"
AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"
STATE_DIR="$tmp/state"
STATUS_TIMEOUT="1"
REPORT_CHANNEL="telegram"
TELEGRAM_TARGET="chat"
TELEGRAM_BOT_TOKEN="fake-token"
TELEGRAM_API_BASE_URL="http://telegram.test"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  set +e
  timeout 6s env PATH="$tmp/bin:$PATH" HOME="$tmp/home" \
    "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" >/dev/null
  status=$?
  set -e

  [[ "$status" -eq 1 ]] ||
    fail "startup runtime probe was not bounded or did not report failure (exit $status)"
  [[ -f "$tmp/telegram-called" ]] ||
    fail "startup runtime failure was not delivered immediately"
  [[ ! -f "$tmp/state/pending-report.txt" ]] ||
    fail "successfully delivered startup failure remained pending"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and .notificationDelivered == true
    and .notificationPending == false
    and any(.incidentCodes[]; . == "openclaw_node_runtime_incompatible")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "bounded startup runtime failure was not persisted as delivered"

  pass "startup runtime probes are bounded and failures are notified"
}

smoke_cli_failure_is_not_misdiagnosed_as_node() {
  local tmp status
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/cli-failure-classification.XXXXXX")"

  mkdir -p "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw" \
    "$tmp/node_modules/openclaw" "$tmp/node_modules/.bin"
  cat >"$tmp/node_modules/openclaw/package.json" <<'EOF'
{"name":"openclaw","version":"2026.1.0","engines":{"node":">=22"}}
EOF
  cat >"$tmp/node_modules/openclaw/openclaw.mjs" <<'EOF'
#!/usr/bin/env bash
printf 'OpenClaw 2026.1.0\n'
printf 'Error: Cannot find module openclaw/dist/missing.js\n' >&2
exit 42
EOF
  chmod +x "$tmp/node_modules/openclaw/openclaw.mjs"
  ln -s ../openclaw/openclaw.mjs "$tmp/node_modules/.bin/openclaw"
  make_fake_node_runtime "$tmp/node24" "24.18.0" 0
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/node_modules/.bin/openclaw"
OPENCLAW_NODE_CANDIDATES="$tmp/node24/bin/node"
AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  set +e
  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "corrupt OpenClaw CLI did not fail startup"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and any(.incidentCodes[]; . == "openclaw_cli_unavailable")
    and all(.incidentCodes[]; . != "openclaw_node_runtime_incompatible")
    and any(.remediations[]; .code == "openclaw_node_runtime" and .result == "blocked_cli_unavailable")
    and any(.actions[]; contains("repair or reinstall"))
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "corrupt OpenClaw CLI was misdiagnosed as a Node incompatibility"

  sed \
    -e "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/disabled-state\"|" \
    -e 's|AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"|AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="false"|' \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/disabled.env"
  set +e
  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/disabled.env" --no-notify >/dev/null
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || fail "disabled runtime selection did not report unavailable CLI"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and any(.errors[]; contains("automatic compatible-Node selection is disabled"))
    and any(.remediations[]; .code == "openclaw_node_runtime" and .result == "blocked_selection_disabled")
  ' "$tmp/disabled-state/doctor-state.json" >/dev/null ||
    fail "disabled runtime selection produced an empty startup report"

  pass "CLI corruption and disabled selection are reported accurately"
}

smoke_runtime_recovery_uses_effective_systemd_execstart() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/runtime-systemd-root.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw" \
    "$tmp/proc/4242" "$tmp/releases/release-a/dist"
  cat >"$tmp/releases/release-a/package.json" <<'EOF'
{"name":"openclaw","version":"2026.1.0","engines":{"node":">=24.15.0 <25"}}
EOF
  cat >"$tmp/releases/release-a/dist/index.js" <<EOF
#!/usr/bin/env bash
if [[ "\${FAKE_NODE_VERSION:-}" != "24.18.0" ]]; then
  printf 'openclaw requires Node >=24.15.0 <25; Detected: node 25.8.2\\n' >&2
  exit 1
fi
if [[ "\${1:-}" == "--profile" ]]; then shift 2; fi
case "\${1:-}" in
  --version) printf 'OpenClaw 2026.1.0\\n' ;;
  update) printf '{"availability":{"available":false,"latestVersion":"2026.1.0"},"update":{"installKind":"package","registry":{"latestVersion":"2026.1.0"}},"channel":{"value":"stable"}}\\n' ;;
  doctor) printf 'doctor complete\\n' ;;
  health) printf '{"ok":true}\\n' ;;
  status) printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\\n' ;;
  *) printf '{}\\n' ;;
esac
EOF
  chmod +x "$tmp/releases/release-a/dist/index.js"
  ln -s release-a "$tmp/releases/current"
  make_fake_node_runtime "$tmp/node24" "24.18.0" 0
  cat >"$tmp/bin/openclaw-gateway-current" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$tmp/bin/openclaw-gateway-current"
  printf '%s\0%s\0%s\0' \
    "$tmp/node24/bin/node" "$tmp/releases/release-a/dist/index.js" gateway \
    >"$tmp/proc/4242/cmdline"
  cat >"$tmp/bin/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\${2:-}" == "show" ]]; then
  printf '4242\\n'
  exit 0
fi
if [[ "\${2:-}" == "cat" ]]; then
  printf '[Service]\\n'
  printf 'ExecStart=$tmp/bin/openclaw-gateway-current gateway\\n'
fi
exit 0
EOF
  chmod +x "$tmp/bin/systemctl"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/bin/missing-openclaw-wrapper"
AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
SYSTEMCTL_BIN="$tmp/bin/systemctl"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
RESTART_MODE="systemd_user"
PROCFS_DIR="$tmp/proc"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
EOF

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null
  "$JQ_BIN" -e '
    any(.remediations[]; .code == "openclaw_node_runtime" and .result == "recovered_before_maintenance")
    and any(.fixes[]; contains("Node 24.18.0"))
    and all(.incidentCodes[]; . != "openclaw_node_runtime_incompatible")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "missing launcher did not recover from the live systemd process command line"

  rm -f "$tmp/proc/4242/cmdline"
  cat >"$tmp/bin/openclaw-gateway-current" <<EOF
#!/usr/bin/env bash
current="$tmp/releases/current"
release="\$(readlink -f "\$current")"
exec "$tmp/node24/bin/node" "\$release/dist/index.js" "\$@"
EOF
  chmod +x "$tmp/bin/openclaw-gateway-current"
  sed \
    -e "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/wrapper-state\"|" \
    -e "/AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE/a OPENCLAW_NODE_CANDIDATES=\"$tmp/node24/bin/node\"" \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/wrapper.env"

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/wrapper.env" --no-notify >/dev/null
  "$JQ_BIN" -e '
    any(.remediations[]; .code == "openclaw_node_runtime" and .result == "recovered_before_maintenance")
    and all(.incidentCodes[]; . != "openclaw_node_runtime_incompatible")
  ' "$tmp/wrapper-state/doctor-state.json" >/dev/null ||
    fail "inactive systemd wrapper did not resolve its checkout package root"

  pass "runtime recovery resolves live systemd commands and checkout wrappers"
}

smoke_update_recovery_preserves_target_engine() {
  local tmp status
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/runtime-target-recovery.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw" \
    "$tmp/node_modules/openclaw" "$tmp/node_modules/.bin"
  printf '2026.1.0\n' >"$tmp/version"
  printf '0\n' >"$tmp/update-attempts"
  printf '">=24.15.0 <25"\n' >"$tmp/target-engine"
  printf 'package\n' >"$tmp/install-kind"
  cat >"$tmp/node_modules/openclaw/package.json" <<'EOF'
{"name":"openclaw","version":"2026.1.0","engines":{"node":">=22"}}
EOF
  cat >"$tmp/node_modules/openclaw/openclaw.mjs" <<EOF
#!/usr/bin/env bash
if [[ -f "$tmp/source-runtime-transition" && -z "\${FAKE_NODE_VERSION:-}" ]]; then
  printf 'openclaw requires a managed Node runtime; Detected: node wrapper\\n' >&2
  exit 1
fi
if [[ "\${1:-}" == "--profile" ]]; then shift 2; fi
case "\${1:-}" in
  --version)
    printf 'OpenClaw %s\\n' "\$(cat "$tmp/version")"
    ;;
  update)
    if [[ "\${2:-}" == "status" ]]; then
      printf '{"availability":{"available":true,"latestVersion":"2026.1.1"},"update":{"installKind":"%s","registry":{"latestVersion":"2026.1.1"}},"channel":{"value":"stable"}}\\n' "\$(cat "$tmp/install-kind")"
    else
      attempts="\$(cat "$tmp/update-attempts")"
      attempts=\$((attempts + 1))
      printf '%s\\n' "\$attempts" >"$tmp/update-attempts"
      if [[ "\$attempts" -eq 1 ]]; then
        if [[ -f "$tmp/source-runtime-transition" ]]; then
          printf '{"name":"openclaw","version":"2026.1.1","engines":{"node":">=24.15.0 <25"}}\\n' >"$tmp/node_modules/openclaw/package.json"
        fi
        if [[ -f "$tmp/remove-target-runtime" ]]; then
          chmod -x "$tmp/node24/bin/node"
        fi
        printf 'npm ERR! code EBADENGINE\\n' >&2
        exit 1
      fi
      printf '%s\\n' "\${FAKE_NODE_VERSION:-wrapper}" >"$tmp/retry-node"
      printf '2026.1.1\\n' >"$tmp/version"
      printf '{"ok":true}\\n'
    fi
    ;;
  doctor) printf 'doctor complete\\n' ;;
  health) printf '{"ok":true}\\n' ;;
  status) printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\\n' ;;
  *) printf '{}\\n' ;;
esac
EOF
  chmod +x "$tmp/node_modules/openclaw/openclaw.mjs"
  ln -s ../openclaw/openclaw.mjs "$tmp/node_modules/.bin/openclaw"
  cat >"$tmp/bin/npm" <<EOF
#!/usr/bin/env bash
if [[ "\${3:-}" == "version" ]]; then
  printf '"2026.1.1"\n'
else
  cat "$tmp/target-engine"
fi
EOF
  chmod +x "$tmp/bin/npm"
  make_fake_node_runtime "$tmp/node25" "25.8.2" "broad-only"
  make_fake_node_runtime "$tmp/node24" "24.18.0" 0
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/node_modules/.bin/openclaw"
OPENCLAW_NODE_CANDIDATES="$tmp/node25/bin/node $tmp/node24/bin/node"
AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
AUTO_ALIGN_OPENCLAW_USER_PLUGINS="false"
AUTO_RESTART_UNHEALTHY_GATEWAY="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null
  [[ "$(cat "$tmp/retry-node")" == "24.18.0" ]] ||
    fail "EBADENGINE recovery abandoned the target-compatible Node runtime"
  "$JQ_BIN" -e '
    .status == "UPDATED"
    and .updateSucceeded == true
    and any(.remediations[]; .code == "openclaw_node_runtime" and .result == "recovered_after_update_failure")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "target-compatible runtime recovery was not reported"

  printf '2026.1.0\n' >"$tmp/version"
  printf '0\n' >"$tmp/update-attempts"
  : >"$tmp/remove-target-runtime"
  rm -f "$tmp/retry-node"
  chmod +x "$tmp/node24/bin/node"
  sed "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/missing-target-state\"|" \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/missing-target.env"

  set +e
  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" \
    --config "$tmp/cfg/missing-target.env" --no-notify >/dev/null
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "runtime recovery failure caused an unexpected process exit"
  [[ "$(cat "$tmp/update-attempts")" == "1" ]] ||
    fail "update retried with a runtime that only satisfied the installed package"
  [[ ! -f "$tmp/retry-node" ]] ||
    fail "update abandoned the target engine requirement during recovery"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and .updateSucceeded == false
    and any(.errors[]; contains("required runtime recovery could not be completed"))
  ' "$tmp/missing-target-state/doctor-state.json" >/dev/null ||
    fail "missing target-compatible runtime was not reported after the failed update"

  printf '2026.1.0\n' >"$tmp/version"
  printf '0\n' >"$tmp/update-attempts"
  rm -f "$tmp/remove-target-runtime" "$tmp/retry-node"
  chmod +x "$tmp/node24/bin/node"
  sed \
    -e "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/disabled-recovery-state\"|" \
    -e 's|AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"|AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="false"|' \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/disabled-recovery.env"

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" \
    --config "$tmp/cfg/disabled-recovery.env" --no-notify >/dev/null
  [[ "$(cat "$tmp/update-attempts")" == "1" ]] ||
    fail "disabled runtime recovery allowed an EBADENGINE retry"
  [[ ! -f "$tmp/retry-node" ]] ||
    fail "disabled runtime recovery retried the update with the same runtime"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and .updateSucceeded == false
    and any(.incidentCodes[]; . == "openclaw_node_runtime_recovery_blocked")
    and any(.remediations[];
      .code == "openclaw_node_runtime"
      and .result == "recovery_blocked_selection_disabled"
    )
  ' "$tmp/disabled-recovery-state/doctor-state.json" >/dev/null ||
    fail "disabled post-update runtime recovery was not reported"

  printf '2026.1.0\n' >"$tmp/version"
  printf '0\n' >"$tmp/update-attempts"
  printf 'source\n' >"$tmp/install-kind"
  printf '{"name":"openclaw","version":"2026.1.0","engines":{"node":">=22"}}\n' >"$tmp/node_modules/openclaw/package.json"
  : >"$tmp/source-runtime-transition"
  rm -f "$tmp/retry-node"
  sed "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/source-state\"|" \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/source.env"

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" \
    --config "$tmp/cfg/source.env" --no-notify >/dev/null
  [[ "$(cat "$tmp/retry-node")" == "24.18.0" ]] ||
    fail "non-package recovery reused the stale installed Node engine"
  "$JQ_BIN" -e '
    .status == "UPDATED"
    and .updateSucceeded == true
    and any(.remediations[];
      .code == "openclaw_node_runtime"
      and .result == "recovered_after_update_failure"
    )
  ' "$tmp/source-state/doctor-state.json" >/dev/null ||
    fail "non-package update did not recover from its newly installed Node engine"

  pass "update recovery preserves the target Node engine requirement"
}

smoke_update_refreshes_relocated_entrypoint() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/runtime-entrypoint-refresh.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw" \
    "$tmp/node_modules/openclaw/dist" "$tmp/node_modules/.bin"
  printf '2026.1.0\n' >"$tmp/version"
  cat >"$tmp/node_modules/openclaw/package.json" <<'EOF'
{"name":"openclaw","version":"2026.1.0","engines":{"node":">=24.15.0 <25"}}
EOF
  cat >"$tmp/node_modules/openclaw/dist/index.next.js" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--profile" ]]; then shift 2; fi
case "\${1:-}" in
  --version) printf 'OpenClaw %s\\n' "\$(cat "$tmp/version")" ;;
  update) printf '{"availability":{"available":false,"latestVersion":"2026.1.1"},"update":{"installKind":"package","registry":{"latestVersion":"2026.1.1"}},"channel":{"value":"stable"}}\\n' ;;
  doctor) : >"$tmp/new-entrypoint-used"; printf 'doctor complete\\n' ;;
  health) printf '{"ok":true}\\n' ;;
  status) printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\\n' ;;
  *) printf '{}\\n' ;;
esac
EOF
  chmod +x "$tmp/node_modules/openclaw/dist/index.next.js"
  cp "$tmp/node_modules/openclaw/dist/index.next.js" "$tmp/new-entrypoint-template"
  cat >"$tmp/node_modules/openclaw/openclaw.mjs" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--profile" ]]; then shift 2; fi
case "\${1:-}" in
  --version)
    printf 'OpenClaw %s\\n' "\$(cat "$tmp/version")"
    ;;
  update)
    if [[ "\${2:-}" == "status" ]]; then
      printf '{"availability":{"available":true,"latestVersion":"2026.1.1"},"update":{"installKind":"package","registry":{"latestVersion":"2026.1.1"}},"channel":{"value":"stable"}}\\n'
    else
      if [[ -f "$tmp/break-post-update-cli" ]]; then
        rm -f "$tmp/node_modules/openclaw/dist/index.next.js"
      else
        mv "$tmp/node_modules/openclaw/dist/index.next.js" "$tmp/node_modules/openclaw/dist/index.js"
      fi
      rm -f "$tmp/node_modules/openclaw/openclaw.mjs"
      if [[ ! -f "$tmp/keep-old-version" ]]; then
        printf '2026.1.1\\n' >"$tmp/version"
      fi
      printf '{"ok":true}\\n'
    fi
    ;;
  health) printf '{"ok":true}\\n' ;;
  status) printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\\n' ;;
  *) printf '{}\\n' ;;
esac
EOF
  chmod +x "$tmp/node_modules/openclaw/openclaw.mjs"
  cp "$tmp/node_modules/openclaw/openclaw.mjs" "$tmp/old-entrypoint-template"
  ln -s ../openclaw/openclaw.mjs "$tmp/node_modules/.bin/openclaw"
  cat >"$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
if [[ "${3:-}" == "version" ]]; then
  printf '"2026.1.1"\n'
else
  printf '">=24.15.0 <25"\n'
fi
EOF
  chmod +x "$tmp/bin/npm"
  make_fake_node_runtime "$tmp/node24" "24.18.0" 0
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/node_modules/.bin/openclaw"
OPENCLAW_NODE_CANDIDATES="$tmp/node24/bin/node"
AUTO_SELECT_COMPATIBLE_OPENCLAW_NODE="true"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
AUTO_ALIGN_OPENCLAW_USER_PLUGINS="false"
AUTO_RESTART_UNHEALTHY_GATEWAY="false"
AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD="false"
AUTO_CLEAN_OPENCLAW_PM2_DAEMONS="false"
AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS="false"
AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
EOF

  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" \
    --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ -f "$tmp/new-entrypoint-used" ]] ||
    fail "post-update maintenance kept using the removed OpenClaw entrypoint"
  "$JQ_BIN" -e '
    .status == "UPDATED"
    and .updateSucceeded == true
    and .currentVersionAfter == "2026.1.1"
    and (.errors | length) == 0
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "relocated OpenClaw entrypoint was not refreshed after the update"

  cp "$tmp/old-entrypoint-template" "$tmp/node_modules/openclaw/openclaw.mjs"
  cp "$tmp/new-entrypoint-template" "$tmp/node_modules/openclaw/dist/index.next.js"
  chmod +x "$tmp/node_modules/openclaw/openclaw.mjs" "$tmp/node_modules/openclaw/dist/index.next.js"
  rm -f "$tmp/node_modules/openclaw/dist/index.js" "$tmp/new-entrypoint-used"
  printf '2026.1.0\n' >"$tmp/version"
  : >"$tmp/keep-old-version"
  sed "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/version-mismatch-state\"|" \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/version-mismatch.env"

  set +e
  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" \
    --config "$tmp/cfg/version-mismatch.env" --no-notify >/dev/null
  set -e
  "$JQ_BIN" -e '
    .status == "FAILED"
    and .updateAttempted == true
    and .updateSucceeded == false
    and .restartAttempted == false
    and (.errorsByPhase.update | contains("expected version 2026.1.1"))
    and any(.incidentCodes[]; . == "post_update_cli_validation_failed")
  ' "$tmp/version-mismatch-state/doctor-state.json" >/dev/null ||
    fail "updater success was accepted without installing the validated target version"

  cp "$tmp/old-entrypoint-template" "$tmp/node_modules/openclaw/openclaw.mjs"
  cp "$tmp/new-entrypoint-template" "$tmp/node_modules/openclaw/dist/index.next.js"
  chmod +x "$tmp/node_modules/openclaw/openclaw.mjs" "$tmp/node_modules/openclaw/dist/index.next.js"
  rm -f "$tmp/node_modules/openclaw/dist/index.js" "$tmp/new-entrypoint-used" "$tmp/keep-old-version"
  printf '2026.1.0\n' >"$tmp/version"
  : >"$tmp/break-post-update-cli"
  sed "s|STATE_DIR=\"$tmp/state\"|STATE_DIR=\"$tmp/broken-state\"|" \
    "$tmp/cfg/openclawnurse.env" >"$tmp/cfg/broken.env"

  set +e
  PATH="$tmp/bin:$PATH" HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" \
    --config "$tmp/cfg/broken.env" --no-notify >/dev/null
  set -e
  "$JQ_BIN" -e '
    .status == "FAILED"
    and .updateAttempted == true
    and .updateSucceeded == false
    and .restartAttempted == false
    and any(.incidentCodes[]; . == "post_update_cli_validation_failed")
    and any(.remediations[];
      .code == "openclaw_node_runtime"
      and .result == "post_update_validation_failed"
    )
  ' "$tmp/broken-state/doctor-state.json" >/dev/null ||
    fail "broken post-update CLI was accepted or restarted"

  pass "post-update validation refreshes relocated entrypoints and blocks broken installs"
}

smoke_gateway_env_file_feeds_openclaw_commands() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/gateway-env.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  printf '2026.1.0\n' >"$tmp/version"
  cat >"$tmp/bin/openclaw" <<EOF
#!/usr/bin/env bash

if [[ "\${1:-}" == "--version" ]]; then
  printf 'OpenClaw %s\n' "\$(cat "$tmp/version")"
  exit 0
fi

case "\${1:-}" in
  update)
    case "\${2:-}" in
      status)
        printf '{"availability":{"available":true,"latestVersion":"2026.1.1"},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf '2026.1.1\n' >"$tmp/version"
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  gateway)
    if [[ "\${2:-}" == "install" ]]; then
      if [[ "\${OPENCLAW_GATEWAY_TOKEN:-}" == "gateway-from-env" && "\${OPENAI_API_KEY:-}" == "openai-from-env" ]]; then
        printf 'saw-env\n' >"$tmp/gateway-install-env"
        printf '{"ok":true}\n'
      else
        printf 'missing gateway env\n' >&2
        exit 1
      fi
    fi
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/bin/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--user" && "\${2:-}" == "restart" ]]; then
  printf restarted >"$tmp/restarted"
fi
exit 0
EOF
  chmod +x "$tmp/bin/systemctl"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/home/.openclaw/gateway.systemd.env" <<EOF
OPENCLAW_GATEWAY_TOKEN=gateway-from-env
OPENAI_API_KEY=openai-from-env
EVIL_COMMAND="\$(printf executed >"$tmp/env-executed")"
PATH=/should-not-be-imported
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
SYSTEMCTL_BIN="$tmp/bin/systemctl"
OPENCLAW_GATEWAY_ENV_FILE="$tmp/home/.openclaw/gateway.systemd.env"
OPENCLAW_CONFIG_FILE="$tmp/home/.openclaw/openclaw.json"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
AUTO_ALIGN_OPENCLAW_USER_PLUGINS="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ "$(cat "$tmp/gateway-install-env" 2>/dev/null)" == "saw-env" ]] ||
    fail "gateway install did not receive values from OPENCLAW_GATEWAY_ENV_FILE"
  [[ ! -f "$tmp/env-executed" ]] ||
    fail "gateway env file executed shell code"
  "$JQ_BIN" -e '
    .status == "UPDATED"
    and .updateSucceeded == true
    and .restartAttempted == true
    and any(.remediations[]; .code == "gateway_service_refresh" and .result == "applied")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "gateway env file refresh path was not recorded as applied"

  pass "gateway env file feeds OpenClaw maintenance commands"
}

smoke_gateway_refresh_failure_skips_restart() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/gateway-refresh-fail.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.openclaw"
  printf '2026.1.0\n' >"$tmp/version"
  cat >"$tmp/bin/openclaw" <<EOF
#!/usr/bin/env bash

if [[ "\${1:-}" == "--version" ]]; then
  printf 'OpenClaw %s\n' "\$(cat "$tmp/version")"
  exit 0
fi

case "\${1:-}" in
  update)
    case "\${2:-}" in
      status)
        printf '{"availability":{"available":true,"latestVersion":"2026.1.1"},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf '2026.1.1\n' >"$tmp/version"
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  gateway)
    if [[ "\${2:-}" == "install" ]]; then
      printf '{"ok":false,"error":"Gateway install blocked: gateway.auth.token SecretRef is configured but unresolved"}\n' >&2
      exit 1
    fi
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/bin/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--user" && "\${2:-}" == "restart" ]]; then
  printf restarted >"$tmp/restarted"
fi
exit 0
EOF
  chmod +x "$tmp/bin/systemctl"
  cat >"$tmp/home/.openclaw/openclaw.json" <<'EOF'
{"gateway":{"port":18789}}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
SYSTEMCTL_BIN="$tmp/bin/systemctl"
OPENCLAW_CONFIG_FILE="$tmp/home/.openclaw/openclaw.json"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
AUTO_ALIGN_OPENCLAW_USER_PLUGINS="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ ! -f "$tmp/restarted" ]] ||
    fail "gateway was restarted after service refresh failed"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and .updateSucceeded == true
    and .restartAttempted == false
    and .gatewayHealthy == true
    and any(.errors[]; contains("Failed to refresh OpenClaw gateway service install after update"))
    and any(.fixes[]; contains("Skipped gateway restart because the service refresh failed"))
    and any(.actions[]; contains("Automatic gateway restart was skipped"))
    and any(.remediations[]; .code == "gateway_service_refresh" and .result == "apply_failed")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "gateway refresh failure did not skip restart cleanly"

  pass "gateway refresh failure skips automatic restart"
}

smoke_gateway_log_scan_reports_oom() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/gateway-oom.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
cat <<'LOGS'
Jun 04 16:52:14 host node[1]: [diagnostic] liveness warning: reasons=event_loop_delay,event_loop_utilization eventLoopDelayP99Ms=39896.2
Jun 04 17:16:38 host systemd[1]: openclaw-gateway.service: A process of this unit has been killed by the OOM killer.
Jun 04 17:16:51 host systemd[1]: openclaw-gateway.service: Failed with result 'oom-kill'.
LOGS
EOF
  chmod +x "$tmp/bin/journalctl"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="true"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
RESTART_COMMAND="true"
GATEWAY_LOG_SINCE="1 hour ago"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .status == "FAILED"
    and .sanity.critical == true
    and .sanity.gatewayOomKillCount == 1
    and .sanity.gatewayEventLoopWarningCount == 1
    and any(.incidentCodes[]; . == "gateway_oom_kill")
    and any(.incidentCodes[]; . == "gateway_event_loop_pressure")
    and any(.errors[]; contains("Gateway logs show an OOM kill"))
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "gateway OOM log scan was not reported as critical"

  pass "gateway log scan reports OOM and event-loop pressure"
}

smoke_remediates_openclaw_installation_drift() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/install-drift.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.npm-global/bin" "$tmp/home/.npm-global/lib/node_modules" "$tmp/home/.local/share/pnpm"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/home/.npm-global/bin/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'OpenClaw 2026.0.8\n'
EOF
  chmod +x "$tmp/home/.npm-global/bin/openclaw"
  mkdir -p "$tmp/home/.npm-global/lib/node_modules/openclaw"
  cat >"$tmp/home/.local/share/pnpm/openclaw" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$tmp/home/.local/share/pnpm/openclaw"
  cat >"$tmp/home/.bashrc" <<'EOF'
alias openclaw="/old/openclaw"
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
OPENCLAW_EXTRA_SCAN_PATHS="$tmp/home/.npm-global/bin/openclaw $tmp/home/.local/share/pnpm/openclaw"
AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS="true"
OPENCLAW_REMEDIABLE_INSTALL_PATHS="$tmp/home/.npm-global/bin/openclaw $tmp/home/.npm-global/lib/node_modules/openclaw"
AUTO_REPAIR_OPENCLAW_LAUNCHER="true"
OPENCLAW_LAUNCHER_PATH="$tmp/home/.local/share/pnpm/openclaw"
AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING="true"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ ! -e "$tmp/home/.npm-global/bin/openclaw" ]] ||
    fail "stale OpenClaw bin was not quarantined"
  [[ ! -e "$tmp/home/.npm-global/lib/node_modules/openclaw" ]] ||
    fail "stale OpenClaw package dir was not quarantined"
  "$tmp/home/.local/share/pnpm/openclaw" --version | grep -Fq 'OpenClaw 2026.1.0' ||
    fail "OpenClaw launcher was not repaired"
  grep -Fq '# openclawnurse disabled shell alias shadowing:' "$tmp/home/.bashrc" ||
    fail "OpenClaw shell alias was not disabled"
  "$JQ_BIN" -e '(.status == "OK") and any(.fixes[]; contains("Remediated OpenClaw stale installation"))' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "installation drift remediation was not recorded as an OK run"

  pass "openclaw installation drift is remediated"
}

smoke_default_deduplicates_local_openclaw_shim() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/local-shim-drift.XXXXXX")"

  mkdir -p \
    "$tmp/home/.npm-global/bin" \
    "$tmp/home/openclaw/node_modules/.bin" \
    "$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw/dist" \
    "$tmp/state" \
    "$tmp/cfg"

  make_fake_openclaw "$tmp/home/.npm-global/bin/openclaw"
  cat >"$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw/package.json" <<'EOF'
{"name":"openclaw","version":"2026.0.8"}
EOF
  cat >"$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw/dist/entry.js" <<'EOF'
#!/usr/bin/env bash
printf 'OpenClaw 2026.0.8\n'
EOF
  chmod +x "$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw/dist/entry.js"
  cat >"$tmp/home/openclaw/node_modules/.bin/openclaw" <<EOF
#!/usr/bin/env bash
exec node "$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw/openclaw.mjs" "\$@"
EOF
  chmod +x "$tmp/home/openclaw/node_modules/.bin/openclaw"
  cat >"$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw/openclaw.mjs" <<'EOF'
#!/usr/bin/env bash
printf 'OpenClaw 2026.0.8\n'
EOF
  chmod +x "$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw/openclaw.mjs"
  cat >"$tmp/home/.bashrc" <<'EOF'
openclaw() {
  "$HOME/openclaw/node_modules/.bin/openclaw" "$@"
}
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/home/.npm-global/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ ! -e "$tmp/home/openclaw/node_modules/.bin/openclaw" ]] ||
    fail "stale local OpenClaw shim was not quarantined by default"
  [[ ! -e "$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw" ]] ||
    fail "stale local OpenClaw package root was not quarantined by default"
  grep -Fq 'openclawnurse disabled shell function shadowing: openclaw' "$tmp/home/.bashrc" ||
    fail "OpenClaw shell function was not neutralized"
  "$JQ_BIN" -e '
    .status == "OK"
    and (.sanity.findings | length) == 0
    and any(.remediations[]; .code == "openclaw_installation_drift" and .result == "applied")
    and any(.remediations[]; .code == "openclaw_shell_shadowing" and .result == "applied")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "default local shim deduplication did not produce a clean OK run"

  pass "default deduplicates local OpenClaw shim and shell function"
}

smoke_missing_local_openclaw_bin_is_remediated() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/missing-local-bin.XXXXXX")"

  mkdir -p \
    "$tmp/home/.npm-global/bin" \
    "$tmp/home/openclaw/node_modules/.bin" \
    "$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw" \
    "$tmp/state" \
    "$tmp/cfg"

  make_fake_openclaw "$tmp/home/.npm-global/bin/openclaw"
  cat >"$tmp/home/openclaw/package.json" <<'EOF'
{"dependencies":{"openclaw":"2026.0.8"}}
EOF
  cat >"$tmp/home/openclaw/node_modules/.pnpm/openclaw@2026.0.8/node_modules/openclaw/package.json" <<'EOF'
{"name":"openclaw","version":"2026.0.8"}
EOF
  ln -s .pnpm/openclaw@2026.0.8/node_modules/openclaw "$tmp/home/openclaw/node_modules/openclaw"
  cat >"$tmp/home/.bashrc" <<'EOF'
alias openclaw="$HOME/openclaw/node_modules/.bin/openclaw"
EOF
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/home/.npm-global/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ ! -e "$tmp/home/openclaw/node_modules/openclaw" ]] ||
    fail "local OpenClaw package root for missing shim was not quarantined"
  grep -Fq '# openclawnurse disabled shell alias shadowing:' "$tmp/home/.bashrc" ||
    fail "OpenClaw shell alias to missing local shim was not disabled"
  "$JQ_BIN" -e '
    .status == "OK"
    and any(.fixes[]; contains("broken local shim"))
    and any(.remediations[]; .code == "openclaw_installation_drift" and .result == "applied")
    and any(.remediations[]; .code == "openclaw_shell_shadowing" and .result == "applied")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "missing local OpenClaw bin remediation was not recorded"

  pass "missing local OpenClaw bin is remediated"
}

write_minimal_self_update_tree() {
  local tree="$1"
  local marker="$2"

  mkdir -p "$tree/scripts" "$tree/systemd" "$tree/config"
  cat >"$tree/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$tree/install.sh"

  cat >"$tree/scripts/openclaw-doctor.sh" <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  -h|--help)
    printf 'self-update test doctor help\n'
    exit 0
    ;;
esac
printf '%s\n' '$marker'
EOF
  chmod +x "$tree/scripts/openclaw-doctor.sh"

  cat >"$tree/scripts/openclawnurse-openclaw-alert.sh" <<'EOF'
#!/usr/bin/env bash
set -u
exit 0
EOF
  chmod +x "$tree/scripts/openclawnurse-openclaw-alert.sh"

  cat >"$tree/scripts/install-doctor.sh" <<'EOF'
#!/usr/bin/env bash
set -u
exit 0
EOF
  chmod +x "$tree/scripts/install-doctor.sh"

  cat >"$tree/systemd/openclawnurse.service" <<'EOF'
[Service]
ExecStart=/bin/true
EOF
  cat >"$tree/systemd/openclawnurse.timer" <<'EOF'
[Timer]
OnCalendar=daily
EOF
}

git_commit_all() {
  local repo="$1"
  local message="$2"
  git -C "$repo" add .
  git -C "$repo" -c user.name='OpenClawNurse Test' -c user.email='test@example.invalid' commit -m "$message" >/dev/null
}

smoke_self_update_applies_valid_upstream() {
  local tmp remote repo updater target_head
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/self-update.XXXXXX")"
  remote="$tmp/remote.git"
  repo="$tmp/repo"
  updater="$tmp/updater"

  mkdir -p "$tmp/bin" "$tmp/home" "$tmp/state" "$tmp/data" "$tmp/cfg"
  make_fake_openclaw "$tmp/bin/openclaw"

  git -c init.defaultBranch=main init --bare "$remote" >/dev/null
  git -c init.defaultBranch=main init "$repo" >/dev/null
  write_minimal_self_update_tree "$repo" "self-update-old"
  git_commit_all "$repo" "initial"
  git -C "$repo" branch -M main
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -u origin main >/dev/null 2>&1

  git clone --branch main "$remote" "$updater" >/dev/null 2>&1
  write_minimal_self_update_tree "$updater" "self-update-new"
  git_commit_all "$updater" "update"
  git -C "$updater" push origin main >/dev/null 2>&1
  target_head="$(git -C "$updater" rev-parse HEAD)"

  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
DATA_DIR="$tmp/data"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
AUTO_SELF_UPDATE="true"
SELF_UPDATE_REPO_DIR="$repo"
SELF_UPDATE_REMOTE="origin"
SELF_UPDATE_BRANCH="main"
SELF_UPDATE_POLICY="reset-to-remote"
SELF_UPDATE_RUN_TESTS="false"
SELF_UPDATE_ROLLBACK_ON_FAILURE="true"
SELF_UPDATE_RESTART_GATEWAY="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD="false"
AUTO_REFRESH_STALE_GATEWAY_SERVICE="false"
AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS="false"
AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING="false"
AUTO_RESTART_UNHEALTHY_GATEWAY="false"
AUTO_REMEDIATE_EXPECTED_OPENCLAW_MODEL="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ "$(git -C "$repo" rev-parse HEAD)" == "$target_head" ]] ||
    fail "self-update did not reset the repo to upstream"
  grep -Fq 'self-update-new' "$tmp/data/bin/openclaw-doctor.sh" ||
    fail "self-update did not install the refreshed doctor script"
  "$JQ_BIN" -e --arg target "$target_head" '
    .status == "OK"
    and .selfUpdate.attempted == true
    and .selfUpdate.available == true
    and .selfUpdate.applied == true
    and .selfUpdate.rolledBack == false
    and .selfUpdate.to == $target
    and any(.remediations[]; .code == "openclawnurse_self_update" and .result == "applied")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "self-update state was not persisted as applied"

  pass "self-update applies valid upstream and installs refreshed runtime"
}

smoke_self_update_skips_when_local_is_ahead() {
  local tmp remote repo local_head remote_head
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/self-update-local-ahead.XXXXXX")"
  remote="$tmp/remote.git"
  repo="$tmp/repo"

  mkdir -p "$tmp/bin" "$tmp/home" "$tmp/state" "$tmp/data" "$tmp/cfg"
  make_fake_openclaw "$tmp/bin/openclaw"

  git -c init.defaultBranch=main init --bare "$remote" >/dev/null
  git -c init.defaultBranch=main init "$repo" >/dev/null
  write_minimal_self_update_tree "$repo" "self-update-base"
  git_commit_all "$repo" "initial"
  git -C "$repo" branch -M main
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -u origin main >/dev/null 2>&1
  remote_head="$(git -C "$repo" rev-parse HEAD)"

  write_minimal_self_update_tree "$repo" "self-update-local"
  git_commit_all "$repo" "local update"
  local_head="$(git -C "$repo" rev-parse HEAD)"

  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
DATA_DIR="$tmp/data"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
AUTO_SELF_UPDATE="true"
SELF_UPDATE_REPO_DIR="$repo"
SELF_UPDATE_REMOTE="origin"
SELF_UPDATE_BRANCH="main"
SELF_UPDATE_POLICY="reset-to-remote"
SELF_UPDATE_RUN_TESTS="false"
SELF_UPDATE_ROLLBACK_ON_FAILURE="true"
SELF_UPDATE_RESTART_GATEWAY="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD="false"
AUTO_REFRESH_STALE_GATEWAY_SERVICE="false"
AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS="false"
AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING="false"
AUTO_RESTART_UNHEALTHY_GATEWAY="false"
AUTO_REMEDIATE_EXPECTED_OPENCLAW_MODEL="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ "$(git -C "$repo" rev-parse HEAD)" == "$local_head" ]] ||
    fail "self-update reset a local checkout that was ahead of upstream"
  "$JQ_BIN" -e --arg current "$local_head" --arg target "$remote_head" '
    .status == "OK"
    and .selfUpdate.attempted == true
    and .selfUpdate.available == false
    and .selfUpdate.applied == false
    and .selfUpdate.from == $current
    and .selfUpdate.to == $target
    and .selfUpdate.summary == "local checkout is ahead of upstream"
    and any(.remediations[]; .code == "openclawnurse_self_update" and .result == "not_needed_local_ahead")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "local-ahead self-update state was not persisted as not needed"

  pass "self-update skips when local checkout is ahead of upstream"
}

smoke_removes_openclaw_related_pm2_apps() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/pm2-openclaw-apps.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$tmp/bin/systemctl"
  cat >"$tmp/bin/pm2" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  jlist)
    cat <<'JSON'
[
  {
    "pm_id": 1,
    "name": "telegram-audio-transcriber",
    "pm2_env": {
      "pm_exec_path": "/srv/telegram-audio-transcriber/index.js",
      "pm_cwd": "/srv/telegram-audio-transcriber"
    }
  },
  {
    "pm_id": 2,
    "name": "legacy-worker",
    "pm2_env": {
      "pm_exec_path": "/home/dev/.npm-global/lib/node_modules/openclaw/dist/index.js",
      "pm_cwd": "/home/dev/.npm-global/lib/node_modules/openclaw",
      "args": ["gateway", "--port", "18789"]
    }
  },
  {
    "pm_id": 3,
    "name": "openclaw-helper",
    "pm2_env": {
      "pm_exec_path": "/opt/tools/helper.js",
      "pm_cwd": "/opt/tools"
    }
  }
]
JSON
    ;;
  delete)
    printf 'delete %s\n' "\${2:-}" >>"$tmp/pm2.log"
    ;;
  save)
    printf 'save\n' >>"$tmp/pm2.log"
    ;;
  *)
    exit 2
    ;;
esac
EOF
  chmod +x "$tmp/bin/pm2"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
AUTO_CLEAN_OPENCLAW_PM2_DAEMONS="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  grep -Fq 'delete 2' "$tmp/pm2.log" ||
    fail "PM2 app with OpenClaw metadata was not deleted by id"
  grep -Fq 'delete 3' "$tmp/pm2.log" ||
    fail "PM2 app with OpenClaw name was not deleted by id"
  ! grep -Fq 'delete 1' "$tmp/pm2.log" ||
    fail "unrelated PM2 app was deleted"
  grep -Fq 'save' "$tmp/pm2.log" ||
    fail "PM2 process list was not saved after OpenClaw app cleanup"
  "$JQ_BIN" -e '
    .status == "OK"
    and any(.remediations[]; .code == "pm2_gateway_legacy" and .result == "applied")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "PM2 OpenClaw app cleanup was not recorded"

  pass "OpenClaw-related PM2 apps are removed while unrelated apps remain"
}

smoke_dry_run_reports_openclaw_pm2_daemon_cleanup() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/pm2-daemon-cleanup.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  make_fake_openclaw "$tmp/bin/openclaw"
  cat >"$tmp/bin/pm2" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  jlist)
    printf '[]\n'
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$tmp/bin/pm2"
  cat >"$tmp/bin/ps" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-eo pid=,args=" ]]; then
  cat <<'PS'
111 PM2 v6.0.14: God Daemon (/home/dev/.pm2)
222 PM2 v6.0.14: God Daemon (/tmp/tmp.example/doctor-defaults.abcd/home/.pm2)
333 PM2 v6.0.14: God Daemon (/tmp/tmp.example/openclaw-runtime/home/.pm2)
PS
else
  /usr/bin/ps "$@"
fi
EOF
  chmod +x "$tmp/bin/ps"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify --dry-run >/dev/null

  "$JQ_BIN" -e '
    .status == "OK"
    and any(.remediations[]; .code == "pm2_openclaw_daemon" and .result == "would_apply")
    and any(.fixes[]; contains("would stop 2 OpenClaw-related PM2 daemon"))
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "OpenClaw-related PM2 daemon cleanup was not reported in dry-run"

  pass "dry-run reports OpenClaw-related PM2 daemon cleanup"
}

smoke_blocks_gateway_restart_when_pm2_daemon_is_in_gateway_cgroup() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/pm2-cgroup-guard.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home/.pm2" "$tmp/proc/4242"
  cat >"$tmp/bin/openclaw" <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in
  --version)
    printf 'OpenClaw 2026.1.0\n'
    ;;
  update)
    case "${2:-}" in
      status)
        printf '{"availability":{"available":true,"latestVersion":"2026.2.0"},"channel":{"value":"stable"}}\n'
        ;;
      *)
        printf '{"ok":true}\n'
        ;;
    esac
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  printf '4242\n' >"$tmp/home/.pm2/pm2.pid"
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/openclaw-gateway.service\n' >"$tmp/proc/4242/cgroup"
  cat >"$tmp/bin/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--user" && "\${2:-}" == "show" ]]; then
  printf '/user.slice/user-1000.slice/user@1000.service/app.slice/openclaw-gateway.service\n'
  exit 0
fi
if [[ "\${1:-}" == "--user" && "\${2:-}" == "restart" ]]; then
  printf 'restart %s\n' "\${3:-}" >>"$tmp/systemctl.log"
  exit 0
fi
exit 0
EOF
  chmod +x "$tmp/bin/systemctl"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
EXTRA_PATH="$tmp/bin"
OPENCLAW_BIN="$tmp/bin/openclaw"
SYSTEMCTL_BIN="$tmp/bin/systemctl"
STATE_DIR="$tmp/state"
PROCFS_DIR="$tmp/proc"
REPORT_CHANNEL="none"
AUTO_UPDATE="true"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_COMMITMENTS_SANITY="false"
ENABLE_SECURITY_AUDIT="false"
ENABLE_PACKAGE_DRIFT_SANITY="false"
ENABLE_DISK_SANITY="false"
ENABLE_CRON_SANITY="false"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD="false"
AUTO_CLEAN_OPENCLAW_PM2_DAEMONS="false"
AUTO_REFRESH_STALE_GATEWAY_SERVICE="false"
AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS="false"
AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING="false"
AUTO_REMEDIATE_EXPECTED_OPENCLAW_MODEL="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  [[ ! -f "$tmp/systemctl.log" ]] ||
    fail "gateway restart was attempted while PM2 daemon was inside gateway cgroup"
  "$JQ_BIN" -e '
    .status == "FAILED"
    and any(.incidentCodes[]; . == "pm2_daemon_in_gateway_cgroup")
    and any(.errors[]; contains("Refusing to restart openclaw-gateway.service"))
    and any(.remediations[]; .code == "gateway_restart" and .result == "blocked_pm2_cgroup")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "PM2 cgroup restart guard was not reported"

  pass "gateway restart is blocked when PM2 daemon is inside gateway cgroup"
}

smoke_accepts_configured_security_warnings() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/security-accepted-warnings.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  cat >"$tmp/bin/openclaw" <<'EOF'
#!/usr/bin/env bash

case "${1:-}" in
  --version)
    printf 'OpenClaw 2026.1.0\n'
    ;;
  update)
    printf '{"availability":{"available":false,"latestVersion":"2026.1.0"},"channel":{"value":"stable"}}\n'
    ;;
  doctor)
    cat <<'DOC'
Doctor warnings
Skills status
Eligible: 18
Missing requirements: 0
Blocked by allowlist: 0
Doctor complete.
DOC
    ;;
  health)
    printf '{"ok":true}\n'
    ;;
  status)
    printf '{"runtimeVersion":"fake","gateway":{"reachable":true},"sessions":{"count":1},"tasks":{},"taskAudit":{}}\n'
    ;;
  security)
    if [[ "${2:-}" == "audit" ]]; then
      cat <<'JSON'
{
  "summary": {"critical": 0, "warn": 1, "info": 0},
  "findings": [
    {
      "checkId": "security.trust_model.multi_user_heuristic",
      "severity": "warn",
      "title": "Potential multi-user setup detected"
    }
  ]
}
JSON
    else
      printf '{}\n'
    fi
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "$tmp/bin/openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/openclaw"
STATE_DIR="$tmp/state"
REPORT_CHANNEL="none"
AUTO_UPDATE="false"
ENABLE_RUNTIME_SANITY="false"
ENABLE_TELEGRAM_SANITY="false"
ENABLE_GATEWAY_LOG_SCAN="false"
ENABLE_SECURITY_AUDIT="true"
SECURITY_AUDIT_ACCEPTED_WARNINGS="security.trust_model.multi_user_heuristic"
CONFIG_BACKUP_ENABLED="false"
RESTART_MODE="custom"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify >/dev/null

  "$JQ_BIN" -e '
    .status == "OK"
    and all(.incidentCodes[]; . != "security_audit_warn" and . != "doctor_warnings")
    and .sanity.securityAuditWarnCount == 0
    and (.sanity.securityAuditSummary | contains("acceptedWarn=1"))
    and (.sanity.doctorWarningSummary == "" or .sanity.doctorWarningSummary == "none")
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "accepted security warning or Missing requirements: 0 handling regressed"

  pass "configured security warnings are accepted without hiding new warnings"
}

main() {
  require_cmd "$JQ_BIN"
  require_cmd git

  smoke_doctor_without_complete_config
  smoke_pending_report_after_notification_failure
  smoke_report_channel_none_skips_delivery
  smoke_light_profile_skips_heavy_maintenance
  smoke_missing_telegram_token_does_not_block_maintenance
  smoke_self_test_uses_openclaw_telegram_token
  smoke_sanity_overrides_updated_status
  smoke_telegram_sanity_uses_implicit_bot_token
  smoke_telegram_sanity_resolves_env_bot_token_from_systemd
  smoke_disabled_high_frequency_cron_is_ignored
  smoke_array_cron_jobs_are_supported
  smoke_model_auth_notice_does_not_degrade
  smoke_commitments_trace_model_access_is_reported
  smoke_commitments_successful_traces_do_not_degrade
  smoke_security_audit_critical_is_reported
  smoke_security_audit_json_with_stderr_preamble_is_accepted
  smoke_telegram_commands_are_remediated
  smoke_config_version_drift_forces_update
  smoke_config_version_drift_update_failure_is_failed
  smoke_openclaw_user_plugin_drift_is_remediated
  smoke_model_config_drift_after_doctor_is_remediated
  smoke_json_preamble_is_accepted
  smoke_update_retry_success_is_not_failed
  smoke_update_selects_compatible_node_runtime
  smoke_update_recovers_after_node_runtime_failure
  smoke_startup_runtime_failure_is_bounded_and_notified
  smoke_cli_failure_is_not_misdiagnosed_as_node
  smoke_runtime_recovery_uses_effective_systemd_execstart
  smoke_update_recovery_preserves_target_engine
  smoke_update_refreshes_relocated_entrypoint
  smoke_gateway_env_file_feeds_openclaw_commands
  smoke_gateway_refresh_failure_skips_restart
  smoke_gateway_log_scan_reports_oom
  smoke_remediates_openclaw_installation_drift
  smoke_default_deduplicates_local_openclaw_shim
  smoke_missing_local_openclaw_bin_is_remediated
  smoke_self_update_applies_valid_upstream
  smoke_self_update_skips_when_local_is_ahead
  smoke_removes_openclaw_related_pm2_apps
  smoke_dry_run_reports_openclaw_pm2_daemon_cleanup
  smoke_blocks_gateway_restart_when_pm2_daemon_is_in_gateway_cgroup
  smoke_accepts_configured_security_warnings
}

main "$@"
