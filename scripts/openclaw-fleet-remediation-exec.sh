#!/usr/bin/env bash

set -euo pipefail

DEFAULT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/openclawnurse"
DEFAULT_INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/openclawnurse"
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/openclawnurse"

PLAN_FILE=""
OUTPUT_FILE=""
EXECUTE=0
NODE_ID="${FLEET_REMEDIATION_NODE_ID:-${HOSTNAME:-$(hostname)}}"
CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_DIR/openclawnurse.env}"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
STATE_DIR="${STATE_DIR:-$DEFAULT_STATE_DIR}"
ACTION_TIMEOUT="${FLEET_REMEDIATION_ACTION_TIMEOUT:-900}"

usage() {
  cat <<'EOF'
Usage: openclaw-fleet-remediation-exec.sh --plan <path> [options]

Options:
  --plan <path>       remediation-plan.json from openclaw-fleet-remediation-plan.sh.
  --node-id <id>      Execute only incidents for this node id. Defaults to hostname.
  --config <path>     OpenClawNurse env file used by local commands.
  --install-dir <p>   OpenClawNurse runtime install directory.
  --state-dir <p>     OpenClawNurse state directory.
  --execute           Execute eligible actions. Without this, only report dry-run actions.
  --output <path>     Write execution report JSON.
  -h, --help          Show this help.
EOF
}

while (($# > 0)); do
  case "$1" in
    --plan)
      PLAN_FILE="${2:?missing value for --plan}"
      shift 2
      ;;
    --node-id)
      NODE_ID="${2:?missing value for --node-id}"
      shift 2
      ;;
    --config)
      CONFIG_FILE="${2:?missing value for --config}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:?missing value for --install-dir}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:?missing value for --state-dir}"
      shift 2
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --output)
      OUTPUT_FILE="${2:?missing value for --output}"
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

if [[ -z "$PLAN_FILE" ]]; then
  usage >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  echo "Missing required command: jq" >&2
  exit 1
}

command -v timeout >/dev/null 2>&1 || {
  echo "Missing required command: timeout" >&2
  exit 1
}

[[ -f "$PLAN_FILE" ]] || {
  echo "Missing plan file: $PLAN_FILE" >&2
  exit 1
}

jq empty "$PLAN_FILE" >/dev/null 2>&1 || {
  echo "Invalid JSON plan file: $PLAN_FILE" >&2
  exit 1
}

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

shell_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

is_forbidden_command() {
  local command_string="$1"
  local pattern
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if [[ "$command_string" == *"$pattern"* ]]; then
      return 0
    fi
  done < <(jq -r '.policy.forbiddenPatterns[]? // empty' "$PLAN_FILE")
  return 1
}

safe_command_for_action() {
  local action="$1"
  case "$action" in
    run_nurse_now)
      printf '%s --config %s --no-notify' \
        "$(shell_quote "$INSTALL_DIR/bin/openclaw-doctor.sh")" \
        "$(shell_quote "$CONFIG_FILE")"
      ;;
    replay_notification)
      printf '%s --config %s --retry-pending' \
        "$(shell_quote "$INSTALL_DIR/bin/openclaw-doctor.sh")" \
        "$(shell_quote "$CONFIG_FILE")"
      ;;
    restart_gateway)
      if [[ -n "${RESTART_COMMAND:-}" ]]; then
        printf '%s' "$RESTART_COMMAND"
      elif [[ "${RESTART_MODE:-systemd_user}" == "systemd_user" ]]; then
        printf 'systemctl --user restart %s' "$(shell_quote "${SYSTEMD_UNIT_NAME:-openclaw-gateway.service}")"
      else
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

run_action() {
  local command_string="$1"
  local output status
  set +e
  output="$(timeout "${ACTION_TIMEOUT}s" bash -lc "$command_string" 2>&1)"
  status=$?
  set -e
  jq -n \
    --arg output "$output" \
    --argjson exitCode "$status" \
    '{exitCode: $exitCode, output: $output}'
}

policy_mode="$(jq -r '.policy.mode // "advisory"' "$PLAN_FILE")"
max_auto_actions="$(jq -r '.policy.maxAutoActionsPerRun // 0' "$PLAN_FILE")"
max_nodes="$(jq -r '.policy.maxNodesPerRun // 0' "$PLAN_FILE")"
[[ "$max_auto_actions" =~ ^[0-9]+$ ]] || max_auto_actions=0
[[ "$max_nodes" =~ ^[0-9]+$ ]] || max_nodes=0

