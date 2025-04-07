#!/bin/bash

# Update system
apt update && apt upgrade -y

# Create user for n8n
useradd -m -s /bin/bash n8nuser
usermod -aG sudo n8nuser

# Install dependencies
apt install -y curl nginx certbot python3-certbot-nginx build-essential

# Install Node.js 20.x (the one n8n needs)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Install pm2 globally
npm install -g pm2

# Switch to n8nuser and install n8n
sudo -i -u n8nuser bash << EOF
cd ~
npm install n8n -g
pm2 start n8n --name n8n -- start
pm2 save
EOF

# Setup pm2 startup for systemd
env PATH=$PATH:/usr/bin /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u n8nuser --hp /home/n8nuser

# Configure NGINX reverse proxy to n8n running on port 5678
cat << 'EOL' > /etc/nginx/sites-available/n8n
server {
    listen 80;
    server_name your.server.ip.here;

    location / {
        proxy_pass http://localhost:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
rm /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# Setup SSL with certbot (if domain is used)
# certbot --nginx -d your.domain.com

echo "✅ n8n installed and running via pm2 + reverse proxied via NGINX"
echo "Visit http://your.server.ip.here or use certbot to add SSL"
