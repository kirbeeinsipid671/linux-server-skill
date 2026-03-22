#!/bin/bash
# generate-index.sh — Comprehensive server state scanner
# Install on server at: /opt/server-tools/generate-index.sh
# Run as root. Scans the entire server and writes /etc/server-index.json
#
# Usage:
#   bash /opt/server-tools/generate-index.sh           # scan + write index
#   bash /opt/server-tools/generate-index.sh --print   # scan + print JSON only (for sync)
#   bash /opt/server-tools/generate-index.sh --quiet   # scan, write, no output

set -euo pipefail

INDEX="/etc/server-index.json"
PRINT_ONLY=false
QUIET=false

for arg in "$@"; do
  case $arg in
    --print)  PRINT_ONLY=true ;;
    --quiet)  QUIET=true ;;
  esac
done

log() { $QUIET || $PRINT_ONLY || echo "[index] $1" >&2; }

require_root() {
  [ "$EUID" -eq 0 ] || { echo "Run as root"; exit 1; }
}

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ─── Meta ─────────────────────────────────────────────────────────────────────
scan_meta() {
  local hostname os_name os_version arch public_ip private_ip uptime_str kernel

  hostname=$(hostname -f 2>/dev/null || hostname)
  arch=$(uname -m)
  kernel=$(uname -r)
  uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | cut -d',' -f1 | xargs)
  public_ip=$(curl -s --max-time 8 ifconfig.me 2>/dev/null \
    || curl -s --max-time 8 api.ipify.org 2>/dev/null \
    || echo "unknown")
  private_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_name="${NAME:-unknown}"
    os_version="${VERSION_ID:-unknown}"
  else
    os_name=$(uname -s)
    os_version="unknown"
  fi

  local cpu_cores ram_total disk_total disk_used disk_pct
  cpu_cores=$(nproc 2>/dev/null || grep -c processor /proc/cpuinfo 2>/dev/null || echo "?")
  ram_total=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo "?")
  disk_total=$(df -h / 2>/dev/null | awk 'NR==2{print $2}' || echo "?")
  disk_used=$(df -h / 2>/dev/null | awk 'NR==2{print $3}' || echo "?")
  disk_pct=$(df / 2>/dev/null | awk 'NR==2{print $5}' || echo "?")

  jq -n \
    --arg hostname "$hostname" \
    --arg public_ip "$public_ip" \
    --arg private_ip "$private_ip" \
    --arg os "$os_name $os_version" \
    --arg arch "$arch" \
    --arg kernel "$kernel" \
    --arg uptime "$uptime_str" \
    --argjson cpu_cores "${cpu_cores:-0}" \
    --arg ram "$ram_total" \
    --arg disk_total "$disk_total" \
    --arg disk_used "$disk_used" \
    --arg disk_pct "$disk_pct" \
    --arg scanned_at "$(ts)" \
    '{
      hostname: $hostname,
      public_ip: $public_ip,
      private_ip: $private_ip,
      os: $os,
      arch: $arch,
      kernel: $kernel,
      uptime: $uptime,
      resources: {
        cpu_cores: $cpu_cores,
        ram: $ram,
        disk: { total: $disk_total, used: $disk_used, pct: $disk_pct }
      },
      scanned_at: $scanned_at
    }'
}

