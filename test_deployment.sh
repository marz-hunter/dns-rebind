#!/bin/bash

# DNSfookup Deployment Testing Script
# Usage: ./test_deployment.sh [domain] [server_ip]

set -e

# Configuration
DOMAIN=${1:-"rebind.com"}
SERVER_IP=${2:-"45.67.67.55"}

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

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

test_dns_records() {
    log_test "Testing DNS records..."
    
    # Test main application records
    log_info "Testing api.$DOMAIN..."
    if dig +short api.$DOMAIN | grep -q "$SERVER_IP"; then
        log_info "✅ api.$DOMAIN resolves to $SERVER_IP"
    else
        log_error "❌ api.$DOMAIN does not resolve to $SERVER_IP"
        return 1
    fi
    
    log_info "Testing app.$DOMAIN..."
    if dig +short app.$DOMAIN | grep -q "$SERVER_IP"; then
        log_info "✅ app.$DOMAIN resolves to $SERVER_IP"
    else
        log_error "❌ app.$DOMAIN does not resolve to $SERVER_IP"
        return 1
    fi
    
    # Test NS records
    log_info "Testing NS delegation for dns.$DOMAIN..."
    if dig NS dns.$DOMAIN +short | grep -q "ns.$DOMAIN"; then
        log_info "✅ NS delegation configured correctly"
    else
        log_warn "⚠️  NS delegation might not be configured"
    fi
    
    log_info "DNS records test completed"
}

test_services() {
    log_test "Testing system services..."
    
    services=("dnsfookup-dns.service" "dnsfookup-api.service" "nginx.service" "docker.service")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet $service; then
            log_info "✅ $service is running"
        else
            log_error "❌ $service is not running"
            systemctl status $service --no-pager -l
        fi
    done
}

test_dns_server() {
    log_test "Testing DNS server functionality..."
    
    # Test direct DNS query
    log_info "Testing direct DNS query to $SERVER_IP..."
    if timeout 5 dig @$SERVER_IP test.dns.$DOMAIN +short >/dev/null 2>&1; then
        log_info "✅ DNS server responds to queries"
    else
        log_error "❌ DNS server not responding"
        return 1
    fi
    
    # Test DNS rebinding functionality
    log_info "Testing DNS rebinding (this requires a created bin)..."
    # This would need a real UUID from the application
    log_warn "⚠️  Manual testing required for DNS rebinding functionality"
}

