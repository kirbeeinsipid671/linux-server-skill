# Deployment Guide

Full deployment workflows for every service type.

---

## Pre-Deployment Checklist

- [ ] SSH access verified
- [ ] Domain DNS A record → server IP (if using SSL)
- [ ] Server initialized (`check-system.sh` run)
- [ ] Service registry (`/etc/server-registry.json`) exists
- [ ] Log directory created: `mkdir -p /var/log/apps/<name>`

---

## Nginx Reverse Proxy Template (Node.js / Python / Java)

Use this for any service running on a local port:

```nginx
upstream <name>_backend {
    server 127.0.0.1:<port>;
    keepalive 32;
}

server {
    listen 80;
    server_name <domain> www.<domain>;

    access_log /var/log/nginx/<name>-access.log;
    error_log  /var/log/nginx/<name>-error.log;

    client_max_body_size 50M;

    location / {
        proxy_pass         http://<name>_backend;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        proxy_cache_bypass $http_upgrade;
    }

    # Static assets passthrough (optional)
    location /static/ {
        alias /var/www/<name>/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
```

Save to `/etc/nginx/sites-available/<name>` (Ubuntu/Debian) or `/etc/nginx/conf.d/<name>.conf` (RHEL/CentOS).

---

## Static Website

**Full workflow:**

```bash
NAME="my-site"
DOMAIN="example.com"
REPO="https://github.com/user/repo"   # or use rsync

# 1. Create directory
mkdir -p /var/www/$NAME
chown -R www-data:www-data /var/www/$NAME

# 2. Deploy source
git clone $REPO /var/www/$NAME
# OR upload:
# rsync -avz -e "ssh -i <key>" ./dist/ user@host:/var/www/$NAME/

# 3. Set permissions
find /var/www/$NAME -type d -exec chmod 755 {} \;
find /var/www/$NAME -type f -exec chmod 644 {} \;

# 4. Nginx vhost
cat > /etc/nginx/sites-available/$NAME << NGINX
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root /var/www/$NAME;
    index index.html index.htm;

    access_log /var/log/nginx/$NAME-access.log;
    error_log  /var/log/nginx/$NAME-error.log;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1000;

    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy strict-origin-when-cross-origin;
}
NGINX

# 5. Activate and test
ln -sf /etc/nginx/sites-available/$NAME /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 6. SSL
certbot --nginx -d $DOMAIN -d www.$DOMAIN \
  --non-interactive --agree-tos --email admin@$DOMAIN --redirect

# 7. Update registry
bash /opt/server-tools/service-registry.sh set $NAME \
  "{\"type\":\"static\",\"domain\":\"$DOMAIN\",\"root\":\"/var/www/$NAME\",\"ssl\":true}"
```

**Update (CI/CD style):**

```bash
cd /var/www/$NAME && git pull origin main
# If SPA build needed: npm run build (if build tools on server)
nginx -t && systemctl reload nginx
```

---

## Node.js Service

**Full workflow:**

