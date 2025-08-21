#!/bin/bash

# DNSfookup Quick Deploy Script
# Works with both root and non-root users
# Usage: bash quick-deploy.sh telcor.my.id 47.128.66.223

DOMAIN=${1:-"rebind.com"}
SERVER_IP=${2:-"45.67.67.55"}

echo "🚀 DNSfookup Quick Deploy"
echo "========================"
echo "Domain: $DOMAIN"
echo "Server IP: $SERVER_IP"
echo ""

# Check if we have the required arguments
if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: bash quick-deploy.sh <domain> <server_ip>"
    echo "Example: bash quick-deploy.sh telcor.my.id 47.128.66.223"
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

echo "📦 Installing system dependencies..."
$SUDO apt update
$SUDO apt install -y curl wget git vim htop ufw build-essential python3 python3-pip python3-venv nodejs npm docker.io docker-compose nginx certbot python3-certbot-nginx

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
$SUDO -u $APP_USER python3 -m venv venv
$SUDO -u $APP_USER bash -c "source venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt && pip install gunicorn"

echo "🐳 Starting database services..."
cd $APP_DIR
$SUDO systemctl start docker
$SUDO systemctl enable docker
$SUDO -u $APP_USER docker-compose up -d

echo "⏳ Waiting for database..."
sleep 30

echo "🗄️  Initializing database..."
cd $APP_DIR/BE
$SUDO -u $APP_USER bash -c "source venv/bin/activate && python3 -c 'from app import app, db; app.app_context().push(); db.create_all()'"

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

$SUDO -u $APP_USER npm install
$SUDO -u $APP_USER npm run build

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

$SUDO ln -sf /etc/nginx/sites-available/dnsfookup /etc/nginx/sites-enabled/
$SUDO rm -f /etc/nginx/sites-enabled/default

echo "🔒 Setting up SSL certificates..."
$SUDO systemctl stop nginx
$SUDO certbot certonly --standalone -d api.$DOMAIN -d app.$DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN
$SUDO systemctl start nginx
$SUDO systemctl enable nginx

echo "🚀 Starting all services..."
$SUDO systemctl enable dnsfookup-dns.service
$SUDO systemctl enable dnsfookup-api.service
$SUDO systemctl start dnsfookup-dns.service
$SUDO systemctl start dnsfookup-api.service

echo ""
echo "🎉 Deployment completed!"
echo "======================="
echo "Frontend: https://app.$DOMAIN"
echo "API: https://api.$DOMAIN"
echo "DNS Server: ns.$DOMAIN ($SERVER_IP:53)"
echo ""
echo "Next steps:"
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
echo "3. Check service status:"
echo "   systemctl status dnsfookup-dns.service"
echo "   systemctl status dnsfookup-api.service"
echo ""
echo "🔍 Monitor logs:"
echo "   journalctl -u dnsfookup-dns.service -f"
echo "   journalctl -u dnsfookup-api.service -f"
