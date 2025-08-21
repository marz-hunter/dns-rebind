# DNSfookup Production Setup Guide

Panduan lengkap untuk setup DNSfookup di production menggunakan:
- **Domain**: rebind.com (NS di Cloudflare)
- **VPS**: AWS Ubuntu dengan IP 45.67.67.55
- **SSL**: Let's Encrypt via Nginx

## 📋 Prerequisites

- Domain dengan NS pointing ke Cloudflare
- VPS Ubuntu 20.04+ dengan public IP
- Root/sudo access ke VPS
- Basic knowledge tentang DNS dan web servers

## 🌐 1. Cloudflare DNS Configuration

### A. Subdomain Setup
Di Cloudflare dashboard untuk domain `rebind.com`, tambahkan DNS records:

```
Type: A
Name: api
Content: 45.67.67.55
Proxy: OFF (DNS Only) - PENTING!

Type: A  
Name: app
Content: 45.67.67.55
Proxy: OFF (DNS Only) - PENTING!

Type: A
Name: *.dns
Content: 45.67.67.55
Proxy: OFF (DNS Only) - PENTING!
```

### B. NS Record untuk DNS Rebinding
```
Type: NS
Name: dns
Content: ns.rebind.com

Type: A
Name: ns
Content: 45.67.67.55
Proxy: OFF (DNS Only) - PENTING!
```

**⚠️ PENTING**: Semua record harus set ke "DNS Only" (tidak di-proxy Cloudflare) agar DNS rebinding berfungsi!

## 🖥️ 2. VPS Ubuntu Setup

### A. Initial Server Setup
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install essential packages
sudo apt install -y curl wget git vim htop ufw

# Setup firewall
sudo ufw allow ssh
sudo ufw allow 80
sudo ufw allow 443
sudo ufw allow 53
sudo ufw --force enable

# Create user untuk aplikasi
sudo adduser dnsfookup
sudo usermod -aG sudo dnsfookup
```

### B. Install Dependencies
```bash
# Install Python 3.9+
sudo apt install -y python3 python3-pip python3-venv python3-dev

# Install Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

# Install Docker & Docker Compose
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Install Nginx
sudo apt install -y nginx

# Reboot untuk apply docker group
sudo reboot
```

## 📁 3. Application Deployment

### A. Clone dan Setup Project
```bash
# Login sebagai dnsfookup user
sudo su - dnsfookup

# Clone project
git clone https://github.com/your-username/dnsFookup.git
cd dnsFookup

# Copy dan edit konfigurasi
cp config.yaml config.yaml.example
vim config.yaml
```

### B. Production Configuration (`config.yaml`)
```yaml
sql:
  protocol: 'postgresql+psycopg2'
  user: 'dnsfookup_user'
  password: 'your_very_strong_password_here'
  host: 'localhost'
  db: 'dnsfookup_prod'
  deprec_warn: false

jwt:
  secret_key: 'your_super_secret_jwt_key_minimum_32_chars'
  blacklist_enabled: true
  blacklist_token_checks: ['access']
  token_expires: 21600 # 6 hours

redis:
  password: 'your_redis_password_here'
  host: '127.0.0.1'
  port: 6379
  expiration: 3600
  timeout: 3

dns:
  domain: 'dns.rebind.com'
  port: 53
  ip: '0.0.0.0'  # Bind ke semua interfaces
  use_failure_ip: false
  failure_ip: '0.0.0.0'
  use_fail_ns: true
  fail_ns: '8.8.8.8'
```

### C. Update Docker Compose untuk Production
```bash
vim docker-compose.yml
```

```yaml
version: '3.8'
services:
  redis:
    image: "redis:7.4-alpine"
    command: "redis-server --requirepass your_redis_password_here"
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - redis_data:/data
    restart: unless-stopped
    
  postgres:
    image: "postgres:16-alpine"
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: "your_very_strong_password_here"
      POSTGRES_DB: "dnsfookup_prod"
      POSTGRES_USER: "dnsfookup_user"
    ports:
      - "127.0.0.1:5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dnsfookup_user"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  redis_data:
  postgres_data:
```

## 🚀 4. Backend Setup

### A. Setup Python Environment
```bash
cd BE

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install --upgrade pip
pip install -r requirements.txt

# Install production WSGI server
pip install gunicorn
```

### B. Database Initialization
```bash
# Start database services
cd ..
docker-compose up -d

# Wait for services to be ready
sleep 30

# Initialize database
cd BE
source venv/bin/activate
python3 -c "from app import app, db; app.app_context().push(); db.create_all()"
```

### C. Create Systemd Services

#### DNS Server Service
```bash
sudo vim /etc/systemd/system/dnsfookup-dns.service
```

```ini
[Unit]
Description=DNSfookup DNS Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/home/dnsfookup/dnsFookup/BE
ExecStart=/home/dnsfookup/dnsFookup/BE/venv/bin/python dns.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

#### API Server Service
```bash
sudo vim /etc/systemd/system/dnsfookup-api.service
```

```ini
[Unit]
Description=DNSfookup API Server
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=dnsfookup
WorkingDirectory=/home/dnsfookup/dnsFookup/BE
Environment=FLASK_APP=app.py
Environment=FLASK_ENV=production
ExecStart=/home/dnsfookup/dnsFookup/BE/venv/bin/gunicorn --bind 127.0.0.1:5000 --workers 4 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

## 🌐 5. Frontend Setup

### A. Build Production Frontend
```bash
cd ../FE