```bash
NAME="my-api"
DOMAIN="api.example.com"
PORT=3000
REPO="https://github.com/user/api"
NODE_VERSION="20"   # LTS

# 1. Install Node.js via nvm (isolated per-user, easy version switching)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm" && source "$NVM_DIR/nvm.sh"
nvm install $NODE_VERSION && nvm alias default $NODE_VERSION
node -v && npm -v

# 2. Install PM2 globally
npm install -g pm2

# 3. Deploy
mkdir -p /var/www/$NAME /var/log/apps/$NAME
git clone $REPO /var/www/$NAME
cd /var/www/$NAME

# 4. Install dependencies
npm ci --omit=dev    # preferred (uses lockfile)
# OR: npm install --production

# 5. Environment variables (NEVER commit .env)
cat > /var/www/$NAME/.env << 'ENV'
NODE_ENV=production
PORT=3000
# DATABASE_URL=...
# Add your vars here
ENV
chmod 600 /var/www/$NAME/.env

# 6. PM2 ecosystem config
cat > /var/www/$NAME/ecosystem.config.js << PM2CFG
module.exports = {
  apps: [{
    name: '$NAME',
    script: './index.js',           // adjust entry point
    instances: 'max',               // cluster mode
    exec_mode: 'cluster',
    env_file: '.env',
    env: { NODE_ENV: 'production', PORT: $PORT },
    error_file: '/var/log/apps/$NAME/err.log',
    out_file: '/var/log/apps/$NAME/out.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    max_memory_restart: '512M',
    restart_delay: 3000,
    watch: false
  }]
}
PM2CFG

# 7. Start and persist
pm2 start /var/www/$NAME/ecosystem.config.js
pm2 save
pm2 startup | tail -1 | bash   # enables PM2 on boot

# 8. Nginx reverse proxy (use template above, fill in NAME, DOMAIN, PORT)
cat > /etc/nginx/sites-available/$NAME << NGINX
# ... (use the upstream template from top of this file)
NGINX
ln -sf /etc/nginx/sites-available/$NAME /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 9. SSL
certbot --nginx -d $DOMAIN --non-interactive --agree-tos \
  --email admin@$DOMAIN --redirect

# 10. Registry
bash /opt/server-tools/service-registry.sh set $NAME \
  "{\"type\":\"nodejs\",\"domain\":\"$DOMAIN\",\"root\":\"/var/www/$NAME\",\"port\":$PORT,\"process_manager\":\"pm2\"}"
```

**Update:**

```bash
cd /var/www/$NAME && git pull
npm ci --omit=dev
pm2 reload $NAME   # zero-downtime reload
```

**Useful PM2 commands:**

```bash
pm2 status          # list all processes
pm2 logs $NAME      # tail logs
pm2 restart $NAME   # hard restart
pm2 reload $NAME    # graceful reload (0 downtime)
pm2 delete $NAME    # remove from PM2
pm2 monit           # live dashboard
```

---

## Java Service (Spring Boot / JAR)

**Full workflow:**

```bash
NAME="my-java-app"
DOMAIN="java.example.com"
PORT=8080
JAR_PATH="/opt/java-apps/$NAME/$NAME.jar"

# 1. Install Java
# Ubuntu/Debian:
apt-get install -y openjdk-17-jdk
# CentOS/RHEL:
dnf install -y java-17-openjdk

java -version

# 2. Install Maven (if building on server)
# Ubuntu/Debian:
apt-get install -y maven
# CentOS/RHEL:
dnf install -y maven

# 3. Deploy directory
mkdir -p /opt/java-apps/$NAME /var/log/apps/$NAME

# Option A: Upload pre-built JAR
rsync -avz -e "ssh -i <key>" ./target/$NAME.jar user@host:/opt/java-apps/$NAME/

# Option B: Build on server
git clone $REPO /opt/java-apps/$NAME/src
cd /opt/java-apps/$NAME/src
mvn package -DskipTests -q
cp target/$NAME*.jar /opt/java-apps/$NAME/$NAME.jar

# 4. Environment file
cat > /opt/java-apps/$NAME/.env << 'ENV'
SPRING_PROFILES_ACTIVE=production
SERVER_PORT=8080
ENV
chmod 600 /opt/java-apps/$NAME/.env

# 5. Create dedicated system user (security best practice)
useradd -r -s /bin/false -d /opt/java-apps/$NAME javaapp-$NAME 2>/dev/null || true
chown -R javaapp-$NAME:javaapp-$NAME /opt/java-apps/$NAME /var/log/apps/$NAME

# 6. Systemd service unit
cat > /etc/systemd/system/$NAME.service << UNIT
[Unit]
Description=$NAME Java Service
After=network.target

[Service]
Type=simple
User=javaapp-$NAME
WorkingDirectory=/opt/java-apps/$NAME
EnvironmentFile=/opt/java-apps/$NAME/.env
ExecStart=/usr/bin/java \
  -Xms256m -Xmx512m \
  -XX:+UseG1GC \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/var/log/apps/$NAME/heap.hprof \
  -Dspring.profiles.active=production \
  -jar $NAME.jar
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/apps/$NAME/app.log
StandardError=append:/var/log/apps/$NAME/error.log

[Install]
WantedBy=multi-user.target
UNIT

# 7. Start service
systemctl daemon-reload
systemctl enable --now $NAME
systemctl status $NAME

# 8. Nginx + SSL (use reverse proxy template, PORT=8080)
# ... (same as Node.js step 8 & 9)

# 9. Registry
bash /opt/server-tools/service-registry.sh set $NAME \
  "{\"type\":\"java\",\"domain\":\"$DOMAIN\",\"root\":\"/opt/java-apps/$NAME\",\"port\":$PORT}"
```

