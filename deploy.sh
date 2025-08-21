#!/bin/bash

# DNSfookup Production Deployment Script
# Usage: ./deploy.sh [domain] [server_ip]

set -e

# Configuration
DOMAIN=${1:-"rebind.com"}
SERVER_IP=${2:-"45.67.67.55"}
APP_USER="dnsfookup"
APP_DIR="/home/$APP_USER/dnsFookup"

echo "🚀 DNSfookup Production Deployment"
echo "=================================="
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

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        exit 1
    fi
}

check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges"
        exit 1
    fi
}

install_dependencies() {
    log_info "Installing system dependencies..."
    
    # Update system
    sudo apt update && sudo apt upgrade -y
    
    # Install essential packages
    sudo apt install -y curl wget git vim htop ufw build-essential
    
    # Install Python 3.9+
    sudo apt install -y python3 python3-pip python3-venv python3-dev
    
    # Install Node.js 18
    if ! command -v node &> /dev/null || [[ $(node -v | cut -d'v' -f2 | cut -d'.' -f1) -lt 18 ]]; then
        log_info "Installing Node.js 18..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt install -y nodejs
    fi
    
    # Install Docker
    if ! command -v docker &> /dev/null; then
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        rm get-docker.sh
    fi
    
    # Install Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        log_info "Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
    
    # Install Nginx
    if ! command -v nginx &> /dev/null; then
        log_info "Installing Nginx..."
        sudo apt install -y nginx
    fi
    
    # Install Certbot
    if ! command -v certbot &> /dev/null; then
        log_info "Installing Certbot..."
        sudo apt install -y certbot python3-certbot-nginx
    fi
    
    log_info "Dependencies installed successfully!"
}

setup_firewall() {
    log_info "Configuring firewall..."
    
    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # Allow essential services
    sudo ufw allow ssh
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw allow 53
    
    sudo ufw --force enable
    log_info "Firewall configured!"
}

create_app_user() {
    if ! id "$APP_USER" &>/dev/null; then
        log_info "Creating application user: $APP_USER"
        sudo adduser --disabled-password --gecos "" $APP_USER
        sudo usermod -aG docker $APP_USER
    else
        log_info "User $APP_USER already exists"
    fi
}

setup_application() {
    log_info "Setting up application..."
    
    # Create app directory
    sudo mkdir -p $APP_DIR
    sudo chown $APP_USER:$APP_USER $APP_DIR
    
    # Copy application files
    if [[ -d "BE" && -d "FE" ]]; then
        sudo cp -r . $APP_DIR/
        sudo chown -R $APP_USER:$APP_USER $APP_DIR
    else
        log_error "Application files not found. Please run this script from the project root."
        exit 1
    fi
    
    # Generate secure passwords
    DB_PASSWORD=$(openssl rand -base64 32)
    REDIS_PASSWORD=$(openssl rand -base64 32)
    JWT_SECRET=$(openssl rand -base64 48)
    
    # Create production config
    sudo -u $APP_USER tee $APP_DIR/config.yaml > /dev/null <<EOF
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
    sudo -u $APP_USER sed -i "s/CHANGETHISPW/$REDIS_PASSWORD/g" $APP_DIR/docker-compose.yml
    sudo -u $APP_USER sed -i "s/CHANGETHISTOO/$DB_PASSWORD/g" $APP_DIR/docker-compose.yml
    
    log_info "Application configured with secure passwords!"
}

setup_backend() {
    log_info "Setting up backend..."
    
    cd $APP_DIR/BE
    
    # Create virtual environment
    sudo -u $APP_USER python3 -m venv venv
    
    # Install Python dependencies
    sudo -u $APP_USER bash -c "source venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt && pip install gunicorn"
    
    # Start database services
    cd $APP_DIR
    sudo -u $APP_USER docker-compose up -d
    
    # Wait for services to be ready
    log_info "Waiting for database services to be ready..."
    sleep 30
    
    # Initialize database
    cd $APP_DIR/BE
    sudo -u $APP_USER bash -c "source venv/bin/activate && python3 -c 'from app import app, db; app.app_context().push(); db.create_all()'"
    
    log_info "Backend setup complete!"
}

