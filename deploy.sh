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
        log_warn "⚠️  Running as root user detected"
        log_warn "⚠️  For security reasons, it's recommended to run as non-root user with sudo"
        
        read -p "Do you want to continue as root? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Exiting. Please run as non-root user with sudo privileges."
            log_info "Example: sudo adduser myuser && usermod -aG sudo myuser"
            log_info "Then login as that user and run: ./deploy.sh $1 $2"
            exit 1
        fi
        
        log_warn "⚠️  Continuing as root (not recommended for production)"
        # If running as root, we don't need sudo for commands
        SUDO_CMD=""
    else
        # Running as non-root, need sudo
        SUDO_CMD="sudo"
    fi
}

check_sudo() {
    if [[ $EUID -eq 0 ]]; then
        # Already root, no need to check sudo
        return 0
    fi
    
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges"
        log_info "Please run: sudo visudo"
        log_info "Or run the script with: sudo ./deploy.sh $1 $2"
        exit 1
    fi
}

check_system_requirements() {
    log_info "Checking system requirements..."
    
    # Check Ubuntu version
    if ! grep -q "Ubuntu" /etc/os-release; then
        log_warn "⚠️  This script is designed for Ubuntu. Other distributions may work but are not tested."
    else
        ubuntu_version=$(lsb_release -rs)
        log_info "✅ Ubuntu $ubuntu_version detected"
    fi
    
    # Check available disk space (minimum 5GB)
    available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 5242880 ]]; then  # 5GB in KB
        log_error "❌ Insufficient disk space. At least 5GB required."
        exit 1
    else
        log_info "✅ Sufficient disk space available"
    fi
    
    # Check memory (minimum 1GB)
    total_mem=$(free -m | awk 'NR==2{print $2}')
    if [[ $total_mem -lt 1024 ]]; then
        log_warn "⚠️  Less than 1GB RAM detected. Performance may be affected."
    else
        log_info "✅ Sufficient memory available (${total_mem}MB)"
    fi
}

