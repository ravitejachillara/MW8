#!/bin/bash
# Combined n8n + LangFlow installer for Ubuntu 24.04
# Run as root

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Configuration
N8N_DOMAIN="n8n.pixerio.in"
LANGF_DOMAIN="flow.pixerio.in"
EMAIL="rajeshvyas71@gmail.com"
CRED_FILE="/root/n8n-langflow-creds.txt"
DB_USER="pixsoladmin"
DB_PASS=$(openssl rand -hex 16)
LANGF_PORT=7860
N8N_PORT=5678

# Check port conflicts
echo "Checking port availability..."
for port in 80 443 $N8N_PORT $LANGF_PORT; do
  if ss -tuln | grep -q ":${port} "; then
    echo "ERROR: Port ${port} already in use!"
    exit 1
  fi
done

# Install system dependencies
apt update && apt upgrade -y
apt install -y curl npm nginx certbot python3-certbot-nginx \
              postgresql postgresql-contrib python3.12-venv

# Install Node.js 20.x
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Configure PostgreSQL
sudo -u postgres psql <<EOF
CREATE DATABASE n8n_db;
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
ALTER ROLE ${DB_USER} SET client_encoding TO 'utf8';
ALTER ROLE ${DB_USER} SET default_transaction_isolation TO 'read committed';
GRANT ALL PRIVILEGES ON DATABASE n8n_db TO ${DB_USER};
EOF

# Install n8n
N8N_VERSION="1.78.1"
npm install -g n8n@${N8N_VERSION}

# n8n Systemd Service
N8N_ADMIN_PASS=$(openssl rand -hex 12)
N8N_ENC_KEY=$(openssl rand -base64 24)

cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=n8n Service
After=network.target postgresql.service

[Service]
User=root
Environment=N8N_BASIC_AUTH_ACTIVE=true
Environment=N8N_BASIC_AUTH_USER=admin
Environment=N8N_BASIC_AUTH_PASSWORD=${N8N_ADMIN_PASS}
Environment=N8N_ENCRYPTION_KEY=${N8N_ENC_KEY}
Environment=N8N_PORT=${N8N_PORT}
Environment=DB_TYPE=postgresdb
Environment=DB_POSTGRESDB_DATABASE=n8n_db
Environment=DB_POSTGRESDB_USER=${DB_USER}
Environment=DB_POSTGRESDB_PASSWORD=${DB_PASS}
ExecStart=/usr/bin/n8n start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Install LangFlow
python3 -m venv /opt/langflow
source /opt/langflow/bin/activate
pip install langflow
deactivate

# LangFlow Systemd Service
cat > /etc/systemd/system/langflow.service <<EOF
[Unit]
Description=LangFlow Service
After=network.target

[Service]
User=root
WorkingDirectory=/opt/langflow
Environment="PATH=/opt/langflow/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/langflow/bin/langflow run --port ${LANGF_PORT} --host 127.0.0.1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Configure Nginx
certbot_install() {
  certbot --nginx -d $1 --non-interactive --agree-tos -m $EMAIL
  sed -i '/server_names_hash_bucket_size/s/^#//g' /etc/nginx/nginx.conf
}

# n8n Nginx Config
cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${N8N_DOMAIN};

    location / {
        proxy_pass http://localhost:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# LangFlow Nginx Config
cat > /etc/nginx/sites-available/langflow <<EOF
server {
    listen 80;
    server_name ${LANGF_DOMAIN};

    location / {
        proxy_pass http://localhost:${LANGF_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# Enable sites
ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
ln -s /etc/nginx/sites-available/langflow /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# Get SSL certificates
certbot_install ${N8N_DOMAIN}
certbot_install ${LANGF_DOMAIN}

# Enable services
systemctl daemon-reload
systemctl enable n8n langflow postgresql
systemctl restart n8n langflow postgresql nginx

# Configure firewall
ufw allow OpenSSH
ufw allow 'Nginx Full'
echo "y" | ufw enable

# Save credentials
cat > ${CRED_FILE} <<EOF
=== n8n Credentials ===
URL: https://${N8N_DOMAIN}
Username: admin
Password: ${N8N_ADMIN_PASS}
DB User: ${DB_USER}
DB Password: ${DB_PASS}
Encryption Key: ${N8N_ENC_KEY}

=== LangFlow Credentials ===
URL: https://${LANGF_DOMAIN}
No authentication by default - secure with:
1. Nginx basic auth
2. LangFlow's --password flag
EOF

chmod 600 ${CRED_FILE}

echo "Installation Complete!"
echo "Credentials saved to: ${CRED_FILE}"
echo -e "\nAccess URLs:"
echo "- n8n: https://${N8N_DOMAIN}"
echo "- LangFlow: https://${LANGF_DOMAIN}"
