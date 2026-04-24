#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE=""
OUTPUT_DIR=""
WRITE_JSON=1
WRITE_HTML=1
PUSH_KUMA=0

usage() {
  cat <<'EOF'
Usage: openclaw-fleet-dashboard.sh --config <path> --output-dir <path> [options]

Options:
  --config <path>      Fleet config JSON.
  --output-dir <path>  Where to write fleet-status.json and index.html.
  --json-only          Only write fleet-status.json.
  --html-only          Only write index.html.
  --push-kuma          Push aggregate/per-node status to configured Kuma URLs.
  -h, --help           Show this help.
EOF
}

while (($# > 0)); do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?missing value for --config}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --json-only)
      WRITE_HTML=0
      shift
      ;;
    --html-only)
      WRITE_JSON=0
      shift
      ;;
    --push-kuma)
      PUSH_KUMA=1
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

if [[ -z "$CONFIG_FILE" || -z "$OUTPUT_DIR" ]]; then
  usage >&2
  exit 2
fi

for cmd in jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd" >&2
    exit 1
  }
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config file: $CONFIG_FILE" >&2
  exit 1
fi

if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
  echo "Invalid JSON config file: $CONFIG_FILE" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

fetch_node_feed() {
  local source="$1"
  if [[ "$source" =~ ^https?:// ]]; then
    curl -fsSL --max-time 20 "$source"
  elif [[ "$source" =~ ^file:// ]]; then
    cat "${source#file://}"
  else
    cat "$source"
  fi
}

build_html() {
  local json_file="$1"
  jq -r '
    def badge_class($s):
      if $s == "ok" then "ok"
      elif $s == "warn" then "warn"
      elif $s == "repaired" then "repaired"
      else "down" end;
    def esc:
      (if . == null then "" else tostring end)
      | gsub("&"; "&amp;")
      | gsub("<"; "&lt;")
      | gsub(">"; "&gt;");
    "<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>\(.fleet.name | esc)</title>
  <style>
    :root { color-scheme: light; --bg:#f4efe7; --panel:#fffdf8; --ink:#1f1f1f; --muted:#6e685f; --line:#d8cfc2; --ok:#1f7a4c; --warn:#a66a00; --down:#a12626; --repaired:#2366b5; }
    * { box-sizing: border-box; }
    body { margin:0; font-family: ui-sans-serif, system-ui, sans-serif; background: linear-gradient(180deg,#efe6d8 0%,#f8f4ee 45%,#f4efe7 100%); color:var(--ink); }
    .wrap { max-width: 1240px; margin: 0 auto; padding: 32px 20px 56px; }
    .hero { display:flex; justify-content:space-between; gap:20px; align-items:flex-end; margin-bottom: 24px; }
    h1 { margin:0; font-size: 34px; line-height:1; letter-spacing:-0.03em; }
    .meta { color:var(--muted); font-size:14px; margin-top:8px; }
    .chips { display:flex; gap:10px; flex-wrap:wrap; }
    .chip { border:1px solid var(--line); background:var(--panel); border-radius:999px; padding:8px 12px; font-size:13px; }
    .grid { display:grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap:14px; margin-bottom:24px; }
    .card { background:var(--panel); border:1px solid var(--line); border-radius:18px; padding:18px; box-shadow: 0 6px 20px rgba(71,53,35,0.06); }
    .k { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.08em; margin-bottom:8px; }
    .v { font-size:28px; font-weight:700; }
    .nodes { display:grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap:14px; }
    .node { background:var(--panel); border:1px solid var(--line); border-radius:22px; padding:18px; box-shadow: 0 10px 24px rgba(71,53,35,0.07); }
    .row { display:flex; justify-content:space-between; gap:12px; align-items:center; }
    .name { font-size:20px; font-weight:700; letter-spacing:-0.02em; }
    .host { color:var(--muted); font-size:13px; margin-top:4px; }
    .badge { display:inline-flex; align-items:center; gap:6px; border-radius:999px; padding:6px 10px; color:#fff; font-size:12px; font-weight:700; text-transform:uppercase; letter-spacing:.06em; }
    .badge.ok { background:var(--ok); }
    .badge.warn { background:var(--warn); }
    .badge.down { background:var(--down); }
    .badge.repaired { background:var(--repaired); }
    .facts { display:grid; grid-template-columns:1fr 1fr; gap:10px; margin-top:16px; }
    .fact { border:1px solid var(--line); border-radius:14px; padding:10px 12px; background:#fffaf3; }
    .fact strong { display:block; font-size:12px; color:var(--muted); margin-bottom:4px; text-transform:uppercase; letter-spacing:.08em; }
    .fact span { font-size:14px; }
    .summary { margin-top:16px; font-size:14px; color:var(--ink); }
    .summary small { display:block; color:var(--muted); margin-top:8px; }
    a { color:#0d4f8b; text-decoration:none; }
  </style>
</head>
<body>
  <div class=\"wrap\">
    <div class=\"hero\">
      <div>
        <h1>\(.fleet.name | esc)</h1>
        <div class=\"meta\">Generated at \(.generatedAt | esc)</div>
      </div>
      <div class=\"chips\">
        <div class=\"chip\">Overall: \(.fleet.overallStatus | esc)</div>
        <div class=\"chip\">Nodes: \(.fleet.counts.total)</div>
        <div class=\"chip\">Healthy: \(.fleet.counts.ok)</div>
        <div class=\"chip\">Warnings: \(.fleet.counts.warn)</div>
        <div class=\"chip\">Down: \(.fleet.counts.down)</div>
      </div>
    </div>
    <div class=\"grid\">
      <div class=\"card\"><div class=\"k\">Overall</div><div class=\"v\">\(.fleet.overallStatus | ascii_upcase)</div></div>
      <div class=\"card\"><div class=\"k\">Healthy Nodes</div><div class=\"v\">\(.fleet.counts.ok)</div></div>
      <div class=\"card\"><div class=\"k\">Warning Nodes</div><div class=\"v\">\(.fleet.counts.warn)</div></div>
      <div class=\"card\"><div class=\"k\">Down Nodes</div><div class=\"v\">\(.fleet.counts.down)</div></div>
    </div>
    <div class=\"nodes\">"
    + (
      .nodes
      | sort_by(.fleetStatus, .node.name)
      | map(
          "<section class=\"node\">
            <div class=\"row\">
              <div>
                <div class=\"name\">\(.node.name | esc)</div>
                <div class=\"host\">\(.node.hostname | esc)</div>
              </div>
              <div class=\"badge \(badge_class(.fleetStatus))\">\(.fleetStatus | esc)</div>
            </div>
            <div class=\"facts\">
              <div class=\"fact\"><strong>Nurse</strong><span>\(.nurse.status | esc)</span></div>
              <div class=\"fact\"><strong>Auth</strong><span>\(.checks.auth | esc)</span></div>
              <div class=\"fact\"><strong>Version</strong><span>\(.nurse.currentVersionAfter // "?" | esc)</span></div>
              <div class=\"fact\"><strong>Gateway</strong><span>\(.checks.gateway | esc)</span></div>
              <div class=\"fact\"><strong>Sessions</strong><span>\(.openclaw.snapshot.sessions.count // "?" | tostring | esc)</span></div>
              <div class=\"fact\"><strong>Updated At</strong><span>\(.nurse.timestamp | esc)</span></div>
            </div>
            <div class=\"summary\">\(.nurse.doctorSummary // "" | esc)
              <small>Source: \(.source.feedUrl | esc)\(if .node.publicUrl then " · <a href=\"\(.node.publicUrl | esc)\">open</a>" else "" end)</small>
            </div>
          </section>"
        )
      | join("\n")
    )
    + "</div>
  </div>
</body>
</html>"
  ' "$json_file"
}

kuma_url_with_status() {
  local url="$1"
  local status="$2"
  local message="$3"
  local ping=0
  case "$status" in
    ok) ping=1 ;;
    warn) ping=1 ;;
    down) ping=0 ;;
    *) ping=0 ;;
  esac
  printf '%s?status=%s&msg=%s' \
    "$url" \
    "$ping" \
    "$(jq -rn --arg v "$message" '$v|@uri')"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

nodes_array='[]'

while IFS= read -r encoded; do
  [[ -n "$encoded" ]] || continue
  node_cfg="$(printf '%s' "$encoded" | base64 -d)"
  node_id="$(printf '%s' "$node_cfg" | jq -r '.id')"
  node_name="$(printf '%s' "$node_cfg" | jq -r '.name // .id')"
  feed_url="$(printf '%s' "$node_cfg" | jq -r '.feedUrl')"
  dashboard_url="$(printf '%s' "$node_cfg" | jq -r '.dashboardUrl // empty')"
  kuma_push_url="$(printf '%s' "$node_cfg" | jq -r '.kumaPushUrl // empty')"
  tags_json="$(printf '%s' "$node_cfg" | jq '.tags // []')"

  fetched_at="$(date --iso-8601=seconds)"
  feed_json=""
  fetch_error=""
  set +e
  feed_json="$(fetch_node_feed "$feed_url" 2>&1)"
  fetch_code=$?
  set -e

  if [[ "$fetch_code" -eq 0 ]] && printf '%s' "$feed_json" | jq empty >/dev/null 2>&1; then
    node_payload="$(printf '%s' "$feed_json" | jq \
      --arg fetchedAt "$fetched_at" \
      --arg feedUrl "$feed_url" \
      --arg dashboardUrl "$dashboard_url" \
      --argjson tags "$tags_json" \
      '. + {
        source: {
          fetchedAt: $fetchedAt,
          feedUrl: $feedUrl,
          dashboardUrl: (if $dashboardUrl == "" then null else $dashboardUrl end),
          ok: true
        },
        node: (.node + { tags: $tags })
      }')"
  else
    fetch_error="$(printf '%s' "$feed_json" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-300)"
    node_payload="$(
      jq -n \
        --arg nodeId "$node_id" \
        --arg nodeName "$node_name" \
        --arg fetchedAt "$fetched_at" \
        --arg feedUrl "$feed_url" \
        --arg fetchError "$fetch_error" \
        --arg dashboardUrl "$dashboard_url" \
        --argjson tags "$tags_json" \
        '{
          schemaVersion: 1,
          generatedAt: $fetchedAt,
          node: {
            id: $nodeId,
            name: $nodeName,
            hostname: $nodeName,
            publicUrl: ($dashboardUrl | select(length > 0)),
            tags: $tags
          },
          checks: {
            auth: "unknown",
            update: "unknown",
            doctor: "issue",
            gateway: "issue",
            notifications: "unknown"
          },
          nurse: {
            timestamp: null,
            status: "UNREACHABLE",
            doctorSummary: "feed fetch failed",
            gatewayHealthy: false,
            notificationPending: false,
            errors: [$fetchError],
            fixes: [],
            actions: []
          },
          openclaw: {
            statusFetchOk: false,
            statusError: $fetchError,
            snapshot: null
          },
          source: {
            fetchedAt: $fetchedAt,
            feedUrl: $feedUrl,
            dashboardUrl: (if $dashboardUrl == "" then null else $dashboardUrl end),
            ok: false
          }
        }'
    )"
  fi

  node_payload="$(printf '%s' "$node_payload" | jq '
    .fleetStatus = (
      if (.source.ok | not) then "down"
      elif .checks.gateway == "issue" or .checks.auth == "issue" then "down"
      elif .nurse.status == "FAILED" or .nurse.status == "FAILED_NOTIFICATION_PENDING" or .nurse.status == "UNREACHABLE" then "down"
      elif .nurse.status == "DEGRADED" or .checks.doctor == "warn" or .checks.notifications == "pending" or .checks.update == "outdated" or .checks.doctor == "repaired" or .nurse.status == "UPDATED_WITH_REPAIRS" then "warn"
      else "ok"
      end
    )')"

  if [[ "$PUSH_KUMA" -eq 1 && -n "$kuma_push_url" ]]; then
    status_value="$(printf '%s' "$node_payload" | jq -r '.fleetStatus')"
    summary_value="$(printf '%s' "$node_payload" | jq -r '.nurse.doctorSummary // .nurse.status // "unknown"')"
    curl -fsS -o /dev/null "$(kuma_url_with_status "$kuma_push_url" "$status_value" "$summary_value")" || true
  fi

  nodes_array="$(jq -n --argjson existing "$nodes_array" --argjson item "$node_payload" '$existing + [$item]')"
done < <(jq -r '.nodes[] | @base64' "$CONFIG_FILE")

aggregate_json="$(
  jq -n \
    --arg generatedAt "$(date --iso-8601=seconds)" \
    --arg configFile "$CONFIG_FILE" \
    --arg fleetName "$(jq -r '.fleetName // "OpenClaw Fleet"' "$CONFIG_FILE")" \
    --argjson nodes "$nodes_array" \
    '{
      schemaVersion: 1,
      generatedAt: $generatedAt,
      configFile: $configFile,
      fleet: {
        name: $fleetName
      },
      nodes: $nodes
    }
    | .fleet.counts = {
        total: (.nodes | length),
        ok: (.nodes | map(select(.fleetStatus == "ok")) | length),
        warn: (.nodes | map(select(.fleetStatus == "warn")) | length),
        down: (.nodes | map(select(.fleetStatus == "down")) | length)
      }
    | .fleet.overallStatus = (
        if .fleet.counts.down > 0 then "down"
        elif .fleet.counts.warn > 0 then "warn"
        else "ok"
        end
      )'
)"

json_path="$OUTPUT_DIR/fleet-status.json"
html_path="$OUTPUT_DIR/index.html"
printf '%s\n' "$aggregate_json" >"$json_path"

if [[ "$WRITE_HTML" -eq 1 ]]; then
  build_html "$json_path" >"$html_path"
fi

if [[ "$WRITE_JSON" -eq 0 ]]; then
  rm -f "$json_path"
fi

overall_kuma_url="$(jq -r '.overallKumaPushUrl // empty' "$CONFIG_FILE")"
if [[ "$PUSH_KUMA" -eq 1 && -n "$overall_kuma_url" ]]; then
  overall_status="$(printf '%s' "$aggregate_json" | jq -r '.fleet.overallStatus')"
  overall_msg="$(printf '%s' "$aggregate_json" | jq -r '"fleet: ok=\(.fleet.counts.ok) warn=\(.fleet.counts.warn) down=\(.fleet.counts.down)"')"
  curl -fsS -o /dev/null "$(kuma_url_with_status "$overall_kuma_url" "$overall_status" "$overall_msg")" || true
fi

if [[ "$WRITE_JSON" -eq 1 ]]; then
  printf 'Wrote %s\n' "$json_path"
fi
if [[ "$WRITE_HTML" -eq 1 ]]; then
  printf 'Wrote %s\n' "$html_path"
fi
