#!/bin/bash

# DNSfookup Version Checker Script
# Usage: ./check_versions.sh

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_check() {
    echo -e "${BLUE}[CHECK]${NC} $1"
}

check_version() {
    local software=$1
    local command=$2
    local min_version=$3
    local current_version=""
    
    if command -v $software &> /dev/null; then
        current_version=$($command 2>/dev/null || echo "unknown")
        log_info "✅ $software: $current_version"
        return 0
    else
        log_error "❌ $software: Not installed"
        return 1
    fi
}

check_python_packages() {
    log_check "Checking Python packages in virtual environment..."
    
    if [[ -d "BE/venv" ]]; then
        source BE/venv/bin/activate
        
        packages=("Flask" "gunicorn" "psycopg2-binary" "redis" "dnslib")
        
        for package in "${packages[@]}"; do
            if pip list | grep -i "$package" &> /dev/null; then
                version=$(pip list | grep -i "$package" | awk '{print $2}')
                log_info "✅ $package: $version"
            else
                log_error "❌ $package: Not installed"
            fi
        done
        
        deactivate
    else
        log_warn "⚠️  Virtual environment not found at BE/venv"
    fi
}

check_node_packages() {
    log_check "Checking Node.js packages..."
    
    if [[ -f "FE/package.json" ]]; then
        cd FE
        
        if [[ -d "node_modules" ]]; then
            packages=("react" "react-dom" "react-router-dom" "semantic-ui-react")
            
            for package in "${packages[@]}"; do
                if npm list "$package" &> /dev/null; then
                    version=$(npm list "$package" --depth=0 2>/dev/null | grep "$package" | awk -F'@' '{print $2}')
                    log_info "✅ $package: $version"
                else
                    log_error "❌ $package: Not installed"
                fi
            done
        else
            log_warn "⚠️  node_modules directory not found"
        fi
        
        cd ..
    else
        log_warn "⚠️  package.json not found in FE directory"
    fi
}

check_services() {
    log_check "Checking system services..."
    
    services=("docker" "dnsfookup-dns.service" "dnsfookup-api.service" "nginx")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet $service; then
            status="✅ Running"
        elif systemctl is-enabled --quiet $service; then
            status="⚠️  Enabled but not running"
        elif systemctl list-unit-files | grep -q "^$service"; then
            status="❌ Stopped"
        else
            status="❌ Not found"
        fi
        
        log_info "$service: $status"
    done
}

check_docker_containers() {
    log_check "Checking Docker containers..."
    
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        containers=$(docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(postgres|redis)")
        
        if [[ -n "$containers" ]]; then
            echo "$containers" | while read line; do
                if [[ "$line" != *"NAMES"* ]]; then
                    name=$(echo "$line" | awk '{print $1}')
                    status=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
                    
                    if [[ "$status" == *"Up"* ]]; then
                        log_info "✅ $name: $status"
                    else
                        log_error "❌ $name: $status"
                    fi
                fi
            done
        else
            log_warn "⚠️  No PostgreSQL or Redis containers found"
        fi
    else
        log_warn "⚠️  Docker is not running or not installed"
    fi
}

check_ssl_certificates() {
    log_check "Checking SSL certificates..."
    
    domains=("api" "app")
    
    for subdomain in "${domains[@]}"; do
        cert_path="/etc/letsencrypt/live/${subdomain}.$(hostname -d)/cert.pem"
        
        if [[ -f "$cert_path" ]]; then
            expiry=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
            
            if openssl x509 -checkend 2592000 -noout -in "$cert_path" >/dev/null 2>&1; then
                log_info "✅ ${subdomain} certificate: Valid until $expiry"
            else
                log_warn "⚠️  ${subdomain} certificate: Expires within 30 days ($expiry)"
            fi
        else
            log_error "❌ ${subdomain} certificate: Not found"
        fi
    done
}

check_dns_resolution() {
    log_check "Checking DNS resolution..."
    
    if [[ -n "${1:-}" ]]; then
        domain=$1
        
        subdomains=("api" "app" "ns")
        
        for subdomain in "${subdomains[@]}"; do
            if dig +short "${subdomain}.${domain}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' &> /dev/null; then
                ip=$(dig +short "${subdomain}.${domain}")
                log_info "✅ ${subdomain}.${domain}: $ip"
            else
                log_error "❌ ${subdomain}.${domain}: No A record found"
            fi
        done
        
        # Check NS record
        if dig NS "dns.${domain}" +short | grep -q "ns.${domain}"; then
            log_info "✅ dns.${domain}: NS record configured"
        else
            log_warn "⚠️  dns.${domain}: NS record not configured"
        fi
    else
        log_warn "⚠️  Domain not provided, skipping DNS resolution check"
    fi
}

check_ports() {
    log_check "Checking open ports..."
    
    ports=("53" "80" "443" "5000")
    
    for port in "${ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            service=$(ss -tuln | grep ":$port " | head -1)
            log_info "✅ Port $port: Open ($service)"
        else
            log_warn "⚠️  Port $port: Not listening"
        fi
    done
}

main() {
    echo "🔍 DNSfookup Version & Status Checker"
    echo "====================================="
    echo ""
    
    log_check "Checking system software versions..."
    
    # System software
    check_version "python3" "python3 --version | cut -d' ' -f2"
    check_version "node" "node --version"
    check_version "npm" "npm --version"
    check_version "docker" "docker --version | cut -d' ' -f3 | cut -d',' -f1"
    check_version "docker-compose" "docker-compose --version | cut -d' ' -f3 | cut -d',' -f1"
    check_version "nginx" "nginx -v 2>&1 | cut -d'/' -f2"
    check_version "certbot" "certbot --version | cut -d' ' -f2"
    check_version "openssl" "openssl version | cut -d' ' -f2"
    
    echo ""
    
    # Python packages
    check_python_packages
    echo ""
    
    # Node.js packages
    check_node_packages
    echo ""
    
    # System services
    check_services
    echo ""
    
    # Docker containers
    check_docker_containers
    echo ""
    
    # SSL certificates
    check_ssl_certificates
    echo ""
    
    # DNS resolution (if domain provided)
    if [[ -n "${1:-}" ]]; then
        check_dns_resolution "$1"
        echo ""
    fi
    
    # Open ports
    check_ports
    echo ""
    
    # System resources
    log_check "System resources:"
    echo "- CPU Usage: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)%"
    echo "- Memory Usage: $(free -m | awk 'NR==2{printf "%.1f%%", $3*100/$2}')"
    echo "- Disk Usage: $(df -h / | awk 'NR==2{print $5}')"
    echo "- Load Average: $(uptime | awk -F'load average:' '{print $2}')"
    
    echo ""
    log_info "✅ Version check completed!"
    
    if [[ -n "${1:-}" ]]; then
        echo ""
        log_info "💡 To test full functionality, run: ./test_deployment.sh $1"
    fi
}

# Run main function
main "$@"
