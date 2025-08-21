from flask import Flask
from flask_restful import Api
from flask_sqlalchemy import SQLAlchemy
from flask_jwt_extended import JWTManager
from flask_cors import CORS
import yaml
import os

app = Flask(__name__)
api = Api(app)
cors = CORS(app, resources={r"/*": {"origins": "*"}})

"""
*** CONFIG ***
"""

# Load config with proper path handling
config_path = os.path.join(os.path.dirname(__file__), "..", "config.yaml")
with open(config_path, 'r') as config_file:
    config = yaml.safe_load(config_file)

db_conf = config['sql']

app.config['SQLALCHEMY_DATABASE_URI'] = f"\
{db_conf['protocol']}://\
{db_conf['user']}:{db_conf['password']}\
@{db_conf['host']}\
/{db_conf['db']}\
"

app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = db_conf['deprec_warn'] # silence the deprecation warning

db = SQLAlchemy(app)

# Initialize database tables using the new Flask 2.2+ pattern
def create_tables():
    with app.app_context():
        db.create_all()

# Call create_tables after all models are imported
@app.before_request
def initialize_database():
    if not hasattr(app, '_database_initialized'):
        create_tables()
        app._database_initialized = True

app.config['JWT_SECRET_KEY'] = config['jwt']['secret_key']
jwt = JWTManager(app)

app.config['JWT_BLACKLIST_ENABLED'] = config['jwt']['blacklist_enabled']
app.config['JWT_BLACKLIST_TOKEN_CHECKS'] = config['jwt']['blacklist_token_checks']
app.config['JWT_ACCESS_TOKEN_EXPIRES'] = config['jwt']['token_expires']

"""
*** CONFIG ***
"""

# Updated for Flask-JWT-Extended 4.x
@jwt.token_in_blocklist_loader
def check_if_token_revoked(jwt_header, jwt_payload):
    jti = jwt_payload['jti']
    return models.RevokedTokenModel.is_jti_blacklisted(jti)

import models, resources, dns_resources

api.add_resource(resources.UserRegistration, '/auth/signup')
api.add_resource(resources.UserLogin, '/auth/login')
api.add_resource(resources.UserLogoutAccess, '/auth/logout')
api.add_resource(resources.ChangePw, '/auth/change_pw')

api.add_resource(dns_resources.iDontWannaBeAnymore, '/auth/delete_me')

api.add_resource(dns_resources.CreateRebindToken, '/api/fookup/new')
api.add_resource(dns_resources.DeleteUUID, '/api/fookup/delete')

api.add_resource(resources.UserName, '/api/user')
api.add_resource(dns_resources.GetUserTokens, '/api/fookup/listAll')
api.add_resource(dns_resources.GetProps, '/api/fookup/props')
api.add_resource(dns_resources.GetUserLogs, '/api/fookup/logs/all')
api.add_resource(dns_resources.GetUuidLogs, '/api/fookup/logs/uuid')
api.add_resource(dns_resources.GetStatistics, '/api/statistics')
