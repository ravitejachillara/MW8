#!/bin/bash

set -e

DOMAIN="n8n.pixerio.in"  # change this to your actual domain
EMAIL="rajeshvyas71@gmail.com"      # email for Let's Encrypt

echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

echo "Installing Node.js (LTS)..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs build-essential

echo "Installing PM2 for process management..."
sudo npm install pm2@latest -g

echo "Installing NGINX..."
sudo apt install nginx -y

echo "Installing Certbot for SSL..."
sudo apt install certbot python3-certbot-nginx -y

echo "Creating n8n user..."
sudo adduser --disabled-password --gecos "" n8nuser || true

echo "Switching to n8n user and installing n8n..."
sudo -u n8nuser bash << EOF
cd ~
npm install n8n -g
EOF

echo "Creating PM2 service for n8n..."
sudo -u n8nuser bash << EOF
pm2 start n8n --name n8n -- start
pm2 startup systemd -u n8nuser --hp /home/n8nuser
pm2 save
EOF

echo "Setting up NGINX reverse proxy..."
sudo tee /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
sudo nginx -t && sudo systemctl reload nginx

echo "Obtaining SSL Certificate for $DOMAIN..."
sudo certbot --nginx --non-interactive --agree-tos --redirect -d $DOMAIN -m $EMAIL

echo "✅ Done! n8n should now be live at https://$DOMAIN"
