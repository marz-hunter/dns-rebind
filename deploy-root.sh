#!/bin/bash

# DNSfookup Production Deployment Script (Root Version)
# Usage: ./deploy-root.sh [domain] [server_ip]
# This version is designed to run as root user

set -e

# Configuration
DOMAIN=${1:-"rebind.com"}
SERVER_IP=${2:-"45.67.67.55"}
APP_USER="dnsfookup"
APP_DIR="/home/$APP_USER/dnsFookup"

echo "🚀 DNSfookup Production Deployment (Root Version)"
echo "================================================="
echo "Domain: $DOMAIN"
echo "Server IP: $SERVER_IP"
echo "App User: $APP_USER"
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    log_info "Please run: sudo bash deploy-root.sh $DOMAIN $SERVER_IP"
    exit 1
fi

install_dependencies() {
    log_info "Installing system dependencies..."
    
    # Update system
    apt update && apt upgrade -y
    
    # Install essential packages
    apt install -y curl wget git vim htop ufw build-essential software-properties-common
    
    # Install Python 3.9+
    apt install -y python3 python3-pip python3-venv python3-dev
    
    # Install Node.js 18
    if ! command -v node &> /dev/null || [[ $(node -v | cut -d'v' -f2 | cut -d'.' -f1) -lt 18 ]]; then
        log_info "Installing Node.js 18..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
        apt install -y nodejs
    fi
    
    # Install Docker
    if ! command -v docker &> /dev/null; then
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
    fi
    
    # Install Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        log_info "Installing Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    # Install Nginx
    if ! command -v nginx &> /dev/null; then
        apt install -y nginx
    fi
    
    # Install Certbot
    if ! command -v certbot &> /dev/null; then
        apt install -y certbot python3-certbot-nginx
    fi
    
    log_info "Dependencies installed!"
}

setup_firewall() {
    log_info "Configuring firewall..."
    
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 53
    ufw --force enable
    
    log_info "Firewall configured!"
}

create_app_user() {
    if ! id "$APP_USER" &>/dev/null; then
        log_info "Creating application user: $APP_USER"
        adduser --disabled-password --gecos "" $APP_USER
        usermod -aG docker $APP_USER
    else
        log_info "User $APP_USER already exists"
    fi
}

setup_application() {
    log_info "Setting up application..."
    
    # Create app directory
    mkdir -p $APP_DIR
    chown $APP_USER:$APP_USER $APP_DIR
    
    # Copy application files
    if [[ -d "BE" && -d "FE" ]]; then
        cp -r . $APP_DIR/
        chown -R $APP_USER:$APP_USER $APP_DIR
    else
        log_error "Application files not found. Please run this script from the project root."
        exit 1
    fi
    
    # Generate secure passwords
    DB_PASSWORD=$(openssl rand -base64 32)
    REDIS_PASSWORD=$(openssl rand -base64 32)
    JWT_SECRET=$(openssl rand -base64 48)
    
    # Create production config
    cat > $APP_DIR/config.yaml <<EOF
sql:
  protocol: 'postgresql+psycopg2'
  user: 'dnsfookup_user'
  password: '$DB_PASSWORD'
  host: 'localhost'
  db: 'dnsfookup_prod'
  deprec_warn: false

jwt:
  secret_key: '$JWT_SECRET'
  blacklist_enabled: true
  blacklist_token_checks: ['access']
  token_expires: 21600

redis:
  password: '$REDIS_PASSWORD'
  host: '127.0.0.1'
  port: 6379
  expiration: 3600
  timeout: 3

dns:
  domain: 'dns.$DOMAIN'
  port: 53
  ip: '0.0.0.0'
  use_failure_ip: false
  failure_ip: '0.0.0.0'
  use_fail_ns: true
  fail_ns: '8.8.8.8'
EOF
    
    # Update docker-compose with generated passwords
    sed -i "s/CHANGETHISPW/$REDIS_PASSWORD/g" $APP_DIR/docker-compose.yml
    sed -i "s/CHANGETHISTOO/$DB_PASSWORD/g" $APP_DIR/docker-compose.yml
    
    chown $APP_USER:$APP_USER $APP_DIR/config.yaml
    
    log_info "Application configured!"
}

setup_backend() {
    log_info "Setting up backend..."
    
    cd $APP_DIR/BE
    
    # Create virtual environment
    su - $APP_USER -c "cd $APP_DIR/BE && python3 -m venv venv"
    
    # Install Python dependencies
    su - $APP_USER -c "cd $APP_DIR/BE && source venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt && pip install gunicorn"
    
    # Start database services
    cd $APP_DIR
    su - $APP_USER -c "cd $APP_DIR && docker-compose up -d"
    
    # Wait for services
    log_info "Waiting for database services..."
    sleep 30
    
    # Initialize database
    su - $APP_USER -c "cd $APP_DIR/BE && source venv/bin/activate && python3 -c 'from app import app, db; app.app_context().push(); db.create_all()'"
    
    log_info "Backend setup complete!"
}

