#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

INSTALL_DIR="${INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/openclawnurse}"
CONFIG_DIR="${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/openclawnurse}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openclawnurse}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/openclawnurse.env}"
SCHEDULER="${SCHEDULER:-auto}"
ON_CALENDAR="${ON_CALENDAR:-*-*-* 04:30:00}"
CRON_SCHEDULE="${CRON_SCHEDULE:-30 4 * * *}"
ENABLE_TIMER="${ENABLE_TIMER:-true}"
RUN_DRY_RUN="${RUN_DRY_RUN:-true}"

usage() {
  cat <<'EOF'
Usage: install-doctor.sh [options]

Options:
  --install-dir <path>   Override the runtime install directory.
  --config-dir <path>    Override the config directory.
  --state-dir <path>     Override the state directory.
  --scheduler <mode>     auto, systemd or cron.
  --on-calendar <expr>   systemd timer expression.
  --cron-schedule <expr> cron expression used in cron fallback mode.
  --skip-enable          Do not enable the timer or install cron.
  --skip-dry-run         Do not execute the post-install dry run.
  -h, --help             Show this help.
EOF
}

while (($# > 0)); do
  case "$1" in
    --install-dir)
      INSTALL_DIR="${2:?missing value for --install-dir}"
      shift 2
      ;;
    --config-dir)
      CONFIG_DIR="${2:?missing value for --config-dir}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:?missing value for --state-dir}"
      shift 2
      ;;
    --scheduler)
      SCHEDULER="${2:?missing value for --scheduler}"
      shift 2
      ;;
    --on-calendar)
      ON_CALENDAR="${2:?missing value for --on-calendar}"
      shift 2
      ;;
    --cron-schedule)
      CRON_SCHEDULE="${2:?missing value for --cron-schedule}"
      shift 2
      ;;
    --skip-enable)
      ENABLE_TIMER="false"
      shift
      ;;
    --skip-dry-run)
      RUN_DRY_RUN="false"
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

log() {
  printf '[install] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

detect_scheduler() {
  if [[ "$SCHEDULER" != "auto" ]]; then
    printf '%s' "$SCHEDULER"
    return
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    printf 'systemd'
  else
    printf 'cron'
  fi
}

detect_telegram_target() {
  local cron_jobs="${OPENCLAW_STATE_HOME:-$HOME/.openclaw}/cron/jobs.json"
  if [[ -f "$cron_jobs" ]]; then
    jq -r '.jobs[]? | .delivery.to // empty' "$cron_jobs" 2>/dev/null | head -n 1
  fi
}

ensure_config_file() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/systemd"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    local detected_target
    detected_target="$(detect_telegram_target || true)"
    cp "$REPO_ROOT/config/openclaw-doctor.env.example" "$CONFIG_FILE"
    if [[ -n "$detected_target" ]]; then
      sed -i 's/^TELEGRAM_TARGET=""/TELEGRAM_TARGET="'"$detected_target"'"/' "$CONFIG_FILE"
      log "Detected TELEGRAM_TARGET=$detected_target"
    fi
    printf '\nCONFIG_DIR="%s"\nSTATE_DIR="%s"\nLOG_DIR="%s/logs"\n' \
      "$CONFIG_DIR" "$STATE_DIR" "$STATE_DIR" >>"$CONFIG_FILE"
    log "Created config file at $CONFIG_FILE"
  else
    log "Config file already exists at $CONFIG_FILE"
  fi
}

install_runtime_files() {
  install -m 0755 "$REPO_ROOT/scripts/openclaw-doctor.sh" "$INSTALL_DIR/bin/openclaw-doctor.sh"
  install -m 0644 "$REPO_ROOT/systemd/openclawnurse.service" "$INSTALL_DIR/systemd/openclawnurse.service.template"
  install -m 0644 "$REPO_ROOT/systemd/openclawnurse.timer" "$INSTALL_DIR/systemd/openclawnurse.timer.template"
}

render_systemd_units() {
  mkdir -p "$SYSTEMD_USER_DIR"
  sed \
    -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
    -e "s|__CONFIG_FILE__|$CONFIG_FILE|g" \
    "$REPO_ROOT/systemd/openclawnurse.service" >"$SYSTEMD_USER_DIR/openclawnurse.service"

  sed \
    -e "s|__ON_CALENDAR__|$ON_CALENDAR|g" \
    "$REPO_ROOT/systemd/openclawnurse.timer" >"$SYSTEMD_USER_DIR/openclawnurse.timer"
}

enable_systemd_timer() {
  systemctl --user daemon-reload
  if [[ "$ENABLE_TIMER" == "true" ]]; then
    systemctl --user enable --now openclawnurse.timer
    log "Enabled systemd timer openclawnurse.timer"
  else
    log "Skipped enabling systemd timer"
  fi
}

install_cron_job() {
  local cron_line="$CRON_SCHEDULE $INSTALL_DIR/bin/openclaw-doctor.sh --config $CONFIG_FILE >> $STATE_DIR/logs/cron.log 2>&1"
  mkdir -p "$STATE_DIR/logs"
  local current
  current="$(crontab -l 2>/dev/null || true)"
  if ! printf '%s\n' "$current" | grep -Fq "$INSTALL_DIR/bin/openclaw-doctor.sh"; then
    {
      printf '%s\n' "$current"
      printf '%s\n' "$cron_line"
    } | crontab -
    log "Installed cron entry"
  else
    log "Cron entry already present"
  fi
}

run_validation() {
  if [[ "$RUN_DRY_RUN" == "true" ]]; then
    log "Running post-install dry run"
    "$INSTALL_DIR/bin/openclaw-doctor.sh" --config "$CONFIG_FILE" --dry-run --no-notify
  fi
}

main() {
  require_cmd jq
  require_cmd install
  require_cmd sed

  local resolved_scheduler
  resolved_scheduler="$(detect_scheduler)"
  log "Installing OpenClawNurse with scheduler=$resolved_scheduler"

  ensure_config_file
  install_runtime_files

  case "$resolved_scheduler" in
    systemd)
      render_systemd_units
      enable_systemd_timer
      ;;
    cron)
      require_cmd crontab
      if [[ "$ENABLE_TIMER" == "true" ]]; then
        install_cron_job
      else
        log "Skipped cron installation"
      fi
      ;;
    *)
      echo "Unsupported scheduler mode: $resolved_scheduler" >&2
      exit 1
      ;;
  esac

  run_validation

  log "Install complete"
  log "Runtime directory: $INSTALL_DIR"
  log "Config file: $CONFIG_FILE"
  log "State directory: $STATE_DIR"
}

main "$@"
