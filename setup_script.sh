#!/bin/bash
# DNS Rebinding Tool Setup Script
# Run with: bash setup.sh myrebinding.com

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

# Check if domain parameter is provided
if [ -z "$1" ]; then
    print_error "Usage: $0 <domain>"
    print_error "Example: $0 myrebinding.com"
    exit 1
fi

DOMAIN=$1
IP=$(curl -s ifconfig.me)

print_status "Starting DNS Rebinding Tool setup for domain: $DOMAIN"
print_status "Detected server IP: $IP"

# Update system
print_status "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
print_status "Installing required packages..."
apt install -y python3 python3-pip apache2 ufw curl dnsutils

# Install Python dependencies
print_status "Installing Python dependencies..."
pip3 install dnslib Flask Flask-CORS

# Configure firewall
print_status "Configuring UFW firewall..."
ufw --force enable
ufw allow 22/tcp   # SSH
ufw allow 53/tcp   # DNS TCP
ufw allow 53/udp   # DNS UDP
ufw allow 80/tcp   # HTTP
ufw allow 443/tcp  # HTTPS

# Enable Apache modules
print_status "Enabling Apache modules..."
a2enmod proxy
a2enmod proxy_http
a2enmod headers
a2enmod rewrite
a2enmod ssl

# Create Apache virtual host configuration
print_status "Creating Apache virtual host configuration..."
cat > /etc/apache2/sites-available/${DOMAIN}.conf << EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias *.${DOMAIN}
    DocumentRoot /var/www/html
    
    # Proxy configuration to forward requests to our Python application
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8080/
    ProxyPassReverse / http://127.0.0.1:8080/
    
    # Enable headers module for debugging
    Header always set X-Forwarded-Proto "http"
    
    # Logging
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
    
    # Security headers
    Header always set X-Content-Type-Options nosniff
    Header always set X-Frame-Options DENY
    Header always set X-XSS-Protection "1; mode=block"
</VirtualHost>
EOF

# Enable the site
print_status "Enabling Apache site..."
a2ensite ${DOMAIN}.conf
a2dissite 000-default.conf
systemctl reload apache2

# Install Certbot for SSL
print_status "Installing Certbot for SSL certificates..."
apt install -y python3-certbot-apache

# Create systemd service for DNS rebinding tool
print_status "Creating systemd service for DNS rebinding tool..."
cat > /etc/systemd/system/dns-rebinding.service << EOF
[Unit]
Description=DNS Rebinding Attack Tool
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/dns-rebinding
ExecStart=/usr/bin/python3 /opt/dns-rebinding/httprebind.py ${DOMAIN} ${IP} ec2
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create working directory
print_status "Creating working directory..."
mkdir -p /opt/dns-rebinding

# Create service management script
print_status "Creating service management script..."
cat > /opt/dns-rebinding/manage.sh << 'EOF'
#!/bin/bash

case "$1" in
    start)
        echo "Starting DNS rebinding service..."
        systemctl start dns-rebinding
        systemctl status dns-rebinding --no-pager
        ;;
    stop)
        echo "Stopping DNS rebinding service..."
        systemctl stop dns-rebinding
        ;;
    restart)
        echo "Restarting DNS rebinding service..."
        systemctl restart dns-rebinding
        systemctl status dns-rebinding --no-pager
        ;;
    status)
        systemctl status dns-rebinding --no-pager
        ;;
    logs)
        journalctl -u dns-rebinding -f
        ;;
    enable)
        echo "Enabling DNS rebinding service to start on boot..."
        systemctl enable dns-rebinding
        ;;
    disable)
        echo "Disabling DNS rebinding service..."
        systemctl disable dns-rebinding
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|enable|disable}"
        exit 1
        ;;
esac
EOF

chmod +x /opt/dns-rebinding/manage.sh

print_status "Setup completed successfully!"
echo
print_status "Next steps:"
echo "1. Copy your httprebind.py and requirements.txt to /opt/dns-rebinding/"
echo "2. Configure your domain's nameservers to point to: $IP"
echo "3. Wait for DNS propagation (can take up to 48 hours)"
echo "4. Test DNS resolution: dig NS $DOMAIN"
echo "5. Get SSL certificate: sudo certbot --apache -d $DOMAIN -d *.$DOMAIN"
echo "6. Start the service: sudo /opt/dns-rebinding/manage.sh start"
echo
print_warning "DNS Configuration Required:"
echo "Set these nameservers for $DOMAIN at your domain registrar:"
echo "  ns1.$DOMAIN -> $IP"
echo "  ns2.$DOMAIN -> $IP"
echo
print_warning "Or if using Cloudflare, add these DNS records:"
echo "  Type: A, Name: @, Content: $IP, Proxy: DNS Only (Gray Cloud)"
echo "  Type: A, Name: *, Content: $IP, Proxy: DNS Only (Gray Cloud)"
echo "  Type: A, Name: ns1, Content: $IP, Proxy: DNS Only (Gray Cloud)"
echo "  Type: A, Name: ns2, Content: $IP, Proxy: DNS Only (Gray Cloud)"
echo
print_status "Service management commands:"
echo "  sudo /opt/dns-rebinding/manage.sh start    # Start the service"
echo "  sudo /opt/dns-rebinding/manage.sh stop     # Stop the service"
echo "  sudo /opt/dns-rebinding/manage.sh restart  # Restart the service"
echo "  sudo /opt/dns-rebinding/manage.sh status   # Check service status"
echo "  sudo /opt/dns-rebinding/manage.sh logs     # View live logs"
echo "  sudo /opt/dns-rebinding/manage.sh enable   # Enable auto-start on boot"