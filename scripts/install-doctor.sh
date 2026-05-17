#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

INSTALL_DIR="${INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/openclawnurse}"
CONFIG_DIR="${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/openclawnurse}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openclawnurse}"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-$HOME/.local/bin}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/openclawnurse.env}"
SCHEDULER="${SCHEDULER:-auto}"
ON_CALENDAR="${ON_CALENDAR:-*-*-* 04:30:00}"
CRON_SCHEDULE="${CRON_SCHEDULE:-30 4 * * *}"
ENABLE_TIMER="${ENABLE_TIMER:-true}"
RUN_DRY_RUN="${RUN_DRY_RUN:-true}"
CONFIGURE_OPENCLAW_ALERT="${CONFIGURE_OPENCLAW_ALERT:-auto}"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
OPENCLAW_ALERT_TARGET="${OPENCLAW_ALERT_TARGET:-}"
OPENCLAW_ALERT_THREAD_ID="${OPENCLAW_ALERT_THREAD_ID:-}"
OPENCLAW_ALERT_AGENT_ID="${OPENCLAW_ALERT_AGENT_ID:-}"
OPENCLAW_ALERT_EVERY="${OPENCLAW_ALERT_EVERY:-}"
OPENCLAW_ALERT_CRON="${OPENCLAW_ALERT_CRON:-}"
OPENCLAW_ALERT_TZ="${OPENCLAW_ALERT_TZ:-}"
OPENCLAW_ALERT_JOB_NAME="${OPENCLAW_ALERT_JOB_NAME:-openclawnurse-alert}"
OPENCLAW_ALERT_JOB_DESCRIPTION="${OPENCLAW_ALERT_JOB_DESCRIPTION:-Alerta OpenClawNurse quando doctor-state registra incidente ou atividade}"
CLI_OPENCLAW_BIN=""
CLI_OPENCLAW_ALERT_TARGET=""
CLI_OPENCLAW_ALERT_THREAD_ID=""
CLI_OPENCLAW_ALERT_AGENT_ID=""
CLI_OPENCLAW_ALERT_EVERY=""
CLI_OPENCLAW_ALERT_CRON=""
CLI_OPENCLAW_ALERT_TZ=""

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
  --configure-openclaw-alert
                         Configure .env and OpenClaw cron alert job.
  --no-configure-openclaw-alert
                         Skip OpenClaw alert configuration.
  --openclaw-bin <path>  OpenClaw CLI used by the alert script/cron setup.
  --openclaw-alert-target <id>
                         Telegram group/chat id used by OpenClaw alerts.
  --openclaw-alert-thread-id <id>
                         Optional Telegram forum topic id for alerts.
  --openclaw-alert-agent <id>
                         Agent id used by the OpenClaw cron job.
  --openclaw-alert-every <duration>
                         Alert cron interval, e.g. 12h.
  --openclaw-alert-cron <expr>
                         Alert cron expression, e.g. "0 11,21 * * *".
  --openclaw-alert-tz <iana>
                         Timezone for --openclaw-alert-cron, e.g. UTC.
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
    --configure-openclaw-alert)
      CONFIGURE_OPENCLAW_ALERT="true"
      shift
      ;;
    --no-configure-openclaw-alert)
      CONFIGURE_OPENCLAW_ALERT="false"
      shift
      ;;
    --openclaw-bin)
      OPENCLAW_BIN="${2:?missing value for --openclaw-bin}"
      CLI_OPENCLAW_BIN="$OPENCLAW_BIN"
      shift 2
      ;;
    --openclaw-alert-target)
      OPENCLAW_ALERT_TARGET="${2:?missing value for --openclaw-alert-target}"
      CLI_OPENCLAW_ALERT_TARGET="$OPENCLAW_ALERT_TARGET"
      shift 2
      ;;
    --openclaw-alert-thread-id)
      OPENCLAW_ALERT_THREAD_ID="${2:?missing value for --openclaw-alert-thread-id}"
      CLI_OPENCLAW_ALERT_THREAD_ID="$OPENCLAW_ALERT_THREAD_ID"
      shift 2
      ;;
    --openclaw-alert-agent)
      OPENCLAW_ALERT_AGENT_ID="${2:?missing value for --openclaw-alert-agent}"
      CLI_OPENCLAW_ALERT_AGENT_ID="$OPENCLAW_ALERT_AGENT_ID"
      shift 2
      ;;
    --openclaw-alert-every)
      OPENCLAW_ALERT_EVERY="${2:?missing value for --openclaw-alert-every}"
      CLI_OPENCLAW_ALERT_EVERY="$OPENCLAW_ALERT_EVERY"
      shift 2
      ;;
    --openclaw-alert-cron)
      OPENCLAW_ALERT_CRON="${2:?missing value for --openclaw-alert-cron}"
      CLI_OPENCLAW_ALERT_CRON="$OPENCLAW_ALERT_CRON"
      shift 2
      ;;
    --openclaw-alert-tz)
      OPENCLAW_ALERT_TZ="${2:?missing value for --openclaw-alert-tz}"
      CLI_OPENCLAW_ALERT_TZ="$OPENCLAW_ALERT_TZ"
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