executed_actions=0
seen_nodes=()
results_file="$(mktemp)"
trap 'rm -f "$results_file"' EXIT

node_seen() {
  local node="$1"
  local seen
  for seen in "${seen_nodes[@]}"; do
    [[ "$seen" == "$node" ]] && return 0
  done
  return 1
}

while IFS= read -r incident; do
  [[ -n "$incident" ]] || continue

  incident_node_id="$(printf '%s' "$incident" | jq -r '.nodeId // empty')"
  action="$(printf '%s' "$incident" | jq -r '.suggestedAction // empty')"
  category="$(printf '%s' "$incident" | jq -r '.category // empty')"
  auto_eligible="$(printf '%s' "$incident" | jq -r 'if has("autoEligible") then .autoEligible else false end')"
  requires_human="$(printf '%s' "$incident" | jq -r 'if has("requiresHumanApproval") then .requiresHumanApproval else true end')"

  result="skipped"
  reason=""
  command_string=""
  exit_code="null"
  command_output=""

  if [[ "$incident_node_id" != "$NODE_ID" ]]; then
    reason="node_mismatch"
  elif [[ "$auto_eligible" != "true" || "$requires_human" == "true" ]]; then
    reason="not_auto_eligible"
  elif (( max_auto_actions <= 0 )); then
    reason="max_auto_actions_zero"
  elif (( max_nodes <= 0 )); then
    reason="max_nodes_zero"
  elif (( max_auto_actions > 0 && executed_actions >= max_auto_actions )); then
    reason="max_auto_actions_reached"
  elif ! node_seen "$incident_node_id" && (( max_nodes > 0 && ${#seen_nodes[@]} >= max_nodes )); then
    reason="max_nodes_reached"
  elif ! command_string="$(safe_command_for_action "$action")"; then
    reason="unsupported_action"
  elif is_forbidden_command "$command_string"; then
    reason="forbidden_pattern"
  elif [[ "$EXECUTE" -eq 0 ]]; then
    result="dry_run"
    reason="execute_flag_not_set"
  elif [[ "$policy_mode" != "execute" ]]; then
    result="dry_run"
    reason="policy_mode_is_$policy_mode"
  else
    if ! node_seen "$incident_node_id"; then
      seen_nodes+=("$incident_node_id")
    fi
    action_result="$(run_action "$command_string")"
    exit_code="$(printf '%s' "$action_result" | jq -r '.exitCode')"
    command_output="$(printf '%s' "$action_result" | jq -r '.output')"
    if [[ "$exit_code" == "0" ]]; then
      result="executed"
      reason="ok"
    else
      result="failed"
      reason="command_failed"
    fi
    executed_actions=$((executed_actions + 1))
  fi

  jq -n \
    --arg nodeId "$incident_node_id" \
    --arg category "$category" \
    --arg action "$action" \
    --arg result "$result" \
    --arg reason "$reason" \
    --arg command "$command_string" \
    --arg output "$command_output" \
    --argjson exitCode "$exit_code" \
    '{
      nodeId: $nodeId,
      category: $category,
      action: $action,
      result: $result,
      reason: $reason,
      command: $command,
      exitCode: $exitCode,
      output: $output
    }' >>"$results_file"
done < <(jq -c '.incidents[]?' "$PLAN_FILE")

report="$(
  jq -s \
    --arg generatedAt "$(date --iso-8601=seconds)" \
    --arg nodeId "$NODE_ID" \
    --arg policyMode "$policy_mode" \
    --argjson execute "$(if [[ "$EXECUTE" -eq 1 ]]; then printf true; else printf false; fi)" \
    '{
      schemaVersion: 1,
      generatedAt: $generatedAt,
      nodeId: $nodeId,
      executeRequested: $execute,
      policyMode: $policyMode,
      results: .,
      summary: {
        total: length,
        executed: (map(select(.result == "executed")) | length),
        failed: (map(select(.result == "failed")) | length),
        dryRun: (map(select(.result == "dry_run")) | length),
        skipped: (map(select(.result == "skipped")) | length)
      }
    }' "$results_file"
)"

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  printf '%s\n' "$report" >"$OUTPUT_FILE"
else
  printf '%s\n' "$report"
fi