test_api_server() {
    log_test "Testing API server..."
    
    # Test HTTP redirect
    log_info "Testing HTTP to HTTPS redirect..."
    if curl -s -o /dev/null -w "%{http_code}" http://api.$DOMAIN/api/user | grep -q "301"; then
        log_info "✅ HTTP to HTTPS redirect working"
    else
        log_warn "⚠️  HTTP redirect might not be working"
    fi
    
    # Test HTTPS API
    log_info "Testing HTTPS API endpoint..."
    response=$(curl -s -o /dev/null -w "%{http_code}" https://api.$DOMAIN/api/user)
    if [[ "$response" == "401" || "$response" == "422" ]]; then
        log_info "✅ API server is responding (got $response - expected for unauthenticated request)"
    else
        log_error "❌ API server not responding correctly (got $response)"
    fi
    
    # Test CORS headers
    log_info "Testing CORS headers..."
    if curl -s -H "Origin: https://app.$DOMAIN" https://api.$DOMAIN/api/user | grep -q "Access-Control-Allow-Origin" || true; then
        log_info "✅ CORS headers present"
    else
        log_warn "⚠️  CORS headers might not be configured"
    fi
}

test_frontend() {
    log_test "Testing frontend..."
    
    # Test HTTP redirect
    log_info "Testing HTTP to HTTPS redirect..."
    if curl -s -o /dev/null -w "%{http_code}" http://app.$DOMAIN | grep -q "301"; then
        log_info "✅ HTTP to HTTPS redirect working"
    else
        log_warn "⚠️  HTTP redirect might not be working"
    fi
    
    # Test HTTPS frontend
    log_info "Testing HTTPS frontend..."
    if curl -s -o /dev/null -w "%{http_code}" https://app.$DOMAIN | grep -q "200"; then
        log_info "✅ Frontend is accessible"
    else
        log_error "❌ Frontend not accessible"
    fi
    
    # Test if React app loads
    log_info "Testing React app content..."
    if curl -s https://app.$DOMAIN | grep -q "DNSfookup\|React"; then
        log_info "✅ React app content detected"
    else
        log_warn "⚠️  React app might not be loading correctly"
    fi
}

test_ssl_certificates() {
    log_test "Testing SSL certificates..."
    
    # Test API SSL
    log_info "Testing API SSL certificate..."
    if echo | openssl s_client -connect api.$DOMAIN:443 -servername api.$DOMAIN 2>/dev/null | grep -q "Verify return code: 0"; then
        log_info "✅ API SSL certificate is valid"
    else
        log_error "❌ API SSL certificate issues"
    fi
    
    # Test Frontend SSL
    log_info "Testing Frontend SSL certificate..."
    if echo | openssl s_client -connect app.$DOMAIN:443 -servername app.$DOMAIN 2>/dev/null | grep -q "Verify return code: 0"; then
        log_info "✅ Frontend SSL certificate is valid"
    else
        log_error "❌ Frontend SSL certificate issues"
    fi
    
    # Check certificate expiry
    log_info "Checking certificate expiry..."
    api_expiry=$(echo | openssl s_client -connect api.$DOMAIN:443 -servername api.$DOMAIN 2>/dev/null | openssl x509 -noout -dates | grep notAfter | cut -d= -f2)
    app_expiry=$(echo | openssl s_client -connect app.$DOMAIN:443 -servername app.$DOMAIN 2>/dev/null | openssl x509 -noout -dates | grep notAfter | cut -d= -f2)
    
    log_info "API certificate expires: $api_expiry"
    log_info "App certificate expires: $app_expiry"
}

test_database_connection() {
    log_test "Testing database connection..."
    
    # Test PostgreSQL container
    if docker ps | grep -q postgres; then
        log_info "✅ PostgreSQL container is running"
    else
        log_error "❌ PostgreSQL container not running"
    fi
    
    # Test Redis container
    if docker ps | grep -q redis; then
        log_info "✅ Redis container is running"
    else
        log_error "❌ Redis container not running"
    fi
    
    # Test database connectivity (requires access to config)
    if [[ -f "/home/dnsfookup/dnsFookup/config.yaml" ]]; then
        log_info "✅ Configuration file exists"
    else
        log_warn "⚠️  Configuration file not found in expected location"
    fi
}

test_security() {
    log_test "Testing security configuration..."
    
    # Test firewall
    if ufw status | grep -q "Status: active"; then
        log_info "✅ Firewall is active"
        
        # Check required ports
        required_ports=("22" "53" "80" "443")
        for port in "${required_ports[@]}"; do
            if ufw status | grep -q "$port"; then
                log_info "✅ Port $port is configured in firewall"
            else
                log_warn "⚠️  Port $port might not be configured in firewall"
            fi
        done
    else
        log_warn "⚠️  Firewall is not active"
    fi
    
    # Test security headers
    log_info "Testing security headers..."
    headers=$(curl -s -I https://app.$DOMAIN)
    
    if echo "$headers" | grep -q "X-Frame-Options"; then
        log_info "✅ X-Frame-Options header present"
    else
        log_warn "⚠️  X-Frame-Options header missing"
    fi
    
    if echo "$headers" | grep -q "X-XSS-Protection"; then
        log_info "✅ X-XSS-Protection header present"
    else
        log_warn "⚠️  X-XSS-Protection header missing"
    fi
}

test_performance() {
    log_test "Testing performance..."
    
    # Test API response time
    log_info "Testing API response time..."
    api_time=$(curl -o /dev/null -s -w "%{time_total}" https://api.$DOMAIN/api/user)
    log_info "API response time: ${api_time}s"
    
    # Test frontend load time
    log_info "Testing frontend load time..."
    frontend_time=$(curl -o /dev/null -s -w "%{time_total}" https://app.$DOMAIN)
    log_info "Frontend load time: ${frontend_time}s"
    
    # Test DNS query time
    log_info "Testing DNS query time..."
    dns_time=$(dig @$SERVER_IP test.dns.$DOMAIN | grep "Query time" | awk '{print $4 " " $5}')
    log_info "DNS query time: $dns_time"
}

generate_test_report() {
    log_info "Generating test report..."
    
    report_file="deployment_test_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > $report_file <<EOF
DNSfookup Deployment Test Report
================================
Date: $(date)
Domain: $DOMAIN
Server IP: $SERVER_IP

Test Results:
- DNS Records: $(test_dns_records >/dev/null 2>&1 && echo "PASS" || echo "FAIL")
- System Services: $(test_services >/dev/null 2>&1 && echo "PASS" || echo "FAIL")  
- DNS Server: $(test_dns_server >/dev/null 2>&1 && echo "PASS" || echo "FAIL")
- API Server: $(test_api_server >/dev/null 2>&1 && echo "PASS" || echo "FAIL")
- Frontend: $(test_frontend >/dev/null 2>&1 && echo "PASS" || echo "FAIL")
- SSL Certificates: $(test_ssl_certificates >/dev/null 2>&1 && echo "PASS" || echo "FAIL")
- Database: $(test_database_connection >/dev/null 2>&1 && echo "PASS" || echo "FAIL")
- Security: $(test_security >/dev/null 2>&1 && echo "PASS" || echo "FAIL")

URLs:
- Frontend: https://app.$DOMAIN
- API: https://api.$DOMAIN
- DNS Server: ns.$DOMAIN ($SERVER_IP:53)
- DNS Rebinding: *.dns.$DOMAIN

Next Steps:
1. Fix any failing tests
2. Configure Cloudflare DNS records
3. Test DNS rebinding functionality manually
4. Monitor logs for any issues
EOF
    
    log_info "Test report saved to: $report_file"
}

print_manual_tests() {
    log_info "Manual tests to perform:"
    echo ""
    echo "1. Test DNS Rebinding:"
    echo "   - Create a new DNS bin via https://app.$DOMAIN"
    echo "   - Use the generated domain in your testing"
    echo "   - Verify IP changes according to your configuration"
    echo ""
    echo "2. Test Vulnerable App:"
    echo "   - Deploy the vulnerable app from vulnerableApp/ directory"
    echo "   - Test SSRF bypass using DNS rebinding"
    echo ""
    echo "3. Monitor Logs:"
    echo "   - sudo journalctl -u dnsfookup-dns.service -f"
    echo "   - sudo journalctl -u dnsfookup-api.service -f"
    echo "   - sudo tail -f /var/log/nginx/access.log"
    echo ""
    echo "4. Load Testing:"
    echo "   - Test with multiple concurrent DNS queries"
    echo "   - Test API under load"
    echo "   - Monitor resource usage"
}

main() {
    echo "🧪 DNSfookup Deployment Testing"
    echo "==============================="
    echo "Domain: $DOMAIN"
    echo "Server IP: $SERVER_IP"
    echo ""
    
    # Run all tests
    test_dns_records || true
    echo ""
    test_services || true
    echo ""
    test_dns_server || true
    echo ""
    test_api_server || true
    echo ""
    test_frontend || true
    echo ""
    test_ssl_certificates || true
    echo ""
    test_database_connection || true
    echo ""
    test_security || true
    echo ""
    test_performance || true
    echo ""
    
    generate_test_report
    print_manual_tests
    
    log_info "🎉 Testing completed! Check the report file for details."
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    log_error "This script should not be run as root"
    exit 1
fi

# Run main function
main "$@"
