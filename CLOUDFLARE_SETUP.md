# Cloudflare DNS Setup untuk DNSfookup

Panduan lengkap untuk mengkonfigurasi Cloudflare DNS agar DNSfookup berfungsi dengan domain `rebind.com` dan VPS `45.67.67.55`.

## 🌐 Overview Setup

```
Domain: rebind.com (managed by Cloudflare)
VPS IP: 45.67.67.55
Frontend: https://app.rebind.com
API: https://api.rebind.com
DNS Server: ns.rebind.com (45.67.67.55:53)
DNS Rebinding: *.dns.rebind.com → 45.67.67.55:53
```

## ⚙️ Cloudflare DNS Records Configuration

Masuk ke Cloudflare Dashboard → pilih domain `rebind.com` → DNS → Records

### 1. Main Application Records

| Type | Name | Content | Proxy Status | TTL |
|------|------|---------|--------------|-----|
| A | api | 45.67.67.55 | 🔴 DNS only | Auto |
| A | app | 45.67.67.55 | 🔴 DNS only | Auto |

**⚠️ PENTING**: Kedua record harus set ke "DNS only" (bukan "Proxied") agar SSL bisa di-handle oleh Nginx di server.

### 2. DNS Server Records

| Type | Name | Content | Proxy Status | TTL |
|------|------|---------|--------------|-----|
| A | ns | 45.67.67.55 | 🔴 DNS only | Auto |
| NS | dns | ns.rebind.com | 🔴 DNS only | Auto |

**Penjelasan**:
- `ns.rebind.com` adalah nameserver untuk DNS rebinding
- `dns.rebind.com` subdomain akan di-handle oleh DNS server kita
- Semua query ke `*.dns.rebind.com` akan diarahkan ke server kita

### 3. Wildcard Record untuk DNS Rebinding

| Type | Name | Content | Proxy Status | TTL |
|------|------|---------|--------------|-----|
| A | *.dns | 45.67.67.55 | 🔴 DNS only | Auto |

**Note**: Record ini sebagai fallback jika NS delegation tidak bekerja sempurna.

## 🔧 Advanced Configuration (Optional)

### CAA Records untuk SSL Security
Tambahkan CAA records untuk keamanan SSL:

| Type | Name | Content | Proxy Status | TTL |
|------|------|---------|--------------|-----|
| CAA | rebind.com | 0 issue "letsencrypt.org" | 🔴 DNS only | Auto |
| CAA | rebind.com | 0 issuewild "letsencrypt.org" | 🔴 DNS only | Auto |

### MX Record (Optional)
Jika ingin email support:

| Type | Name | Content | Proxy Status | Priority | TTL |
|------|------|---------|--------------|----------|-----|
| MX | rebind.com | mail.rebind.com | 🔴 DNS only | 10 | Auto |
| A | mail | 45.67.67.55 | 🔴 DNS only | - | Auto |

## 🧪 Testing DNS Configuration

### 1. Test Basic Resolution
```bash
# Test main records
dig api.rebind.com
dig app.rebind.com
dig ns.rebind.com

# Should all return 45.67.67.55
```

### 2. Test NS Delegation
```bash
# Test NS record
dig NS dns.rebind.com

# Should return: dns.rebind.com. IN NS ns.rebind.com.
```

### 3. Test DNS Server Response
```bash
# Test direct query to your DNS server
dig @45.67.67.55 test.dns.rebind.com

# Should return NXDOMAIN atau failure IP (sesuai config)
```

### 4. Test Recursive Resolution
```bash
# Test via public DNS
dig @8.8.8.8 test.dns.rebind.com

# Should query your server dan return response
```

## 🔍 Troubleshooting DNS Issues

### Issue 1: NS Delegation Tidak Bekerja

**Symptoms**: Query ke `*.dns.rebind.com` tidak sampai ke server Anda

**Solutions**:
```bash
# Check NS propagation
dig NS dns.rebind.com @8.8.8.8
dig NS dns.rebind.com @1.1.1.1

# Check dari berbagai DNS servers
for dns in 8.8.8.8 1.1.1.1 208.67.222.222; do
  echo "Testing $dns:"
  dig @$dns NS dns.rebind.com
done
```