log() {
  printf '[install] %s\n' "$*"
}

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

env_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local quoted
  quoted="$(env_quote "$value")"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  touch "$CONFIG_FILE"
  if grep -Eq "^${key}=" "$CONFIG_FILE"; then
    sed -i "s|^${key}=.*|${key}=${quoted}|" "$CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$quoted" >>"$CONFIG_FILE"
  fi
}

set_env_default() {
  local key="$1"
  local value="$2"
  if ! grep -Eq "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    set_env_value "$key" "$value"
  fi
}

confirm_prompt() {
  local prompt="$1"
  local default="${2:-yes}"
  local suffix answer
  if [[ "$default" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  printf '%s %s ' "$prompt" "$suffix" >&2
  read -r answer
  case "$answer" in
    "" )
      [[ "$default" == "yes" ]]
      ;;
    y|Y|yes|YES|sim|SIM|s|S)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

input_prompt() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  read -r answer
  if [[ -n "$answer" ]]; then
    printf '%s' "$answer"
  else
    printf '%s' "$default"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

openclaw_config_path() {
  printf '%s/openclaw.json' "${OPENCLAW_STATE_HOME:-$HOME/.openclaw}"
}

detect_openclaw_bin() {
  if [[ "$OPENCLAW_BIN" != "openclaw" ]]; then
    printf '%s' "$OPENCLAW_BIN"
    return 0
  fi
  if [[ -x "$HOME/openclaw/node_modules/.bin/openclaw" ]]; then
    printf '%s' "$HOME/openclaw/node_modules/.bin/openclaw"
    return 0
  fi
  command -v openclaw 2>/dev/null || printf 'openclaw'
}

detect_openclaw_alert_target() {
  local cfg
  cfg="$(openclaw_config_path)"
  [[ -f "$cfg" ]] || return 0
  jq -r '.channels.telegram.groups // {} | keys[0] // empty' "$cfg" 2>/dev/null
}

detect_openclaw_alert_thread_id() {
  local target="$1"
  local cfg
  cfg="$(openclaw_config_path)"
  [[ -n "$target" && -f "$cfg" ]] || return 0
  jq -r --arg target "$target" '
    (.channels.telegram.groups[$target].topics // {})
    | to_entries
    | map(select((.value.agentId // "") == "automacoes" or ((.value.systemPrompt // "") | test("autom"; "i"))))
    | .[0].key // empty
  ' "$cfg" 2>/dev/null
}

detect_openclaw_alert_agent_id() {
  local target="$1"
  local thread_id="$2"
  local cfg
  cfg="$(openclaw_config_path)"
  if [[ -n "$target" && -n "$thread_id" && -f "$cfg" ]]; then
    local topic_agent
    topic_agent="$(jq -r --arg target "$target" --arg thread "$thread_id" '.channels.telegram.groups[$target].topics[$thread].agentId // empty' "$cfg" 2>/dev/null)"
    [[ -n "$topic_agent" ]] && {
      printf '%s' "$topic_agent"
      return 0
    }
  fi
  if [[ -f "$cfg" ]] && jq -e '.agents.list[]? | select(.id == "automacoes")' "$cfg" >/dev/null 2>&1; then
    printf 'automacoes'
  else
    printf 'main'
  fi
}

apply_cli_overrides() {
  [[ -n "$CLI_OPENCLAW_BIN" ]] && OPENCLAW_BIN="$CLI_OPENCLAW_BIN"
  [[ -n "$CLI_OPENCLAW_ALERT_TARGET" ]] && OPENCLAW_ALERT_TARGET="$CLI_OPENCLAW_ALERT_TARGET"
  [[ -n "$CLI_OPENCLAW_ALERT_THREAD_ID" ]] && OPENCLAW_ALERT_THREAD_ID="$CLI_OPENCLAW_ALERT_THREAD_ID"
  [[ -n "$CLI_OPENCLAW_ALERT_AGENT_ID" ]] && OPENCLAW_ALERT_AGENT_ID="$CLI_OPENCLAW_ALERT_AGENT_ID"
  [[ -n "$CLI_OPENCLAW_ALERT_EVERY" ]] && OPENCLAW_ALERT_EVERY="$CLI_OPENCLAW_ALERT_EVERY"
  [[ -n "$CLI_OPENCLAW_ALERT_CRON" ]] && OPENCLAW_ALERT_CRON="$CLI_OPENCLAW_ALERT_CRON"
  [[ -n "$CLI_OPENCLAW_ALERT_TZ" ]] && OPENCLAW_ALERT_TZ="$CLI_OPENCLAW_ALERT_TZ"
  return 0
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
  mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/systemd" "$INSTALL_DIR/config-examples"

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
  install -m 0755 "$REPO_ROOT/scripts/openclawnurse-openclaw-alert.sh" "$INSTALL_DIR/bin/openclawnurse-openclaw-alert.sh"
  install -m 0644 "$REPO_ROOT/systemd/openclawnurse.service" "$INSTALL_DIR/systemd/openclawnurse.service.template"
  install -m 0644 "$REPO_ROOT/systemd/openclawnurse.timer" "$INSTALL_DIR/systemd/openclawnurse.timer.template"
}

configure_self_update_env() {
  set_env_value SELF_UPDATE_REPO_DIR "$REPO_ROOT"
  set_env_default AUTO_SELF_UPDATE "true"
  set_env_default SELF_UPDATE_REMOTE "origin"
  set_env_default SELF_UPDATE_BRANCH "main"
  set_env_default SELF_UPDATE_POLICY "reset-to-remote"
  set_env_default SELF_UPDATE_TIMEOUT "300"
  set_env_default SELF_UPDATE_RUN_TESTS "true"
  set_env_default SELF_UPDATE_ROLLBACK_ON_FAILURE "true"
  set_env_default SELF_UPDATE_RESTART_GATEWAY "false"
  set_env_default SELF_UPDATE_POST_SELF_TEST "false"
}

install_cli_wrapper() {
  mkdir -p "$LOCAL_BIN_DIR"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec %q --config %q "$@"\n' "$INSTALL_DIR/bin/openclaw-doctor.sh" "$CONFIG_FILE"
  } >"$LOCAL_BIN_DIR/openclawnurse"
  chmod 0755 "$LOCAL_BIN_DIR/openclawnurse"
  log "Installed CLI wrapper at $LOCAL_BIN_DIR/openclawnurse"
}

should_configure_openclaw_alert() {
  case "$CONFIGURE_OPENCLAW_ALERT" in
    true) return 0 ;;
    false) return 1 ;;
    auto)
      [[ -t 0 && -t 1 ]] || return 1
      if [[ -n "${OPENCLAW_ALERT_TARGET:-}" ]]; then
        return 0
      fi
      if grep -Eq '^OPENCLAW_ALERT_TARGET="[^"]+"' "$CONFIG_FILE" 2>/dev/null; then
        return 1
      fi
      confirm_prompt "Configure OpenClaw Telegram alerts for this Nurse install?" "yes"
      ;;
    *)
      echo "Unsupported CONFIGURE_OPENCLAW_ALERT=$CONFIGURE_OPENCLAW_ALERT" >&2
      exit 1
      ;;
  esac
}