**Update:**

```bash
# Upload new JAR
rsync -avz ./target/$NAME.jar user@host:/opt/java-apps/$NAME/
systemctl restart $NAME
```

---

## Python Service (Django / Flask / FastAPI)

**Full workflow:**

```bash
NAME="my-python-app"
DOMAIN="python.example.com"
PORT=8000
REPO="https://github.com/user/app"
PYTHON_VERSION="python3"   # or python3.11

# 1. Install Python + virtualenv
# Ubuntu/Debian:
apt-get install -y python3 python3-pip python3-venv python3-dev build-essential
# CentOS/RHEL:
dnf install -y python3 python3-pip python3-devel gcc

# 2. Install Gunicorn (WSGI server) + Uvicorn (for async/FastAPI)
# Done inside venv below

# 3. Deploy
mkdir -p /opt/python-apps/$NAME /var/log/apps/$NAME
git clone $REPO /opt/python-apps/$NAME
cd /opt/python-apps/$NAME

# 4. Create virtualenv and install deps
$PYTHON_VERSION -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
pip install gunicorn uvicorn[standard]   # add if not in requirements.txt

# 5. Environment file
cat > /opt/python-apps/$NAME/.env << 'ENV'
DEBUG=False
SECRET_KEY=change-this-to-random-secret
DATABASE_URL=sqlite:///./db.sqlite3
PORT=8000
ENV
chmod 600 /opt/python-apps/$NAME/.env

# 6. Django: collect static + migrate
# source venv/bin/activate && python manage.py collectstatic --noinput && python manage.py migrate

# 7. Create dedicated user
useradd -r -s /bin/false -d /opt/python-apps/$NAME pyapp-$NAME 2>/dev/null || true
chown -R pyapp-$NAME:pyapp-$NAME /opt/python-apps/$NAME /var/log/apps/$NAME

# 8. Gunicorn systemd service
# For Django/Flask (WSGI):
cat > /etc/systemd/system/$NAME.service << UNIT
[Unit]
Description=$NAME Python Service
After=network.target

[Service]
Type=simple
User=pyapp-$NAME
WorkingDirectory=/opt/python-apps/$NAME
EnvironmentFile=/opt/python-apps/$NAME/.env
ExecStart=/opt/python-apps/$NAME/venv/bin/gunicorn \
    --workers 4 \
    --bind 127.0.0.1:$PORT \
    --access-logfile /var/log/apps/$NAME/access.log \
    --error-logfile /var/log/apps/$NAME/error.log \
    --log-level info \
    app:application    # adjust module:callable
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# For FastAPI (ASGI), replace ExecStart with:
# ExecStart=/opt/python-apps/$NAME/venv/bin/uvicorn \
#     main:app --host 127.0.0.1 --port $PORT --workers 4

systemctl daemon-reload
systemctl enable --now $NAME
systemctl status $NAME

# 9. Nginx + SSL (use reverse proxy template)
# 10. Registry
bash /opt/server-tools/service-registry.sh set $NAME \
  "{\"type\":\"python\",\"domain\":\"$DOMAIN\",\"root\":\"/opt/python-apps/$NAME\",\"port\":$PORT}"
```

**Update:**

```bash
cd /opt/python-apps/$NAME && git pull
source venv/bin/activate && pip install -r requirements.txt
# Django: python manage.py migrate
systemctl restart $NAME
```

---

## PHP Service (Laravel / WordPress / Custom)

**Full workflow:**

