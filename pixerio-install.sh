#!/bin/bash
set -eo pipefail
# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root or using sudo."
    exit 1
fi

# System Requirements Check
check_system() {
    echo "Performing system checks..."
    
    # OS Check (General Ubuntu)
    . /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        echo "Error: Requires Ubuntu. Detected: $PRETTY_NAME"
        exit 1
    fi

    # RAM Check (4GB minimum)
    local RAM=$(free -m | awk '/Mem:/ {print $2}')
    if [ $RAM -lt 4096 ]; then
        echo "Error: Minimum 4GB RAM required. Detected: ${RAM}MB"
        exit 1
    fi

    # Disk Check (20GB minimum)
    local DISK=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ $DISK -lt 20 ]; then
        echo "Error: Minimum 20GB disk space required. Detected: ${DISK}GB"
        exit 1
    fi

    # CPU Check (2 cores minimum)
    local CPU=$(nproc)
    if [ $CPU -lt 2 ]; then
        echo "Error: Minimum 2 CPU cores required. Detected: $CPU cores"
        exit 1
    fi
}

# Install Docker and Docker Compose
install_docker() {
    echo "Installing Docker components..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    
    # Add Docker repository
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable docker
    systemctl start docker

    # Install Docker Compose
    DOCKER_COMPOSE_VERSION="v2.23.0"
    curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
}

# Configure Firewall
configure_firewall() {
    echo "Configuring firewall..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
}

# User Input Prompts
get_user_input() {
    echo
    read -p "Enter your email for SSL certificates: " SSL_EMAIL
    echo
    
    read -p "Enter WordPress subdomain (e.g., wp.example.com): " WP_SUBDOMAIN
    read -p "Enter Mautic subdomain (e.g., mautic.example.com): " MAUTIC_SUBDOMAIN
    read -p "Enter n8n subdomain (e.g., n8n.example.com): " N8N_SUBDOMAIN

    echo
    read -p "Enter WordPress admin username: " WP_USER
    read -s -p "Enter WordPress admin password: " WP_PASS
    echo
    
    read -p "Enter Mautic admin username: " MAUTIC_USER
    read -s -p "Enter Mautic admin password: " MAUTIC_PASS
    echo
    
    read -p "Enter n8n admin username: " N8N_USER
    read -s -p "Enter n8n admin password: " N8N_PASS
    echo
}

