#!/bin/bash
# Permanent URL: https://github.com/ravitejachillara/pixerio/raw/main/pixsol-install.sh

set -euo pipefail

# Configuration
INSTALL_DIR="/opt/pixsol"
SECURE_PREFIX="pixsol-$(openssl rand -hex 3)"

# Install Docker if missing
install_docker() {
    if ! command -v docker &>/dev/null; then
        echo "🔧 Installing Docker..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker $USER
        newgrp docker
    fi

    if ! command -v docker-compose &>/dev/null; then
        echo "🔧 Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
}

# Generate secure compose file
generate_config() {
    cat <<EOL > docker-compose.yml
version: '3.8'

services:
  ${SECURE_PREFIX}-reverse-proxy:
    image: traefik:v2.10
    command:
      - --providers.docker
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=admin@pixerio.in
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - letsencrypt:/letsencrypt
    restart: always

  ${SECURE_PREFIX}-wordpress:
    image: wordpress:6.5-php8.3-apache
    environment:
      WORDPRESS_DB_HOST: ${SECURE_PREFIX}-database
      WORDPRESS_DB_USER: pixsoladmin
      WORDPRESS_DB_PASSWORD: $(openssl rand -base64 24)
    labels:
      - "traefik.http.routers.wp.rule=Host(\`at.pixerio.in\`)"
      - "traefik.http.routers.wp.tls.certresolver=le"
    restart: always

  ${SECURE_PREFIX}-mautic:
    image: mautic/mautic:4.4
    environment:
      MAUTIC_DB_HOST: ${SECURE_PREFIX}-database
      MAUTIC_DB_USER: pixsoladmin
      MAUTIC_DB_PASSWORD: $(openssl rand -base64 24)
    labels:
      - "traefik.http.routers.mtc.rule=Host(\`mautic.pixerio.in\`)"
      - "traefik.http.routers.mtc.tls.certresolver=le"
    restart: always

  ${SECURE_PREFIX}-n8n:
    image: n8nio/n8n:1.24
    labels:
      - "traefik.http.routers.n8n.rule=Host(\`n8n.pixerio.in\`)"
      - "traefik.http.routers.n8n.tls.certresolver=le"
    restart: always

  ${SECURE_PREFIX}-database:
    image: mariadb:11.0
    environment:
      MYSQL_ROOT_PASSWORD: $(openssl rand -base64 48)
    volumes:
      - db_data:/var/lib/mysql
    restart: always

volumes:
  db_data:
  letsencrypt:
EOL
}

# Main installation
main() {
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
    install_docker
    generate_config
    docker-compose up -d
    
    echo -e "\n✅ Installation Complete!"
    echo -e "Access URLs:"
    echo -e "- WordPress: https://at.pixerio.in"
    echo -e "- Mautic: https://mautic.pixerio.in"
    echo -e "- n8n: https://n8n.pixerio.in"
    echo -e "\n🔑 Passwords stored in: ${INSTALL_DIR}/docker-compose.yml"
}

# Run with error handling
trap 'echo "🆘 Error occurred - contact support@pixerio.in" && exit 1' ERR
main
