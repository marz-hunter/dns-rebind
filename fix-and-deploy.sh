#!/bin/bash

# Fix Common Issues and Deploy
# Usage: bash fix-and-deploy.sh telcor.my.id 47.128.66.223

DOMAIN=${1:-"rebind.com"}
SERVER_IP=${2:-"45.67.67.55"}

echo "🔧 DNSfookup Fix and Deploy"
echo "============================"
echo "Domain: $DOMAIN"
echo "Server IP: $SERVER_IP"
echo ""

# Check if we have the required arguments
if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: bash fix-and-deploy.sh <domain> <server_ip>"
    echo "Example: bash fix-and-deploy.sh telcor.my.id 47.128.66.223"
    exit 1
fi

# Detect if running as root
if [[ $EUID -eq 0 ]]; then
    echo "✅ Running as root"
    SUDO=""
    APP_USER="dnsfookup"
else
    echo "✅ Running as regular user"
    SUDO="sudo"
    APP_USER="dnsfookup"
fi

echo "🔧 Fixing common system issues..."

# Fix 9proxy.sh issue
if [[ -f "/etc/profile.d/9proxy.sh" ]]; then
    echo "🔍 Found 9proxy.sh issue, fixing..."
    $SUDO rm -f /etc/profile.d/9proxy.sh
    echo "✅ Removed problematic 9proxy.sh"
fi

# Fix environment issues
echo "🔧 Cleaning environment..."
unset http_proxy
unset https_proxy
unset HTTP_PROXY
unset HTTPS_PROXY

echo "📦 Installing/updating system dependencies..."
$SUDO apt update
$SUDO apt install -y curl wget git vim htop ufw build-essential python3 python3-pip python3-venv nodejs npm docker.io docker-compose nginx certbot python3-certbot-nginx openssl

# Check Node.js version
if ! command -v node &> /dev/null || [[ $(node -v | cut -d'v' -f2 | cut -d'.' -f1) -lt 18 ]]; then
    echo "📦 Installing Node.js 18..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | $SUDO -E bash -
    $SUDO apt install -y nodejs
fi

echo "🔥 Setting up firewall..."
$SUDO ufw --force enable
$SUDO ufw allow ssh
$SUDO ufw allow 80
$SUDO ufw allow 443  
$SUDO ufw allow 53

echo "👤 Creating app user..."
if ! id "$APP_USER" &>/dev/null; then
    $SUDO adduser --disabled-password --gecos "" $APP_USER
    $SUDO usermod -aG docker $APP_USER
fi

echo "📁 Setting up application..."
APP_DIR="/home/$APP_USER/dnsFookup"
$SUDO mkdir -p $APP_DIR

# Stop existing services if running
echo "🛑 Stopping existing services..."
$SUDO systemctl stop dnsfookup-dns.service 2>/dev/null || true
$SUDO systemctl stop dnsfookup-api.service 2>/dev/null || true

# Copy application files
$SUDO cp -r . $APP_DIR/
$SUDO chown -R $APP_USER:$APP_USER $APP_DIR

# Generate passwords
DB_PASSWORD=$(openssl rand -base64 32)
REDIS_PASSWORD=$(openssl rand -base64 32)
JWT_SECRET=$(openssl rand -base64 48)

echo "⚙️  Creating configuration..."
$SUDO tee $APP_DIR/config.yaml > /dev/null <<EOF
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

# Update docker-compose
$SUDO sed -i "s/CHANGETHISPW/$REDIS_PASSWORD/g" $APP_DIR/docker-compose.yml
$SUDO sed -i "s/CHANGETHISTOO/$DB_PASSWORD/g" $APP_DIR/docker-compose.yml

echo "🐍 Setting up Python backend..."
cd $APP_DIR/BE

# Remove old venv if exists
$SUDO rm -rf venv

# Create fresh virtual environment
$SUDO -u $APP_USER python3 -m venv venv

# Install dependencies with clean environment
$SUDO -u $APP_USER bash -c "cd $APP_DIR/BE && source venv/bin/activate && unset http_proxy && unset https_proxy && pip install --upgrade pip && pip install -r requirements.txt && pip install gunicorn"

echo "🐳 Setting up database services..."
cd $APP_DIR
$SUDO systemctl start docker
$SUDO systemctl enable docker

# Stop existing containers
$SUDO -u $APP_USER docker-compose down 2>/dev/null || true

# Start fresh containers
$SUDO -u $APP_USER docker-compose up -d

echo "⏳ Waiting for database..."
sleep 30

