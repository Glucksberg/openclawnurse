#!/usr/bin/env bash

set -euo pipefail

FLEET_STATUS_FILE=""
POLICY_FILE=""
OUTPUT_FILE=""
MARKDOWN_FILE=""

usage() {
  cat <<'EOF'
Usage: openclaw-fleet-remediation-plan.sh --fleet-status <path> --policy <path> [options]

Options:
  --fleet-status <path>  Aggregated fleet-status.json input.
  --policy <path>        Remediation policy JSON.
  --output <path>        Write remediation-plan.json.
  --markdown <path>      Write a Markdown operator summary.
  -h, --help             Show this help.
EOF
}

while (($# > 0)); do
  case "$1" in
    --fleet-status)
      FLEET_STATUS_FILE="${2:?missing value for --fleet-status}"
      shift 2
      ;;
    --policy)
      POLICY_FILE="${2:?missing value for --policy}"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="${2:?missing value for --output}"
      shift 2
      ;;
    --markdown)
      MARKDOWN_FILE="${2:?missing value for --markdown}"
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

if [[ -z "$FLEET_STATUS_FILE" || -z "$POLICY_FILE" ]]; then
  usage >&2
  exit 2
fi

for cmd in jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd" >&2
    exit 1
  }
done

for path in "$FLEET_STATUS_FILE" "$POLICY_FILE"; do
  [[ -f "$path" ]] || {
    echo "Missing input file: $path" >&2
    exit 1
  }
  jq empty "$path" >/dev/null 2>&1 || {
    echo "Invalid JSON file: $path" >&2
    exit 1
  }
done

