#!/bin/bash
# n8n-only installer for Ubuntu 24.04
# Run as root

# Check root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Configuration
DOMAIN="n8n.pixerio.in"
EMAIL="rajeshvyas71@gmail.com"
CRED_FILE="/root/n8n_credentials.txt"
DB_USER="pixsoladmin"
DB_PASS=$(openssl rand -hex 16)
N8N_PORT=5678

# Verify ports 80/443/5678
echo "Checking port availability..."
for port in 80 443 $N8N_PORT; do
  if ss -tuln | grep -q ":${port} "; then
    echo "ERROR: Port ${port} already in use!"
    exit 1
  fi
done

# System setup
apt update && apt upgrade -y
apt install -y curl npm nginx certbot python3-certbot-nginx postgresql postgresql-contrib

# Install Node.js 20.x
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# PostgreSQL Configuration
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

# Generate credentials
ADMIN_PASS=$(openssl rand -hex 12)
ENC_KEY=$(openssl rand -base64 24)

# Systemd Service
cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=n8n Service
After=network.target postgresql.service

[Service]
User=root
Environment=N8N_BASIC_AUTH_ACTIVE=true
Environment=N8N_BASIC_AUTH_USER=admin
Environment=N8N_BASIC_AUTH_PASSWORD=${ADMIN_PASS}
Environment=N8N_ENCRYPTION_KEY=${ENC_KEY}
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

# Nginx Configuration
cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

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

# Enable site
ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# SSL Certificate
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m ${EMAIL}
sed -i '/server_names_hash_bucket_size/s/^#//g' /etc/nginx/nginx.conf

# Finalize
systemctl daemon-reload
systemctl enable n8n postgresql nginx
systemctl restart n8n postgresql nginx

# Firewall
ufw allow OpenSSH
ufw allow 'Nginx Full'
echo "y" | ufw enable

# Save credentials
cat > ${CRED_FILE} <<EOF
=== n8n Credentials ===
URL: https://${DOMAIN}
Username: admin
Password: ${ADMIN_PASS}
Database User: ${DB_USER}
Database Password: ${DB_PASS}
Encryption Key: ${ENC_KEY}

=== Important Notes ===
1. Store encryption key securely - required for data recovery
2. Database backups located at: /var/lib/postgresql/16/main/n8n_db
3. n8n data directory: /root/.n8n
EOF

chmod 600 ${CRED_FILE}

echo "Installation Complete!"
echo "Credentials saved to: ${CRED_FILE}"
echo "Access URL: https://${DOMAIN}"
