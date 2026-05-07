#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
JQ_BIN="${JQ_BIN:-jq}"
SMOKE_TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$SMOKE_TMP_ROOT"' EXIT

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
CONFIG_BACKUP_ENABLED="false"
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-doctor.sh" --config "$tmp/cfg/openclawnurse.env" --no-notify --dry-run >/dev/null

  "$JQ_BIN" -e '.status == "FAILED" and any(.incidentCodes[]; . == "security_audit_critical") and .sanity.securityAuditCriticalCount == 1' \
    "$tmp/state/doctor-state.json" >/dev/null ||
    fail "security audit critical finding was not reported"

  pass "security audit critical findings are reported"
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
        "primary": "openai/gpt-5.5",
        "fallbacks": [
          "claude-cli/claude-opus-4-6"
        ]
      },
      "models": {
        "claude-cli/claude-opus-4-6": {
          "alias": "opus"
        },
        "openai/gpt-5.4": {},
        "openai/gpt-5.5": {}
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
    .agents.defaults.model.primary == "openai-codex/gpt-5.5"
    and (.agents.defaults.agentRuntime | not)
    and (.agents.defaults.models | has("openai-codex/gpt-5.5"))
    and (.agents.defaults.models | has("openai/gpt-5.5") | not)
  ' "$tmp/home/.openclaw/openclaw.json" >/dev/null ||
    fail "OpenClaw model config drift was not repaired after doctor"
  grep -Fq 'restarted' "$tmp/restarts" ||
    fail "model config remediation did not restart the gateway"
  "$JQ_BIN" -e '
    .status == "OK"
    and .restartAttempted == true
    and .gatewayHealthy == true
    and any(.incidentCodes[]; . == "openclaw_model_config_drift")
    and any(.remediations[]; .code == "openclaw_model_config_drift" and .result == "applied")
    and .sanity.expectedOpenclawModel == "openai-codex/gpt-5.5"
  ' "$tmp/state/doctor-state.json" >/dev/null ||
    fail "model config drift remediation was not recorded cleanly"

  pass "model config drift after doctor is remediated"
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

main() {
  require_cmd "$JQ_BIN"

  smoke_doctor_without_complete_config
  smoke_pending_report_after_notification_failure
  smoke_report_channel_none_skips_delivery
  smoke_missing_telegram_token_does_not_block_maintenance
  smoke_self_test_uses_openclaw_telegram_token
  smoke_sanity_overrides_updated_status
  smoke_telegram_sanity_uses_implicit_bot_token
  smoke_commitments_trace_model_access_is_reported
  smoke_security_audit_critical_is_reported
  smoke_telegram_commands_are_remediated
  smoke_config_version_drift_forces_update
  smoke_config_version_drift_update_failure_is_failed
  smoke_model_config_drift_after_doctor_is_remediated
  smoke_json_preamble_is_accepted
  smoke_update_retry_success_is_not_failed
  smoke_remediates_openclaw_installation_drift
  smoke_default_deduplicates_local_openclaw_shim
}

main "$@"