configure_openclaw_alert_env() {
  if ! should_configure_openclaw_alert; then
    log "Skipped OpenClaw alert configuration"
    return 0
  fi

  local detected_bin detected_target detected_thread detected_agent target thread_id agent_id every cron_expr cron_tz
  detected_bin="$(detect_openclaw_bin)"
  detected_target="${OPENCLAW_ALERT_TARGET:-$(detect_openclaw_alert_target || true)}"
  detected_thread="${OPENCLAW_ALERT_THREAD_ID:-$(detect_openclaw_alert_thread_id "$detected_target" || true)}"
  detected_agent="${OPENCLAW_ALERT_AGENT_ID:-$(detect_openclaw_alert_agent_id "$detected_target" "$detected_thread" || true)}"

  if [[ -t 0 && -t 1 && "$CONFIGURE_OPENCLAW_ALERT" != "false" ]]; then
    OPENCLAW_BIN="$(input_prompt "OpenClaw CLI path" "$detected_bin")"
    target="$(input_prompt "Telegram group/chat id for OpenClaw alert" "$detected_target")"
    thread_id="$(input_prompt "Telegram topic/thread id for alert (blank for main group)" "$detected_thread")"
    agent_id="$(input_prompt "OpenClaw agent id for alert cron job" "${detected_agent:-main}")"
    every="$(input_prompt "OpenClaw alert interval fallback (blank when using cron expression)" "$OPENCLAW_ALERT_EVERY")"
    cron_expr="$(input_prompt "OpenClaw alert cron expression (blank to use interval)" "$OPENCLAW_ALERT_CRON")"
    cron_tz="$(input_prompt "OpenClaw alert cron timezone" "$OPENCLAW_ALERT_TZ")"
  else
    OPENCLAW_BIN="$detected_bin"
    target="$detected_target"
    thread_id="$detected_thread"
    agent_id="${detected_agent:-main}"
    every="$OPENCLAW_ALERT_EVERY"
    cron_expr="$OPENCLAW_ALERT_CRON"
    cron_tz="$OPENCLAW_ALERT_TZ"
  fi

  if [[ -z "$target" ]]; then
    log "OpenClaw alert target is empty; .env was not configured for alert delivery"
    return 0
  fi

  OPENCLAW_ALERT_TARGET="$target"
  OPENCLAW_ALERT_THREAD_ID="$thread_id"
  OPENCLAW_ALERT_AGENT_ID="$agent_id"
  OPENCLAW_ALERT_EVERY="$every"
  OPENCLAW_ALERT_CRON="$cron_expr"
  OPENCLAW_ALERT_TZ="$cron_tz"
  if [[ -n "$OPENCLAW_ALERT_CRON" ]]; then
    OPENCLAW_ALERT_EVERY=""
  elif [[ -z "$OPENCLAW_ALERT_EVERY" ]]; then
    OPENCLAW_ALERT_EVERY="12h"
  fi

  set_env_value OPENCLAW_BIN "$OPENCLAW_BIN"
  set_env_value REPORT_CHANNEL "none"
  set_env_value OPENCLAW_ALERT_CHANNEL "telegram"
  set_env_value OPENCLAW_ALERT_TARGET "$OPENCLAW_ALERT_TARGET"
  set_env_value OPENCLAW_ALERT_THREAD_ID "$OPENCLAW_ALERT_THREAD_ID"
  set_env_value OPENCLAW_ALERT_AGENT_ID "$OPENCLAW_ALERT_AGENT_ID"
  set_env_value OPENCLAW_ALERT_EVERY "$OPENCLAW_ALERT_EVERY"
  set_env_value OPENCLAW_ALERT_CRON "$OPENCLAW_ALERT_CRON"
  set_env_value OPENCLAW_ALERT_TZ "$OPENCLAW_ALERT_TZ"
  set_env_value OPENCLAW_ALERT_JOB_NAME "$OPENCLAW_ALERT_JOB_NAME"
  set_env_value OPENCLAW_ALERT_JOB_DESCRIPTION "$OPENCLAW_ALERT_JOB_DESCRIPTION"
  set_env_value OPENCLAW_ALERT_MIN_INTERVAL_SECONDS "${OPENCLAW_ALERT_MIN_INTERVAL_SECONDS:-21600}"
  set_env_value OPENCLAW_ALERT_RECOVERY "${OPENCLAW_ALERT_RECOVERY:-true}"
  log "Configured OpenClaw alert target=$OPENCLAW_ALERT_TARGET thread=${OPENCLAW_ALERT_THREAD_ID:-main} agent=$OPENCLAW_ALERT_AGENT_ID"
}

