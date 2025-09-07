#!/bin/bash
# setupnginx.sh v1.1.6 (Added PHP installation check + Improved error handling)

VERSION="1.1.6"
PROJECTS_DIR="$HOME/Projects/www"
NGINX_SITES_AVAILABLE="/usr/local/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/usr/local/etc/nginx/servers"
HOSTS_FILE="/etc/hosts"
HOSTS_BACKUP="/etc/hosts.bak"

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Usage ---
usage() {
  cat <<EOF
setupnginx.sh v$VERSION

Usage:
  ./setupnginx.sh --host <domain> [options]

Options:
  --host, -h        Set hostname (e.g. project.test) *Required
  --project-name, -n Set project folder name (e.g. myapp)
  --php, -p         Enable PHP-FPM (TCP port 9000) *Default for macOS
  --php-tcp [port]  PHP-FPM via TCP (default: 9000)
  --php-sock <path> PHP-FPM via Unix socket
  --ssl, -s         Enable SSL (mkcert)
  --remove, -r      Remove site (config + hosts)
  --port, -P        Custom HTTP port (default 80)
  --help            Show this help

Examples:
  ./setupnginx.sh --host myapp.test --project-name myapp --php
  ./setupnginx.sh --host myapp.test --php --ssl
  ./setupnginx.sh --host api.project.test -n project-api --ssl
  ./setupnginx.sh --host myapp.test --remove
EOF
  exit 0
}

# --- Parse arguments ---
HOST=""
PROJECT_NAME=""
PHP=false
PHP_TCP=false
PHP_TCP_PORT="9000"
PHP_SOCK_PATH=""
SSL=false
REMOVE=false
CUSTOM_PORT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --host|-h) HOST="$2"; shift 2 ;;
    --project-name|-n) PROJECT_NAME="$2"; shift 2 ;;
    --php|-p) PHP=true; PHP_TCP=true; shift ;; # Default to TCP 9000
    --php-tcp) PHP=true; PHP_TCP=true; PHP_TCP_PORT="$2";
               if [[ ! "$PHP_TCP_PORT" =~ ^[0-9]+$ ]]; then PHP_TCP_PORT="9000"; fi; shift $(( $#>=2 ? 2 : 1 )) ;;
    --php-sock) PHP=true; PHP_SOCK_PATH="$2"; shift 2 ;;
    --ssl|-s) SSL=true; shift ;;
    --remove|-r) REMOVE=true; shift ;;
    --port|-P) CUSTOM_PORT="$2"; shift 2 ;;
    --help) usage ;;
    *) echo "❌  Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "❌ Error: --host is required."
  usage
fi

# --- Determine project folder name ---
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="${HOST%%.*}"
  echo "ℹ️   Using default project name: $PROJECT_NAME"
fi

ROOT="$PROJECTS_DIR/$PROJECT_NAME"
CONF_PATH="$NGINX_SITES_AVAILABLE/$HOST.conf"
LINK_PATH="$NGINX_SITES_ENABLED/$HOST.conf"
HTTP_PORT="${CUSTOM_PORT:-80}"

# --- Function: Backup hosts ---
backup_hosts() {
  if [[ -f "$HOSTS_FILE" ]]; then
    sudo cp "$HOSTS_FILE" "$HOSTS_BACKUP"
    echo -e "${GREEN}💾  Backup hosts file created at $HOSTS_BACKUP${NC}"
  fi
}

# --- Check PHP Installation ---
check_php_installation() {
    if [[ "$PHP" == true ]]; then
        echo -e "${BLUE}🔍  Checking PHP installation...${NC}"
        
        # Check if Homebrew is installed
        if ! command -v brew >/dev/null 2>&1; then
            echo -e "${RED}❌  ERROR: Homebrew is not installed${NC}"
            echo "    Please install Homebrew first:"
            echo "    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            exit 1
        fi
        
        # Check if PHP formula is installed via Homebrew
        if ! brew list --formula | grep -q "^php@\?[0-9.]*$"; then
            echo -e "${RED}❌  ERROR: PHP is not installed via Homebrew${NC}"
            echo "    Please install PHP first:"
            echo "    brew install php"
            echo "    or"
            echo "    brew install php@8.3"
            echo "    or specific version: brew install php@8.2"
            exit 1
        fi
        
        # Check PHP version
        if command -v php >/dev/null 2>&1; then
            PHP_VERSION=$(php -v | head -1 | awk '{print $2}' | cut -d. -f1-2)
            echo -e "${GREEN}✅  PHP $PHP_VERSION is installed${NC}"
        else
            echo -e "${RED}❌  ERROR: PHP is installed but not in PATH${NC}"
            echo "    Please check your PHP installation and PATH configuration"
            exit 1
        fi
    fi
}

