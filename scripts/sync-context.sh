#!/bin/bash
# sync-context.sh — Pull server state to local workspace context files
# Run LOCALLY (not on server). Requires SSH access.
#
# Usage:
#   bash sync-context.sh                    # sync default server
#   bash sync-context.sh prod-web           # sync specific server by ID
#   bash sync-context.sh --all              # sync all servers in servers.json
#   bash sync-context.sh --add              # interactive: add a new server
#   bash sync-context.sh --list             # list all configured servers
#   bash sync-context.sh --init <id> <host> <port> <user> <key>  # add server non-interactively
#
# Context files (relative to workspace root):
#   .server/servers.json              ← SSH configs (NOT in git)
#   .server/snapshots/<id>.json       ← Server state snapshots

set -euo pipefail

SERVERS_FILE=".server/servers.json"
SNAPSHOTS_DIR=".server/snapshots"
SKILL_DIR="$HOME/.cursor/skills/linux-server-ops"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1" >&2; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }

# ─── Helpers ──────────────────────────────────────────────────────────────────
require_jq() {
  command -v jq &>/dev/null || { echo "jq is required. brew install jq"; exit 1; }
}

resolve_path() {
  # Expand ~ in paths
  echo "${1/#\~/$HOME}"
}

# Build SSH command
ssh_cmd() {
  local host=$1 port=$2 user=$3 key=$4
  key=$(resolve_path "$key")
  echo "ssh -i $key -p $port -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes $user@$host"
}

scp_cmd() {
  local port=$1 key=$2
  key=$(resolve_path "$key")
  echo "scp -i $key -P $port -o StrictHostKeyChecking=no -o BatchMode=yes"
}

# ─── Initialize servers.json ──────────────────────────────────────────────────
init_servers_file() {
  if [ ! -f "$SERVERS_FILE" ]; then
    mkdir -p .server
    cat > "$SERVERS_FILE" << 'EOF'
{
  "_note": "SSH configs for managed servers. key_path supports ~ expansion. DO NOT commit this file.",
  "_gitignore_reminder": "Add .server/servers.json to .gitignore",
  "default": "",
  "servers": {}
}
EOF
    ok "Created $SERVERS_FILE"
  fi

  mkdir -p "$SNAPSHOTS_DIR"

  # Suggest adding to .gitignore
  if [ -d ".git" ] && ! grep -q "\.server/servers\.json" .gitignore 2>/dev/null; then
    warn ".server/servers.json not in .gitignore"
    echo "  Run: echo '.server/servers.json' >> .gitignore"
    echo "       echo '.server/snapshots/' >> .gitignore"
  fi
}

# ─── CMD: --list ──────────────────────────────────────────────────────────────
cmd_list() {
  if [ ! -f "$SERVERS_FILE" ]; then
    warn "No servers configured. Run: bash sync-context.sh --add"
    return
  fi

  echo ""
  echo -e "${BOLD}${CYAN}Configured Servers${NC}"
  echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"

  local default_id
  default_id=$(jq -r '.default // ""' "$SERVERS_FILE")
  local count
  count=$(jq '.servers | length' "$SERVERS_FILE")

  if [ "$count" -eq 0 ]; then
    echo "  (no servers configured)"
  else
    jq -r '.servers | to_entries[] | [.key, .value.host, (.value.port|tostring), .value.user, .value.label//""] | @tsv' \
      "$SERVERS_FILE" | while IFS=$'\t' read -r id host port user label; do
      local marker=""
      [ "$id" = "$default_id" ] && marker=" ${GREEN}(default)${NC}"
      printf "  %-15s  %-20s  %-5s  %-15s  %s\n" "$id" "$host" "$port" "$user" "$label"
      echo -ne "$marker"
      echo ""

      # Check if snapshot exists
      if [ -f "$SNAPSHOTS_DIR/$id.json" ]; then
        local synced_at
        synced_at=$(jq -r '.meta.scanned_at // "unknown"' "$SNAPSHOTS_DIR/$id.json" 2>/dev/null || echo "unknown")
        echo -e "    ${BLUE}snapshot: $synced_at${NC}"
      fi
    done
  fi
  echo ""
}