openclaw_cron_job_message() {
  printf 'Tarefa automatica de alerta do OpenClawNurse. Execute exatamente este comando: %s/bin/openclawnurse-openclaw-alert.sh --config %s . Nao envie mensagens por conta propria; o script ja envia alerta para o destino configurado quando necessario. No final, responda apenas com uma linha curta indicando o resultado do comando.' "$INSTALL_DIR" "$CONFIG_FILE"
}

openclaw_alert_failure_target() {
  if [[ -n "${OPENCLAW_ALERT_THREAD_ID:-}" && "$OPENCLAW_ALERT_TARGET" != *":topic:"* ]]; then
    printf '%s:topic:%s' "$OPENCLAW_ALERT_TARGET" "$OPENCLAW_ALERT_THREAD_ID"
  else
    printf '%s' "$OPENCLAW_ALERT_TARGET"
  fi
}

ensure_openclaw_alert_cron_job() {
  [[ -n "${OPENCLAW_ALERT_TARGET:-}" ]] || return 0
  [[ -n "${OPENCLAW_ALERT_AGENT_ID:-}" ]] || OPENCLAW_ALERT_AGENT_ID="main"
  if [[ -z "${OPENCLAW_ALERT_CRON:-}" && -z "${OPENCLAW_ALERT_EVERY:-}" ]]; then
    OPENCLAW_ALERT_EVERY="12h"
  fi

  local openclaw_cmd=("$OPENCLAW_BIN")
  if [[ "$OPENCLAW_BIN" != */* ]] && ! command -v "$OPENCLAW_BIN" >/dev/null 2>&1; then
    log "OpenClaw CLI not found; skipping OpenClaw cron alert setup"
    return 0
  fi
  if [[ "$OPENCLAW_BIN" == */* && ! -x "$OPENCLAW_BIN" ]]; then
    log "OpenClaw CLI is not executable at $OPENCLAW_BIN; skipping OpenClaw cron alert setup"
    return 0
  fi

  local existing_json existing_id message output status failure_target
  message="$(openclaw_cron_job_message)"
  failure_target="$(openclaw_alert_failure_target)"
  set +e
  existing_json="$("${openclaw_cmd[@]}" cron list --json 2>/dev/null)"
  status=$?
  set -e
  if [[ "$status" -ne 0 ]] || ! printf '%s' "$existing_json" | jq empty >/dev/null 2>&1; then
    log "Could not list OpenClaw cron jobs; skipping alert cron setup. Run the installer again after approving/repairing OpenClaw CLI scopes."
    return 0
  fi

  existing_id="$(printf '%s' "$existing_json" | jq -r --arg name "$OPENCLAW_ALERT_JOB_NAME" '.jobs[]? | select(.name == $name) | .id' | head -n 1)"
  local cron_args=(--name "$OPENCLAW_ALERT_JOB_NAME" --description "$OPENCLAW_ALERT_JOB_DESCRIPTION" --agent "$OPENCLAW_ALERT_AGENT_ID" --session isolated --light-context --tools exec --timeout-seconds 120 --message "$message" --channel telegram --to "$OPENCLAW_ALERT_TARGET" --no-deliver)
  if [[ -n "${OPENCLAW_ALERT_CRON:-}" ]]; then
    cron_args+=(--cron "$OPENCLAW_ALERT_CRON")
    if [[ -n "${OPENCLAW_ALERT_TZ:-}" ]]; then
      cron_args+=(--tz "$OPENCLAW_ALERT_TZ")
    fi
  else
    cron_args+=(--every "$OPENCLAW_ALERT_EVERY")
  fi
  if [[ -n "${OPENCLAW_ALERT_THREAD_ID:-}" ]]; then
    cron_args+=(--thread-id "$OPENCLAW_ALERT_THREAD_ID")
  fi

  set +e
  if [[ -n "$existing_id" ]]; then
    output="$("${openclaw_cmd[@]}" cron edit "$existing_id" "${cron_args[@]}" --failure-alert --failure-alert-mode announce --failure-alert-channel telegram --failure-alert-to "$failure_target" --failure-alert-after 1 --failure-alert-cooldown 6h 2>&1)"
    status=$?
  else
    output="$("${openclaw_cmd[@]}" cron add --json "${cron_args[@]}" 2>&1)"
    status=$?
    if [[ "$status" -eq 0 ]]; then
      existing_id="$(printf '%s' "$output" | jq -r '.id // empty' 2>/dev/null)"
      if [[ -n "$existing_id" ]]; then
        "${openclaw_cmd[@]}" cron edit "$existing_id" --failure-alert --failure-alert-mode announce --failure-alert-channel telegram --failure-alert-to "$failure_target" --failure-alert-after 1 --failure-alert-cooldown 6h >/dev/null 2>&1 || true
      fi
    fi
  fi
  set -e

  if [[ "$status" -ne 0 ]]; then
    log "OpenClaw alert cron setup failed; leaving .env configured. Output: $output"
    return 0
  fi

  if [[ -n "$existing_id" ]]; then
    log "OpenClaw alert cron job ready: $existing_id"
  else
    log "OpenClaw alert cron job ready"
  fi
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
  local script_path config_path cron_log
  script_path="$(shell_quote "$INSTALL_DIR/bin/openclaw-doctor.sh")"
  config_path="$(shell_quote "$CONFIG_FILE")"
  cron_log="$(shell_quote "$STATE_DIR/logs/cron.log")"
  local cron_line="$CRON_SCHEDULE $script_path --config $config_path >> $cron_log 2>&1"
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
    local status

    log "Running post-install self-test"
    set +e
    "$INSTALL_DIR/bin/openclaw-doctor.sh" --config "$CONFIG_FILE" --self-test --no-notify
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
      if [[ "$status" -eq 75 ]]; then
        log "Self-test skipped because another run is holding the lock"
      else
        return "$status"
      fi
    fi
    log "Running post-install dry run"
    set +e
    "$INSTALL_DIR/bin/openclaw-doctor.sh" --config "$CONFIG_FILE" --dry-run --no-notify
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
      if [[ "$status" -eq 75 ]]; then
        log "Dry run skipped because another run is holding the lock"
      else
        return "$status"
      fi
    fi
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
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  apply_cli_overrides
  install_runtime_files
  configure_self_update_env
  install_cli_wrapper
  configure_openclaw_alert_env
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  apply_cli_overrides

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

  ensure_openclaw_alert_cron_job

  run_validation

  log "Install complete"
  log "Runtime directory: $INSTALL_DIR"
  log "Config file: $CONFIG_FILE"
  log "State directory: $STATE_DIR"
}

main "$@"
