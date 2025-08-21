#!/bin/bash
# DNS Testing and Validation Script for DNS Rebinding Tool

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}  DNS Rebinding - DNS Tests${NC}"
    echo -e "${BLUE}================================${NC}"
}

if [ -z "$1" ]; then
    echo "Usage: $0 <domain>"
    echo "Example: $0 myrebinding.com"
    exit 1
fi

DOMAIN=$1
SERVER_IP=$(curl -s ifconfig.me)

print_header
echo "Testing domain: $DOMAIN"
echo "Server IP: $SERVER_IP"
echo

# Test 1: Basic DNS resolution
print_test "Testing basic DNS resolution..."
BASIC_RESULT=$(dig +short $DOMAIN @8.8.8.8 2>/dev/null)
if [ -n "$BASIC_RESULT" ]; then
    print_status "Basic DNS resolution: $DOMAIN -> $BASIC_RESULT"
    if [ "$BASIC_RESULT" == "$SERVER_IP" ]; then
        print_status "DNS points to correct server IP"
    else
        print_warning "DNS points to different IP than server IP"
    fi
else
    print_error "Basic DNS resolution failed"
fi

# Test 2: Nameserver resolution
print_test "Testing nameserver resolution..."
NS_RESULT=$(dig +short NS $DOMAIN @8.8.8.8 2>/dev/null)
if [ -n "$NS_RESULT" ]; then
    print_status "Nameservers found:"
    echo "$NS_RESULT" | while read -r ns; do
        echo "  - $ns"
    done
else
    print_error "No nameservers found"
fi

# Test 3: Subdomain resolution (critical for attack)
print_test "Testing subdomain resolution..."
SUB_RESULT=$(dig +short ex.$DOMAIN @8.8.8.8 2>/dev/null)
if [ -n "$SUB_RESULT" ]; then
    print_status "Subdomain resolution: ex.$DOMAIN -> $SUB_RESULT"
else
    print_error "Subdomain resolution failed - attack will not work!"
fi

# Test 4: Wildcard resolution
print_test "Testing wildcard resolution..."
WILD_RESULT=$(dig +short test123.$DOMAIN @8.8.8.8 2>/dev/null)
if [ -n "$WILD_RESULT" ]; then
    print_status "Wildcard resolution: *.${DOMAIN} -> $WILD_RESULT"
else
    print_warning "Wildcard resolution failed - some attacks may not work"
fi

# Test 5: Backchannel subdomain
print_test "Testing backchannel subdomain..."
BC_RESULT=$(dig +short bc.$DOMAIN @8.8.8.8 2>/dev/null)
if [ -n "$BC_RESULT" ]; then
    print_status "Backchannel resolution: bc.$DOMAIN -> $BC_RESULT"
else
    print_error "Backchannel resolution failed - logging will not work!"
fi

# Test 6: DNS cache poisoning subdomains
print_test "Testing DNS cache poisoning subdomains..."
POISON_COUNT=0
for i in {1..5}; do
    POISON_RESULT=$(dig +short a${i}.ex.$DOMAIN @8.8.8.8 2>/dev/null)
    if [ -n "$POISON_RESULT" ]; then
        ((POISON_COUNT++))
    fi
done

if [ $POISON_COUNT -eq 5 ]; then
    print_status "DNS cache poisoning subdomains working ($POISON_COUNT/5)"
else
    print_warning "Some DNS cache poisoning subdomains not working ($POISON_COUNT/5)"
fi

# Test 7: HTTP connectivity
print_test "Testing HTTP connectivity..."
HTTP_RESULT=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://$DOMAIN/ 2>/dev/null)
if [ "$HTTP_RESULT" == "200" ] || [ "$HTTP_RESULT" == "000" ]; then
    if [ "$HTTP_RESULT" == "200" ]; then
        print_status "HTTP connectivity: Working (HTTP $HTTP_RESULT)"
    else
        print_warning "HTTP connectivity: Connection possible but no response"
    fi