# --- Check PHP-FPM Status ---
check_php_fpm() {
    if [[ "$PHP" == true ]]; then
        echo "🔍  Checking PHP-FPM status..."
        
        if [[ "$PHP_TCP" == true ]]; then
            PORT="${PHP_TCP_PORT:-9000}"
            if lsof -i:$PORT >/dev/null 2>&1; then
                echo "✅  PHP-FPM is running on TCP port $PORT"
            else
                echo "❌  ERROR: PHP-FPM is NOT running on TCP port $PORT"
                echo "    Please start PHP-FPM: brew services start php"
                exit 1
            fi
        else
            SOCK_PATH="${PHP_SOCK_PATH:-/tmp/php-fpm.sock}"
            if [[ -S "$SOCK_PATH" ]]; then
                echo "✅  PHP-FPM socket found: $SOCK_PATH"
            else
                echo "❌  ERROR: PHP-FPM socket NOT found: $SOCK_PATH"
                echo "    Please start PHP-FPM: brew services start php"
                exit 1
            fi
        fi
    fi
}

# --- Fix Permissions ---
fix_permissions() {
    echo "🔧  Fixing file permissions..."
    
    # Set ownership to user
    sudo chown -R $(whoami):staff "$ROOT"
    
    # Set appropriate permissions
    find "$ROOT" -type d -exec chmod 755 {} \;
    find "$ROOT" -type f -exec chmod 644 {} \;
    
    # Jika ada folder writable yang khusus untuk CodeIgniter
    if [[ -d "$ROOT/application/cache" ]]; then
        chmod -R 775 "$ROOT/application/cache"
    fi
    if [[ -d "$ROOT/application/logs" ]]; then
        chmod -R 775 "$ROOT/application/logs"
    fi
    if [[ -d "$ROOT/writable" ]]; then
        chmod -R 775 "$ROOT/writable"
    fi
    
    echo "✅  Permissions fixed"
}

# --- Test PHP-FPM Connection ---
test_php_fpm() {
    if [[ "$PHP" == true ]]; then
        echo "🧪  Testing PHP-FPM connection..."
        
        # Create test PHP file
        TEST_FILE="$WEB_ROOT/test.php"
        echo "<?php 
        echo 'PHP is working!';
        echo 'PHP Version: ' . phpversion();
        ?>" | sudo tee "$TEST_FILE" >/dev/null
        
        # Fix permissions immediately
        sudo chown $(whoami):staff "$TEST_FILE"
        chmod 644 "$TEST_FILE"
        
        # Test via curl dengan timeout
        echo "🔗  Testing URL: http://$HOST:$HTTP_PORT/test.php"
        
        if response=$(curl -s --connect-timeout 10 "http://$HOST:$HTTP_PORT/test.php"); then
            if echo "$response" | grep -q "PHP is working"; then
                echo "✅  PHP-FPM connection successful"
                echo "    Response: $response"
                sudo rm -f "$TEST_FILE"
            else
                echo "❌  PHP-FPM returned unexpected response"
                echo "    Response: $response"
                echo "    Please check PHP-FPM configuration manually"
            fi
        else
            echo "❌  PHP-FPM connection failed (timeout or connection error)"
            echo "    Test file: $TEST_FILE"
            echo "    Please check:"
            echo "    1. PHP-FPM is running: brew services start php"
            echo "    2. Nginx configuration"
            echo "    3. File permissions"
        fi
    fi
}

# --- Remove site ---
if [[ "$REMOVE" == true ]]; then
  echo "🗑   Removing site $HOST..."
  backup_hosts
  [[ -f "$CONF_PATH" ]] && sudo rm -f "$CONF_PATH"
  [[ -L "$LINK_PATH" ]] && sudo rm -f "$LINK_PATH"
  sudo sed -i.bak "/[[:space:]]$HOST$/d" "$HOSTS_FILE"
  echo "ℹ️   Project folder: $ROOT"
  echo "🔄  Restarting Nginx..."
  brew services restart nginx
  echo "✅  $HOST removed successfully"
  exit 0