```bash
NAME="my-php-app"
DOMAIN="php.example.com"
REPO="https://github.com/user/app"
PHP_VERSION="8.2"    # adjust as needed

# 1. Install PHP + extensions
# Ubuntu/Debian (with ondrej/php PPA):
add-apt-repository ppa:ondrej/php -y && apt-get update -y
apt-get install -y \
  php${PHP_VERSION} php${PHP_VERSION}-fpm \
  php${PHP_VERSION}-mysql php${PHP_VERSION}-pgsql \
  php${PHP_VERSION}-xml php${PHP_VERSION}-mbstring \
  php${PHP_VERSION}-curl php${PHP_VERSION}-zip \
  php${PHP_VERSION}-gd php${PHP_VERSION}-intl \
  php${PHP_VERSION}-bcmath php${PHP_VERSION}-redis

# CentOS/RHEL (enable remi repo for modern PHP):
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
dnf module enable php:remi-8.2 -y
dnf install -y php php-fpm php-mysqlnd php-xml php-mbstring php-gd php-zip

# 2. Install Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
composer --version

# 3. Deploy
mkdir -p /var/www/$NAME /var/log/apps/$NAME
git clone $REPO /var/www/$NAME
cd /var/www/$NAME

# 4. Install PHP deps
composer install --no-dev --optimize-autoloader

# 5. Laravel setup (if Laravel)
cp .env.example .env
php artisan key:generate
php artisan config:cache
php artisan route:cache
php artisan view:cache
php artisan storage:link
php artisan migrate --force

# 6. Permissions
chown -R www-data:www-data /var/www/$NAME
chmod -R 755 /var/www/$NAME
chmod -R 775 /var/www/$NAME/storage /var/www/$NAME/bootstrap/cache   # Laravel

# 7. PHP-FPM pool config (optional, per-app isolation)
cat > /etc/php/${PHP_VERSION}/fpm/pool.d/$NAME.conf << POOL
[$NAME]
user = www-data
group = www-data
listen = /run/php/${PHP_VERSION}-fpm-$NAME.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[error_log] = /var/log/apps/$NAME/php-error.log
POOL
systemctl reload php${PHP_VERSION}-fpm

# 8. Nginx vhost for PHP
cat > /etc/nginx/sites-available/$NAME << NGINX
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root /var/www/$NAME/public;    # Laravel: /public; WordPress: /
    index index.php index.html;

    access_log /var/log/nginx/$NAME-access.log;
    error_log  /var/log/nginx/$NAME-error.log;

    client_max_body_size 50M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/${PHP_VERSION}-fpm-$NAME.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\.(?!well-known).* { deny all; }
}
NGINX
ln -sf /etc/nginx/sites-available/$NAME /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 9. SSL
certbot --nginx -d $DOMAIN -d www.$DOMAIN \
  --non-interactive --agree-tos --email admin@$DOMAIN --redirect

# 10. Registry
bash /opt/server-tools/service-registry.sh set $NAME \
  "{\"type\":\"php\",\"domain\":\"$DOMAIN\",\"root\":\"/var/www/$NAME\",\"port\":null}"
```

**WordPress-specific:**

```bash
# Download WordPress
wget https://wordpress.org/latest.tar.gz -O /tmp/wp.tar.gz
tar -xzf /tmp/wp.tar.gz -C /var/www/$NAME --strip-components=1

# Create database (MySQL)
mysql -u root -p -e "
  CREATE DATABASE IF NOT EXISTS wp_$NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS 'wp_$NAME'@'localhost' IDENTIFIED BY '<strong-password>';
  GRANT ALL PRIVILEGES ON wp_$NAME.* TO 'wp_$NAME'@'localhost';
  FLUSH PRIVILEGES;"

# Configure wp-config.php
cp /var/www/$NAME/wp-config-sample.php /var/www/$NAME/wp-config.php
# Edit DB_NAME, DB_USER, DB_PASSWORD, DB_HOST in wp-config.php
```

---

## Docker Deployment (Alternative)

Use when the project provides a `Dockerfile` or `docker-compose.yml`.

```bash
# Install Docker
curl -fsSL https://get.docker.com | bash
usermod -aG docker $USER
systemctl enable --now docker

# Deploy with docker-compose
git clone $REPO /opt/docker-apps/$NAME
cd /opt/docker-apps/$NAME
cp .env.example .env   # edit .env
docker compose up -d --build

# Nginx reverse proxy to Docker container port
# (use same reverse proxy template, just set PORT to docker host port)

# Useful Docker commands
docker compose ps          # status
docker compose logs -f     # logs
docker compose pull && docker compose up -d    # update
docker system prune -f     # cleanup unused images
```