# Update configuration untuk production
vim src/config.js
```

```javascript
// Configuration file for DNSfookup frontend
const config = {
  development: {
    API_URL: 'http://localhost:5000',
    REBIND_DOMAIN: 'dns.rebind.com'
  },
  production: {
    API_URL: 'https://api.rebind.com',
    REBIND_DOMAIN: 'dns.rebind.com'
  }
};

const currentEnv = process.env.NODE_ENV || 'development';

export default config[currentEnv];
```

```bash
# Install dependencies dan build
npm install
npm run build

# Copy build ke web directory
sudo mkdir -p /var/www/rebind.com
sudo cp -r build/* /var/www/rebind.com/
sudo chown -R www-data:www-data /var/www/rebind.com
```

## 🔒 6. Nginx Configuration

### A. SSL Certificate dengan Let's Encrypt
```bash
# Install Certbot
sudo apt install -y certbot python3-certbot-nginx

# Generate SSL certificates
sudo certbot certonly --nginx -d api.rebind.com -d app.rebind.com
```

### B. Nginx Site Configuration
```bash
sudo vim /etc/nginx/sites-available/dnsfookup
```

```nginx
# Frontend (app.rebind.com)
server {
    listen 80;
    server_name app.rebind.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name app.rebind.com;
    
    ssl_certificate /etc/letsencrypt/live/app.rebind.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.rebind.com/privkey.pem;
    
    root /var/www/rebind.com;
    index index.html;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    
    location / {
        try_files $uri $uri/ /index.html;
    }
    
    location /static/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}

# API Backend (api.rebind.com)
server {
    listen 80;
    server_name api.rebind.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name api.rebind.com;
    
    ssl_certificate /etc/letsencrypt/live/api.rebind.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.rebind.com/privkey.pem;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # CORS headers
        add_header Access-Control-Allow-Origin "https://app.rebind.com" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization" always;
        
        if ($request_method = 'OPTIONS') {
            return 204;
        }
    }
}
```

### C. Enable Site dan Restart Nginx
```bash
# Enable site
sudo ln -s /etc/nginx/sites-available/dnsfookup /etc/nginx/sites-enabled/

# Test configuration
sudo nginx -t

# Restart nginx
sudo systemctl restart nginx
sudo systemctl enable nginx
```

## ⚙️ 7. Start All Services

### A. Enable dan Start Services
```bash
# Start database services
sudo systemctl start docker
sudo systemctl enable docker
cd /home/dnsfookup/dnsFookup
sudo docker-compose up -d

# Start DNSfookup services
sudo systemctl enable dnsfookup-dns.service
sudo systemctl enable dnsfookup-api.service
sudo systemctl start dnsfookup-dns.service
sudo systemctl start dnsfookup-api.service

# Check status
sudo systemctl status dnsfookup-dns.service
sudo systemctl status dnsfookup-api.service
```

### B. Verify Installation
```bash
# Test DNS server
dig @45.67.67.55 test.dns.rebind.com

# Test API
curl https://api.rebind.com/api/user

# Check logs
sudo journalctl -u dnsfookup-dns.service -f
sudo journalctl -u dnsfookup-api.service -f
```

## 🔧 8. Monitoring & Maintenance

### A. Log Monitoring
```bash
# DNS server logs
sudo journalctl -u dnsfookup-dns.service -f

# API server logs  
sudo journalctl -u dnsfookup-api.service -f

# Nginx logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### B. SSL Certificate Auto-Renewal
```bash
# Test renewal
sudo certbot renew --dry-run

# Setup auto-renewal (already included in Ubuntu)
sudo systemctl status certbot.timer
```

### C. Backup Script
```bash
sudo vim /home/dnsfookup/backup.sh
```

```bash
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
```

```bash
chmod +x /home/dnsfookup/backup.sh

# Add to crontab untuk daily backup
sudo crontab -e
# Add line: 0 2 * * * /home/dnsfookup/backup.sh
```

## 🌐 9. Testing DNS Rebinding

### A. Create Test Bin
1. Akses https://app.rebind.com
2. Register/Login
3. Create new DNS bin dengan:
   - Name: "test"
   - IP 1: "1.2.3.4", repeat: 2, type: A
   - IP 2: "127.0.0.1", repeat: "4ever", type: A

### B. Test DNS Resolution
```bash
# Test resolusi (akan berubah setelah 2 request)
dig @45.67.67.55 [generated-uuid].dns.rebind.com
dig @45.67.67.55 [generated-uuid].dns.rebind.com
dig @45.67.67.55 [generated-uuid].dns.rebind.com
```

## 🔒 10. Security Checklist

- [ ] Strong passwords di config.yaml
- [ ] JWT secret key minimal 32 karakter
- [ ] Firewall properly configured
- [ ] SSL certificates installed
- [ ] Regular backups scheduled
- [ ] Services running as non-root (kecuali DNS server)
- [ ] Nginx security headers enabled
- [ ] Database tidak expose ke public

## 🆘 11. Troubleshooting

### Common Issues:

**DNS Server tidak bisa bind ke port 53:**
```bash
sudo netstat -tulpn | grep :53
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
```

**Database connection error:**
```bash
sudo docker-compose ps
sudo docker-compose logs postgres
```

**SSL certificate issues:**
```bash
sudo certbot certificates
sudo certbot renew
```

**API tidak accessible:**
```bash
curl -I https://api.rebind.com
sudo systemctl status dnsfookup-api.service
```

Dengan setup ini, DNSfookup akan berjalan di:
- **Frontend**: https://app.rebind.com
- **API**: https://api.rebind.com  
- **DNS Server**: ns.rebind.com (45.67.67.55:53)
- **DNS Rebinding Domain**: *.dns.rebind.com
