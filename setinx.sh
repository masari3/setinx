#!/bin/bash
# setupnginx.sh v1.0.7
VERSION="1.0.7"

set -e

PROJECTS_ROOT="$HOME/Projects/www"
NGINX_ETC="/usr/local/etc/nginx"
SITES_AVAILABLE="$NGINX_ETC/sites-available"
SITES_ENABLED="$NGINX_ETC/sites-enabled"

USE_PHP=false
USE_SSL=false
REMOVE=false
CUSTOM_PORT=""
PHP_TCP=""
PHP_SOCK=""
HOST=""

# Usage
usage() {
  cat <<EOF
setupnginx.sh v$VERSION

Usage:
  ./setupnginx.sh --host <domain> [options]

Options:
  --host, -h <domain>   Set hostname (required)
  --php, -p             Enable PHP-FPM (default TCP 127.0.0.1:9000)
  --php-tcp <port>      Use PHP-FPM via TCP (default: 127.0.0.1:9000)
  --php-sock <path>     Use PHP-FPM via Unix socket (e.g. /usr/local/var/run/php-fpm.sock)
  --ssl, -s             Enable SSL with mkcert (force redirect to HTTPS)
  --remove, -r          Remove the site (config + hosts entry + project folder check)
  --port, -P <number>   Custom HTTP port (default: 80 / 443 with --ssl)
  --help                Show this help message

Examples:
  ./setupnginx.sh --host myapp.test --php
  ./setupnginx.sh --host myapp.test --php --ssl
  ./setupnginx.sh --host myapp.test --php-tcp 9000
  ./setupnginx.sh --host myapp.test --php-sock /usr/local/var/run/php-fpm.sock
  ./setupnginx.sh --host myapp.test --remove
EOF
  exit 0
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|-h) HOST="$2"; shift 2 ;;
    --php|-p) USE_PHP=true; shift ;;
    --php-tcp) USE_PHP=true; PHP_TCP="$2"; shift 2 ;;
    --php-sock) USE_PHP=true; PHP_SOCK="$2"; shift 2 ;;
    --ssl|-s) USE_SSL=true; shift ;;
    --remove|-r) REMOVE=true; shift ;;
    --port|-P) CUSTOM_PORT="$2"; shift 2 ;;
    --help) usage ;;
    *) echo "❌ Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "❌ Error: --host is required"
  usage
fi

SITE_ROOT="$PROJECTS_ROOT/$HOST"
CONF_FILE="$SITES_AVAILABLE/$HOST.conf"

restart_nginx() {
  echo "🔄 Restarting Nginx..."
  if command -v brew &>/dev/null && brew services list | grep -q nginx; then
    brew services restart nginx >/dev/null
  else
    sudo nginx -s reload
  fi
}

remove_site() {
  echo "ℹ️ Project folder exists: $SITE_ROOT"
  echo "🗑 Removing site $HOST..."
  sudo rm -f "$CONF_FILE"
  sudo rm -f "$SITES_ENABLED/$HOST.conf"
  sudo sed -i.bak "/$HOST/d" /etc/hosts
  restart_nginx
  echo "✅ $HOST removed successfully"
  exit 0
}

if [[ "$REMOVE" == true ]]; then
  remove_site
fi

# Ensure dirs
mkdir -p "$PROJECTS_ROOT" "$SITES_AVAILABLE" "$SITES_ENABLED"

# Create project root if not exists
if [[ ! -d "$SITE_ROOT" ]]; then
  mkdir -p "$SITE_ROOT"
  echo "📂 Created project root: $SITE_ROOT"
fi

# Add to /etc/hosts
if ! grep -q "$HOST" /etc/hosts; then
  echo "➕ Added $HOST to /etc/hosts"
  echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts >/dev/null
fi

# Ports
HTTP_PORT="${CUSTOM_PORT:-80}"
HTTPS_PORT="443"

# Generate config
cat <<EOF | sudo tee "$CONF_FILE" >/dev/null
server {
    listen $HTTP_PORT;
    server_name $HOST;
    root $SITE_ROOT;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
EOF

if [[ "$USE_PHP" == true ]]; then
  if [[ -n "$PHP_TCP" ]]; then
    FASTCGI="127.0.0.1:$PHP_TCP"
  elif [[ -n "$PHP_SOCK" ]]; then
    FASTCGI="unix:$PHP_SOCK"
  else
    FASTCGI="127.0.0.1:9000"
  fi

  cat <<EOF | sudo tee -a "$CONF_FILE" >/dev/null
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass $FASTCGI;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
EOF
fi

cat <<EOF | sudo tee -a "$CONF_FILE" >/dev/null
}
EOF

if $USE_SSL; then
  mkcert -install
  mkcert "$HOST"

  # Redirect HTTP -> HTTPS
  cat <<EOF | sudo tee -a "$NGINX_CONFIG" > /dev/null

server {
    listen $HTTP_PORT;
    server_name $HOST;
    return 301 https://\$host\$request_uri;
}

server {
    listen $HTTPS_PORT ssl http2;
    server_name $HOST;
    root $PROJECTS_ROOT;

    ssl_certificate     $(pwd)/$HOST.pem;
    ssl_certificate_key $(pwd)/$HOST-key.pem;

    index index.php index.html index.htm;

    access_log /var/log/nginx/${HOST}_ssl_access.log;
    error_log  /var/log/nginx/${HOST}_ssl_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
EOF

  if $USE_PHP; then
    if [[ "$PHP_MODE" == "tcp" ]]; then
      cat <<EOF | sudo tee -a "$NGINX_CONFIG" > /dev/null
    location ~ \.php\$ {
        include fastcgi.conf;
        fastcgi_pass 127.0.0.1:$PHP_TCP_PORT;
    }
EOF
    else
      cat <<EOF | sudo tee -a "$NGINX_CONFIG" > /dev/null
    location ~ \.php\$ {
        include fastcgi.conf;
        fastcgi_pass unix:$PHP_SOCK_PATH;
    }
EOF
    fi
  fi

  echo "}" | sudo tee -a "$NGINX_CONFIG" > /dev/null
fi

# ==============================
# Enable site
# ==============================
sudo ln -sf "$NGINX_SITES_AVAILABLE/$HOST.conf" "$NGINX_SITES_ENABLED/$HOST.conf"

# ==============================
# Reload nginx
# ==============================
sudo nginx -t && sudo nginx -s reload

# ==============================
# Done
# ==============================
echo "🎉 Site setup complete!"
echo "   URL: http://$HOST:$HTTP_PORT"
if $USE_SSL; then
  echo "   HTTPS: https://$HOST"
fi
echo "   Root: $PROJECTS_ROOT"
echo "   Config: $NGINX_CONFIG"
