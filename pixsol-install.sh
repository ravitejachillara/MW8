#!/bin/bash
# Final working version with automatic latest images
# Run with: bash <(curl -fsSL https://github.com/ravitejachillara/pixerio/raw/main/pixsol-install.sh)

set -euo pipefail

# Configuration
INSTALL_DIR="/opt/pixsol"
SECURE_PREFIX="pixsol-$(openssl rand -hex 3)"

# Install Docker with latest stable
install_docker() {
    if ! command -v docker &>/dev/null; then
        echo "🔧 Installing Docker..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker $USER
        sudo systemctl enable --now docker
    fi

    if ! command -v docker-compose &>/dev/null; then
        echo "🔧 Installing Docker Compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
}

# Generate production config
generate_config() {
    cat <<EOL > docker-compose.yml
services:
  ${SECURE_PREFIX}-reverse-proxy:
    image: traefik:latest
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
    image: wordpress:latest
    environment:
      WORDPRESS_DB_HOST: ${SECURE_PREFIX}-database
      WORDPRESS_DB_USER: pixsoladmin
      WORDPRESS_DB_PASSWORD: $(openssl rand -base64 24)
    labels:
      - "traefik.http.routers.wp.rule=Host(\`at.pixerio.in\`)"
      - "traefik.http.routers.wp.tls.certresolver=le"
    depends_on:
      ${SECURE_PREFIX}-database:
        condition: service_healthy
    restart: always

  ${SECURE_PREFIX}-mautic:
    image: mautic/mautic:latest
    environment:
      MAUTIC_DB_HOST: ${SECURE_PREFIX}-database
      MAUTIC_DB_USER: pixsoladmin
      MAUTIC_DB_PASSWORD: $(openssl rand -base64 24)
    labels:
      - "traefik.http.routers.mtc.rule=Host(\`mautic.pixerio.in\`)"
      - "traefik.http.routers.mtc.tls.certresolver=le"
    depends_on:
      ${SECURE_PREFIX}-database:
        condition: service_healthy
    restart: always

  ${SECURE_PREFIX}-n8n:
    image: n8nio/n8n:latest
    labels:
      - "traefik.http.routers.n8n.rule=Host(\`n8n.pixerio.in\`)"
      - "traefik.http.routers.n8n.tls.certresolver=le"
    restart: always

  ${SECURE_PREFIX}-database:
    image: mariadb:latest
    environment:
      MYSQL_ROOT_PASSWORD: $(openssl rand -base64 48)
      MYSQL_USER: pixsoladmin
      MYSQL_PASSWORD: $(openssl rand -base64 48)
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 2s
      retries: 10
    restart: always

volumes:
  db_data:
  letsencrypt:
EOL
}

# Main installation flow
main() {
    echo "🚀 Starting PixSol installation..."
    sudo mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
    install_docker
    generate_config
    
    echo "🔧 Starting services..."
    sudo docker-compose up -d
    
    echo -e "\n✅ Installation Complete!"
    echo -e "Access URLs (may take 2-5 minutes to become available):"
    echo -e "- WordPress: https://at.pixerio.in"
    echo -e "- Mautic: https://mautic.pixerio.in"
    echo -e "- n8n: https://n8n.pixerio.in"
    echo -e "\n🔑 Passwords stored in: ${INSTALL_DIR}/docker-compose.yml"
}

# Error handling
trap 'echo -e "\n🆘 Installation failed - contact support@pixerio.in" && exit 1' ERR

# Execute
main
