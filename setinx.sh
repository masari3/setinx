#!/bin/bash
# setupnginx.sh v1.1.10

VERSION="1.1.10"
PROJECTS_DIR="$HOME/Projects/www"
NGINX_SITES_AVAILABLE="/usr/local/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/usr/local/etc/nginx/servers"

usage() {
  cat <<EOF
setupnginx.sh v$VERSION

Usage:
  ./setupnginx.sh --host <domain> [options]

Options:
  --host, -h       Set the hostname (e.g. project.test)
  --php, -p        Enable PHP-FPM (auto-detect root/public, socket or TCP)
  --php-tcp [port] Enable PHP-FPM via TCP (default: 9000, or custom port)
  --php-sock [path] Enable PHP-FPM via Unix socket (default: /tmp/php-fpm.sock)
  --ssl, -s        Enable SSL with mkcert (force redirect to HTTPS)
  --remove, -r     Remove the site (config + hosts entry + project folder check)
  --port, -P       Custom HTTP port (default: 80,443 with SSL)
  --help           Show this help message

Examples:
  ./setupnginx.sh --host myapp.test --php
  ./setupnginx.sh --host myapp.test --php --ssl
  ./setupnginx.sh --host myapp.test --php-tcp 9100 --ssl
  ./setupnginx.sh --host myapp.test --php-sock /usr/local/var/run/php-fpm.sock
  ./setupnginx.sh --host myapp.test --remove
EOF
  exit 0
}

# --- Parse args ---
HOST=""
PHP=false
PHP_TCP=false
PHP_TCP_PORT=""
PHP_SOCK_PATH=""
SSL=false
REMOVE=false
CUSTOM_PORT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --host|-h) HOST="$2"; shift 2 ;;
    --php|-p) PHP=true; shift ;;
    --php-tcp) PHP=true; PHP_TCP=true; PHP_TCP_PORT="$2"; 
               if [[ "$PHP_TCP_PORT" =~ ^[0-9]+$ ]]; then shift 2; else PHP_TCP_PORT="9000"; shift; fi ;;
    --php-sock) PHP=true; PHP_SOCK_PATH="$2"; shift 2 ;;
    --ssl|-s) SSL=true; shift ;;
    --remove|-r) REMOVE=true; shift ;;
    --port|-P) CUSTOM_PORT="$2"; shift 2 ;;
    --help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "❌ Error: --host is required."
  usage
fi

ROOT="$PROJECTS_DIR/$HOST"
CONF_PATH="$NGINX_SITES_AVAILABLE/$HOST.conf"
LINK_PATH="$NGINX_SITES_ENABLED/$HOST.conf"

# --- Remove site ---
if [[ "$REMOVE" == true ]]; then
  if [[ -f "$CONF_PATH" ]]; then
    echo "🗑 Removing site $HOST..."
    sudo rm -f "$CONF_PATH"
  fi
  if [[ -L "$LINK_PATH" ]]; then
    sudo rm -f "$LINK_PATH"
  fi
  sudo sed -i.bak "/[[:space:]]$HOST$/d" /etc/hosts
  echo "ℹ️ Project folder exists: $ROOT"
  echo "🔄 Restarting Nginx..."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    brew services restart nginx
  else
    sudo systemctl restart nginx || sudo service nginx restart
  fi
  echo "✅ $HOST removed successfully"
  exit 0
fi

# --- Create project folder ---
if [[ ! -d "$ROOT" ]]; then
  mkdir -p "$ROOT"
  echo "📂 Created project root: $ROOT"
else
  echo "ℹ️ Project folder exists: $ROOT"
fi

# --- Add to /etc/hosts ---
if ! grep -q "$HOST" /etc/hosts; then
  echo "➕ Added $HOST to /etc/hosts"
  echo "127.0.0.1 $HOST" | sudo tee -a /etc/hosts >/dev/null
fi

# --- SSL handling ---
CERT_LINE=""
SSL_LISTEN=""
SSL_REDIRECT=""

if [[ "$SSL" == true ]]; then
  if ! command -v mkcert >/dev/null 2>&1; then
    echo "❌ mkcert not found."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      echo "👉 Install with: brew install mkcert nss && mkcert -install"
    else
      echo "👉 Install with: sudo apt install mkcert && mkcert -install"
    fi
    read -p "SSL dependencies missing. Continue without SSL? (y/N): " choice
    case "$choice" in
      y|Y ) echo "⚠️  Continuing without SSL..."; SSL=false ;;
      * ) echo "❌ Aborting setup."; exit 1 ;;
    esac
  else
    CERT_DIR=$(mkcert -CAROOT)
    [[ ! -f "$CERT_DIR/$HOST.pem" ]] && mkcert "$HOST"
    CERT_LINE="ssl_certificate $CERT_DIR/$HOST.pem;
    ssl_certificate_key $CERT_DIR/$HOST-key.pem;"
    SSL_LISTEN="listen 443 ssl;"
    SSL_REDIRECT="if (\$scheme = http) { return 301 https://\$host\$request_uri; }"
  fi
fi

# --- Build PHP block ---
PHP_BLOCK=""
if [[ "$PHP" == true ]]; then
  if [[ "$PHP_TCP" == true ]]; then
    PORT="${PHP_TCP_PORT:-9000}"
    PHP_BLOCK="location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass 127.0.0.1:$PORT;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }"
  else
    SOCK="${PHP_SOCK:-/tmp/php-fpm.sock}"
    PHP_BLOCK="location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:$SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }"
  fi
fi

# --- Custom ports ---
HTTP_PORT="${CUSTOM_PORT:-80}"

# --- Write config ---
sudo mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"
cat <<EOF | sudo tee "$CONF_PATH" >/dev/null
server {
    listen $HTTP_PORT;
    $SSL_LISTEN
    server_name $HOST;
    root $ROOT;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    $PHP_BLOCK

    $SSL_REDIRECT
    $CERT_LINE
}
EOF

# --- Symlink ---
sudo ln -sf "$CONF_PATH" "$LINK_PATH"

# --- Restart nginx ---
echo "🔄 Restarting Nginx..."
if ! sudo nginx -t; then
  echo "❌ Error: nginx configuration test failed"
  exit 1
fi
sudo brew services restart nginx

# --- Final output ---
echo "🎉 Site setup complete!"
if [[ "$SSL" == true ]]; then
  echo "   URL: https://$HOST"
else
  echo "   URL: http://$HOST:$HTTP_PORT"
fi
echo "   Root: $ROOT"
echo "   Config: $CONF_PATH"