fi

# --- Create project folder ---
if [[ ! -d "$ROOT" ]]; then
  mkdir -p "$ROOT"
  echo "📂 Created project root: $ROOT"
else
  echo "ℹ️ Project folder exists: $ROOT"
fi

# --- Simple Auto-detect web root folder ---
if [[ -d "$ROOT/public" ]]; then
  WEB_ROOT="$ROOT/public"
  echo "🌐  Detected Laravel-like structure, using web root: $WEB_ROOT"
else
  WEB_ROOT="$ROOT"
  echo "🌐  Using project root as web root: $WEB_ROOT"
fi

# --- Check PHP-FPM before proceeding ---
check_php_fpm

# --- Fix permissions for CodeIgniter ---
fix_permissions

# --- Add to /etc/hosts ---
if ! grep -q "$HOST" "$HOSTS_FILE"; then
  backup_hosts
  echo "127.0.0.1 $HOST" | sudo tee -a "$HOSTS_FILE" >/dev/null
  echo "➕  Added $HOST to $HOSTS_FILE"
fi

# --- SSL handling ---
CERT_LINE=""
SSL_LISTEN=""
SSL_REDIRECT=""

if [[ "$SSL" == true ]]; then
  if command -v mkcert >/dev/null 2>&1; then
    CERT_DIR=$(mkcert -CAROOT)
    [[ ! -f "$CERT_DIR/$HOST.pem" ]] && mkcert "$HOST"
    CERT_LINE="ssl_certificate $CERT_DIR/$HOST.pem;
    ssl_certificate_key $CERT_DIR/$HOST-key.pem;"
    SSL_LISTEN="listen 443 ssl;"
    SSL_REDIRECT="if (\$scheme = http) { return 301 https://\$host\$request_uri; }"
    HTTP_PORT=80
  else
    echo "⚠️   mkcert not found. SSL skipped."
    SSL=false
  fi
fi

# --- Build PHP block ---
PHP_BLOCK=""
if [[ "$PHP" == true ]]; then
    if [[ "$PHP_TCP" == true ]]; then
        PORT="${PHP_TCP_PORT:-9000}"
        PHP_BLOCK="location ~ \.php\$ {
    fastcgi_pass 127.0.0.1:$PORT;
    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
    fastcgi_param QUERY_STRING \$query_string;
    fastcgi_param REQUEST_METHOD \$request_method;
    fastcgi_param CONTENT_TYPE \$content_type;
    fastcgi_param CONTENT_LENGTH \$content_length;
}"
    else
        SOCK_PATH="${PHP_SOCK_PATH:-/tmp/php-fpm.sock}"
        PHP_BLOCK="location ~ \.php\$ {
    fastcgi_pass unix:$SOCK_PATH;
    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
    fastcgi_param QUERY_STRING \$query_string;
    fastcgi_param REQUEST_METHOD \$request_method;
    fastcgi_param CONTENT_TYPE \$content_type;
    fastcgi_param CONTENT_LENGTH \$content_length;
}"
    fi
fi

# --- Check port availability ---
if lsof -i:$HTTP_PORT >/dev/null 2>&1; then
  echo "⚠️   Warning: Port $HTTP_PORT already in use"
fi

# --- Write nginx config ---
sudo mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"
cat <<EOF | sudo tee "$CONF_PATH" >/dev/null
server {
    listen $HTTP_PORT;
    $SSL_LISTEN
    server_name $HOST;
    root $WEB_ROOT;

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

# --- Restart services ---
echo "🔄  Restarting Nginx..."
if ! sudo nginx -t -c /usr/local/etc/nginx/nginx.conf; then
    echo "❌  Error: nginx config test failed"
    exit 1
fi

brew services restart nginx

# Restart PHP-FPM jika menggunakan PHP
if [[ "$PHP" == true ]]; then
    echo "🔄  Restarting PHP-FPM..."
    brew services restart php
    sleep 2 # Beri waktu untuk PHP-FPM restart
fi

# --- Test PHP-FPM connection ---
test_php_fpm

# --- Final output ---
echo ""
echo "🎉  Site setup complete!"
echo "    URL: $( [[ "$SSL" == true ]] && echo "https://$HOST" || echo "http://$HOST:$HTTP_PORT" )"
echo "    Root: $ROOT"
echo "    Web Root: $WEB_ROOT"
echo "    Config: $CONF_PATH"
echo ""