install_dependencies() {
    log_info "Checking and installing system dependencies..."
    
    # Update system packages
    log_info "Updating system packages..."
    $SUDO_CMD apt update && $SUDO_CMD apt upgrade -y
    
    # Install essential packages
    essential_packages=("curl" "wget" "git" "vim" "htop" "ufw" "build-essential" "software-properties-common")
    missing_packages=()
    
    for package in "${essential_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            missing_packages+=("$package")
        else
            log_info "✅ $package is already installed"
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_info "Installing missing essential packages: ${missing_packages[*]}"
        $SUDO_CMD apt install -y "${missing_packages[@]}"
    else
        log_info "✅ All essential packages are already installed"
    fi
    
    # Check and install Python 3.9+
    if command -v python3 &> /dev/null; then
        python_version=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
        python_major=$(echo $python_version | cut -d'.' -f1)
        python_minor=$(echo $python_version | cut -d'.' -f2)
        
        if [[ $python_major -eq 3 && $python_minor -ge 9 ]] || [[ $python_major -gt 3 ]]; then
            log_info "✅ Python $python_version is already installed and compatible"
        else
            log_warn "⚠️  Python $python_version detected, but Python 3.9+ is recommended"
        fi
    else
        log_info "Installing Python 3.9+..."
        $SUDO_CMD apt install -y python3 python3-pip python3-venv python3-dev
    fi
    
    # Check pip
    if ! command -v pip3 &> /dev/null; then
        log_info "Installing pip3..."
        $SUDO_CMD apt install -y python3-pip
    else
        log_info "✅ pip3 is already installed"
    fi
    
    # Check and install Node.js 18+
    if command -v node &> /dev/null; then
        node_version=$(node -v | cut -d'v' -f2)
        node_major=$(echo $node_version | cut -d'.' -f1)
        
        if [[ $node_major -ge 18 ]]; then
            log_info "✅ Node.js $node_version is already installed and compatible"
        else
            log_info "Upgrading Node.js from $node_version to 18.x..."
            # Remove old Node.js
            sudo apt remove -y nodejs npm
            # Install Node.js 18
            curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
            sudo apt install -y nodejs
        fi
    else
        log_info "Installing Node.js 18.x..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt install -y nodejs
    fi
    
    # Check npm
    if ! command -v npm &> /dev/null; then
        log_info "Installing npm..."
        sudo apt install -y npm
    else
        npm_version=$(npm -v)
        log_info "✅ npm $npm_version is already installed"
    fi
    
    # Check and install Docker
    if command -v docker &> /dev/null; then
        docker_version=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
        log_info "✅ Docker $docker_version is already installed"
        
        # Check if user is in docker group
        if groups $USER | grep -q docker; then
            log_info "✅ User is already in docker group"
        else
            log_info "Adding user to docker group..."
            sudo usermod -aG docker $USER
            log_warn "⚠️  You may need to log out and back in for docker group changes to take effect"
        fi
    else
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker $USER
        rm get-docker.sh
        log_info "✅ Docker installed successfully"
    fi
    
    # Check and install Docker Compose
    if command -v docker-compose &> /dev/null; then
        compose_version=$(docker-compose --version | cut -d' ' -f3 | cut -d',' -f1)
        log_info "✅ Docker Compose $compose_version is already installed"
    else
        log_info "Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        log_info "✅ Docker Compose installed successfully"
    fi
    
    # Check and install Nginx
    if command -v nginx &> /dev/null; then
        nginx_version=$(nginx -v 2>&1 | cut -d'/' -f2)
        log_info "✅ Nginx $nginx_version is already installed"
    else
        log_info "Installing Nginx..."
        sudo apt install -y nginx
        log_info "✅ Nginx installed successfully"
    fi
    
    # Check and install Certbot
    if command -v certbot &> /dev/null; then
        certbot_version=$(certbot --version | cut -d' ' -f2)
        log_info "✅ Certbot $certbot_version is already installed"
    else
        log_info "Installing Certbot..."
        sudo apt install -y certbot python3-certbot-nginx
        log_info "✅ Certbot installed successfully"
    fi
    
    # Check and install OpenSSL (for password generation)
    if command -v openssl &> /dev/null; then
        openssl_version=$(openssl version | cut -d' ' -f2)
        log_info "✅ OpenSSL $openssl_version is already installed"
    else
        log_info "Installing OpenSSL..."
        sudo apt install -y openssl
        log_info "✅ OpenSSL installed successfully"
    fi
    
    log_info "✅ All dependencies checked and installed successfully!"
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
    
    # Check if virtual environment already exists
    if [[ -d "venv" ]]; then
        log_info "✅ Virtual environment already exists"
    else
        log_info "Creating virtual environment..."
        sudo -u $APP_USER python3 -m venv venv
    fi
    
    # Check if requirements are already installed
    if sudo -u $APP_USER bash -c "source venv/bin/activate && pip list | grep -q Flask"; then
        log_info "✅ Python dependencies appear to be installed, checking for updates..."
        sudo -u $APP_USER bash -c "source venv/bin/activate && pip install --upgrade pip"
        sudo -u $APP_USER bash -c "source venv/bin/activate && pip install -r requirements.txt --upgrade"
    else
        log_info "Installing Python dependencies..."
        sudo -u $APP_USER bash -c "source venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt"
    fi
    
    # Check if gunicorn is installed
    if sudo -u $APP_USER bash -c "source venv/bin/activate && pip list | grep -q gunicorn"; then
        log_info "✅ Gunicorn is already installed"
    else
        log_info "Installing Gunicorn..."
        sudo -u $APP_USER bash -c "source venv/bin/activate && pip install gunicorn"
    fi
    
    # Start database services
    cd $APP_DIR
    
    # Check if containers are already running
    if sudo -u $APP_USER docker-compose ps | grep -q "Up"; then
        log_info "✅ Database containers are already running"
    else
        log_info "Starting database services..."
        sudo -u $APP_USER docker-compose up -d
        
        # Wait for services to be ready
        log_info "Waiting for database services to be ready..."
        sleep 30
        
        # Additional check for database readiness
        max_attempts=12
        attempt=1
        while [[ $attempt -le $max_attempts ]]; do
            if sudo -u $APP_USER docker-compose exec -T postgres pg_isready -U dnsfookup_user >/dev/null 2>&1; then
                log_info "✅ Database is ready"
                break
            else
                log_info "Waiting for database... (attempt $attempt/$max_attempts)"
                sleep 10
                ((attempt++))
            fi
        done
        
        if [[ $attempt -gt $max_attempts ]]; then
            log_warn "⚠️  Database readiness check timed out, proceeding anyway..."
        fi
    fi
    
    # Check if database tables exist
    cd $APP_DIR/BE
    if sudo -u $APP_USER bash -c "source venv/bin/activate && python3 -c 'from app import app, db; app.app_context().push(); db.engine.execute(\"SELECT 1 FROM information_schema.tables WHERE table_name = \\\"users\\\";\").fetchone()'" >/dev/null 2>&1; then
        log_info "✅ Database tables already exist"
    else
        log_info "Initializing database..."
        sudo -u $APP_USER bash -c "source venv/bin/activate && python3 -c 'from app import app, db; app.app_context().push(); db.create_all()'"
    fi
    
    log_info "✅ Backend setup complete!"
}

