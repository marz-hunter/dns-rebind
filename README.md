# DNS Rebinding Attack Tool

A modern DNS rebinding attack tool for security testing against cloud metadata services (AWS EC2, ECS, and Google Cloud Platform). Updated for Python 3 compatibility and enhanced with better error handling and user interface.

## What is DNS Rebinding?

DNS rebinding is a technique that bypasses the Same-Origin Policy (SOP) in web browsers by manipulating DNS responses. This tool demonstrates how an attacker can potentially access cloud metadata services from a victim's browser, which could lead to credential theft and privilege escalation in cloud environments.

## Features

- **Multi-Cloud Support**: Targets AWS EC2, ECS, and Google Cloud Platform metadata services
- **Modern Python 3**: Updated from legacy Python 2 code
- **Enhanced UI**: Improved web interface with real-time status updates
- **Better Logging**: Comprehensive logging and error handling
- **SSL Support**: Works with HTTPS configurations

## Installation

### Prerequisites

- Ubuntu/Debian server with root access
- Python 3.6 or higher
- Domain name with ability to configure nameservers

### Quick Setup

1. Clone or download this repository:
```bash
git clone <repository-url>
cd dns-rebinding-tool
```

2. Install Python dependencies:
```bash
sudo pip3 install -r requirements.txt
```

3. For SSL support, install Apache and Certbot:
```bash
sudo apt update
sudo apt install apache2 python3-certbot-apache -y
sudo systemctl enable apache2
sudo systemctl start apache2
```

## Usage

### Basic Command
```bash
sudo python3 httprebind.py <domain> <server-ip> <mode>
```

**Parameters:**
- `domain`: Your domain name (e.g., myrebinding.com)
- `server-ip`: External IPv4 address of your server (e.g., 77.77.77.77)
- `mode`: Target cloud platform (`ec2`, `ecs`, or `gcloud`)

### Examples

**AWS EC2 Testing:**
```bash
sudo python3 httprebind.py myrebinding.com 77.77.77.77 ec2
```

**AWS ECS Testing:**
```bash
sudo python3 httprebind.py myrebinding.com 77.77.77.77 ecs
```

**Google Cloud Testing:**
```bash
sudo python3 httprebind.py myrebinding.com 77.77.77.77 gcloud
```

## Setup Guide

### Step 1: Domain and DNS Configuration

1. **Purchase a domain** (e.g., myrebinding.com from any registrar)

2. **Configure nameservers** to point to your VPS:
   - ns1.myrebinding.com → 77.77.77.77
   - ns2.myrebinding.com → 77.77.77.77

### Step 2: Cloudflare Setup (Optional but Recommended)

Using Cloudflare provides additional features like DDoS protection and easier SSL management:

