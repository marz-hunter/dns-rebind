# DNSfookup Installation Guide - 2025 Update

This guide provides updated installation instructions for DNSfookup v2.1.0, compatible with modern dependencies and Python 3.9+.

## Prerequisites

- Python 3.9 or higher
- Node.js 18.x or higher
- Docker and Docker Compose
- Git

## Installation Steps

### 1. Clone and Setup

```bash
git clone https://github.com/your-username/dnsFookup.git
cd dnsFookup
```

### 2. Configuration

Edit the configuration file:

```bash
cp config.yaml config.yaml.backup
vim config.yaml
```

**Important**: Change the following values:
- `jwt.secret_key`: Use a strong random key
- `sql.password`: Your PostgreSQL password
- `redis.password`: Your Redis password
- `dns.domain`: Your domain name

### 3. Backend Setup

```bash
cd BE

# Create virtual environment (recommended)
python3 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Set environment variables
export FLASK_APP=app.py
export FLASK_ENV=development
```

### 4. Database Setup

Start PostgreSQL and Redis using Docker:

```bash
# From project root
docker-compose up -d
```

Wait for services to be ready, then initialize the database:

```bash
cd BE
python3 -c "from app import app, db; app.app_context().push(); db.create_all()"
```

### 5. Frontend Setup

```bash
cd ../FE

# Install dependencies
npm install

# Update configuration
# Edit src/config.js to match your backend URL and domain
```

### 6. Running the Application

#### Start the DNS Server
```bash
cd BE
python3 dns.py
```

#### Start the API Server
```bash
cd BE
flask run --host=0.0.0.0 --port=5000
```

#### Start the Frontend
```bash
cd FE
npm start
```

The application will be available at:
- Frontend: http://localhost:3000
- API: http://localhost:5000
- DNS Server: port 53 (requires sudo/admin privileges)

## Production Deployment

### Using uWSGI (Backend)

```bash
cd BE
pip install uwsgi
uwsgi --ini uwsgi.ini
```

### Building Frontend for Production

```bash
cd FE
npm run build
```

Serve the `build` directory with your web server (nginx, Apache, etc.).

## Troubleshooting

### Common Issues

1. **Port 53 Permission Denied**
   ```bash
   sudo python3 dns.py
   ```

2. **Database Connection Issues**
   - Ensure PostgreSQL is running: `docker-compose ps`
   - Check connection settings in config.yaml

3. **Redis Connection Issues**
   - Verify Redis is running: `docker exec -it dnsfookup-redis redis-cli ping`
   - Check password in config.yaml

4. **Frontend API Connection**
   - Update `src/config.js` with correct backend URL
   - Check CORS settings in backend

### Development vs Production

- **Development**: Uses `localhost` URLs
- **Production**: Update `src/config.js` with your domain

## Security Notes

1. Change all default passwords in `config.yaml`
2. Use HTTPS in production
3. Restrict database access
4. Use strong JWT secret keys
5. Keep dependencies updated

## Updates from Original Version

- **Flask 3.1.1**: Modern Flask with updated patterns
- **React 18**: Latest React with Router v6
- **Python 3.9+**: Modern Python support
- **Updated Dependencies**: All packages updated to 2025 versions
- **Docker Compose 3.8**: Modern Docker configuration
- **Security Improvements**: Updated authentication patterns

## Support

If you encounter issues:
1. Check the logs for error messages
2. Verify all services are running
3. Ensure configuration is correct
4. Check firewall settings for DNS port 53
