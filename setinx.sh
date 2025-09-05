#!/bin/bash
# setupnginx.sh v1.0.8
# Nginx virtual host setup helper for macOS & Linux
# Author: masari x ChatGPT

VERSION="1.0.8"

# Default values
OS=""
USE_PHP=false
PHP_MODE=""       # tcp / sock
PHP_TCP_PORT=""   # tcp port number
PHP_SOCK_PATH=""  # sock path
USE_SSL=false
REMOVE=false
CUSTOM_PORT=""
HOST=""

# Usage
usage() {
  cat <<EOF
setupnginx.sh v$VERSION

Usage:
  ./setupnginx.sh --host <domain> [options]

Options:
  --host, -h <domain>   Set hostname (required)
  --php, -p             Enable PHP-FPM (default TCP port 9000)
  --php-tcp [port]      Use PHP-FPM via TCP (default: 127.0.0.1:9000 if port omitted)
  --php-sock <path>     Use PHP-FPM via Unix socket (e.g. /usr/local/var/run/php-fpm.sock)
  --ssl, -s             Enable SSL and force redirect to HTTPS
  --remove, -r          Remove the site (config + hosts entry + project folder check)
  --port, -P <number>   Custom HTTP port (default: 80 / 443 with --ssl)
  --linux               Force Linux mode
  --macos               Force macOS mode
  --help                Show this help message

Examples:
  ./setupnginx.sh --host myapp.test --php
  ./setupnginx.sh --host myapp.test --php-tcp
  ./setupnginx.sh --host myapp.test --php-tcp 9070
  ./setupnginx.sh --host myapp.test --php-sock /usr/local/var/run/php-fpm.sock
  ./setupnginx.sh --host myapp.test --php --ssl
  ./setupnginx.sh --host myapp.test --remove

EOF
  exit 0
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|-h)
      HOST="$2"
      shift 2
      ;;
    --php|-p)
      USE_PHP=true
      PHP_MODE="tcp"
      PHP_TCP_PORT="9000"
      shift 1
      ;;
    --php-tcp)
      USE_PHP=true
      PHP_MODE="tcp"
      if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
        PHP_TCP_PORT="$2"
        shift 2
      else
        PHP_TCP_PORT="9000"
        shift 1
      fi
      ;;
    --php-sock)
      USE_PHP=true
      PHP_MODE="sock"
      PHP_SOCK_PATH="$2"
      shift 2
      ;;
    --ssl|-s)
      USE_SSL=true
      shift 1
      ;;
    --remove|-r)
      REMOVE=true
      shift 1
      ;;
    --port|-P)
      CUSTOM_PORT="$2"
      shift 2
      ;;
    --linux)
      OS="linux"
      shift 1
      ;;
    --macos)
      OS="macos"
      shift 1
      ;;
    --help)
      usage
      ;;
    *)
      echo "❌ Unknown option: $1"
      usage
      ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "❌ Error: --host is required"
  usage
fi

# Detect OS if not forced
if [[ -z "$OS" ]]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
  else
    OS="linux"
  fi
fi

# Paths
if [[ "$OS" == "macos" ]]; then
  NGINX_CONF_DIR="/usr/local/etc/nginx"
  NGINX_SITES_AVAILABLE="$NGINX_CONF_DIR/servers"
  NGINX_SITES_ENABLED="$NGINX_CONF_DIR/servers"
  NGINX_BIN="brew services restart nginx"
else
  NGINX_CONF_DIR="/etc/nginx"
  NGINX_SITES_AVAILABLE="$NGINX_CONF_DIR/sites-available"
  NGINX_SITES_ENABLED="$NGINX_CONF_DIR/sites-enabled"
  NGINX_BIN="systemctl restart nginx"
fi

PROJECTS_DIR="$HOME/Projects/www"
PROJECT_ROOT="$PROJECTS_DIR/$HOST"
CONFIG_FILE="$NGINX_SITES_AVAILABLE/$HOST.conf"

# Remove site
if [[ "$REMOVE" == true ]]; then
  if [[ -d "$PROJECT_ROOT" ]]; then
    echo "ℹ️ Project folder exists: $PROJECT_ROOT"
  fi
  echo "🗑 Removing site $HOST..."
  sudo rm -f "$CONFIG_FILE"
  sudo sed -i.bak "/$HOST/d" /etc/hosts
  $NGINX_BIN
  echo "✅ $HOST removed successfully"
  exit 0
fi

# Create dirs
mkdir -p "$PROJECT_ROOT"
echo "📂 Created project root: $PROJECT_ROOT"

# Add to hosts
if ! grep -q "$HOST" /etc/hosts; then
  echo "➕ Added $HOST to /etc/hosts"
  echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts >/dev/null
fi

# Listen port
if [[ -n "$CUSTOM_PORT" ]]; then
  LISTEN_PORT="$CUSTOM_PORT"
else
  LISTEN_PORT="80"
fi
LISTEN_SSL_PORT="443"

# Generate config
CONF="server {
    listen $LISTEN_PORT;
    server_name $HOST;
    root $PROJECT_ROOT;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
"

if [[ "$USE_PHP" == true ]]; then
  CONF+="
    location ~ \.php\$ {
        include fastcgi_params;
"
  if [[ "$PHP_MODE" == "tcp" ]]; then
    CONF+="        fastcgi_pass 127.0.0.1:${PHP_TCP_PORT};
"
  elif [[ "$PHP_MODE" == "sock" ]]; then
    CONF+="        fastcgi_pass unix:${PHP_SOCK_PATH};
"
  fi
  CONF+="        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
"
fi

CONF+="}
"

# SSL block
if [[ "$USE_SSL" == true ]]; then
  CONF="server {
    listen 80;
    server_name $HOST;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $HOST;
    root $PROJECT_ROOT;
    index index.php index.html index.htm;

    ssl_certificate $(mkcert -CAROOT)/$HOST.pem;
    ssl_certificate_key $(mkcert -CAROOT)/$HOST-key.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
"

  if [[ "$USE_PHP" == true ]]; then
    CONF+="
    location ~ \.php\$ {
        include fastcgi_params;
"
    if [[ "$PHP_MODE" == "tcp" ]]; then
      CONF+="        fastcgi_pass 127.0.0.1:${PHP_TCP_PORT};
"
    elif [[ "$PHP_MODE" == "sock" ]]; then
      CONF+="        fastcgi_pass unix:${PHP_SOCK_PATH};
"
    fi
    CONF+="        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
"
  fi

  CONF+="}
"
fi

# Save config
echo "$CONF" | sudo tee "$CONFIG_FILE" >/dev/null

# Restart Nginx
echo "🔄 Restarting Nginx..."
if ! sudo nginx -t; then
  echo "❌ Error: nginx configuration test failed"
  exit 1
fi
$NGINX_BIN

# Final info
echo "🎉 Site setup complete!"
echo "   URL: http://$HOST:$HTTP_PORT"
echo "   Root: $SITE_ROOT"
echo "   Config: $CONF_FILE"
