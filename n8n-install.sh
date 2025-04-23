#!/bin/bash

set -e

DOMAIN="n8n.pixerio.in"
EMAIL="rajeshvyas71@gmail.com"
N8N_PORT=5678

echo "Updating system..."
apt update && apt upgrade -y

echo "Installing Docker, Docker Compose, and dependencies..."
apt install -y docker.io docker-compose ufw fail2ban nginx certbot python3-certbot-nginx curl gnupg2 ca-certificates lsb-release software-properties-common

echo "Creating Docker network..."
docker network create n8n-network || true

echo "Creating directories for persistent data..."
mkdir -p /opt/n8n/.n8n
chown -R 1000:1000 /opt/n8n/.n8n

echo "Creating Docker Compose file..."
cat <<EOF > /opt/n8n/docker-compose.yml
version: "3.7"
services:
  n8n:
    image: n8nio/n8n
    restart: always
    ports:
      - "${N8N_PORT}:5678"
    environment:
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - WEBHOOK_TUNNEL_URL=https://${DOMAIN}
      - N8N_PROTOCOL=https
      - TZ=Asia/Kolkata
    volumes:
      - /opt/n8n/.n8n:/home/node/.n8n
    networks:
      - n8n-network
networks:
  n8n-network:
    external: true
EOF

echo "Starting n8n container..."
cd /opt/n8n
docker-compose up -d

echo "Configuring Nginx..."
cat <<EOF > /etc/nginx/sites-available/n8n
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://localhost:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "Installing SSL certificate with Let's Encrypt..."
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m ${EMAIL}

echo "Setting up firewall rules..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo "Configuring Fail2Ban..."
cat <<EOF > /etc/fail2ban/jail.d/ssh.conf
[sshd]
enabled = true
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "All set! n8n is now live at https://${DOMAIN}"

echo "To view logs: cd /opt/n8n && docker-compose logs -f"