generate_compose() {
    echo "Generating Docker configuration..."
    mkdir -p /opt/appstack

    # Generate UNIQUE passwords for each service
    MYSQL_ROOT_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    WP_DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    MAUTIC_DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    N8N_DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
    
    # Create initialization SQL
    cat > /opt/appstack/init.sql <<EOF
CREATE DATABASE IF NOT EXISTS wordpress;
CREATE DATABASE IF NOT EXISTS mautic;
CREATE DATABASE IF NOT EXISTS n8n;

CREATE USER 'wordpress'@'%' IDENTIFIED BY '${WP_DB_PASS}';
CREATE USER 'mautic'@'%' IDENTIFIED BY '${MAUTIC_DB_PASS}';
CREATE USER 'n8n'@'%' IDENTIFIED BY '${N8N_DB_PASS}';

GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'%';
GRANT ALL PRIVILEGES ON mautic.* TO 'mautic'@'%';
GRANT ALL PRIVILEGES ON n8n.* TO 'n8n'@'%';

FLUSH PRIVILEGES;
EOF

    # Modified Docker Compose without n8n
    cat > /opt/appstack/docker-compose.yml <<EOF
version: '3.8'

services:
  reverse-proxy:
    image: traefik:v2.10
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.le.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.le.acme.storage=/certs/acme.json"
      - "--certificatesresolvers.le.acme.httpchallenge=true"
      - "--certificatesresolvers.le.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "traefik_certs:/certs"
    networks:
      - proxy

  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
    volumes:
      - mysql_data:/var/lib/mysql
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 10s
      retries: 10
    networks:
      - proxy

  wordpress:
    image: wordpress:latest
    environment:
      WORDPRESS_DB_HOST: mysql
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: ${WP_DB_PASS}
      WORDPRESS_DB_NAME: wordpress
    depends_on:
      mysql:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wp.rule=Host(\`${WP_SUBDOMAIN}\`)"
      - "traefik.http.routers.wp.entrypoints=websecure"
      - "traefik.http.routers.wp.tls.certresolver=le"
    networks:
      - proxy

  mautic:
    image: mautic/mautic:latest
    environment:
      MAUTIC_DB_HOST: mysql
      MAUTIC_DB_USER: mautic
      MAUTIC_DB_PASSWORD: ${MAUTIC_DB_PASS}
      MAUTIC_DB_NAME: mautic
    depends_on:
      mysql:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mautic.rule=Host(\`${MAUTIC_SUBDOMAIN}\`)"
      - "traefik.http.routers.mautic.entrypoints=websecure"
      - "traefik.http.routers.mautic.tls.certresolver=le"
    networks:
      - proxy

volumes:
  mysql_data:
  traefik_certs:

networks:
  proxy:
    driver: bridge
EOF
}

install_n8n() {
    echo "Installing n8n directly via Node.js..."
    
    # Install Node.js
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    apt-get install -y nodejs build-essential
    
    # Install PM2 process manager
    npm install pm2 -g

    # Create n8n user
    useradd --system --home /opt/n8n --create-home n8n

    # Install n8n
    sudo -u n8n bash <<EOF
    cd /opt/n8n
    npm install n8n
EOF

    # Create systemd service
    cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=n8n Service
After=network.target mysql.service

[Service]
User=n8n
Group=n8n
Environment=DB_TYPE=mysql
Environment=DB_MYSQLDB_HOST=localhost
Environment=DB_MYSQLDB_USER=n8n
Environment=DB_MYSQLDB_PASSWORD=${N8N_DB_PASS}
Environment=DB_MYSQLDB_DATABASE=n8n
Environment=N8N_HOST=${N8N_SUBDOMAIN}
Environment=N8N_PROTOCOL=https
Environment=N8N_WEBHOOK_URL=https://${N8N_SUBDOMAIN}/
ExecStart=/usr/bin/pm2 start /opt/n8n/node_modules/n8n/bin/n8n -- start
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start service
    systemctl daemon-reload
    systemctl enable n8n
    systemctl start n8n

    # Add Traefik configuration
    cat >> /opt/appstack/docker-compose.yml <<EOF

  n8n-proxy:
    image: traefik:v2.10
    command:
      - "--providers.file.directory=/etc/traefik/"
      - "--providers.file.watch=true"
    volumes:
      - ./n8n.yml:/etc/traefik/n8n.yml
    ports:
      - "5678:80"
    networks:
      - proxy
EOF

    # Create Traefik configuration
    cat > /opt/appstack/n8n.yml <<EOF
http:
  routers:
    n8n:
      entryPoints:
        - "web"
      rule: "Host(\`${N8N_SUBDOMAIN}\`)"
      service: "n8n"
  
  services:
    n8n:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:5678/"
EOF
}

# Modify start_services
start_services() {
    echo "Starting Docker services..."
    cd /opt/appstack || exit 1
    docker-compose up -d
    
    echo "Waiting for MySQL to initialize..."
    sleep 30
    
    echo "Starting n8n service..."
    systemctl restart n8n
}

# Modify show_credentials
show_credentials() {
    echo
    echo "========== DEPLOYMENT SUCCESSFUL =========="
    echo 
    echo "Access URLs:"
    echo "WordPress: https://${WP_SUBDOMAIN}"
    echo "Mautic:    https://${MAUTIC_SUBDOMAIN}"
    echo "n8n:       https://${N8N_SUBDOMAIN}"
    echo
    echo "Credentials:"
    echo "WordPress Admin: ${WP_USER} / ${WP_PASS}"
    echo "Mautic Admin:    ${MAUTIC_USER} / ${MAUTIC_PASS}"
    echo "n8n Access:      ${N8N_USER} / ${N8N_PASS}"
    echo
    echo "Database Root Password: ${MYSQL_ROOT_PASS}"
    echo
    echo "==========================================="
}

# Updated main execution
check_system
install_docker
configure_firewall
get_user_input
generate_compose
install_n8n
start_services
show_credentials
