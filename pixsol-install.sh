#!/bin/bash
# Self-updating script URL: https://github.com/ravitejachillara/pixerio/raw/main/pixsol-install.sh

set -euo pipefail

# Configuration
GITHUB_RAW_URL="https://github.com/ravitejachillara/pixerio/raw/main/pixsol-install.sh"
INSTALL_DIR="/opt/pixsol"
SECURE_PREFIX="pixsol-$(openssl rand -hex 3)"

# Self-update mechanism
self_update() {
    echo "🔄 Checking for updates..."
    TEMP_FILE=$(mktemp)
    if curl -fsSL "$GITHUB_RAW_URL" -o "$TEMP_FILE"; then
        if ! diff "$0" "$TEMP_FILE" >/dev/null; then
            echo "🔁 New version found - updating..."
            chmod +x "$TEMP_FILE"
            mv "$TEMP_FILE" "$0"
            exec "$0" "$@"
        fi
    fi
}

# Dependency installer
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

# Security-hardened Docker setup
generate_compose() {
    cat <<EOL > docker-compose.yml
version: '3.8'

services:
  ${SECURE_PREFIX}-reverse-proxy:
    image: traefik:v2.10 --platform linux/amd64
    command:
      - --providers.docker
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=admin@pixerio.in
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
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
      WORDPRESS_DB_USER: pixsoladmin-wp
      WORDPRESS_DB_PASSWORD: $(openssl rand -base64 24)
    labels:
      - "traefik.http.routers.${SECURE_PREFIX}-wp.rule=Host(\`at.pixerio.in\`)"
      - "traefik.http.routers.${SECURE_PREFIX}-wp.tls.certresolver=le"
    restart: always
    depends_on:
      - ${SECURE_PREFIX}-database

  ${SECURE_PREFIX}-mautic:
    image: mautic/mautic:4.4
    environment:
      MAUTIC_DB_HOST: ${SECURE_PREFIX}-database
      MAUTIC_DB_USER: pixsoladmin-mtc
      MAUTIC_DB_PASSWORD: $(openssl rand -base64 24)
    labels:
      - "traefik.http.routers.${SECURE_PREFIX}-mtc.rule=Host(\`mautic.pixerio.in\`)"
      - "traefik.http.routers.${SECURE_PREFIX}-mtc.tls.certresolver=le"
    restart: always
    depends_on:
      - ${SECURE_PREFIX}-database

  ${SECURE_PREFIX}-n8n:
    image: n8nio/n8n:1.24
    environment:
      N8N_HOST: n8n.pixerio.in
      N8N_PROTOCOL: https
    labels:
      - "traefik.http.routers.${SECURE_PREFIX}-n8n.rule=Host(\`n8n.pixerio.in\`)"
      - "traefik.http.routers.${SECURE_PREFIX}-n8n.tls.certresolver=le"
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

# Main installation flow
main() {
    self_update
    mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
    install_docker
    generate_compose
    docker-compose up -d
    
    echo -e "\n✅ Installation Complete!"
    echo -e "Access URLs:"
    echo -e "https://at.pixerio.in (WordPress)"
    echo -e "https://mautic.pixerio.in (Mautic)"
    echo -e "https://n8n.pixerio.in (n8n)"
}

# Run with error handling
trap 'echo "🆘 Error occurred - contact support@pixerio.in" && exit 1' ERR
main
