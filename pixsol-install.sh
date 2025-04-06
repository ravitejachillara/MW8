#!/bin/bash
# Final working version with database healthcheck fixes
# Run with: bash <(curl -fsSL https://github.com/ravitejachillara/pixerio/raw/main/pixsol-install.sh)

set -euo pipefail

# Configuration
INSTALL_DIR="/opt/pixsol"
SECURE_PREFIX="pixsol-$(openssl rand -hex 3)"

# Generate database credentials without special characters
DB_ROOT_PASS=$(openssl rand -hex 24)
DB_USER_PASS=$(openssl rand -hex 24)

# Fixed Docker Compose configuration
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
      WORDPRESS_DB_PASSWORD: ${DB_USER_PASS}
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
      MAUTIC_DB_PASSWORD: ${DB_USER_PASS}
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
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MYSQL_USER: pixsoladmin
      MYSQL_PASSWORD: ${DB_USER_PASS}
      MYSQL_DATABASE: pixsol_main
    volumes:
      - db_data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h localhost -u root -p\${MYSQL_ROOT_PASSWORD}"]
      interval: 5s
      timeout: 5s
      retries: 30
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
    
    # Install Docker if missing
    if ! command -v docker &>/dev/null; then
        echo "🔧 Installing Docker..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo systemctl enable --now docker
        sleep 5  # Wait for Docker daemon
    fi

    generate_config
    
    echo "🔧 Starting services (this may take 5-10 minutes)..."
    sudo docker-compose up -d
    
    echo -e "\n✅ Installation Complete!"
    echo -e "Services will become available within 5-10 minutes as containers initialize"
    echo -e "Access URLs:"
    echo -e "- WordPress: https://at.pixerio.in"
    echo -e "- Mautic: https://mautic.pixerio.in"
    echo -e "- n8n: https://n8n.pixerio.in"
    echo -e "\n🔑 Database credentials:"
    echo -e "Root Password: ${DB_ROOT_PASS}"
    echo -e "User Password: ${DB_USER_PASS}"
}

# Error handling
trap 'echo -e "\n🆘 Installation failed - contact support@pixerio.in" && exit 1' ERR

# Execute
main
