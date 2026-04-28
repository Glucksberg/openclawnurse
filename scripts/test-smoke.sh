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
    printf 'openclaw 1.0.0\n'
    ;;
  update)
    case "${2:-}" in
      status)
        printf '{"availability":{"latestVersion":"1.0.0"},"channel":{"value":"stable"}}\n'
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

smoke_fleet_export_respects_openclaw_config() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/fleet-export.XXXXXX")"

  mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cfg" "$tmp/home"
  make_fake_openclaw "$tmp/bin/fake-openclaw"
  cat >"$tmp/cfg/openclawnurse.env" <<EOF
OPENCLAW_BIN="$tmp/bin/fake-openclaw"
OPENCLAW_PROFILE="ci"
STATE_DIR="$tmp/state"
EOF
  cat >"$tmp/state/doctor-state.json" <<'EOF'
{"timestamp":"now","hostname":"host","status":"OK","currentVersionAfter":"1.0.0","availableVersion":"1.0.0","gatewayHealthy":true,"notificationPending":false,"doctorSummary":"ok","outputs":{"doctor":""}}
EOF

  HOME="$tmp/home" "$ROOT_DIR/scripts/openclaw-fleet-export.sh" \
    --config "$tmp/cfg/openclawnurse.env" \
    --state-file "$tmp/state/doctor-state.json" >"$tmp/feed.json"

  "$JQ_BIN" -e '.openclaw.statusFetchOk == true and .openclaw.snapshot.runtimeVersion == "fake"' "$tmp/feed.json" >/dev/null ||
    fail "fleet export did not use OPENCLAW_BIN/OPENCLAW_PROFILE"

  pass "fleet export uses configured openclaw command"
}

smoke_dashboard_link_safety() {
  local tmp
  tmp="$(mktemp -d "$SMOKE_TMP_ROOT/dashboard.XXXXXX")"

  mkdir -p "$tmp/out"
  cat >"$tmp/fleet-unsafe.json" <<'EOF'
{"fleetName":"Test","nodes":[{"id":"n1","name":"Node","feedUrl":"/missing","dashboardUrl":"javascript:alert(1)\" onclick=\"alert(2)","tags":[]}]}
EOF
  "$ROOT_DIR/scripts/openclaw-fleet-dashboard.sh" --config "$tmp/fleet-unsafe.json" --output-dir "$tmp/out" >/dev/null
  if grep -Fq 'href=' "$tmp/out/index.html"; then
    fail "dashboard rendered href for unsafe URL"
  fi

  cat >"$tmp/fleet-safe.json" <<'EOF'
{"fleetName":"Test","nodes":[{"id":"n1","name":"Node","feedUrl":"/missing","dashboardUrl":"https://example.com/?q=\"x\"&a='b'","tags":[]}]}
EOF
  "$ROOT_DIR/scripts/openclaw-fleet-dashboard.sh" --config "$tmp/fleet-safe.json" --output-dir "$tmp/out" >/dev/null
  grep -Fq 'href="https://example.com/?q=&quot;x&quot;&amp;a=&#39;b&#39;"' "$tmp/out/index.html" ||
    fail "dashboard did not escape safe URL attributes"

  pass "dashboard filters unsafe links and escapes attributes"
}

main() {
  require_cmd "$JQ_BIN"

  smoke_doctor_without_complete_config
  smoke_pending_report_after_notification_failure
  smoke_fleet_export_respects_openclaw_config
  smoke_dashboard_link_safety
}

main "$@"
