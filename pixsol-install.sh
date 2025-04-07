#!/bin/bash

# === MW8 Stack Installer ===
# Customized for: pixerio.in
# Subdomains: n8n.pixerio.in, mautic.pixerio.in, at.pixerio.in, traefik.pixerio.in
# Author: Quantocos

set -e

# =============== COLORS ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============== BASIC SETUP ===============
echo -e "${YELLOW}Updating system & installing dependencies...${NC}"
apt update && apt upgrade -y
apt install -y curl git docker.io docker-compose ufw pwgen

# =============== SETUP DIRECTORIES ===============
INSTALL_DIR="$HOME/mw8-stack"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# =============== CREATE NETWORK ===============
docker network create traefik-network || true

# =============== UFW FIREWALL ===============
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

# =============== LOGGING ===============
LOG_FILE="$INSTALL_DIR/mw8-setup.log"
touch "$LOG_FILE"

# =============== DOMAIN CONFIG ===============
DOMAIN_MAUTIC="mautic.pixerio.in"
DOMAIN_N8N="n8n.pixerio.in"
DOMAIN_WP="at.pixerio.in"
DOMAIN_TRAEFIK="traefik.pixerio.in"

# =============== GENERATE CREDS ===============
ADMIN_PASS=$(pwgen 12 1)
DB_PASS=$(pwgen 16 1)
echo "Admin Password: $ADMIN_PASS" | tee -a $LOG_FILE
echo "DB Password: $DB_PASS" >> $LOG_FILE

# =============== COMPOSE FILE ===============
cat <<EOF > docker-compose.yml
version: '3.8'

services:

  traefik:
    image: traefik:latest
    command:
      - "--api.dashboard="
      - "--providers.docker=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.myresolver.acme.email=admin@$DOMAIN_WP"
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./letsencrypt:/letsencrypt"
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\"$DOMAIN_TRAEFIK\")"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=myresolver"

  wordpress:
    image: wordpress:latest
    environment:
      WORDPRESS_DB_HOST: wp-db
      WORDPRESS_DB_USER: root
      WORDPRESS_DB_PASSWORD: $DB_PASS
      WORDPRESS_DB_NAME: wp
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wp.rule=Host(\"$DOMAIN_WP\")"
      - "traefik.http.routers.wp.entrypoints=websecure"
      - "traefik.http.routers.wp.tls.certresolver=myresolver"
    networks:
      - traefik-network
    depends_on:
      - wp-db

  wp-db:
    image: mysql:5.7
    environment:
      MYSQL_ROOT_PASSWORD: $DB_PASS
      MYSQL_DATABASE: wp
    networks:
      - traefik-network

  mautic:
    image: mautic/mautic:latest
    environment:
      MAUTIC_DB_HOST: mautic-db
      MAUTIC_DB_USER: root
      MAUTIC_DB_PASSWORD: $DB_PASS
      MAUTIC_DB_NAME: mautic
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mautic.rule=Host(\"$DOMAIN_MAUTIC\")"
      - "traefik.http.routers.mautic.entrypoints=websecure"
      - "traefik.http.routers.mautic.tls.certresolver=myresolver"
    networks:
      - traefik-network
    depends_on:
      - mautic-db

  mautic-db:
    image: mariadb:10.6
    environment:
      MYSQL_ROOT_PASSWORD: $DB_PASS
      MYSQL_DATABASE: mautic
    networks:
      - traefik-network

  n8n:
    image: n8nio/n8n
    environment:
      DB_TYPE: postgres
      DB_POSTGRESDB_HOST: n8n-db
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_PASSWORD: $DB_PASS
      N8N_BASIC_AUTH_ACTIVE: "true"
      N8N_BASIC_AUTH_USER: admin
      N8N_BASIC_AUTH_PASSWORD: $ADMIN_PASS
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\"$DOMAIN_N8N\")"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
    depends_on:
      - n8n-db
    networks:
      - traefik-network

  n8n-db:
    image: postgres:15
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: n8n
    networks:
      - traefik-network

networks:
  traefik-network:
    external: true
EOF

# =============== START STACK ===============
docker-compose up -d

sleep 10

echo -e "${BLUE}Checking container status...${NC}"
docker ps -a | tee -a $LOG_FILE

echo -e "${GREEN}MW8 Stack installation complete!${NC}"
echo -e "\nAccess your services here:" | tee -a $LOG_FILE
echo "- Traefik: https://$DOMAIN_TRAEFIK" | tee -a $LOG_FILE
echo "- Mautic: https://$DOMAIN_MAUTIC" | tee -a $LOG_FILE
echo "- Wordpress: https://$DOMAIN_WP" | tee -a $LOG_FILE
echo "- n8n: https://$DOMAIN_N8N" | tee -a $LOG_FILE

echo -e "\nLogin Details (also in $LOG_FILE):"
echo "- Admin Username: admin"
echo "- Admin Password: $ADMIN_PASS"
echo "- DB Root Password: $DB_PASS"

exit 0
# End of script
# =========================================
