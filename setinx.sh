#!/usr/bin/env bash
VERSION="1.0.6"

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
  --php-sock <path>      Use PHP-FPM via Unix socket (e.g. /usr/local/var/run/php-fpm.sock)
  --ssl, -s              Enable SSL (mkcert) and force redirect to HTTPS
  --remove, -r           Remove the site (nginx config + hosts entry, without deleting project root)
  --port, -P <number>    Custom HTTP port (default 80, or 443 with --ssl)
  --linux                Force Linux mode
  --macos                Force macOS mode
  --help                 Show this help message

Examples:
  ./setupnginx.sh --host myapp.test --php
  ./setupnginx.sh --host myapp.test --php --ssl
  ./setupnginx.sh --host myapp.test --php-sock /usr/local/var/run/php-fpm.sock
  ./setupnginx.sh --host myapp.test --remove
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
    --php-tcp) USE_PHP=true; PHP_MODE="tcp"; PHP_TCP_PORT="$2"; shift 2;;
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

# --------------------------
# Set ROOT_DIR
# --------------------------
HOST_FOLDER_NAME=$(echo "$HOST" | sed -E 's/\.(test|dev|local)$//')
DEFAULT_FOLDER="$PROJECTS_DIR/$HOST_FOLDER_NAME"

if [ -z "$ROOT_DIR" ]; then
  if [ -d "$DEFAULT_FOLDER" ]; then
    ROOT_DIR="$DEFAULT_FOLDER"
    echo "ℹ️  Folder $ROOT_DIR exists, will be used as root"
  else
    ROOT_DIR="$DEFAULT_FOLDER"
    mkdir -p "$ROOT_DIR"
    echo "ℹ️  Folder $ROOT_DIR does not exist, created new"
  fi
fi

# --------------------------
# Paths
# --------------------------
BREW_PREFIX=$(brew --prefix)
NGINX_DIR="$BREW_PREFIX/etc/nginx"
SITES_AVAILABLE="$NGINX_DIR/sites-available"
SITES_ENABLED="$NGINX_DIR/sites-enabled"
CONF_FILE="$SITES_AVAILABLE/$HOST.conf"
ENABLED_FILE="$SITES_ENABLED/$HOST.conf"

# --------------------------
# Port defaults
# --------------------------
if [ -n "$CUSTOM_PORT" ]; then
  PORT_HTTP="$CUSTOM_PORT"
  PORT_HTTPS="$CUSTOM_PORT"
else
  if [[ "$OS_TYPE" == "macos" ]]; then
    PORT_HTTP=8080
    PORT_HTTPS=8443
  else
    PORT_HTTP=80
    PORT_HTTPS=443
  fi
fi

# --------------------------
# REMOVE MODE
# --------------------------
if [ "$REMOVE" = true ]; then
  echo "🗑 Removing site $HOST ..."
  [ -f "$CONF_FILE" ] && rm -f "$CONF_FILE" && echo "✅ Removed $CONF_FILE"
  [ -f "$ENABLED_FILE" ] && rm -f "$ENABLED_FILE" && echo "✅ Removed symlink $ENABLED_FILE"
  if grep -q "$HOST" /etc/hosts; then
    sudo sed -i.bak "/$HOST/d" /etc/hosts
    echo "✅ Removed $HOST from /etc/hosts"
  fi
  if [[ "$OS_TYPE" == "macos" ]]; then
    brew services restart nginx
  else
    sudo systemctl restart nginx
  fi
  echo "🎉 Site $HOST removed!"
  exit 0
fi

# --------------------------
# ADD MODE
# --------------------------
mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED"

# Detect public/ for PHP projects
if [ "$PHP" = true ] && [ -d "$ROOT_DIR/public" ]; then
  ROOT_DIR="$ROOT_DIR/public"
  echo "ℹ️  Detected public/ folder, root set to $ROOT_DIR"
fi

# --------------------------
# Ensure log folder exists
# --------------------------
if [[ "$OS_TYPE" == "macos" ]]; then
  LOG_DIR="/usr/local/var/log/nginx"
  mkdir -p "$LOG_DIR"
  sudo chown -R $(whoami):staff "$LOG_DIR"
fi

# --------------------------
# SSL setup
# --------------------------
if [ "$SSL" = true ]; then
  CERT_DIR="$HOME/.nginx/certs"
  mkdir -p "$CERT_DIR"
  CRT_FILE="$CERT_DIR/$HOST.crt"
  KEY_FILE="$CERT_DIR/$HOST.key"
  if [ ! -f "$CRT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "🔐 Generating self-signed certificate for $HOST ..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$KEY_FILE" -out "$CRT_FILE" \
      -subj "/CN=$HOST/O=Dev"
  fi
fi

# --------------------------
# Generate server block
# --------------------------
if [ "$PHP" = true ]; then
cat > "$CONF_FILE" <<EOF
server {
    listen $PORT_HTTP;
    server_name $HOST;

    root $ROOT_DIR;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:$BREW_PREFIX/var/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_index index.php;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

else
cat > "$CONF_FILE" <<EOF
server {
    listen $PORT_HTTP;
    server_name $HOST;

    root $ROOT_DIR;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
fi

# --------------------------
# SSL block + redirect
# --------------------------
if [ "$SSL" = true ]; then
cat >> "$CONF_FILE" <<EOF

server {
    listen $PORT_HTTPS ssl;
    server_name $HOST;

    root $ROOT_DIR;
    index index.php index.html index.htm;

    ssl_certificate     $CRT_FILE;
    ssl_certificate_key $KEY_FILE;
EOF

if [ "$PHP" = true ]; then
cat >> "$CONF_FILE" <<'EOF'
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:'"$BREW_PREFIX"'/var/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_index index.php;
    }

    location ~ /\.ht {
        deny all;
    }
EOF
fi

cat >> "$CONF_FILE" <<EOF
}

server {
    listen $PORT_HTTP;
    server_name $HOST;
    return 301 https://\$server_name\$request_uri;
}
EOF
fi

# --------------------------
# Symlink
# --------------------------
ln -sf "$CONF_FILE" "$ENABLED_FILE"

# Default index.html if non-PHP
if [ "$PHP" != true ] && [ ! -f "$ROOT_DIR/index.html" ]; then
  echo "<h1>Hello from $HOST</h1>" > "$ROOT_DIR/index.html"
fi

# Add to /etc/hosts
if ! grep -q "$HOST" /etc/hosts; then
  echo "127.0.0.1   $HOST" | sudo tee -a /etc/hosts >/dev/null
  echo "✅ Added $HOST to /etc/hosts"
else
  echo "ℹ️  $HOST already exists in /etc/hosts"
fi

# --------------------------
# Reload Nginx
# --------------------------
if [[ "$OS_TYPE" == "macos" ]]; then
    brew services restart nginx
else
    sudo systemctl restart nginx
fi

echo "🎉 Site setup complete!"
echo "   URL: http://$HOST:$PORT_HTTP"
if [ "$SSL" = true ]; then
  echo "   HTTPS: https://$HOST:$PORT_HTTPS"
fi
echo "   Root: $ROOT_DIR"
echo "   Config: $CONF_FILE"