---

## SSL Certificate Management

### Issue cert (standard)

```bash
certbot --nginx -d <domain> --non-interactive --agree-tos \
  --email <email> --redirect
```

### Issue cert (multiple domains)

```bash
certbot --nginx -d domain.com -d www.domain.com -d api.domain.com \
  --non-interactive --agree-tos --email admin@domain.com --redirect
```

### Wildcard cert (DNS challenge)

```bash
certbot certonly --manual --preferred-challenges dns \
  -d "*.domain.com" -d "domain.com" \
  --email admin@domain.com --agree-tos
# Certbot will show a DNS TXT record to add — add it, then press Enter
```

### Auto-renewal status

```bash
# Check timer (systemd)
systemctl status certbot.timer
systemctl list-timers | grep certbot

# Check cron (fallback)
crontab -l -u root | grep certbot

# Test renewal (dry run)
certbot renew --dry-run

# Force renew a specific cert
certbot renew --cert-name <domain> --force-renewal

# List all certs and expiry
certbot certificates
```

### Manual renewal setup (if timer missing)

```bash
# Add cron for twice-daily renewal attempts (standard practice)
echo "0 0,12 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" \
  > /etc/cron.d/certbot-renew
```

---

## Database Setup

### MySQL / MariaDB

```bash
# Install
apt-get install -y mysql-server    # Ubuntu/Debian
dnf install -y mysql-server        # CentOS/RHEL

systemctl enable --now mysql

# Secure installation
mysql_secure_installation

# Create DB and user
mysql -u root -p << SQL
CREATE DATABASE IF NOT EXISTS <dbname> CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '<dbuser>'@'localhost' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON <dbname>.* TO '<dbuser>'@'localhost';
FLUSH PRIVILEGES;
SQL
```

### PostgreSQL

```bash
# Install
apt-get install -y postgresql postgresql-contrib    # Ubuntu/Debian
dnf install -y postgresql-server postgresql-contrib # CentOS/RHEL
postgresql-setup --initdb && systemctl enable --now postgresql

# Create DB and user
sudo -u postgres psql << SQL
CREATE USER <dbuser> WITH ENCRYPTED PASSWORD '<password>';
CREATE DATABASE <dbname> OWNER <dbuser>;
GRANT ALL PRIVILEGES ON DATABASE <dbname> TO <dbuser>;
SQL
```

### Redis

```bash
apt-get install -y redis-server    # Ubuntu/Debian
dnf install -y redis               # CentOS/RHEL
systemctl enable --now redis
redis-cli ping   # should return PONG
```

---

---

## Docker Full Management

### Install Docker

```bash
# Universal installer (all major distros)
curl -fsSL https://get.docker.com | bash
usermod -aG docker $USER   # add current user to docker group
systemctl enable --now docker
docker --version && docker compose version
```

### Deploy with Docker Compose

```bash
NAME="my-stack"
mkdir -p /opt/docker-apps/$NAME
cd /opt/docker-apps/$NAME

# Create or upload docker-compose.yml
cat > docker-compose.yml << 'COMPOSE'
version: "3.9"
services:
  app:
    image: my-image:latest
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
    env_file: .env
    volumes:
      - app-data:/app/data
    networks:
      - internal
  # Add more services here

volumes:
  app-data:

networks:
  internal:
    driver: bridge
COMPOSE

# Create .env file
cat > .env << 'ENV'
# App environment variables
# DATABASE_URL=...
ENV
chmod 600 .env

# Start
docker compose up -d --build

# Check status
docker compose ps
docker compose logs -f
```

### Nginx reverse proxy for Docker service

Use the standard upstream template from the top of this file, pointing to the mapped port:

```bash
# If docker-compose maps port 3000:3000, use port 3000 in the proxy
```

### Common Docker Operations

