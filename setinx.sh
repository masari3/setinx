#!/usr/bin/env bash
VERSION="1.0.7"

# ==============================
# Default values
# ==============================
OS=""
USE_PHP=false
PHP_MODE="tcp"
PHP_TCP_PORT="9000"
PHP_SOCK_PATH=""
USE_SSL=false
REMOVE_MODE=false
CUSTOM_PORT=""
HOST=""

# ==============================
# Usage
# ==============================
usage() {
  cat <<EOF
setupnginx.sh v$VERSION

Usage:
  ./setupnginx.sh --host <domain> [options]

Options:
  --host, -h <domain>    Set hostname (required)
  --php, -p              Enable PHP-FPM (default TCP 127.0.0.1:9000)
  --php-tcp <port>       Use PHP-FPM via TCP (custom port, default 9000)
  --php-sock <path>      Use PHP-FPM via Unix socket
  --ssl, -s              Enable SSL (mkcert) and redirect HTTP -> HTTPS
  --remove, -r           Remove the site (nginx config + hosts entry)
  --port, -P <number>    Custom HTTP port (default 80, or 443 with --ssl)
  --linux                Force Linux mode
  --macos                Force macOS mode
  --help                 Show this help message
EOF
  exit 0
}

# ==============================
# Parse Arguments
# ==============================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|-h) HOST="$2"; shift 2;;
    --php|-p) USE_PHP=true; shift;;
    --php-tcp) USE_PHP=true; PHP_MODE="tcp"; PHP_TCP_PORT="${2:-9000}"; shift 2;;
    --php-sock) USE_PHP=true; PHP_MODE="sock"; PHP_SOCK_PATH="$2"; shift 2;;
    --ssl|-s) USE_SSL=true; shift;;
    --remove|-r) REMOVE_MODE=true; shift;;
    --port|-P) CUSTOM_PORT="$2"; shift 2;;
    --linux) OS="linux"; shift;;
    --macos) OS="macos"; shift;;
    --help) usage;;
    *) echo "❌ Unknown option: $1"; usage;;
  esac
done

# ==============================
# Validation
# ==============================
if [[ -z "$HOST" ]]; then
  echo "❌ Error: --host is required"
  usage
fi

# ==============================
# Detect OS
# ==============================
if [[ -z "$OS" ]]; then
  case "$(uname -s)" in
    Linux*) OS="linux";;
    Darwin*) OS="macos";;
    *) echo "❌ Unsupported OS"; exit 1;;
  esac
fi

# ==============================
# Paths
# ==============================
if [[ "$OS" == "macos" ]]; then
  NGINX_CONF_DIR="/usr/local/etc/nginx"
  NGINX_SITES_AVAILABLE="$NGINX_CONF_DIR/sites-available"
  NGINX_SITES_ENABLED="$NGINX_CONF_DIR/sites-enabled"
elif [[ "$OS" == "linux" ]]; then
  NGINX_CONF_DIR="/etc/nginx"
  NGINX_SITES_AVAILABLE="$NGINX_CONF_DIR/sites-available"
  NGINX_SITES_ENABLED="$NGINX_CONF_DIR/sites-enabled"
fi

PROJECTS_ROOT="$HOME/Projects/www/$HOST"

# ==============================
# Remove mode
# ==============================
if $REMOVE_MODE; then
  echo "🗑 Removing site: $HOST"
  sudo rm -f "$NGINX_SITES_AVAILABLE/$HOST.conf"
  sudo rm -f "$NGINX_SITES_ENABLED/$HOST.conf"
  sudo sed -i.bak "/$HOST/d" /etc/hosts
  sudo nginx -s reload || true
  echo "✅ Site $HOST removed."
  exit 0
fi

# ==============================
# Prepare project folder
# ==============================
if [[ ! -d "$PROJECTS_ROOT" ]]; then
  mkdir -p "$PROJECTS_ROOT"
  echo "📂 Created project root: $PROJECTS_ROOT"
  echo "<?php phpinfo();" > "$PROJECTS_ROOT/index.php"
else
  echo "ℹ️  Folder $PROJECTS_ROOT already exists, using it."
fi

# ==============================
# Add to /etc/hosts
# ==============================
if ! grep -q "$HOST" /etc/hosts; then
  echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts > /dev/null
  echo "➕ Added $HOST to /etc/hosts"
else
  echo "ℹ️  $HOST already exists in /etc/hosts"
fi

# ==============================
# Nginx Config
# ==============================
HTTP_PORT="${CUSTOM_PORT:-80}"
HTTPS_PORT="443"
NGINX_CONFIG="$NGINX_SITES_AVAILABLE/$HOST.conf"

sudo mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"

cat <<EOF | sudo tee "$NGINX_CONFIG" > /dev/null
server {
    listen $HTTP_PORT;
    server_name $HOST;
    root $PROJECTS_ROOT;

    index index.php index.html index.htm;

    access_log /var/log/nginx/${HOST}_access.log;
    error_log  /var/log/nginx/${HOST}_error.log;

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