else
    print_error "HTTP connectivity failed (HTTP $HTTP_RESULT)"
fi

# Test 8: HTTPS connectivity (if available)
print_test "Testing HTTPS connectivity..."
HTTPS_RESULT=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 -k https://$DOMAIN/ 2>/dev/null)
if [ "$HTTPS_RESULT" == "200" ]; then
    print_status "HTTPS connectivity: Working (HTTP $HTTPS_RESULT)"
elif [ "$HTTPS_RESULT" == "000" ]; then
    print_warning "HTTPS connectivity: No SSL certificate or connection refused"
else
    print_warning "HTTPS connectivity: Limited (HTTP $HTTPS_RESULT)"
fi

# Test 9: DNS propagation across multiple servers
print_test "Testing DNS propagation across multiple servers..."
DNS_SERVERS=("8.8.8.8" "1.1.1.1" "208.67.222.222" "9.9.9.9")
PROPAGATION_COUNT=0

for dns in "${DNS_SERVERS[@]}"; do
    PROP_RESULT=$(dig +short $DOMAIN @$dns 2>/dev/null | head -1)
    if [ -n "$PROP_RESULT" ] && [ "$PROP_RESULT" == "$SERVER_IP" ]; then
        ((PROPAGATION_COUNT++))
    fi
done

if [ $PROPAGATION_COUNT -eq ${#DNS_SERVERS[@]} ]; then
    print_status "DNS propagation: Complete (${PROPAGATION_COUNT}/${#DNS_SERVERS[@]} servers)"
elif [ $PROPAGATION_COUNT -gt 0 ]; then
    print_warning "DNS propagation: Partial (${PROPAGATION_COUNT}/${#DNS_SERVERS[@]} servers) - may need more time"
else
    print_error "DNS propagation: Failed (${PROPAGATION_COUNT}/${#DNS_SERVERS[@]} servers)"
fi

# Test 10: Port accessibility
print_test "Testing required ports..."
PORTS=("53" "80" "443")
for port in "${PORTS[@]}"; do
    if timeout 3 bash -c "echo >/dev/tcp/$SERVER_IP/$port" 2>/dev/null; then
        print_status "Port $port: Open"
    else
        if [ "$port" == "53" ]; then
            print_error "Port $port: Closed or filtered (DNS will not work!)"
        elif [ "$port" == "443" ]; then
            print_warning "Port $port: Closed or filtered (HTTPS will not work)"
        else
            print_warning "Port $port: Closed or filtered (HTTP may not work)"
        fi
    fi
done

echo
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}         Test Summary${NC}"
echo -e "${BLUE}================================${NC}"

# Overall assessment
CRITICAL_ISSUES=0
if [ -z "$BASIC_RESULT" ]; then ((CRITICAL_ISSUES++)); fi
if [ -z "$SUB_RESULT" ]; then ((CRITICAL_ISSUES++)); fi
if [ -z "$BC_RESULT" ]; then ((CRITICAL_ISSUES++)); fi

if [ $CRITICAL_ISSUES -eq 0 ]; then
    print_status "All critical tests passed - DNS rebinding attack should work!"
    echo
    echo "You can now run:"
    echo "  sudo python3 httprebind.py $DOMAIN $SERVER_IP ec2"
    echo "  sudo python3 httprebind.py $DOMAIN $SERVER_IP ecs"
    echo "  sudo python3 httprebind.py $DOMAIN $SERVER_IP gcloud"
elif [ $CRITICAL_ISSUES -eq 1 ]; then
    print_warning "1 critical issue found - attack may have limited functionality"
else
    print_error "$CRITICAL_ISSUES critical issues found - attack likely will not work"
    echo
    echo "Common fixes:"
    echo "1. Check nameserver configuration at your domain registrar"
    echo "2. Wait for DNS propagation (can take up to 48 hours)"
    echo "3. Verify firewall allows ports 53, 80, and 443"
    echo "4. Ensure your DNS server is running and responding"
fi

echo
echo "For detailed troubleshooting, check the README.md file."
