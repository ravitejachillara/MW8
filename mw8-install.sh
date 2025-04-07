#!/bin/bash

# File: mw8-install.sh
# App: MW8 Stack Installer
# Default Directory: mw8-stack

set -e

# Define colors for readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Prelim setup and update
printf "${BLUE}Updating system and installing core dependencies...${NC}\n"
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git ufw docker.io docker-compose jq pwgen unzip

# Get install directory
read -rp $'\nWhere should the MW8 stack be installed? (default: mw8-stack): ' INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-mw8-stack}
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Ask for domain and app selection
read -rp $'\nEnter base domain (e.g., example.com, sub-domains will be created based on this): ' BASE_DOMAIN
read -rp $'\nEnter admin email (for SSL certs and alerts): ' ADMIN_EMAIL

printf "\nSelect applications to install:\n"
echo "a) Mautic"
echo "b) WordPress"
echo "c) n8n"
echo "d) Mautic + n8n"
echo "e) Mautic + WordPress"
echo "f) n8n + WordPress"
echo "g) All (Mautic + WordPress + n8n)"
read -rp $'\nEnter your choice (a-g): ' APP_CHOICE

# App selection logic
INSTALL_MAUTIC=false
INSTALL_WP=false
INSTALL_N8N=false
case $APP_CHOICE in
  a) INSTALL_MAUTIC=true ;;
  b) INSTALL_WP=true ;;
  c) INSTALL_N8N=true ;;
  d) INSTALL_MAUTIC=true; INSTALL_N8N=true ;;
  e) INSTALL_MAUTIC=true; INSTALL_WP=true ;;
  f) INSTALL_N8N=true; INSTALL_WP=true ;;
  g) INSTALL_MAUTIC=true; INSTALL_WP=true; INSTALL_N8N=true ;;
  *) echo -e "${RED}Invalid choice. Exiting.${NC}"; exit 1 ;;
esac

# Ask for or generate credentials
read -rp $'\nEnter admin username: ' ADMIN_USER
read -rsp $'Enter admin password (leave empty to auto-generate): ' ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-$(pwgen -s 16 1)}
echo "\nUsing admin password: $ADMIN_PASS"

# Setup firewall
printf "${BLUE}Configuring UFW firewall rules...${NC}\n"
sudo ufw allow OpenSSH
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable

# Docker network
docker network create mw8-net || true

# Create subdomains and directory tree
mkdir -p logs traefik

# Start logging
LOG_FILE="install-log.txt"
echo "Installation started on $(date)" >> "$LOG_FILE"

# Create docker-compose.yml dynamically
cat > docker-compose.yml <<EOF
version: '3.9'
services:
  traefik:
    image: traefik:latest
    command:
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--certificatesresolvers.myresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.myresolver.acme.email=$ADMIN_EMAIL"
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock"
      - "./traefik:/letsencrypt"
    networks:
      - mw8-net
EOF

# App service templates
[[ "$INSTALL_MAUTIC" == true ]] && cat >> docker-compose.yml <<EOF
  mautic:
    image: mautic/mautic:latest
    environment:
      - MAUTIC_DB_HOST=mautic-db
      - MAUTIC_DB_USER=mautic
      - MAUTIC_DB_PASSWORD=$(pwgen -s 12 1)
      - MAUTIC_DB_NAME=mautic
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mautic.rule=Host(\"mautic.$BASE_DOMAIN\")"
      - "traefik.http.routers.mautic.entrypoints=websecure"
      - "traefik.http.routers.mautic.tls.certresolver=myresolver"
    depends_on:
      - mautic-db
    networks:
      - mw8-net

  mautic-db:
    image: mariadb:10.6
    environment:
      - MYSQL_ROOT_PASSWORD=$(pwgen -s 12 1)
      - MYSQL_DATABASE=mautic
      - MYSQL_USER=mautic
      - MYSQL_PASSWORD=$(pwgen -s 12 1)
    volumes:
      - mautic-db-data:/var/lib/mysql
    networks:
      - mw8-net
EOF

[[ "$INSTALL_WP" == true ]] && cat >> docker-compose.yml <<EOF
  wordpress:
    image: wordpress:latest
    environment:
      - WORDPRESS_DB_HOST=wp-db
      - WORDPRESS_DB_USER=wp
      - WORDPRESS_DB_PASSWORD=$(pwgen -s 12 1)
      - WORDPRESS_DB_NAME=wp
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wordpress.rule=Host(\"wp.$BASE_DOMAIN\")"
      - "traefik.http.routers.wordpress.entrypoints=websecure"
      - "traefik.http.routers.wordpress.tls.certresolver=myresolver"
    depends_on:
      - wp-db
    networks:
      - mw8-net

  wp-db:
    image: mysql:5.7
    environment:
      - MYSQL_ROOT_PASSWORD=$(pwgen -s 12 1)
      - MYSQL_DATABASE=wp
      - MYSQL_USER=wp
      - MYSQL_PASSWORD=$(pwgen -s 12 1)
    volumes:
      - wp-db-data:/var/lib/mysql
    networks:
      - mw8-net
EOF

[[ "$INSTALL_N8N" == true ]] && cat >> docker-compose.yml <<EOF
  n8n:
    image: n8nio/n8n
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=n8n-db
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=$(pwgen -s 12 1)
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\"n8n.$BASE_DOMAIN\")"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
    depends_on:
      - n8n-db
    networks:
      - mw8-net

  n8n-db:
    image: postgres:15
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=$(pwgen -s 12 1)
      - POSTGRES_DB=n8n
    volumes:
      - n8n-db-data:/var/lib/postgresql/data
    networks:
      - mw8-net
EOF

# Add volume section
cat >> docker-compose.yml <<EOF
volumes:
  mautic-db-data:
  wp-db-data:
  n8n-db-data:

networks:
  mw8-net:
    external: true
EOF

# Launch stack
printf "${GREEN}Starting containers...${NC}\n"
docker-compose up -d

# Post-deploy checks
printf "${YELLOW}Waiting for services to stabilize...${NC}\n"
sleep 10

docker ps

# Save credentials and summary
CRED_FILE="mw8-credentials.txt"
echo -e "\nMW8 Stack Deployment Complete" | tee "$CRED_FILE"
echo "Admin User: $ADMIN_USER" | tee -a "$CRED_FILE"
echo "Admin Pass: $ADMIN_PASS" | tee -a "$CRED_FILE"
echo "Mautic URL: https://mautic.$BASE_DOMAIN" | tee -a "$CRED_FILE"
echo "WordPress URL: https://wp.$BASE_DOMAIN" | tee -a "$CRED_FILE"
echo "n8n URL: https://n8n.$BASE_DOMAIN" | tee -a "$CRED_FILE"
echo "Traefik Dashboard: https://$BASE_DOMAIN (if configured)" | tee -a "$CRED_FILE"

echo -e "\n${GREEN}All done! Visit the URLs above to complete app setups.${NC}"