# ─── Websites (from Nginx vhost configs) ──────────────────────────────────────
scan_websites() {
  local sites=()
  local conf_dirs=(
    "/etc/nginx/sites-enabled"
    "/etc/nginx/conf.d"
    "/etc/nginx/http.d"
  )

  for dir in "${conf_dirs[@]}"; do
    [ -d "$dir" ] || continue
    for conf in "$dir"/*; do
      [ -f "$conf" ] || [ -L "$conf" ] || continue
      [ "$(basename "$conf")" = "default" ] && continue

      local name domain root ssl ssl_cert ssl_expires proxy_port
      name=$(basename "$conf" | sed 's/\.conf$//')
      domain=$(grep -m1 "server_name" "$conf" 2>/dev/null | awk '{print $2}' | tr -d ';' | head -1 || echo "")
      root=$(grep -m1 "root " "$conf" 2>/dev/null | awk '{print $2}' | tr -d ';' || echo "")
      ssl="false"
      ssl_cert=""
      ssl_expires=""
      proxy_port=""

      if grep -q "ssl_certificate " "$conf" 2>/dev/null; then
        ssl="true"
        ssl_cert=$(grep -m1 "ssl_certificate " "$conf" | awk '{print $2}' | tr -d ';' || echo "")
        # Get expiry from cert file
        if [ -f "$ssl_cert" ]; then
          ssl_expires=$(openssl x509 -noout -enddate -in "$ssl_cert" 2>/dev/null \
            | cut -d= -f2 | xargs -I{} date -d{} +%Y-%m-%d 2>/dev/null || echo "")
        fi
      fi

      if grep -q "proxy_pass" "$conf" 2>/dev/null; then
        proxy_port=$(grep -m1 "proxy_pass" "$conf" | grep -oE ':[0-9]+' | tr -d ':' | head -1 || echo "")
      fi

      # Determine real config path (resolve symlink)
      local real_conf
      real_conf=$(readlink -f "$conf" 2>/dev/null || echo "$conf")

      sites+=("$(jq -n \
        --arg name "$name" \
        --arg domain "$domain" \
        --arg root "$root" \
        --arg conf "$real_conf" \
        --arg ssl "$ssl" \
        --arg ssl_cert "$ssl_cert" \
        --arg ssl_expires "$ssl_expires" \
        --arg proxy_port "$proxy_port" \
        '{
          name: $name,
          domain: $domain,
          root: $root,
          nginx_conf: $conf,
          ssl: ($ssl == "true"),
          ssl_cert: (if $ssl_cert != "" then $ssl_cert else null end),
          ssl_expires: (if $ssl_expires != "" then $ssl_expires else null end),
          proxy_port: (if $proxy_port != "" then ($proxy_port | tonumber) else null end)
        }')")
    done
  done

  if [ ${#sites[@]} -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "${sites[@]}" | jq -s '.'
  fi
}

# ─── Services ────────────────────────────────────────────────────────────────
scan_services() {
  local services=()

  # PM2 processes (Node.js)
  if command -v pm2 &>/dev/null; then
    # Run as the user who has pm2 (try common users)
    for pm2_user in root ubuntu deploy www-data ec2-user; do
      if id "$pm2_user" &>/dev/null; then
        local pm2_json
        pm2_json=$(su - "$pm2_user" -c 'pm2 jlist 2>/dev/null' 2>/dev/null || echo "[]")
        if [ "$pm2_json" != "[]" ] && [ -n "$pm2_json" ]; then
          while IFS= read -r proc; do
            local name status cwd script port
            name=$(echo "$proc" | jq -r '.name // ""')
            status=$(echo "$proc" | jq -r '.pm2_env.status // "unknown"')
            cwd=$(echo "$proc" | jq -r '.pm2_env.pm_cwd // ""')
            script=$(echo "$proc" | jq -r '.pm2_env.pm_exec_path // ""')
            port=$(echo "$proc" | jq -r '(.pm2_env.PORT // .pm2_env.env.PORT // "") | tostring')
            [ "$name" = "" ] && continue
            services+=("$(jq -n \
              --arg name "$name" \
              --arg type "nodejs" \
              --arg status "$status" \
              --arg root "$cwd" \
              --arg script "$script" \
              --arg port "$port" \
              --arg pm "pm2" \
              '{name:$name,type:$type,status:$status,root:$root,entry:$script,
                port:(if $port != "" and $port != "null" then ($port|tonumber?) else null end),
                process_manager:$pm,log_dir:("/var/log/apps/"+$name)}')")
          done < <(echo "$pm2_json" | jq -c '.[]')
          break
        fi
      fi
    done
  fi

  # Systemd custom services (non-system)
  if command -v systemctl &>/dev/null; then
    while IFS= read -r unit; do
      local name unit_file type exec_start port
      name=$(echo "$unit" | awk '{print $1}' | sed 's/\.service$//')
      # Skip system units
      [[ "$name" =~ ^(nginx|mysql|mariadb|postgresql|redis|docker|fail2ban|certbot|ssh|cron|ufw|firewalld|systemd|dbus|network|accounts|avahi|bluetooth|cups|gdm|getty|grub|ifup|init|kernel|logrotate|logind|machine|mount|polkit|rsyslog|snapd|swap|udisks|unattended|user|apt|dpkg|lvm|mdmon|ModemManager|NetworkManager|plymouth|proc|remote|rtkit|selinux|smartd|thermald|wpa|zram) ]] && continue

      unit_file=$(systemctl show "$name.service" --property=FragmentPath 2>/dev/null | cut -d= -f2)
      [ -z "$unit_file" ] || [ ! -f "$unit_file" ] && continue
      # Only include units in /etc/systemd/system (user-created)
      [[ "$unit_file" == /etc/systemd/system/* ]] || continue

      exec_start=$(systemctl show "$name.service" --property=ExecStart 2>/dev/null | grep -oP 'path=\K[^ ]+' | head -1)
      local working_dir
      working_dir=$(systemctl show "$name.service" --property=WorkingDirectory 2>/dev/null | cut -d= -f2)
      local svc_status
      svc_status=$(systemctl is-active "$name.service" 2>/dev/null || echo "inactive")

      # Detect type from exec
      type="service"
      if echo "$exec_start" | grep -qi java; then type="java"
      elif echo "$exec_start" | grep -qi "gunicorn\|uvicorn\|python"; then type="python"
      elif echo "$exec_start" | grep -qi node; then type="nodejs"
      elif echo "$exec_start" | grep -qi php; then type="php"
      fi

      services+=("$(jq -n \
        --arg name "$name" \
        --arg type "$type" \
        --arg status "$svc_status" \
        --arg root "$working_dir" \
        --arg exec "$exec_start" \
        --arg unit "$unit_file" \
        --arg pm "systemd" \
        '{name:$name,type:$type,status:$status,root:$root,exec:$exec,
          unit_file:$unit,process_manager:$pm,log_dir:("/var/log/apps/"+$name)}')")
    done < <(systemctl list-units --type=service --state=loaded --no-pager --no-legend 2>/dev/null | grep -v "^$")
  fi

  if [ ${#services[@]} -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "${services[@]}" | jq -s '.'
  fi
}

# ─── Databases ────────────────────────────────────────────────────────────────
scan_databases() {
  local dbs=()

  # MySQL / MariaDB
  for mysql_cmd in mysql mariadb; do
    if command -v $mysql_cmd &>/dev/null; then
      local mysql_version mysql_status db_list
      mysql_version=$($mysql_cmd --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
      mysql_status=$(systemctl is-active mysql 2>/dev/null \
        || systemctl is-active mariadb 2>/dev/null || echo "unknown")
      # Get DB list without password (relies on root unix socket auth)
      db_list=$($mysql_cmd -u root -e "SHOW DATABASES;" 2>/dev/null \
        | grep -vE "^Database|information_schema|performance_schema|sys|mysql$" \
        | tr '\n' ',' | sed 's/,$//' || echo "")
      local mysql_port
      mysql_port=$(grep -r "^port" /etc/mysql/ 2>/dev/null | head -1 | awk '{print $3}' || echo "3306")

      dbs+=("$(jq -n \
        --arg engine "$mysql_cmd" \
        --arg version "$mysql_version" \
        --arg status "$mysql_status" \
        --argjson port "${mysql_port:-3306}" \
        --arg dbs "$db_list" \
        --arg data_dir "/var/lib/mysql" \
        --arg conf "/etc/mysql" \
        '{engine:$engine,version:$version,status:$status,port:$port,
          databases:(if $dbs != "" then ($dbs|split(",")) else [] end),
          data_dir:$data_dir,config_dir:$conf}')")
      break
    fi
  done

  # PostgreSQL
  if command -v psql &>/dev/null; then
    local pg_version pg_status pg_dbs pg_port
    pg_version=$(psql --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' | head -1 || echo "?")
    pg_status=$(systemctl is-active postgresql 2>/dev/null || echo "unknown")
    pg_dbs=$(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datistemplate=false;" 2>/dev/null \
      | grep -v "^postgres$" | tr '\n' ',' | sed 's/,$//' || echo "")
    pg_port=$(sudo -u postgres psql -tAc "SHOW port;" 2>/dev/null | xargs || echo "5432")

    dbs+=("$(jq -n \
      --arg engine "postgresql" \
      --arg version "$pg_version" \
      --arg status "$pg_status" \
      --argjson port "${pg_port:-5432}" \
      --arg dbs "$pg_dbs" \
      --arg data_dir "/var/lib/postgresql" \
      '{engine:$engine,version:$version,status:$status,port:$port,
        databases:(if $dbs != "" then ($dbs|split(",")) else [] end),
        data_dir:$data_dir}')")
  fi

  # Redis
  if command -v redis-cli &>/dev/null; then
    local redis_version redis_status redis_port redis_conf
    redis_version=$(redis-cli --version 2>/dev/null | awk '{print $2}' || echo "?")
    redis_status=$(systemctl is-active redis 2>/dev/null \
      || systemctl is-active redis-server 2>/dev/null || echo "unknown")
    redis_port=$(redis-cli config get port 2>/dev/null | tail -1 || echo "6379")
    redis_conf=$(find /etc/redis /etc -name "redis.conf" -maxdepth 3 2>/dev/null | head -1 || echo "")

    dbs+=("$(jq -n \
      --arg engine "redis" \
      --arg version "$redis_version" \
      --arg status "$redis_status" \
      --argjson port "${redis_port:-6379}" \
      --arg conf "$redis_conf" \
      '{engine:$engine,version:$version,status:$status,port:$port,config:$conf}')")
  fi

  # MongoDB
  if command -v mongosh &>/dev/null || command -v mongo &>/dev/null; then
    local mongo_cmd
    command -v mongosh &>/dev/null && mongo_cmd=mongosh || mongo_cmd=mongo
    local mongo_version mongo_status
    mongo_version=$($mongo_cmd --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
    mongo_status=$(systemctl is-active mongod 2>/dev/null || echo "unknown")
    local mongo_dbs
    mongo_dbs=$($mongo_cmd --quiet --eval "db.adminCommand('listDatabases').databases.map(d=>d.name).join(',')" 2>/dev/null \
      | grep -v "^$" | tail -1 || echo "")

    dbs+=("$(jq -n \
      --arg engine "mongodb" \
      --arg version "$mongo_version" \
      --arg status "$mongo_status" \
      --argjson port 27017 \
      --arg dbs "$mongo_dbs" \
      '{engine:$engine,version:$version,status:$status,port:$port,
        databases:(if $dbs != "" then ($dbs|split(",")) else [] end)}')")
  fi

  if [ ${#dbs[@]} -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "${dbs[@]}" | jq -s '.'
  fi
}

# ─── Docker ───────────────────────────────────────────────────────────────────
scan_docker() {
  if ! command -v docker &>/dev/null; then
    echo '{"installed":false}'
    return
  fi

  local docker_version docker_status
  docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
  docker_status=$(systemctl is-active docker 2>/dev/null || echo "unknown")

  # Running containers
  local containers
  containers=$(docker ps --format '{"id":"{{.ID}}","name":"{{.Names}}","image":"{{.Image}}","status":"{{.Status}}","ports":"{{.Ports}}"}' \
    2>/dev/null | jq -s '.' || echo "[]")

  # All containers (including stopped)
  local all_containers_count
  all_containers_count=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')

  # Images
  local images_count images_size
  images_count=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
  images_size=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "?")

  # Compose projects (look in standard locations)
  local compose_projects=()
  local compose_dirs=(
    "/opt/docker-apps"
    "/srv"
    "/home"
    "/root"
  )
  for base_dir in "${compose_dirs[@]}"; do
    [ -d "$base_dir" ] || continue
    while IFS= read -r compose_file; do
      local proj_dir proj_name
      proj_dir=$(dirname "$compose_file")
      proj_name=$(basename "$proj_dir")
      local compose_services
      compose_services=$(grep "^  [a-zA-Z]" "$compose_file" 2>/dev/null \
        | grep -v "^  #" | awk '{print $1}' | tr -d ':' | head -20 | tr '\n' ',' | sed 's/,$//' || echo "")

      # Check if project is running
      local compose_status
      compose_status=$(docker compose -f "$compose_file" ps --quiet 2>/dev/null | wc -l | tr -d ' ')

      compose_projects+=("$(jq -n \
        --arg name "$proj_name" \
        --arg dir "$proj_dir" \
        --arg file "$compose_file" \
        --arg services "$compose_services" \
        --argjson running "${compose_status:-0}" \
        '{name:$name,dir:$dir,compose_file:$file,
          services:(if $services != "" then ($services|split(",")) else [] end),
          running_containers:$running}')")
    done < <(find "$base_dir" -maxdepth 3 -name "docker-compose.yml" -o -name "compose.yml" 2>/dev/null)
  done

  local compose_json
  if [ ${#compose_projects[@]} -eq 0 ]; then
    compose_json="[]"
  else
    compose_json=$(printf '%s\n' "${compose_projects[@]}" | jq -s '.')
  fi

  jq -n \
    --arg version "$docker_version" \
    --arg status "$docker_status" \
    --argjson containers "$containers" \
    --argjson all_count "${all_containers_count:-0}" \
    --argjson images_count "${images_count:-0}" \
    --arg images_size "$images_size" \
    --argjson compose "$compose_json" \
    '{
      installed: true,
      version: $version,
      status: $status,
      containers: $containers,
      total_containers: $all_count,
      images: {count: $images_count, size: $images_size},
      compose_projects: $compose
    }'
}

# ─── SSL Certificates ─────────────────────────────────────────────────────────
scan_ssl() {
  local certs=()
  if ! command -v certbot &>/dev/null; then
    echo "[]"
    return
  fi

  local cert_name domains expiry days_left
  while IFS= read -r line; do
    if echo "$line" | grep -q "Certificate Name:"; then
      cert_name=$(echo "$line" | awk '{print $3}')
    elif echo "$line" | grep -q "Domains:"; then
      domains=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
    elif echo "$line" | grep -q "Expiry Date:"; then
      expiry=$(echo "$line" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1)
      if [ -n "$expiry" ]; then
        days_left=$(( ($(date -d "$expiry" +%s 2>/dev/null || echo 0) - $(date +%s)) / 86400 ))
      else
        days_left=0
      fi
      certs+=("$(jq -n \
        --arg name "$cert_name" \
        --arg domains "$domains" \
        --arg expiry "$expiry" \
        --argjson days "$days_left" \
        '{name:$name,domains:($domains|split(" ")),expires:$expiry,days_remaining:$days}')")
      cert_name=""
      domains=""
      expiry=""
    fi
  done < <(certbot certificates 2>/dev/null | grep -E "Certificate Name:|Domains:|Expiry Date:")

  if [ ${#certs[@]} -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "${certs[@]}" | jq -s '.'
  fi
}

# ─── Cron Jobs ────────────────────────────────────────────────────────────────
scan_cron() {
  local crons=()

  # System cron files
  for cron_file in /etc/cron.d/* /etc/crontab; do
    [ -f "$cron_file" ] || continue
    while IFS= read -r line; do
      [[ "$line" =~ ^#.*$ ]] && continue
      [[ -z "$line" ]] && continue
      crons+=("$(jq -n --arg line "$line" --arg src "$cron_file" '{source:$src,entry:$line}')")
    done < <(grep -v "^#\|^$\|^SHELL\|^PATH\|^MAILTO" "$cron_file" 2>/dev/null || true)
  done

  # Root crontab
  local root_crontab
  root_crontab=$(crontab -u root -l 2>/dev/null || echo "")
  if [ -n "$root_crontab" ]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^#.*$ ]] && continue
      [[ -z "$line" ]] && continue
      crons+=("$(jq -n --arg line "$line" --arg src "root-crontab" '{source:$src,entry:$line}')")
    done <<< "$root_crontab"
  fi

  if [ ${#crons[@]} -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "${crons[@]}" | jq -s '.'
  fi
}

# ─── Firewall ─────────────────────────────────────────────────────────────────
scan_firewall() {
  if command -v ufw &>/dev/null; then
    local ufw_status ufw_rules
    ufw_status=$(ufw status 2>/dev/null | head -1 | awk '{print $2}')
    ufw_rules=$(ufw status numbered 2>/dev/null | grep -E "^\[" \
      | awk -F'|' '{print $2}' | xargs -I{} echo '{}' | head -20 || echo "")
    local open_ports
    open_ports=$(ufw status 2>/dev/null | grep "ALLOW" | grep -oP '^\d+(/\w+)?' | sort -u | tr '\n' ',' | sed 's/,$//')
    jq -n \
      --arg engine "ufw" \
      --arg status "$ufw_status" \
      --arg rules "$ufw_rules" \
      --arg ports "$open_ports" \
      '{engine:$engine,status:$status,
        open_ports:(if $ports != "" then ($ports|split(",")) else [] end)}'
  elif command -v firewall-cmd &>/dev/null; then
    local fw_status fw_services
    fw_status=$(firewall-cmd --state 2>/dev/null || echo "unknown")
    fw_services=$(firewall-cmd --list-services 2>/dev/null | tr ' ' ',' || echo "")
    jq -n \
      --arg engine "firewalld" \
      --arg status "$fw_status" \
      --arg services "$fw_services" \
      '{engine:$engine,status:$status,
        services:(if $services != "" then ($services|split(",")) else [] end)}'
  else
    jq -n '{"engine":"none","status":"no firewall detected"}'
  fi
}

# ─── Open Ports ───────────────────────────────────────────────────────────────
scan_ports() {
  ss -tlnp 2>/dev/null | awk 'NR>1 {
    split($4, addr, ":");
    port = addr[length(addr)];
    match($6, /users:\(\("([^"]+)"/, arr);
    process = arr[1];
    if (port+0 > 0 && port+0 < 65536) print "{\"port\":" port+0 ",\"process\":\"" process "\"}"
  }' | sort -t: -k2 -n | jq -s 'unique_by(.port)' 2>/dev/null || echo "[]"
}

# ─── Installed runtimes ───────────────────────────────────────────────────────
scan_runtimes() {
  local runtimes=()
  declare -A runtime_cmds=(
    [nginx]="nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+'"
    [node]="node -v 2>/dev/null | tr -d v"
    [npm]="npm -v 2>/dev/null"
    [python3]="python3 --version 2>/dev/null | awk '{print \$2}'"
    [java]="java -version 2>&1 | grep -oP '[0-9]+\.[0-9.]+' | head -1"
    [php]="php -v 2>/dev/null | head -1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head-1"
    [docker]="docker version --format '{{.Server.Version}}' 2>/dev/null"
    [git]="git --version 2>/dev/null | awk '{print \$3}'"
    [certbot]="certbot --version 2>&1 | awk '{print \$2}'"
    [pm2]="pm2 -v 2>/dev/null"
    [composer]="composer --version 2>/dev/null | awk '{print \$3}'"
  )

  for name in "${!runtime_cmds[@]}"; do
    if command -v "$name" &>/dev/null; then
      local version
      version=$(eval "${runtime_cmds[$name]}" 2>/dev/null | head -1 || echo "installed")
      runtimes+=("$(jq -n --arg n "$name" --arg v "$version" '{name:$n,version:$v}')")
    fi
  done

  if [ ${#runtimes[@]} -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "${runtimes[@]}" | jq -s 'sort_by(.name)'
  fi
}

# ─── WAF Status ───────────────────────────────────────────────────────────────
scan_waf() {
  local modsec_enabled="false"
  local rate_limit_zones=0
  local security_headers="false"
  local blocklist_entries=0
  local fail2ban_bans=0

  # ModSecurity
  if command -v nginx &>/dev/null; then
    nginx -T 2>/dev/null | grep -q "modsecurity on" && modsec_enabled="true"
    rate_limit_zones=$(nginx -T 2>/dev/null | grep "limit_req_zone" | wc -l | tr -d ' ')
    nginx -T 2>/dev/null | grep -q "X-Frame-Options\|x-frame-options" && security_headers="true"
  fi

  # Nginx IP blocklist
  for bl in /etc/nginx/blocklist.conf /etc/nginx/conf.d/blocklist.conf; do
    if [ -f "$bl" ]; then
      blocklist_entries=$(grep "^deny " "$bl" 2>/dev/null | wc -l | tr -d ' ')
      break
    fi
  done

  # fail2ban total bans
  if command -v fail2ban-client &>/dev/null; then
    fail2ban_bans=$(fail2ban-client status 2>/dev/null \
      | grep "Jail list" | sed 's/.*://;s/,/\n/g' \
      | while read jail; do
          jail=$(echo "$jail" | xargs)
          [ -z "$jail" ] && continue
          fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $4}'
        done \
      | paste -sd+ 2>/dev/null | bc 2>/dev/null || echo 0)
  fi

  # UFW rules count
  local ufw_rules=0
  command -v ufw &>/dev/null && ufw_rules=$(ufw status numbered 2>/dev/null | grep "^\[" | wc -l | tr -d ' ')

  jq -n \
    --arg modsec "$modsec_enabled" \
    --argjson rate_zones "${rate_limit_zones:-0}" \
    --arg sec_headers "$security_headers" \
    --argjson blocklist "${blocklist_entries:-0}" \
    --argjson banned "${fail2ban_bans:-0}" \
    --argjson ufw_rules "${ufw_rules:-0}" \
    --arg fail2ban_status "$(systemctl is-active fail2ban 2>/dev/null || echo unknown)" \
    --arg ufw_status "$(ufw status 2>/dev/null | head -1 | awk '{print $2}' || echo unknown)" \
    '{
      modsecurity: ($modsec == "true"),
      nginx_rate_limit_zones: $rate_zones,
      security_headers: ($sec_headers == "true"),
      nginx_blocklist_entries: $blocklist,
      fail2ban: {status: $fail2ban_status, currently_banned: $banned},
      firewall: {ufw_status: $ufw_status, rule_count: $ufw_rules}
    }'
}

# ─── Users ────────────────────────────────────────────────────────────────────
scan_users() {
  local users=()

  # Non-system users (UID >= 1000, < 65534)
  while IFS=: read -r username _ uid gid gecos home shell; do
    [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] || continue
    [ "$shell" = "/usr/sbin/nologin" ] || [ "$shell" = "/bin/false" ] && user_type="sftp-only" || user_type="login"
    local groups
    groups=$(id "$username" 2>/dev/null | grep -oP 'groups=.*' | grep -oP '\(\w+\)' | tr -d '()' | tr '\n' ',' | sed 's/,$//' || echo "")
    local has_sudo="false"
    groups "$username" 2>/dev/null | grep -qE "\bsudo\b|\bwheel\b" && has_sudo="true"
    local ssh_keys=0
    [ -f "/home/$username/.ssh/authorized_keys" ] && \
      ssh_keys=$(grep "^ssh" "/home/$username/.ssh/authorized_keys" 2>/dev/null | wc -l | tr -d ' ')
    local last_login
    last_login=$(last -n 1 -w "$username" 2>/dev/null | head -1 | awk '{print $4, $5, $6, $7}' | xargs || echo "never")

    users+=("$(jq -n \
      --arg name "$username" \
      --argjson uid "$uid" \
      --arg home "$home" \
      --arg shell "$shell" \
      --arg type "$user_type" \
      --arg groups "$groups" \
      --arg sudo "$has_sudo" \
      --argjson ssh_keys "${ssh_keys:-0}" \
      --arg last_login "$last_login" \
      '{name:$name,uid:$uid,home:$home,shell:$shell,type:$type,
        groups:($groups|split(",")),sudo:($sudo=="true"),
        ssh_key_count:$ssh_keys,last_login:$last_login}')")
  done < /etc/passwd

  if [ ${#users[@]} -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "${users[@]}" | jq -s '.'
  fi
}

# ─── Network ──────────────────────────────────────────────────────────────────
scan_network() {
  local interfaces=()

  # Network interfaces
  while IFS= read -r iface; do
    [[ "$iface" =~ ^lo ]] && continue
    local ip4 ip6 state
    ip4=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet )\S+' | head -1 || echo "")
    ip6=$(ip -6 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet6 )\S+' | grep -v "^fe80" | head -1 || echo "")
    state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
    interfaces+=("$(jq -n \
      --arg name "$iface" \
      --arg ip4 "$ip4" \
      --arg ip6 "$ip6" \
      --arg state "$state" \
      '{name:$name,ipv4:$ip4,ipv6:$ip6,state:$state}')")
  done < <(ip link show 2>/dev/null | grep -oP '^\d+: \K\w+' || ls /sys/class/net/)

  local interfaces_json
  if [ ${#interfaces[@]} -eq 0 ]; then
    interfaces_json="[]"
  else
    interfaces_json=$(printf '%s\n' "${interfaces[@]}" | jq -s '.')
  fi

  # Default gateway
  local gateway
  gateway=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1 || echo "")

  # DNS servers
  local dns
  dns=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ',' | sed 's/,$//' || echo "")

  jq -n \
    --argjson interfaces "$interfaces_json" \
    --arg gateway "$gateway" \
    --arg dns "$dns" \
    '{
      interfaces: $interfaces,
      gateway: $gateway,
      dns_servers: (if $dns != "" then ($dns|split(",")) else [] end)
    }'
}

# ─── Backups ──────────────────────────────────────────────────────────────────
scan_backups() {
  local backup_dirs=("/var/backups" "/opt/backups" "/backup" "/root/backups")
  local result=()

  for dir in "${backup_dirs[@]}"; do
    [ -d "$dir" ] || continue
    local count size last_file last_modified
    count=$(find "$dir" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')
    size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}' || echo "?")
    last_file=$(find "$dir" -maxdepth 2 -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -n | tail -1 | awk '{print $2}' || echo "")
    last_modified=$(find "$dir" -maxdepth 2 -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -n | tail -1 | awk '{print $1}' \
      | xargs -I{} date -d "@{}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

    result+=("$(jq -n \
      --arg dir "$dir" \
      --argjson count "$count" \
      --arg size "$size" \
      --arg last_file "$last_file" \
      --arg last_modified "$last_modified" \
      '{dir:$dir,file_count:$count,total_size:$size,last_backup:$last_file,last_modified:$last_modified}')")
  done

  if [ ${#result[@]} -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "${result[@]}" | jq -s '.'
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  $PRINT_ONLY || require_root

  log "Scanning system..."
  local meta websites services databases docker ssl cron firewall ports runtimes backups

  log "  → meta"
  meta=$(scan_meta)
  log "  → websites (nginx)"
  websites=$(scan_websites)
  log "  → services (pm2 + systemd)"
  services=$(scan_services)
  log "  → databases"
  databases=$(scan_databases)
  log "  → docker"
  docker=$(scan_docker)
  log "  → ssl certs"
  ssl=$(scan_ssl)
  log "  → cron jobs"
  cron=$(scan_cron)
  log "  → firewall"
  firewall=$(scan_firewall)
  log "  → open ports"
  ports=$(scan_ports)
  log "  → runtimes"
  runtimes=$(scan_runtimes)
  log "  → backups"
  backups=$(scan_backups)
  log "  → waf"
  waf=$(scan_waf)
  log "  → users"
  users=$(scan_users)
  log "  → network"
  network=$(scan_network)

  local index
  index=$(jq -n \
    --argjson meta "$meta" \
    --argjson websites "$websites" \
    --argjson services "$services" \
    --argjson databases "$databases" \
    --argjson docker "$docker" \
    --argjson ssl "$ssl" \
    --argjson cron "$cron" \
    --argjson firewall "$firewall" \
    --argjson ports "$ports" \
    --argjson runtimes "$runtimes" \
    --argjson backups "$backups" \
    --argjson waf "$waf" \
    --argjson users "$users" \
    --argjson network "$network" \
    '{
      _version: "2.1",
      _generator: "generate-index.sh",
      meta: $meta,
      network: $network,
      websites: $websites,
      services: $services,
      databases: $databases,
      docker: $docker,
      ssl_certs: $ssl,
      waf: $waf,
      cron_jobs: $cron,
      firewall: $firewall,
      open_ports: $ports,
      users: $users,
      runtimes: $runtimes,
      backups: $backups
    }')

  if $PRINT_ONLY; then
    echo "$index"
  else
    echo "$index" > "$INDEX"
    chmod 600 "$INDEX"
    chown root:root "$INDEX"
    $QUIET || echo "[index] Written to $INDEX"
    $QUIET || echo "[index] Summary: $(echo "$index" | jq -r '"  websites:\(.websites|length)  services:\(.services|length)  databases:\(.databases|length)  ssl_certs:\(.ssl_certs|length)  users:\(.users|length)  docker_containers:\(.docker.containers|length)"')"
  fi
}

main "$@"