**Fix**: Pastikan NS record di Cloudflare benar dan tunggu propagasi (bisa 24-48 jam).

### Issue 2: DNS Server Tidak Respond

**Symptoms**: Timeout saat query langsung ke server

**Solutions**:
```bash
# Check if DNS service running
sudo systemctl status dnsfookup-dns.service

# Check if port 53 open
sudo netstat -tulpn | grep :53

# Check firewall
sudo ufw status

# Test local resolution
dig @127.0.0.1 test.dns.rebind.com
```

### Issue 3: Cloudflare Proxy Issues

**Symptoms**: SSL errors atau connection issues

**Solutions**:
- Pastikan semua DNS records set ke "DNS only" (tidak di-proxy)
- Cloudflare proxy tidak compatible dengan custom DNS servers
- SSL harus di-handle di server Anda, bukan Cloudflare

## 📊 DNS Propagation Monitoring

### Online Tools
- https://dnschecker.org/
- https://www.whatsmydns.net/
- https://dns.google/ (Google DNS lookup)

### Command Line Monitoring
```bash
# Monitor propagation script
#!/bin/bash
DOMAIN="dns.rebind.com"
SERVERS=("8.8.8.8" "1.1.1.1" "208.67.222.222" "9.9.9.9")

for server in "${SERVERS[@]}"; do
    echo "Checking $server:"
    dig @$server NS $DOMAIN +short
    echo ""
done
```

## 🔒 Security Considerations

### 1. DNS Security
- **DNSSEC**: Tidak direkomendasikan untuk DNS rebinding (akan conflict)
- **CAA Records**: Gunakan untuk restrict SSL certificate issuance
- **Rate Limiting**: Implementasikan di aplikasi level

### 2. Subdomain Security
```bash
# Monitor unusual DNS queries
sudo tail -f /var/log/syslog | grep named

# Monitor DNSfookup logs
sudo journalctl -u dnsfookup-dns.service -f
```

### 3. Firewall Rules
```bash
# Only allow DNS from specific sources (optional)
sudo ufw allow from any to any port 53 proto udp
sudo ufw allow from any to any port 53 proto tcp
```

## 🚀 Production Checklist

- [ ] Semua DNS records sudah dibuat di Cloudflare
- [ ] Semua records set ke "DNS only" (tidak di-proxy)
- [ ] NS delegation berfungsi (`dig NS dns.rebind.com`)
- [ ] DNS server respond (`dig @45.67.67.55 test.dns.rebind.com`)
- [ ] SSL certificates ter-install untuk api.rebind.com dan app.rebind.com
- [ ] Firewall allow port 53, 80, 443
- [ ] DNS propagation sudah selesai (24-48 jam)
- [ ] Testing DNS rebinding functionality

## 📝 DNS Record Summary

Setelah setup selesai, DNS records Anda di Cloudflare harus seperti ini:

```
rebind.com.           A      45.67.67.55 (if needed)
api.rebind.com.       A      45.67.67.55 (DNS only)
app.rebind.com.       A      45.67.67.55 (DNS only)
ns.rebind.com.        A      45.67.67.55 (DNS only)
dns.rebind.com.       NS     ns.rebind.com. (DNS only)
*.dns.rebind.com.     A      45.67.67.55 (DNS only, fallback)
```

## 🆘 Emergency Recovery

Jika DNS setup bermasalah dan perlu rollback:

```bash
# Temporary: Point semua ke server IP
# Di Cloudflare, ubah sementara:
dns.rebind.com.       A      45.67.67.55 (DNS only)

# Hapus NS record sementara:
# dns.rebind.com.       NS     ns.rebind.com.
```

Ini akan membuat semua query `*.dns.rebind.com` langsung ke server Anda tanpa NS delegation, sebagai workaround sementara.

---

**💡 Tips**: Selalu test konfigurasi DNS dari berbagai lokasi dan DNS servers untuk memastikan propagation sudah selesai sebelum go-live!