# ─── CMD: --add (interactive) ─────────────────────────────────────────────────
cmd_add_interactive() {
  echo ""
  echo -e "${BOLD}Add a New Server${NC}"
  echo "─────────────────────────────────"

  read -rp "Server ID (e.g. prod-web, staging): " server_id
  read -rp "Host (IP or hostname): " host
  read -rp "SSH Port [22]: " port
  port="${port:-22}"
  read -rp "SSH User [ubuntu]: " user
  user="${user:-ubuntu}"
  read -rp "Private Key Path [~/.ssh/id_ed25519]: " key_path
  key_path="${key_path:-~/.ssh/id_ed25519}"
  read -rp "Label (description): " label
  read -rp "Tags (comma-separated, e.g. production,web): " tags_raw

  # Convert tags to JSON array
  local tags_json
  tags_json=$(echo "$tags_raw" | tr ',' '\n' | jq -R '.' | jq -s '.')

  cmd_init "$server_id" "$host" "$port" "$user" "$key_path" "$label" "$tags_json"

  read -rp "Sync server state now? [Y/n]: " sync_now
  if [[ ! "$sync_now" =~ ^[Nn]$ ]]; then
    cmd_sync "$server_id"
  fi
}

# ─── CMD: --init ──────────────────────────────────────────────────────────────
cmd_init() {
  local server_id="$1" host="$2" port="$3" user="$4" key_path="$5"
  local label="${6:-}" tags="${7:-[]}"

  init_servers_file

  # Check if server ID already exists
  if jq -e ".servers[\"$server_id\"]" "$SERVERS_FILE" &>/dev/null; then
    warn "Server '$server_id' already exists — updating"
  fi

  local tmp
  tmp=$(mktemp)
  local current_default
  current_default=$(jq -r '.default // ""' "$SERVERS_FILE")

  jq --arg id "$server_id" \
     --arg host "$host" \
     --argjson port "${port:-22}" \
     --arg user "$user" \
     --arg key "$key_path" \
     --arg label "$label" \
     --argjson tags "$tags" \
     --arg snapshot ".server/snapshots/$server_id.json" \
     '.servers[$id] = {
       label: $label,
       host: $host,
       port: $port,
       user: $user,
       key_path: $key,
       tags: $tags,
       snapshot: $snapshot,
       added_at: (now | todate)
     }' "$SERVERS_FILE" > "$tmp"

  # Set as default if it's the first server
  if [ "$current_default" = "" ]; then
    jq --arg id "$server_id" '.default = $id' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
  fi

  mv "$tmp" "$SERVERS_FILE"
  ok "Server '$server_id' added to $SERVERS_FILE"
}