setup_frontend() {
    log_info "Setting up frontend..."
    
    cd $APP_DIR/FE
    
    # Update configuration
    sudo -u $APP_USER tee src/config.js > /dev/null <<EOF
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
    
    # Install dependencies and build
    sudo -u $APP_USER npm install
    sudo -u $APP_USER npm run build
    
    # Setup web directory
    sudo mkdir -p /var/www/$DOMAIN
    sudo cp -r build/* /var/www/$DOMAIN/
    sudo chown -R www-data:www-data /var/www/$DOMAIN
    
    log_info "Frontend setup complete!"
}

create_systemd_services() {
    log_info "Creating systemd services..."
    
    # DNS Server Service
    sudo tee /etc/systemd/system/dnsfookup-dns.service > /dev/null <<EOF
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
    sudo tee /etc/systemd/system/dnsfookup-api.service > /dev/null <<EOF
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
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    log_info "Systemd services created!"
}

setup_nginx() {
    log_info "Setting up Nginx..."
    
    # Create Nginx configuration
    sudo tee /etc/nginx/sites-available/dnsfookup > /dev/null <<EOF
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
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    location /static/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
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
        
        # CORS headers
        add_header Access-Control-Allow-Origin "https://app.$DOMAIN" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization" always;
        
        if (\$request_method = 'OPTIONS') {
            return 204;
        }
    }
}
EOF
    
    # Enable site
    sudo ln -sf /etc/nginx/sites-available/dnsfookup /etc/nginx/sites-enabled/
    
    # Remove default site
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Test configuration
    sudo nginx -t
    
    log_info "Nginx configured!"
}

setup_ssl() {
    log_info "Setting up SSL certificates..."
    
    # Stop nginx temporarily
    sudo systemctl stop nginx
    
    # Generate certificates
    sudo certbot certonly --standalone -d api.$DOMAIN -d app.$DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
    
    # Start nginx
    sudo systemctl start nginx
    sudo systemctl enable nginx
    
    log_info "SSL certificates installed!"
}

start_services() {
    log_info "Starting services..."
    
    # Start and enable services
    sudo systemctl enable docker
    sudo systemctl start docker
    
    # Start database services
    cd $APP_DIR
    sudo -u $APP_USER docker-compose up -d
    
    # Start DNSfookup services
    sudo systemctl enable dnsfookup-dns.service
    sudo systemctl enable dnsfookup-api.service
    sudo systemctl start dnsfookup-dns.service
    sudo systemctl start dnsfookup-api.service
    
    # Start nginx
    sudo systemctl restart nginx
    
    log_info "All services started!"
}

setup_monitoring() {
    log_info "Setting up monitoring and backup..."
    
    # Create backup script
    sudo -u $APP_USER tee $APP_DIR/backup.sh > /dev/null <<'EOF'
#!/bin/bash
BACKUP_DIR="/home/dnsfookup/backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

# Backup database
docker exec dnsfookup-postgres-1 pg_dump -U dnsfookup_user dnsfookup_prod > $BACKUP_DIR/db_$DATE.sql

# Backup config
cp /home/dnsfookup/dnsFookup/config.yaml $BACKUP_DIR/config_$DATE.yaml

# Keep only last 7 days
find $BACKUP_DIR -name "*.sql" -mtime +7 -delete
find $BACKUP_DIR -name "*.yaml" -mtime +7 -delete

echo "Backup completed: $DATE"
EOF
    
    sudo chmod +x $APP_DIR/backup.sh
    
    # Add to crontab
    (sudo -u $APP_USER crontab -l 2>/dev/null; echo "0 2 * * * $APP_DIR/backup.sh") | sudo -u $APP_USER crontab -
    
    log_info "Monitoring and backup configured!"
}

verify_installation() {
    log_info "Verifying installation..."
    
    # Check services
    services=("dnsfookup-dns.service" "dnsfookup-api.service" "nginx.service" "docker.service")
    
    for service in "${services[@]}"; do
        if sudo systemctl is-active --quiet $service; then
            log_info "✅ $service is running"
        else
            log_error "❌ $service is not running"
        fi
    done
    
    # Check DNS
    if dig @$SERVER_IP test.dns.$DOMAIN +short | grep -q "NXDOMAIN\|connection timed out"; then
        log_info "✅ DNS server is responding"
    else
        log_warn "⚠️  DNS server might not be properly configured"
    fi
    
    # Check API
    if curl -s -o /dev/null -w "%{http_code}" https://api.$DOMAIN/api/user | grep -q "401\|422"; then
        log_info "✅ API server is responding"
    else
        log_warn "⚠️  API server might not be accessible"
    fi
    
    # Check frontend
    if curl -s -o /dev/null -w "%{http_code}" https://app.$DOMAIN | grep -q "200"; then
        log_info "✅ Frontend is accessible"
    else
        log_warn "⚠️  Frontend might not be accessible"
    fi
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
    echo "1. Configure Cloudflare DNS records as described in PRODUCTION_SETUP.md"
    echo "2. Test DNS rebinding functionality"
    echo "3. Monitor logs: sudo journalctl -u dnsfookup-dns.service -f"
    echo "4. Monitor API: sudo journalctl -u dnsfookup-api.service -f"
    echo ""
    echo "Configuration files:"
    echo "- App config: $APP_DIR/config.yaml"
    echo "- Nginx config: /etc/nginx/sites-available/dnsfookup"
    echo "- Systemd services: /etc/systemd/system/dnsfookup-*.service"
    echo ""
    log_warn "IMPORTANT: Update your Cloudflare DNS records before testing!"
}

# Main execution
main() {
    check_root
    check_sudo
    
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
    setup_monitoring
    verify_installation
    print_summary
}

# Run main function
main "$@"