setup_frontend() {
    log_info "Setting up frontend..."
    
    cd $APP_DIR/FE
    
    # Update configuration
    if [[ -f "src/config.js" ]]; then
        log_info "✅ Frontend config already exists, updating..."
    else
        log_info "Creating frontend configuration..."
    fi
    
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
    
    # Check if node_modules exists and is populated
    if [[ -d "node_modules" && -n "$(ls -A node_modules 2>/dev/null)" ]]; then
        log_info "✅ Node modules already installed, checking for updates..."
        sudo -u $APP_USER npm update
    else
        log_info "Installing Node.js dependencies..."
        sudo -u $APP_USER npm install
    fi
    
    # Check if build directory exists and is recent
    if [[ -d "build" && "build" -nt "src" && "build" -nt "package.json" ]]; then
        log_info "✅ Frontend build appears to be up-to-date"
    else
        log_info "Building frontend for production..."
        sudo -u $APP_USER npm run build
    fi
    
    # Setup web directory
    if [[ -d "/var/www/$DOMAIN" ]]; then
        log_info "✅ Web directory already exists, updating content..."
        sudo rm -rf /var/www/$DOMAIN/*
    else
        log_info "Creating web directory..."
        sudo mkdir -p /var/www/$DOMAIN
    fi
    
    sudo cp -r build/* /var/www/$DOMAIN/
    sudo chown -R www-data:www-data /var/www/$DOMAIN
    
    log_info "✅ Frontend setup complete!"
}

create_systemd_services() {
    log_info "Creating systemd services..."
    
    # Check if services already exist
    dns_service_exists=false
    api_service_exists=false
    
    if [[ -f "/etc/systemd/system/dnsfookup-dns.service" ]]; then
        dns_service_exists=true
        log_info "✅ DNS service file already exists"
    fi
    
    if [[ -f "/etc/systemd/system/dnsfookup-api.service" ]]; then
        api_service_exists=true
        log_info "✅ API service file already exists"
    fi
    
    # DNS Server Service
    if [[ "$dns_service_exists" == false ]]; then
        log_info "Creating DNS server service..."
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
    else
        log_info "Updating DNS server service configuration..."
        sudo sed -i "s|WorkingDirectory=.*|WorkingDirectory=$APP_DIR/BE|" /etc/systemd/system/dnsfookup-dns.service
        sudo sed -i "s|ExecStart=.*|ExecStart=$APP_DIR/BE/venv/bin/python dns.py|" /etc/systemd/system/dnsfookup-dns.service
    fi
    
    # API Server Service
    if [[ "$api_service_exists" == false ]]; then
        log_info "Creating API server service..."
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
    else
        log_info "Updating API server service configuration..."
        sudo sed -i "s|WorkingDirectory=.*|WorkingDirectory=$APP_DIR/BE|" /etc/systemd/system/dnsfookup-api.service
        sudo sed -i "s|ExecStart=.*|ExecStart=$APP_DIR/BE/venv/bin/gunicorn --bind 127.0.0.1:5000 --workers 4 app:app|" /etc/systemd/system/dnsfookup-api.service
        sudo sed -i "s|User=.*|User=$APP_USER|" /etc/systemd/system/dnsfookup-api.service
    fi
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    log_info "✅ Systemd services configured!"
}

setup_nginx() {
    log_info "Setting up Nginx..."
    
    # Check if Nginx configuration already exists
    if [[ -f "/etc/nginx/sites-available/dnsfookup" ]]; then
        log_info "✅ Nginx configuration already exists, updating..."
    else
        log_info "Creating Nginx configuration..."
    fi
    
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
    if [[ -L "/etc/nginx/sites-enabled/dnsfookup" ]]; then
        log_info "✅ Nginx site already enabled"
    else
        log_info "Enabling Nginx site..."
        sudo ln -sf /etc/nginx/sites-available/dnsfookup /etc/nginx/sites-enabled/
    fi
    
    # Remove default site if it exists
    if [[ -f "/etc/nginx/sites-enabled/default" ]]; then
        log_info "Removing default Nginx site..."
        sudo rm -f /etc/nginx/sites-enabled/default
    else
        log_info "✅ Default Nginx site already removed"
    fi
    
    # Test configuration
    if sudo nginx -t; then
        log_info "✅ Nginx configuration is valid"
    else
        log_error "❌ Nginx configuration test failed"
        return 1
    fi
    
    log_info "✅ Nginx configured successfully!"
}

setup_ssl() {
    log_info "Setting up SSL certificates..."
    
    # Check if certificates already exist
    if [[ -d "/etc/letsencrypt/live/api.$DOMAIN" && -d "/etc/letsencrypt/live/app.$DOMAIN" ]]; then
        log_info "✅ SSL certificates already exist"
        
        # Check certificate expiry
        api_expiry=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/api.$DOMAIN/cert.pem | cut -d= -f2)
        app_expiry=$(openssl x509 -enddate -noout -in /etc/letsencrypt/live/app.$DOMAIN/cert.pem | cut -d= -f2)
        
        log_info "API certificate expires: $api_expiry"
        log_info "App certificate expires: $app_expiry"
        
        # Check if certificates expire within 30 days
        if openssl x509 -checkend 2592000 -noout -in /etc/letsencrypt/live/api.$DOMAIN/cert.pem >/dev/null 2>&1; then
            log_info "✅ API certificate is valid for more than 30 days"
        else
            log_warn "⚠️  API certificate expires within 30 days, consider renewal"
        fi
        
        if openssl x509 -checkend 2592000 -noout -in /etc/letsencrypt/live/app.$DOMAIN/cert.pem >/dev/null 2>&1; then
            log_info "✅ App certificate is valid for more than 30 days"
        else
            log_warn "⚠️  App certificate expires within 30 days, consider renewal"
        fi
    else
        log_info "Generating SSL certificates..."
        
        # Stop nginx temporarily
        if systemctl is-active --quiet nginx; then
            sudo systemctl stop nginx
            nginx_was_running=true
        else
            nginx_was_running=false
        fi
        
        # Generate certificates
        if sudo certbot certonly --standalone -d api.$DOMAIN -d app.$DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN; then
            log_info "✅ SSL certificates generated successfully"
        else
            log_error "❌ Failed to generate SSL certificates"
            if [[ "$nginx_was_running" == true ]]; then
                sudo systemctl start nginx
            fi
            return 1
        fi
        
        # Start nginx if it was running
        if [[ "$nginx_was_running" == true ]]; then
            sudo systemctl start nginx
        fi
    fi
    
    # Enable and start nginx
    sudo systemctl enable nginx
    if ! systemctl is-active --quiet nginx; then
        sudo systemctl start nginx
    fi
    
    log_info "✅ SSL certificates configured!"
}

start_services() {
    log_info "Starting services..."
    
    # Start and enable Docker
    if systemctl is-enabled --quiet docker; then
        log_info "✅ Docker is already enabled"
    else
        log_info "Enabling Docker..."
        sudo systemctl enable docker
    fi
    
    if systemctl is-active --quiet docker; then
        log_info "✅ Docker is already running"
    else
        log_info "Starting Docker..."
        sudo systemctl start docker
    fi
    
    # Start database services
    cd $APP_DIR
    if sudo -u $APP_USER docker-compose ps | grep -q "Up"; then
        log_info "✅ Database containers are already running"
    else
        log_info "Starting database services..."
        sudo -u $APP_USER docker-compose up -d
    fi
    
    # Start DNSfookup services
    services=("dnsfookup-dns.service" "dnsfookup-api.service")
    
    for service in "${services[@]}"; do
        if systemctl is-enabled --quiet $service; then
            log_info "✅ $service is already enabled"
        else
            log_info "Enabling $service..."
            sudo systemctl enable $service
        fi
        
        if systemctl is-active --quiet $service; then
            log_info "✅ $service is already running"
        else
            log_info "Starting $service..."
            sudo systemctl start $service
            
            # Wait a moment and check if service started successfully
            sleep 3
            if systemctl is-active --quiet $service; then
                log_info "✅ $service started successfully"
            else
                log_error "❌ $service failed to start"
                sudo systemctl status $service --no-pager -l
            fi
        fi
    done
    
    # Start/restart nginx
    if systemctl is-active --quiet nginx; then
        log_info "Restarting Nginx to load new configuration..."
        sudo systemctl restart nginx
    else
        log_info "Starting Nginx..."
        sudo systemctl start nginx
    fi
    
    # Final service status check
    log_info "Final service status check..."
    all_services=("docker" "dnsfookup-dns.service" "dnsfookup-api.service" "nginx")
    
    for service in "${all_services[@]}"; do
        if systemctl is-active --quiet $service; then
            log_info "✅ $service is running"
        else
            log_error "❌ $service is not running"
        fi
    done
    
    log_info "✅ All services configured and started!"
}

setup_monitoring() {
    log_info "Setting up monitoring and backup..."
    
    # Check if backup script already exists
    if [[ -f "$APP_DIR/backup.sh" ]]; then
        log_info "✅ Backup script already exists, updating..."
    else
        log_info "Creating backup script..."
    fi
    
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
    if sudo -u $APP_USER crontab -l 2>/dev/null | grep -q "$APP_DIR/backup.sh"; then
        log_info "✅ Backup cron job already exists"
    else
        log_info "Adding backup cron job..."
        (sudo -u $APP_USER crontab -l 2>/dev/null; echo "0 2 * * * $APP_DIR/backup.sh") | sudo -u $APP_USER crontab -
    fi
    
    # Create backup directory
    if [[ -d "/home/$APP_USER/backups" ]]; then
        log_info "✅ Backup directory already exists"
    else
        log_info "Creating backup directory..."
        sudo -u $APP_USER mkdir -p /home/$APP_USER/backups
    fi
    
    log_info "✅ Monitoring and backup configured!"
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
    echo "=================================="
    echo "     DEPLOYMENT SUMMARY"
    echo "=================================="
    echo "Domain: $DOMAIN"
    echo "Server IP: $SERVER_IP"
    echo "Frontend URL: https://app.$DOMAIN"
    echo "API URL: https://api.$DOMAIN"
    echo "DNS Server: ns.$DOMAIN ($SERVER_IP:53)"
    echo "DNS Rebinding Domain: *.dns.$DOMAIN"
    echo ""
    echo "Installed Software Versions:"
    echo "- Python: $(python3 --version 2>/dev/null | cut -d' ' -f2 || echo 'Not found')"
    echo "- Node.js: $(node --version 2>/dev/null || echo 'Not found')"
    echo "- npm: $(npm --version 2>/dev/null || echo 'Not found')"
    echo "- Docker: $(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1 || echo 'Not found')"
    echo "- Docker Compose: $(docker-compose --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1 || echo 'Not found')"
    echo "- Nginx: $(nginx -v 2>&1 | cut -d'/' -f2 || echo 'Not found')"
    echo "- Certbot: $(certbot --version 2>/dev/null | cut -d' ' -f2 || echo 'Not found')"
    echo ""
    echo "Service Status:"
    services=("docker" "dnsfookup-dns.service" "dnsfookup-api.service" "nginx")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet $service; then
            echo "- $service: ✅ Running"
        else
            echo "- $service: ❌ Not running"
        fi
    done
    echo ""
    echo "Next steps:"
    echo "1. Configure Cloudflare DNS records (see CLOUDFLARE_SETUP.md)"
    echo "2. Test deployment: ./test_deployment.sh $DOMAIN $SERVER_IP"
    echo "3. Create your first DNS rebinding bin via https://app.$DOMAIN"
    echo "4. Monitor logs:"
    echo "   - DNS Server: sudo journalctl -u dnsfookup-dns.service -f"
    echo "   - API Server: sudo journalctl -u dnsfookup-api.service -f"
    echo "   - Nginx: sudo tail -f /var/log/nginx/access.log"
    echo ""
    echo "Configuration files:"
    echo "- App config: $APP_DIR/config.yaml"
    echo "- Nginx config: /etc/nginx/sites-available/dnsfookup"
    echo "- Systemd services: /etc/systemd/system/dnsfookup-*.service"
    echo "- Backup script: $APP_DIR/backup.sh"
    echo ""
    log_warn "IMPORTANT: Configure Cloudflare DNS records before testing!"
    log_info "📖 See CLOUDFLARE_SETUP.md for detailed DNS configuration instructions"
}

# Main execution
main() {
    check_root
    check_sudo
    
    log_info "Starting deployment process..."
    
    check_system_requirements
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
