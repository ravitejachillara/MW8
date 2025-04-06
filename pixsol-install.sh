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
    
    # General Ubuntu check
    . /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        echo "Error: Requires Ubuntu. Detected: $PRETTY_NAME"
        exit 1
    fi

    # RAM Check (4GB minimum)
    local RAM=$(free -m | awk '/Mem:/ {print $2}')
    (( RAM < 4096 )) && { echo "Error: Minimum 4GB RAM required. Detected: ${RAM}MB"; exit 1; }

    # Disk Check (20GB minimum)
    local DISK=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    (( DISK < 20 )) && { echo "Error: Minimum 20GB disk space required. Detected: ${DISK}GB"; exit 1; }

    # CPU Check (2 cores minimum)
    local CPU=$(nproc)
    (( CPU < 2 )) && { echo "Error: Minimum 2 CPU cores required. Detected: $CPU cores"; exit 1; }
}

clean_previous() {
    echo "Cleaning previous installations..."
    docker compose -f /opt/appstack/docker-compose.yml down --volumes --rmi all 2>/dev/null || true
    rm -rf /opt/appstack
}

install_docker() {
    echo "Installing Docker components..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    
    # Add Docker repo
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker

    # Install Docker Compose Plugin
    apt-get install -y docker-compose-plugin
}

configure_firewall() {
    echo "Configuring firewall..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
}

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
    cd /opt/appstack

    # Generate secure passwords
    MYSQL_ROOT_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n1)
    WP_DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n1)
    MAUTIC_DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n1)
    N8N_DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n1)

    # SQL Initialization
    cat > init.sql <<EOF
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

    # Docker Compose
    cat > docker-compose.yml <<EOF
version: '3.8'

services:
  reverse-proxy:
    image: traefik:v2.10
    restart: unless-stopped
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
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASS}
    volumes:
      - mysql_data:/var/lib/mysql
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - proxy

  wordpress:
    image: wordpress:latest
    restart: unless-stopped
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
    restart: unless-stopped
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

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    environment:
      DB_TYPE: mysql
      DB_MYSQLDB_HOST: mysql
      DB_MYSQLDB_USER: n8n
      DB_MYSQLDB_PASSWORD: ${N8N_DB_PASS}
      DB_MYSQLDB_DATABASE: n8n
      N8N_HOST: ${N8N_SUBDOMAIN}
      N8N_PROTOCOL: https
      N8N_WEBHOOK_URL: https://${N8N_SUBDOMAIN}/
      VUE_APP_URL_BASE_API: https://${N8N_SUBDOMAIN}/
    depends_on:
      mysql:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_SUBDOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"
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

start_services() {
    echo "Starting application stack..."
    cd /opt/appstack
    docker compose up -d

    # Wait for n8n initialization
    echo "Waiting for services to stabilize..."
    sleep 30
    docker compose logs n8n --tail=50
}

show_credentials() {
    echo
    echo "========== DEPLOYMENT COMPLETE =========="
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
    echo "==========================================="
}

# Execution Flow
check_system
clean_previous
install_docker
configure_firewall
get_user_input
generate_compose
start_services
show_credentials
