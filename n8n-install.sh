#!/bin/bash

# N8N Installation Script for KVM Server
# Configuration: 4 CPU, 16GB RAM, 200GB HDD
# Domain: n8n.pixerio.in
# SSL Email: rajeshvyas71@gmail.com
# DB Username: pixsoln8n

# Exit on error
set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Function to generate a random password
generate_password() {
    # Generate a secure 16-character password with letters, numbers, and symbols
    password=$(tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[\]^_{}~' < /dev/urandom | head -c 16)
    echo "$password"
}

# Main installation function
install_n8n() {
    print_message "Starting n8n installation process"
    
    # Save all configuration variables
    DOMAIN="n8n.pixerio.in"
    SSL_EMAIL="rajeshvyas71@gmail.com"
    DB_USER="pixsoln8n" 
    DB_PASSWORD=$(generate_password)
    DB_NAME="n8n"
    N8N_PORT="5678"
    
    # Save passwords to a secure file
    print_message "Saving credentials to /root/.n8n_credentials"
    cat > /root/.n8n_credentials << EOL
N8N Installation Credentials
==========================
Domain: $DOMAIN
Database User: $DB_USER
Database Password: $DB_PASSWORD
Database Name: $DB_NAME
==========================
Created on: $(date)
EOL
    chmod 600 /root/.n8n_credentials
    
    # Update system
    print_message "Updating system packages"
    apt-get update
    apt-get upgrade -y
    
    # Install dependencies
    print_message "Installing dependencies"
    apt-get install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common

    # Install Node.js (using NodeSource)
    print_message "Installing Node.js"
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
    
    # Check Node.js and NPM versions
    node -v
    npm -v
    
    # Install PostgreSQL
    print_message "Installing PostgreSQL"
    apt-get install -y postgresql postgresql-contrib
    
    # Configure PostgreSQL for n8n
    print_message "Configuring PostgreSQL database"
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"
    sudo -u postgres psql -c "ALTER USER $DB_USER WITH SUPERUSER;"
    
    # Install Nginx
    print_message "Installing Nginx"
    apt-get install -y nginx

    # Install Certbot for SSL
    print_message "Installing Certbot for SSL"
    apt-get install -y certbot python3-certbot-nginx
    
    # Configure Nginx
    print_message "Configuring Nginx for n8n"
    cat > /etc/nginx/sites-available/$DOMAIN << EOL
server {
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:$N8N_PORT;
        proxy_set_header Connection '';
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        chunked_transfer_encoding on;
    }

    # For websocket support
    location /sockjs-node {
        proxy_pass http://localhost:$N8N_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOL

    # Enable the site
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    
    # Test Nginx configuration and restart
    nginx -t
    systemctl restart nginx
    
    # Allow Nginx through firewall
    if command -v ufw &> /dev/null; then
        print_message "Configuring firewall"
        ufw allow 'Nginx Full'
        ufw allow ssh
        ufw --force enable
    fi
    
    # Install SSL certificate
    print_message "Obtaining SSL certificate"
    certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $SSL_EMAIL --redirect
    
    # Install n8n globally
    print_message "Installing n8n"
    npm install -g n8n
    
    # Create n8n systemd service
    print_message "Creating n8n service"
    cat > /etc/systemd/system/n8n.service << EOL
[Unit]
Description=n8n process automation
After=network.target postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/.n8n
Environment=NODE_ENV=production
Environment=N8N_PROTOCOL=https
Environment=N8N_HOST=$DOMAIN
Environment=N8N_PORT=$N8N_PORT
Environment=NODE_FUNCTION_ALLOW_EXTERNAL=moment,lodash
Environment=N8N_ENCRYPTION_KEY=$(openssl rand -hex 24)
Environment=WEBHOOK_URL=https://$DOMAIN/
Environment=DB_TYPE=postgresdb
Environment=DB_POSTGRESDB_HOST=localhost
Environment=DB_POSTGRESDB_PORT=5432
Environment=DB_POSTGRESDB_DATABASE=$DB_NAME
Environment=DB_POSTGRESDB_USER=$DB_USER
Environment=DB_POSTGRESDB_PASSWORD=$DB_PASSWORD
Environment=DB_POSTGRESDB_SCHEMA=public
Environment=N8N_EMAIL_MODE=smtp
ExecStart=/usr/bin/node /usr/bin/n8n start
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL

    # Create n8n config directory
    mkdir -p /root/.n8n
    
    # Enable and start the service
    print_message "Starting n8n service"
    systemctl daemon-reload
    systemctl enable n8n
    systemctl start n8n
    
    # Set up auto-renewal for SSL certificate
    print_message "Setting up SSL auto-renewal"
    echo "0 3 * * * /usr/bin/certbot renew --quiet" | crontab -
    
    # Final message
    print_message "Installation completed successfully!"
    print_message "n8n is now accessible at: https://$DOMAIN"
    print_message "Credentials are stored in: /root/.n8n_credentials"
    print_message "Database Username: $DB_USER"
    print_message "Database Password: $DB_PASSWORD"
}

# Execute the installation
install_n8n