# Test database connection
echo "🧪 Testing database connection..."
max_attempts=5
attempt=1
while [[ $attempt -le $max_attempts ]]; do
    if $SUDO -u $APP_USER docker-compose exec -T postgres pg_isready -U dnsfookup_user >/dev/null 2>&1; then
        echo "✅ Database is ready"
        break
    else
        echo "⏳ Waiting for database... (attempt $attempt/$max_attempts)"
        sleep 10
        ((attempt++))
    fi
done

echo "🗄️  Initializing database..."
cd $APP_DIR/BE
$SUDO -u $APP_USER bash -c "cd $APP_DIR/BE && source venv/bin/activate && python3 -c 'from app import app, db; app.app_context().push(); db.create_all()'"

echo "⚛️  Setting up React frontend..."
cd $APP_DIR/FE

$SUDO -u $APP_USER tee src/config.js > /dev/null <<EOF
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

# Clean install
$SUDO -u $APP_USER rm -rf node_modules package-lock.json
$SUDO -u $APP_USER bash -c "cd $APP_DIR/FE && unset http_proxy && unset https_proxy && npm install && npm run build"

$SUDO mkdir -p /var/www/$DOMAIN
$SUDO cp -r build/* /var/www/$DOMAIN/
$SUDO chown -R www-data:www-data /var/www/$DOMAIN

echo "⚡ Creating systemd services..."

$SUDO tee /etc/systemd/system/dnsfookup-dns.service > /dev/null <<EOF
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
Environment=PATH=$APP_DIR/BE/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

$SUDO tee /etc/systemd/system/dnsfookup-api.service > /dev/null <<EOF
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
Environment=PATH=$APP_DIR/BE/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$APP_DIR/BE/venv/bin/gunicorn --bind 127.0.0.1:5000 --workers 4 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

$SUDO systemctl daemon-reload

echo "🌐 Setting up Nginx..."
$SUDO tee /etc/nginx/sites-available/dnsfookup > /dev/null <<EOF
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

$SUDO ln -sf /etc/nginx/sites-available/dnsfookup /etc/nginx/sites-enabled/
$SUDO rm -f /etc/nginx/sites-enabled/default

# Test nginx config
if ! $SUDO nginx -t; then
    echo "❌ Nginx configuration error"
    exit 1
fi

echo "🔒 Setting up SSL certificates..."
$SUDO systemctl stop nginx
if $SUDO certbot certonly --standalone -d api.$DOMAIN -d app.$DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN; then
    echo "✅ SSL certificates created"
else
    echo "⚠️  SSL certificate creation failed, continuing without SSL"
fi
$SUDO systemctl start nginx
$SUDO systemctl enable nginx

echo "🚀 Starting all services..."
$SUDO systemctl enable dnsfookup-dns.service
$SUDO systemctl enable dnsfookup-api.service
$SUDO systemctl start dnsfookup-dns.service
$SUDO systemctl start dnsfookup-api.service

# Check service status
echo "🔍 Checking service status..."
services=("dnsfookup-dns.service" "dnsfookup-api.service" "nginx" "docker")
for service in "${services[@]}"; do
    if $SUDO systemctl is-active --quiet $service; then
        echo "✅ $service: Running"
    else
        echo "❌ $service: Not running"
        $SUDO systemctl status $service --no-pager -l
    fi
done

echo ""
echo "🎉 Deployment completed!"
echo "======================="
echo "Frontend: https://app.$DOMAIN"
echo "API: https://api.$DOMAIN"
echo "DNS Server: ns.$DOMAIN ($SERVER_IP:53)"
echo ""
echo "🔧 Next steps:"
echo "1. Configure Cloudflare DNS records:"
echo "   - api.$DOMAIN A → $SERVER_IP (DNS only)"
echo "   - app.$DOMAIN A → $SERVER_IP (DNS only)"  
echo "   - ns.$DOMAIN A → $SERVER_IP (DNS only)"
echo "   - dns.$DOMAIN NS → ns.$DOMAIN (DNS only)"
echo ""
echo "2. Test your deployment:"
echo "   curl https://api.$DOMAIN/api/user"
echo "   curl https://app.$DOMAIN"
echo ""
echo "🔍 Monitor logs:"
echo "   journalctl -u dnsfookup-dns.service -f"
echo "   journalctl -u dnsfookup-api.service -f"
echo ""
echo "🧪 Test DNS server:"
echo "   dig @$SERVER_IP test.dns.$DOMAIN"
