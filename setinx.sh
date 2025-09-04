#!/bin/bash

# --------------------------
# Version
# --------------------------
VERSION="1.0.2"

# --------------------------
# Default values
# --------------------------
HOST=""
CUSTOM_PORT=""
REMOVE=false
PHP=false
SSL=false
PROJECTS_DIR="$HOME/Projects/www"
ROOT_DIR=""

# --------------------------
# Auto-detect OS
# --------------------------
OS_TYPE=$(uname -s)
if [[ "$OS_TYPE" == "Darwin" ]]; then
    OS_TYPE="macos"
elif [[ "$OS_TYPE" == "Linux" ]]; then
    OS_TYPE="linux"
else
    echo "❌ Unsupported OS: $OS_TYPE"
    exit 1
fi

# --------------------------
# Usage / Help
# --------------------------
show_help() {
  cat <<EOF
setupnginx.sh v$VERSION - Nginx dev server setup

Usage:
  $0 -h <domain> [options]

Options:
  -h, --host     Domain / host name (required, e.g., laravel.test)
  -p, --port     Custom port (default 80 HTTP / 443 HTTPS)
  -r, --root     Custom root folder (default \$HOME/Projects/www/<host_name_without_domain>)
  -P, --php      Enable PHP-FPM
  -s, --ssl      Enable HTTPS with self-signed certificate and HTTP -> HTTPS redirect
  -d, --remove   Remove site and its server block
  -H, --help     Show this help message

Examples:
  # Laravel dev, PHP-FPM, HTTPS
  $0 -h laravel.test -P -s

  # CI3 / procedural PHP
  $0 -h ci3.test -P

  # Static HTML site
  $0 -h site.local

  # Custom root folder
  $0 -h custom.dev -r \$HOME/Work/projectX

  # Remove site
  $0 -h ci3.test -d

  # Custom port
  $0 -h laravel.test -P -s -p 8081

  # Show help
  $0 -H
EOF
}

# Show help if requested
for arg in "$@"; do
  if [[ "$arg" == "-H" || "$arg" == "--help" ]]; then
    show_help
    exit 0
  fi
done

# --------------------------
# Parse arguments
# --------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -h|--host) HOST="$2"; shift ;;
    -p|--port) CUSTOM_PORT="$2"; shift ;;
    -r|--root) ROOT_DIR="$2"; shift ;;
    -P|--php) PHP=true ;;
    -s|--ssl) SSL=true ;;
    -d|--remove) REMOVE=true ;;
    -H|--help) show_help; exit 0 ;;
    *) echo "❌ Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

if [ -z "$HOST" ]; then
    echo "⚠️  Host is required. Use -h or --host"
    show_help
    exit 1
fi

# --------------------------
# Set ROOT_DIR
# --------------------------
# Ambil nama folder dari host, tanpa ekstensi .test/.dev/.local
HOST_FOLDER_NAME=$(echo "$HOST" | sed -E 's/\.(test|dev|local)$//')

DEFAULT_FOLDER="$PROJECTS_DIR/$HOST_FOLDER_NAME"

if [ -z "$ROOT_DIR" ]; then
  if [ -d "$DEFAULT_FOLDER" ]; then
    ROOT_DIR="$DEFAULT_FOLDER"
    echo "ℹ️  Folder $ROOT_DIR sudah ada, akan digunakan sebagai root"
  else
    ROOT_DIR="$DEFAULT_FOLDER"
    mkdir -p "$ROOT_DIR"
    echo "ℹ️  Folder $ROOT_DIR belum ada, dibuat baru"
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

# Default ports
PORT_HTTP=80
PORT_HTTPS=443
if [ -n "$CUSTOM_PORT" ]; then
  PORT_HTTP="$CUSTOM_PORT"
  PORT_HTTPS="$CUSTOM_PORT"
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
  nginx -s reload
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
  echo "ℹ️  Detected public/ folder, root set ke $ROOT_DIR"
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
# Add SSL block and HTTP → HTTPS redirect
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

# HTTP redirect to HTTPS
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

# Create default index.html if non-PHP
if [ "$PHP" != true ] && [ ! -f "$ROOT_DIR/index.html" ]; then
  echo "<h1>Hello from $HOST</h1>" > "$ROOT_DIR/index.html"
fi

# Add to /etc/hosts
if ! grep -q "$HOST" /etc/hosts; then
  echo "127.0.0.1   $HOST" | sudo tee -a /etc/hosts >/dev/null
  echo "✅ Added $HOST to /etc/hosts"
else
  echo "ℹ️  $HOST sudah ada di /etc/hosts"
fi

# Reload nginx
nginx -s reload

echo "🎉 Site setup complete!"
echo "   URL: http://$HOST:$PORT_HTTP"
if [ "$SSL" = true ]; then
  echo "   HTTPS: https://$HOST"
fi
echo "   Root: $ROOT_DIR"
echo "   Config: $CONF_FILE"