1. **Add your domain to Cloudflare:**
   - Sign up at [cloudflare.com](https://cloudflare.com)
   - Add your domain
   - Update nameservers at your registrar to Cloudflare's nameservers

2. **Configure DNS records in Cloudflare:**
   ```
   Type  | Name | Content      | Proxy Status
   ------|------|------------- |-------------
   A     | @    | 77.77.77.77  | DNS Only (Gray Cloud)
   A     | *    | 77.77.77.77  | DNS Only (Gray Cloud)
   A     | ns1  | 77.77.77.77  | DNS Only (Gray Cloud)
   A     | ns2  | 77.77.77.77  | DNS Only (Gray Cloud)
   ```

   **Important**: Use "DNS Only" (gray cloud) to avoid Cloudflare proxy interfering with the DNS rebinding attack.

3. **Set custom nameservers** (if you want your own NS records):
   - Go to DNS → Records
   - Add NS records pointing to ns1.yourdomain.com and ns2.yourdomain.com

### Step 3: SSL Certificate Setup

#### Option A: Using Certbot with Apache (Recommended)

1. **Configure Apache virtual host:**
```bash
sudo nano /etc/apache2/sites-available/rebinding.conf
```

Add the following configuration:
```apache
<VirtualHost *:80>
    ServerName myrebinding.com
    ServerAlias *.myrebinding.com
    DocumentRoot /var/www/html
    
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8080/
    ProxyPassReverse / http://127.0.0.1:8080/
    
    ErrorLog ${APACHE_LOG_DIR}/rebinding_error.log
    CustomLog ${APACHE_LOG_DIR}/rebinding_access.log combined
</VirtualHost>
```

2. **Enable the site and required modules:**
```bash
sudo a2enmod proxy
sudo a2enmod proxy_http
sudo a2ensite rebinding.conf
sudo systemctl reload apache2
```

3. **Obtain SSL certificate:**
```bash
sudo certbot --apache -d myrebinding.com -d *.myrebinding.com
```

4. **Modify your Python script** to run on port 8080:
```python
# Change the Flask app run line to:
lambda: app.run(host='0.0.0.0', port=8080, debug=False)
```

#### Option B: Using Cloudflare SSL

1. In Cloudflare dashboard:
   - Go to SSL/TLS → Overview
   - Set SSL/TLS encryption mode to "Flexible" or "Full"
   - Enable "Always Use HTTPS"

2. Your domain will automatically have SSL enabled

### Step 4: Running the Tool

1. **Start the DNS rebinding server:**
```bash
sudo python3 httprebind.py myrebinding.com 77.77.77.77 ec2
```

2. **Access the attack interface:**
   - HTTP: `http://myrebinding.com`
   - HTTPS: `https://myrebinding.com`

3. **Monitor the logs** for successful attacks and data exfiltration

## How It Works

1. **Initial Phase**: Victim visits your domain, DNS resolves to your server IP
2. **Cache Poisoning**: JavaScript floods DNS cache with subdomain requests
3. **DNS Rebinding**: Server changes DNS response to target metadata IP (169.254.169.254)
4. **Metadata Access**: Browser makes requests to metadata services thinking it's still your domain
5. **Data Exfiltration**: Retrieved metadata is sent back to your server via logging

## Target Metadata Services

### AWS EC2 (169.254.169.254)
- IAM roles and security credentials
- Instance metadata
- User data
- Network interfaces information

### AWS ECS (169.254.170.2)
- Task metadata
- Container credentials
- Task definitions

### Google Cloud Platform (169.254.169.254)
- Instance metadata
- Service account tokens
- SSH keys
- Project information

## Security Considerations

⚠️ **This tool is for authorized security testing only. Use responsibly:**

- Only test systems you own or have explicit permission to test
- Follow responsible disclosure practices
- Be aware of legal implications in your jurisdiction
- Consider the impact on production systems

## Troubleshooting

### DNS Issues
- Verify nameserver configuration: `dig NS yourdomain.com`
- Check DNS propagation: `dig @8.8.8.8 yourdomain.com`
- Test subdomain resolution: `dig a1.ex.yourdomain.com`

### SSL Issues
- Check certificate validity: `openssl s_client -connect yourdomain.com:443`
- Verify Apache configuration: `sudo apache2ctl configtest`
- Review certificate logs: `sudo tail -f /var/log/letsencrypt/letsencrypt.log`

### Firewall Configuration
Make sure these ports are open:
```bash
sudo ufw allow 22    # SSH
sudo ufw allow 53    # DNS
sudo ufw allow 80    # HTTP
sudo ufw allow 443   # HTTPS
sudo ufw enable
```

## Legal Disclaimer

This tool is provided for educational and authorized security testing purposes only. Users are responsible for complying with all applicable laws and regulations. The authors assume no liability for misuse of this software.

## Conference Presentation Notes

When presenting this tool:
- Emphasize the educational nature and responsible disclosure
- Demonstrate the attack in a controlled environment
- Discuss mitigation strategies for cloud providers and developers
- Highlight the importance of proper network segmentation

## Changes from Original

- **Python 3 Compatibility**: Updated all Python 2 syntax
- **Enhanced Error Handling**: Better exception management and logging
- **Improved UI**: Modern HTML interface with real-time updates
- **SSL Support**: Complete SSL/HTTPS setup instructions
- **Better Documentation**: Comprehensive setup and troubleshooting guide
- **Security Enhancements**: Updated security considerations and warnings

## Contributing

Feel free to submit issues, suggestions, or pull requests to improve this tool.

---

*Last updated: 2025*
