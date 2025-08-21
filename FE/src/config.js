// Configuration file for DNSfookup frontend
const config = {
  development: {
    API_URL: 'http://localhost:5000',
    REBIND_DOMAIN: 'gel0.space'
  },
  production: {
    API_URL: 'https://your-domain.com',
    REBIND_DOMAIN: 'gel0.space'
  }
};

const currentEnv = process.env.NODE_ENV || 'development';

export default config[currentEnv];