# ─── CMD: sync ────────────────────────────────────────────────────────────────
cmd_sync() {
  local server_id="${1:-}"

  if [ -z "$server_id" ]; then
    server_id=$(jq -r '.default // ""' "$SERVERS_FILE" 2>/dev/null || echo "")
    if [ -z "$server_id" ]; then
      fail "No default server set and no server ID provided"
      echo "Usage: bash sync-context.sh <server-id>"
      cmd_list
      exit 1
    fi
    info "Using default server: $server_id"
  fi

  if ! jq -e ".servers[\"$server_id\"]" "$SERVERS_FILE" &>/dev/null; then
    fail "Server '$server_id' not found in $SERVERS_FILE"
    cmd_list
    exit 1
  fi

  local host port user key_path
  host=$(jq -r ".servers[\"$server_id\"].host" "$SERVERS_FILE")
  port=$(jq -r ".servers[\"$server_id\"].port" "$SERVERS_FILE")
  user=$(jq -r ".servers[\"$server_id\"].user" "$SERVERS_FILE")
  key_path=$(resolve_path "$(jq -r ".servers[\"$server_id\"].key_path" "$SERVERS_FILE")")

  echo ""
  info "Syncing: $server_id ($user@$host:$port)"

  # Test SSH connection
  info "Testing SSH connection..."
  if ! ssh -i "$key_path" -p "$port" \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=10 \
       -o BatchMode=yes \
       "$user@$host" 'echo ok' &>/dev/null; then
    fail "SSH connection failed — check host, port, user, key_path"
    exit 1
  fi
  ok "SSH connection successful"

  # Upload generate-index.sh if not present on server
  info "Ensuring generate-index.sh is on server..."
  ssh -i "$key_path" -p "$port" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "$user@$host" '[ -f /opt/server-tools/generate-index.sh ] && echo exists || echo missing' 2>/dev/null | \
  grep -q "missing" && {
    info "Uploading generate-index.sh..."
    scp -i "$key_path" -P "$port" \
        -o StrictHostKeyChecking=no \
        "$SKILL_DIR/scripts/generate-index.sh" \
        "$user@$host:/tmp/generate-index.sh"
    ssh -i "$key_path" -p "$port" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        "$user@$host" \
        'sudo mkdir -p /opt/server-tools && sudo mv /tmp/generate-index.sh /opt/server-tools/ && sudo chmod +x /opt/server-tools/generate-index.sh'
    ok "generate-index.sh uploaded"
  } || ok "generate-index.sh already present"

  # Also upload service-registry.sh
  ssh -i "$key_path" -p "$port" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "$user@$host" '[ -f /opt/server-tools/service-registry.sh ] && echo exists || echo missing' 2>/dev/null | \
  grep -q "missing" && {
    scp -i "$key_path" -P "$port" \
        -o StrictHostKeyChecking=no \
        "$SKILL_DIR/scripts/service-registry.sh" \
        "$user@$host:/tmp/service-registry.sh"
    ssh -i "$key_path" -p "$port" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        "$user@$host" \
        'sudo mv /tmp/service-registry.sh /opt/server-tools/ && sudo chmod +x /opt/server-tools/service-registry.sh'
  } || true

  # Run generate-index.sh on server and capture output
  info "Scanning server (this may take ~10 seconds)..."
  local snapshot
  snapshot=$(ssh -i "$key_path" -p "$port" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "$user@$host" \
      'sudo bash /opt/server-tools/generate-index.sh --print' 2>/dev/null)

  if [ -z "$snapshot" ] || ! echo "$snapshot" | jq . &>/dev/null; then
    fail "Failed to get valid JSON from server"
    echo "Raw output: ${snapshot:0:200}"
    exit 1
  fi

  # Add server_id and connection info to snapshot (for local reference)
  local enriched_snapshot
  enriched_snapshot=$(echo "$snapshot" | jq \
    --arg server_id "$server_id" \
    --arg host "$host" \
    --argjson port "${port:-22}" \
    --arg user "$user" \
    --arg key "$key_path" \
    --arg synced_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {
      _server_id: $server_id,
      _connection: {host: $host, port: $port, user: $user, key_path: $key},
      _synced_at: $synced_at
    }')

  # Save snapshot
  mkdir -p "$SNAPSHOTS_DIR"
  echo "$enriched_snapshot" > "$SNAPSHOTS_DIR/$server_id.json"
  ok "Snapshot saved: $SNAPSHOTS_DIR/$server_id.json"

  # Update servers.json with last_synced
  local tmp
  tmp=$(mktemp)
  jq --arg id "$server_id" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.servers[$id].last_synced = $ts' "$SERVERS_FILE" > "$tmp"
  mv "$tmp" "$SERVERS_FILE"

  # Print summary
  echo ""
  echo -e "${BOLD}${CYAN}Snapshot Summary: $server_id${NC}"
  echo -e "${CYAN}──────────────────────────────────────────────${NC}"
  echo "$enriched_snapshot" | jq -r '"  Host:        \(.meta.hostname) (\(.meta.public_ip))"'
  echo "$enriched_snapshot" | jq -r '"  OS:          \(.meta.os)"'
  echo "$enriched_snapshot" | jq -r '"  RAM:         \(.meta.resources.ram)  Disk: \(.meta.resources.disk.used)/\(.meta.resources.disk.total) (\(.meta.resources.disk.pct))"'
  echo ""
  echo "$enriched_snapshot" | jq -r '"  Websites:    \(.websites | length)"'
  echo "$enriched_snapshot" | jq -r '"  Services:    \(.services | length)"'
  echo "$enriched_snapshot" | jq -r '"  Databases:   \(.databases | length) engines"'
  echo "$enriched_snapshot" | jq -r '"  SSL Certs:   \(.ssl_certs | length)"'
  echo "$enriched_snapshot" | jq -r '"  Docker:      \(if .docker.installed then (.docker.containers | length | tostring) + " containers" else "not installed" end)"'
  echo ""

  # Warn on SSL certs expiring soon
  local expiring
  expiring=$(echo "$enriched_snapshot" | jq -r '.ssl_certs[] | select(.days_remaining < 30) | "  ⚠ \(.name): expires in \(.days_remaining) days"' 2>/dev/null || true)
  if [ -n "$expiring" ]; then
    echo -e "${YELLOW}SSL Expiry Warnings:${NC}"
    echo "$expiring"
    echo ""
  fi
}

# ─── CMD: --all ───────────────────────────────────────────────────────────────
cmd_sync_all() {
  if [ ! -f "$SERVERS_FILE" ]; then
    fail "No servers configured."
    exit 1
  fi

  local servers
  servers=$(jq -r '.servers | keys[]' "$SERVERS_FILE" 2>/dev/null || echo "")

  if [ -z "$servers" ]; then
    warn "No servers in $SERVERS_FILE"
    return
  fi

  local failed=0
  while IFS= read -r server_id; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cmd_sync "$server_id" || { fail "Failed to sync $server_id"; ((failed++)) || true; }
  done <<< "$servers"

  echo ""
  if [ "$failed" -eq 0 ]; then
    ok "All servers synced successfully"
  else
    warn "$failed server(s) failed to sync"
  fi
}

# ─── CMD: show snapshot ───────────────────────────────────────────────────────
cmd_show() {
  local server_id="${1:-$(jq -r '.default // ""' "$SERVERS_FILE" 2>/dev/null)}"
  local snapshot="$SNAPSHOTS_DIR/$server_id.json"

  if [ ! -f "$snapshot" ]; then
    fail "No snapshot found for '$server_id'. Run: bash sync-context.sh $server_id"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}${CYAN}Server Snapshot: $server_id${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"

  jq -r '"Meta: \(.meta.hostname) | \(.meta.public_ip) | \(.meta.os) | \(.meta.uptime)"' "$snapshot"
  jq -r '"Synced: \(._synced_at)"' "$snapshot"
  echo ""

  # Websites
  local web_count
  web_count=$(jq '.websites | length' "$snapshot")
  echo -e "${BOLD}Websites ($web_count):${NC}"
  jq -r '.websites[] | "  \(.name)  →  \(.domain // "no-domain")  [\(if .ssl then "SSL✓" else "no-ssl" end)]  \(.root // "")"' "$snapshot" 2>/dev/null || echo "  (none)"

  echo ""
  # Services
  local svc_count
  svc_count=$(jq '.services | length' "$snapshot")
  echo -e "${BOLD}Services ($svc_count):${NC}"
  jq -r '.services[] | "  \(.name)  [\(.type)]  \(.status // "?")  port:\(.port // "-")  \(.root // "")"' "$snapshot" 2>/dev/null || echo "  (none)"

  echo ""
  # Databases
  local db_count
  db_count=$(jq '.databases | length' "$snapshot")
  echo -e "${BOLD}Databases ($db_count):${NC}"
  jq -r '.databases[] | "  \(.engine) \(.version)  [\(.status)]  port:\(.port)  dbs:[\(.databases // [] | join(", "))]"' "$snapshot" 2>/dev/null || echo "  (none)"

  echo ""
  # Docker
  local docker_info
  docker_info=$(jq -r 'if .docker.installed then "  Docker \(.docker.version) [\(.docker.status)] — \(.docker.containers | length) running containers, \(.docker.compose_projects | length) compose projects" else "  Docker: not installed" end' "$snapshot")
  echo -e "${BOLD}Docker:${NC}"
  echo "$docker_info"
  jq -r '.docker.containers[]? | "    • \(.name)  [\(.image)]  \(.status)"' "$snapshot" 2>/dev/null

  echo ""
  # SSL
  echo -e "${BOLD}SSL Certs:${NC}"
  jq -r '.ssl_certs[] | "  \(.name)  expires:\(.expires)  (\(.days_remaining) days)"' "$snapshot" 2>/dev/null || echo "  (none)"

  echo ""
  # Open ports
  echo -e "${BOLD}Open Ports:${NC}"
  jq -r '[.open_ports[]? | "\(.port)/\(.process // "?")"] | join("  ")' "$snapshot" 2>/dev/null | sed 's/^/  /'

  echo ""
}

# ─── CMD: help ────────────────────────────────────────────────────────────────
cmd_help() {
  cat << 'HELP'

sync-context.sh — Local workspace server context manager

Usage:
  bash sync-context.sh [server-id]         Sync specific server (or default)
  bash sync-context.sh --all               Sync all configured servers
  bash sync-context.sh --add               Interactive: add a new server
  bash sync-context.sh --init <id> <host> <port> <user> <key>
                                           Add server non-interactively
  bash sync-context.sh --list              List all configured servers
  bash sync-context.sh --show [server-id]  Show snapshot details
  bash sync-context.sh --help              This help

Context files (in workspace):
  .server/servers.json              SSH configs (ADD TO .gitignore)
  .server/snapshots/<id>.json       Server state snapshots

Quick start:
  1. bash sync-context.sh --add             # add your first server
  2. bash sync-context.sh                   # sync state
  3. cat .server/snapshots/my-server.json   # review snapshot

In a new Cursor session, the AI reads these files automatically to
understand your server environment without re-asking for details.

HELP
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  require_jq
  init_servers_file

  local cmd="${1:-sync}"

  case "$cmd" in
    --add)        cmd_add_interactive ;;
    --init)       shift; cmd_init "$@" ;;
    --list)       cmd_list ;;
    --all)        cmd_sync_all ;;
    --show)       shift; cmd_show "${1:-}" ;;
    --help|-h)    cmd_help ;;
    --*)
      fail "Unknown option: $cmd"
      cmd_help
      exit 1
      ;;
    *)
      # Positional: treat as server ID (or empty = use default)
      cmd_sync "$cmd"
      ;;
  esac
}

main "$@"
