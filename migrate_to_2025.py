#!/usr/bin/env python3
"""
Migration script for DNSfookup from 2019 version to 2025 version
This script helps migrate existing data and configuration
"""

import os
import sys
import yaml
import json
import subprocess
from pathlib import Path

def check_python_version():
    """Check if Python version is 3.9 or higher"""
    if sys.version_info < (3, 9):
        print("❌ Python 3.9 or higher is required")
        print(f"Current version: {sys.version}")
        return False
    print(f"✅ Python version: {sys.version}")
    return True

def check_node_version():
    """Check if Node.js version is 18 or higher"""
    try:
        result = subprocess.run(['node', '--version'], capture_output=True, text=True)
        version = result.stdout.strip().replace('v', '')
        major_version = int(version.split('.')[0])
        
        if major_version < 18:
            print(f"❌ Node.js 18 or higher is required. Current: {version}")
            return False
        print(f"✅ Node.js version: {version}")
        return True
    except Exception as e:
        print(f"❌ Node.js not found: {e}")
        return False

def backup_config():
    """Backup existing configuration"""
    config_path = Path("config.yaml")
    if config_path.exists():
        backup_path = Path("config.yaml.backup.2025")
        config_path.rename(backup_path)
        print(f"✅ Backed up config to {backup_path}")
        return backup_path
    return None

def migrate_config(backup_path):
    """Migrate configuration to new format"""
    if not backup_path or not backup_path.exists():
        print("❌ No backup config found")
        return False
    
    with open(backup_path, 'r') as f:
        old_config = yaml.safe_load(f)
    
    # The config structure is already compatible, just copy it back
    with open("config.yaml", 'w') as f:
        yaml.dump(old_config, f, default_flow_style=False)
    
    print("✅ Configuration migrated")
    return True

def update_backend_dependencies():
    """Update backend dependencies"""
    print("📦 Updating backend dependencies...")
    os.chdir("BE")
    
    try:
        # Create virtual environment if it doesn't exist
        if not os.path.exists("venv"):
            subprocess.run([sys.executable, "-m", "venv", "venv"], check=True)
            print("✅ Created virtual environment")
        
        # Activate virtual environment and install dependencies
        if os.name == 'nt':  # Windows
            pip_path = "venv\\Scripts\\pip"
        else:  # Unix-like
            pip_path = "venv/bin/pip"
        
        subprocess.run([pip_path, "install", "--upgrade", "pip"], check=True)
        subprocess.run([pip_path, "install", "-r", "requirements.txt"], check=True)
        print("✅ Backend dependencies updated")
        return True
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to update backend dependencies: {e}")
        return False
    finally:
        os.chdir("..")

def update_frontend_dependencies():
    """Update frontend dependencies"""
    print("📦 Updating frontend dependencies...")
    os.chdir("FE")
    
    try:
        # Remove old node_modules and package-lock.json
        if os.path.exists("node_modules"):
            import shutil
            shutil.rmtree("node_modules")
        if os.path.exists("package-lock.json"):
            os.remove("package-lock.json")
        
        # Install new dependencies
        subprocess.run(["npm", "install"], check=True)
        print("✅ Frontend dependencies updated")
        return True
    except subprocess.CalledProcessError as e:
        print(f"❌ Failed to update frontend dependencies: {e}")
        return False
    finally:
        os.chdir("..")

def check_docker():
    """Check if Docker and Docker Compose are available"""
    try:
        subprocess.run(["docker", "--version"], capture_output=True, check=True)
        subprocess.run(["docker-compose", "--version"], capture_output=True, check=True)
        print("✅ Docker and Docker Compose are available")
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("❌ Docker or Docker Compose not found")
        return False

def main():
    print("🚀 DNSfookup Migration to 2025")
    print("=" * 40)
    
    # Check prerequisites
    checks = [
        check_python_version(),
        check_node_version(),
        check_docker()
    ]
    
    if not all(checks):
        print("\n❌ Prerequisites not met. Please install missing components.")
        sys.exit(1)
    
    print("\n📋 Starting migration...")
    
    # Backup and migrate config
    backup_path = backup_config()
    if not migrate_config(backup_path):
        print("❌ Config migration failed")
        sys.exit(1)
    
    # Update dependencies
    if not update_backend_dependencies():
        print("❌ Backend update failed")
        sys.exit(1)
    
    if not update_frontend_dependencies():
        print("❌ Frontend update failed")
        sys.exit(1)
    
    print("\n🎉 Migration completed successfully!")
    print("\nNext steps:")
    print("1. Review and update config.yaml with your settings")
    print("2. Start services: docker-compose up -d")
    print("3. Initialize database: cd BE && python -c 'from app import app, db; app.app_context().push(); db.create_all()'")
    print("4. Start DNS server: cd BE && python dns.py")
    print("5. Start API server: cd BE && flask run")
    print("6. Start frontend: cd FE && npm start")
    print("\nSee INSTALL_2025.md for detailed instructions.")

if __name__ == "__main__":
    main()