```bash
# Status of all containers (all projects)
docker ps -a

# Compose project commands (run from project dir or use -f)
cd /opt/docker-apps/<name>
docker compose ps                  # service status
docker compose logs -f             # follow all logs
docker compose logs -f <service>   # single service logs
docker compose exec <service> sh   # shell into container
docker compose restart <service>   # restart one service
docker compose down                # stop + remove containers (keep volumes)
docker compose down -v             # stop + remove containers AND volumes
docker compose pull && docker compose up -d   # update images

# Container management
docker ps                          # running containers
docker ps -a                       # all containers
docker stop <name>                 # stop container
docker rm <name>                   # remove container
docker logs <name> -f --tail 100   # container logs
docker exec -it <name> bash        # interactive shell
docker stats                       # live resource usage

# Image management
docker images                      # list images
docker pull <image>                # pull latest
docker rmi <image>                 # remove image
docker image prune                 # remove dangling images

# Volume management
docker volume ls
docker volume inspect <name>
docker volume rm <name>            # careful: deletes data

# Network management
docker network ls
docker network inspect bridge

# System cleanup
docker system prune -f             # remove stopped containers + dangling images
docker system prune -af            # remove ALL unused images too
docker system df                   # disk usage
```

### Docker Registry (private)

```bash
# Run a private registry
docker run -d --restart=unless-stopped \
  -p 5000:5000 \
  -v /opt/docker-registry:/var/lib/registry \
  --name registry \
  registry:2

# Tag and push to private registry
docker tag my-image:latest localhost:5000/my-image:latest
docker push localhost:5000/my-image:latest

# Pull from private registry
docker pull <server-ip>:5000/my-image:latest
```

### Docker with Nginx SSL termination

```bash
# docker-compose.yml for a service with Nginx+SSL in front
cat > /opt/docker-apps/$NAME/docker-compose.yml << 'COMPOSE'
version: "3.9"
services:
  app:
    image: my-image:latest
    restart: unless-stopped
    expose:
      - "3000"        # expose internally, not to host
    networks:
      - web
    environment:
      - NODE_ENV=production

networks:
  web:
    driver: bridge
COMPOSE

# Then configure Nginx to proxy to the container's exposed port
# Find the container's internal IP or use host port mapping
```

### Useful Docker Compose Files

**Monitoring Stack (Grafana + Prometheus):**

```yaml
# /opt/docker-apps/monitoring/docker-compose.yml
version: "3.9"
services:
  prometheus:
    image: prom/prometheus:latest
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"

  grafana:
    image: grafana/grafana:latest
    restart: unless-stopped
    volumes:
      - grafana-data:/var/lib/grafana
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=change-this

  node-exporter:
    image: prom/node-exporter:latest
    restart: unless-stopped
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro

volumes:
  prometheus-data:
  grafana-data:
```

**Database Stack (MySQL + phpMyAdmin):**

```yaml
# /opt/docker-apps/mysql/docker-compose.yml
version: "3.9"
services:
  mysql:
    image: mysql:8.0
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - mysql-data:/var/lib/mysql
    ports:
      - "127.0.0.1:3306:3306"

  phpmyadmin:
    image: phpmyadmin/phpmyadmin:latest
    restart: unless-stopped
    environment:
      PMA_HOST: mysql
      PMA_PORT: 3306
    ports:
      - "127.0.0.1:8080:80"
    depends_on:
      - mysql

volumes:
  mysql-data:
```

**Uptime Kuma (Service Monitoring):**

```yaml
# /opt/docker-apps/uptime-kuma/docker-compose.yml
version: "3.9"
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:3001:3001"
```

---

## Deployment Troubleshooting

| Symptom | Check |
|---------|-------|
| 502 Bad Gateway | Service not running: `pm2 status` / `systemctl status <name>` |
| 403 Forbidden | File permissions: `ls -la /var/www/<name>` |
| 404 Not Found | Nginx root path wrong or `try_files` missing |
| SSL cert fails | DNS not propagated yet; check with `dig +short <domain>` |
| PHP not executing | PHP-FPM not running: `systemctl status phpX.X-fpm` |
| Java OOM | Increase `-Xmx` in systemd unit, or check heap dump |
| Port conflict | `ss -tlnp | grep <port>` |
| SELinux deny | `journalctl -xe | grep denied` → `setsebool -P httpd_can_network_connect 1` |