setup_frontend() {
    log_info "Setting up frontend..."
    
    cd $APP_DIR/FE
    
    # Update configuration
    cat > src/config.js <<EOF
const config = {
  development: {
    API_URL: 'http://localhost:5000',
    REBIND_DOMAIN: 'dns.$DOMAIN'
  },
  production: {
    API_URL: 'https://api.$DOMAIN',
    REBIND_DOMAIN: 'dns.$DOMAIN'
  }
};

const currentEnv = process.env.NODE_ENV || 'development';

export default config[currentEnv];
EOF
    
    chown $APP_USER:$APP_USER src/config.js
    
    # Install dependencies and build
    su - $APP_USER -c "cd $APP_DIR/FE && npm install && npm run build"
    
    # Setup web directory
    mkdir -p /var/www/$DOMAIN
    cp -r build/* /var/www/$DOMAIN/
    chown -R www-data:www-data /var/www/$DOMAIN
    
    log_info "Frontend setup complete!"
}

create_systemd_services() {
    log_info "Creating systemd services..."
    
    # DNS Server Service
    cat > /etc/systemd/system/dnsfookup-dns.service <<EOF
[Unit]
Description=DNSfookup DNS Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR/BE
ExecStart=$APP_DIR/BE/venv/bin/python dns.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    
    # API Server Service
    cat > /etc/systemd/system/dnsfookup-api.service <<EOF
[Unit]
Description=DNSfookup API Server
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR/BE
Environment=FLASK_APP=app.py
Environment=FLASK_ENV=production
ExecStart=$APP_DIR/BE/venv/bin/gunicorn --bind 127.0.0.1:5000 --workers 4 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_info "Systemd services created!"
}

setup_nginx() {
    log_info "Setting up Nginx..."
    
    cat > /etc/nginx/sites-available/dnsfookup <<EOF
# Frontend (app.$DOMAIN)
server {
    listen 80;
    server_name app.$DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name app.$DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/app.$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.$DOMAIN/privkey.pem;
    
    root /var/www/$DOMAIN;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}

# API Backend (api.$DOMAIN)
server {
    listen 80;
    server_name api.$DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.$DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/api.$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.$DOMAIN/privkey.pem;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        add_header Access-Control-Allow-Origin "https://app.$DOMAIN" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization" always;
        
        if (\$request_method = 'OPTIONS') {
            return 204;
        }
    }
}
EOF
    
    ln -sf /etc/nginx/sites-available/dnsfookup /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t
    log_info "Nginx configured!"
}

setup_ssl() {
    log_info "Setting up SSL certificates..."
    
    systemctl stop nginx
    certbot certonly --standalone -d api.$DOMAIN -d app.$DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
    systemctl start nginx
    systemctl enable nginx
    
    log_info "SSL certificates installed!"
}

start_services() {
    log_info "Starting services..."
    
    systemctl enable docker
    systemctl start docker
    
    cd $APP_DIR
    su - $APP_USER -c "cd $APP_DIR && docker-compose up -d"
    
    systemctl enable dnsfookup-dns.service
    systemctl enable dnsfookup-api.service
    systemctl start dnsfookup-dns.service
    systemctl start dnsfookup-api.service
    
    systemctl restart nginx
    
    log_info "All services started!"
}

print_summary() {
    log_info "🎉 Deployment completed!"
    echo ""
    echo "=========================="
    echo "   DEPLOYMENT SUMMARY"
    echo "=========================="
    echo "Frontend URL: https://app.$DOMAIN"
    echo "API URL: https://api.$DOMAIN"
    echo "DNS Server: ns.$DOMAIN ($SERVER_IP:53)"
    echo "DNS Rebinding Domain: *.dns.$DOMAIN"
    echo ""
    echo "Next steps:"
    echo "1. Configure Cloudflare DNS records"
    echo "2. Test DNS rebinding functionality"
    echo "3. Monitor logs: journalctl -u dnsfookup-dns.service -f"
    echo ""
    log_warn "IMPORTANT: Update your Cloudflare DNS records before testing!"
}

# Main execution
main() {
    log_info "Starting deployment process..."
    
    install_dependencies
    setup_firewall
    create_app_user
    setup_application
    setup_backend
    setup_frontend
    create_systemd_services
    setup_nginx
    setup_ssl
    start_services
    print_summary
}

# Run main function
main "$@"