plan_json="$(
  jq -n \
    --slurpfile fleet "$FLEET_STATUS_FILE" \
    --slurpfile policy "$POLICY_FILE" \
    --arg generatedAt "$(date --iso-8601=seconds)" '
    ($fleet[0]) as $fleet_doc
    | ($policy[0]) as $policy_doc
    | def category($n):
        if (($n.source.ok // false) | not) then "feed_unreachable"
        elif $n.checks.auth == "issue" then "auth_issue"
        elif (($n.nurse.incidentCodes // []) | index("config_invalid") != null) then "config_issue"
        elif $n.checks.gateway == "issue" then "gateway_issue"
        elif ($n.nurse.status == "FAILED" or $n.nurse.status == "FAILED_NOTIFICATION_PENDING") then "nurse_failed"
        elif $n.checks.update == "outdated" then "update_available"
        elif $n.checks.notifications == "pending" then "notification_pending"
        elif ($n.nurse.status == "DEGRADED" or $n.checks.doctor == "warn") then "doctor_warning"
        else "healthy"
        end;
      def action_for($category):
        if $category == "feed_unreachable" then "check_export_timer"
        elif $category == "auth_issue" then "manual_auth_refresh"
        elif $category == "config_issue" then "manual_config_repair"
        elif $category == "gateway_issue" then "restart_gateway"
        elif $category == "nurse_failed" then "run_nurse_now"
        elif $category == "update_available" then "run_nurse_now"
        elif $category == "notification_pending" then "replay_notification"
        elif $category == "doctor_warning" then "run_nurse_now"
        else "none"
        end;
      def command_hint($action):
        if $action == "check_export_timer" then "systemctl --user status openclaw-fleet-export.timer"
        elif $action == "manual_auth_refresh" then "claude auth login"
        elif $action == "manual_config_repair" then "review OpenClaw config restore status and fix ~/.openclaw/openclaw.json manually if no valid backup exists"
        elif $action == "restart_gateway" then "pm2 restart openclaw-gateway"
        elif $action == "run_nurse_now" then "~/.local/share/openclawnurse/bin/openclaw-doctor.sh --config ~/.config/openclawnurse/openclawnurse.env --no-notify"
        elif $action == "replay_notification" then "~/.local/share/openclawnurse/bin/openclaw-doctor.sh --config ~/.config/openclawnurse/openclawnurse.env --retry-pending"
        else ""
        end;
      def requires_human($action):
        ($action == "none")
        or ($action == "manual_auth_refresh")
        or ($action == "manual_config_repair")
        or (($policy_doc.manualApprovalRequiredActions // []) | index($action) != null);
      def auto_eligible($action):
        (($policy_doc.allowedActions // []) | index($action) != null)
        and (requires_human($action) | not);
      {
        schemaVersion: 1,
        generatedAt: $generatedAt,
        fleetName: ($fleet_doc.fleet.name // "OpenClaw Fleet"),
        policy: {
          mode: ($policy_doc.mode // "advisory"),
          allowedActions: ($policy_doc.allowedActions // []),
          manualApprovalRequiredActions: ($policy_doc.manualApprovalRequiredActions // []),
          forbiddenPatterns: ($policy_doc.forbiddenPatterns // []),
          maxAutoActionsPerRun: ($policy_doc.maxAutoActionsPerRun // 0),
          maxNodesPerRun: ($policy_doc.maxNodesPerRun // 0),
          notes: ($policy_doc.notes // "")
        },
        incidents: [
          $fleet_doc.nodes[]
          | . as $node
          | (category($node)) as $category
          | select($category != "healthy")
          | (action_for($category)) as $action
          | {
              nodeId: $node.node.id,
              nodeName: $node.node.name,
              fleetStatus: $node.fleetStatus,
              category: $category,
              suggestedAction: $action,
              autoEligible: auto_eligible($action),
              requiresHumanApproval: requires_human($action),
              commandHint: command_hint($action),
              summary: ($node.nurse.doctorSummary // $node.nurse.status // "unknown"),
              facts: {
                nurseStatus: ($node.nurse.status // "UNKNOWN"),
                auth: ($node.checks.auth // "unknown"),
                gateway: ($node.checks.gateway // "unknown"),
                update: ($node.checks.update // "unknown"),
                notifications: ($node.checks.notifications // "unknown"),
                feedOk: ($node.source.ok // false),
                incidentCodes: ($node.nurse.incidentCodes // [])
              },
              llmBrief: (
                "Node "
                + ($node.node.name // $node.node.id // "unknown")
                + " is in state "
                + ($node.fleetStatus // "unknown")
                + ". Category: "
                + $category
                + ". Suggested action: "
                + $action
                + ". Summary: "
                + ($node.nurse.doctorSummary // $node.nurse.status // "unknown")
              )
            }
        ]
      }
      | .summary = {
          totalIncidents: (.incidents | length),
          autoEligible: (.incidents | map(select(.autoEligible)) | length),
          humanApprovalRequired: (.incidents | map(select(.requiresHumanApproval)) | length)
        }'
)"

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  printf '%s\n' "$plan_json" >"$OUTPUT_FILE"
else
  printf '%s\n' "$plan_json"
fi

if [[ -n "$MARKDOWN_FILE" ]]; then
  mkdir -p "$(dirname "$MARKDOWN_FILE")"
  {
    printf '# Fleet Remediation Plan\n\n'
    printf -- '- Generated at: `%s`\n' "$(printf '%s' "$plan_json" | jq -r '.generatedAt')"
    printf -- '- Fleet: `%s`\n' "$(printf '%s' "$plan_json" | jq -r '.fleetName')"
    printf -- '- Total incidents: `%s`\n' "$(printf '%s' "$plan_json" | jq -r '.summary.totalIncidents')"
    printf -- '- Auto-eligible: `%s`\n' "$(printf '%s' "$plan_json" | jq -r '.summary.autoEligible')"
    printf -- '- Human approval required: `%s`\n\n' "$(printf '%s' "$plan_json" | jq -r '.summary.humanApprovalRequired')"
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      printf '## %s\n\n' "$(printf '%s' "$item" | jq -r '.nodeName')"
      printf -- '- Category: `%s`\n' "$(printf '%s' "$item" | jq -r '.category')"
      printf -- '- Fleet status: `%s`\n' "$(printf '%s' "$item" | jq -r '.fleetStatus')"
      printf -- '- Suggested action: `%s`\n' "$(printf '%s' "$item" | jq -r '.suggestedAction')"
      printf -- '- Auto-eligible: `%s`\n' "$(printf '%s' "$item" | jq -r '.autoEligible')"
      printf -- '- Requires human approval: `%s`\n' "$(printf '%s' "$item" | jq -r '.requiresHumanApproval')"
      printf -- '- Command hint: `%s`\n' "$(printf '%s' "$item" | jq -r '.commandHint')"
      printf -- '- Summary: %s\n\n' "$(printf '%s' "$item" | jq -r '.summary')"
    done < <(printf '%s' "$plan_json" | jq -c '.incidents[]')
  } >"$MARKDOWN_FILE"
fi
