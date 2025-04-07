#!/bin/bash

# === MW8 Stack Installer ===
# General purpose version
# Author: Quantocos (Modified)

set -e

# =============== COLORS ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============== GATHER USER INPUT ===============
echo -e "${BLUE}Welcome to the MW8 Stack Installer${NC}"
echo -e "This script will install Traefik, WordPress, Mautic, and n8n."
echo -e "${YELLOW}Please provide the following information:${NC}"

# Collect main domain information
read -p "Enter your primary domain name (e.g., example.com): " PRIMARY_DOMAIN
while [[ -z "$PRIMARY_DOMAIN" ]]; do
    echo -e "${RED}Domain cannot be empty.${NC}"
    read -p "Enter your primary domain name (e.g., example.com): " PRIMARY_DOMAIN
done

read -p "Enter email for SSL certificates: " EMAIL_SSL
while [[ ! "$EMAIL_SSL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
    echo -e "${RED}Please enter a valid email address.${NC}"
    read -p "Enter email for SSL certificates: " EMAIL_SSL
done

# Ask for subdomains or set defaults
read -p "Enter subdomain for Traefik dashboard [traefik]: " TRAEFIK_SUB
TRAEFIK_SUB=${TRAEFIK_SUB:-traefik}

read -p "Enter subdomain for WordPress [wp]: " WP_SUB
WP_SUB=${WP_SUB:-wp}

read -p "Enter subdomain for Mautic [mautic]: " MAUTIC_SUB
MAUTIC_SUB=${MAUTIC_SUB:-mautic}

read -p "Enter subdomain for n8n [n8n]: " N8N_SUB
N8N_SUB=${N8N_SUB:-n8n}

# Email configuration
read -p "Enter sender email address for Mautic [no-reply@$PRIMARY_DOMAIN]: " MAUTIC_EMAIL_FROM_ADDRESS
MAUTIC_EMAIL_FROM_ADDRESS=${MAUTIC_EMAIL_FROM_ADDRESS:-no-reply@$PRIMARY_DOMAIN}

read -p "Enter sender name for Mautic [Notification]: " MAUTIC_EMAIL_FROM_NAME
MAUTIC_EMAIL_FROM_NAME=${MAUTIC_EMAIL_FROM_NAME:-Notification}

read -p "Enter SMTP server host [mail.$PRIMARY_DOMAIN]: " MAUTIC_MAILER_HOST
MAUTIC_MAILER_HOST=${MAUTIC_MAILER_HOST:-mail.$PRIMARY_DOMAIN}

read -p "Enter SMTP server port [587]: " MAUTIC_MAILER_PORT
MAUTIC_MAILER_PORT=${MAUTIC_MAILER_PORT:-587}

read -p "Enter SMTP encryption (tls/ssl) [tls]: " MAUTIC_MAILER_ENCRYPTION
MAUTIC_MAILER_ENCRYPTION=${MAUTIC_MAILER_ENCRYPTION:-tls}

read -p "Enter SMTP username [$MAUTIC_EMAIL_FROM_ADDRESS]: " MAUTIC_MAILER_USER
MAUTIC_MAILER_USER=${MAUTIC_MAILER_USER:-$MAUTIC_EMAIL_FROM_ADDRESS}

# Set SMTP Transport
MAUTIC_MAILER_TRANSPORT="smtp"
MAUTIC_SPOOL_TYPE="file"

# Confirm installation
echo -e "\n${YELLOW}Installation Summary:${NC}"
echo "Main Domain: $PRIMARY_DOMAIN"
echo "Traefik Dashboard: $TRAEFIK_SUB.$PRIMARY_DOMAIN"
echo "WordPress: $WP_SUB.$PRIMARY_DOMAIN"
echo "Mautic: $MAUTIC_SUB.$PRIMARY_DOMAIN"
echo "n8n: $N8N_SUB.$PRIMARY_DOMAIN"
echo "Email for SSL: $EMAIL_SSL"
echo "SMTP Configuration:"
echo "  - From: $MAUTIC_EMAIL_FROM_NAME <$MAUTIC_EMAIL_FROM_ADDRESS>"
echo "  - Server: $MAUTIC_MAILER_HOST:$MAUTIC_MAILER_PORT ($MAUTIC_MAILER_ENCRYPTION)"
echo "  - Username: $MAUTIC_MAILER_USER"

read -p "Proceed with installation? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo -e "${RED}Installation aborted.${NC}"
    exit 1
fi

# =============== BASIC SETUP ===============
echo -e "${YELLOW}Updating system & installing dependencies...${NC}"
apt update && apt upgrade -y
apt install -y curl git docker.io docker-compose ufw pwgen htop

# =============== SETUP DIRECTORIES ===============
INSTALL_DIR="$HOME/mw8-stack"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/data/n8n"
mkdir -p "$INSTALL_DIR/data/mautic"
mkdir -p "$INSTALL_DIR/data/wordpress"
mkdir -p "$INSTALL_DIR/data/mysql"
mkdir -p "$INSTALL_DIR/data/postgres"
mkdir -p "$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/scripts"
mkdir -p "$INSTALL_DIR/configs"
cd "$INSTALL_DIR"

# =============== CREATE NETWORK ===============
docker network create traefik-network || true

# =============== UFW FIREWALL ===============
echo -e "${YELLOW}Configuring firewall...${NC}"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 25
ufw allow 465
ufw allow 587
ufw allow 2525
ufw --force enable

# =============== LOGGING ===============
LOG_FILE="$INSTALL_DIR/logs/mw8-setup.log"
touch "$LOG_FILE"
echo "=== MW8 Stack Installation Log - $(date) ===" > "$LOG_FILE"

# =============== DOMAIN CONFIG ===============
DOMAIN_MAUTIC="$MAUTIC_SUB.$PRIMARY_DOMAIN"
DOMAIN_N8N="$N8N_SUB.$PRIMARY_DOMAIN"
DOMAIN_WP="$WP_SUB.$PRIMARY_DOMAIN"
DOMAIN_TRAEFIK="$TRAEFIK_SUB.$PRIMARY_DOMAIN"

echo -e "${BLUE}Configuring domains:${NC}" | tee -a $LOG_FILE
echo "- Traefik Dashboard: $DOMAIN_TRAEFIK" | tee -a $LOG_FILE
echo "- WordPress: $DOMAIN_WP" | tee -a $LOG_FILE
echo "- Mautic: $DOMAIN_MAUTIC" | tee -a $LOG_FILE
echo "- n8n: $DOMAIN_N8N" | tee -a $LOG_FILE
echo "- SSL Email: $EMAIL_SSL" | tee -a $LOG_FILE

# =============== GENERATE CREDS ===============
ADMIN_USER="admin"
ADMIN_PASS=$(pwgen -s 16 1)
WP_DB_NAME="wp_db"
WP_DB_USER="wp_user"
WP_DB_PASS=$(pwgen -s 16 1)
MAUTIC_DB_NAME="mautic_db"
MAUTIC_DB_USER="mautic_user"
MAUTIC_DB_PASS=$(pwgen -s 16 1)
N8N_DB_NAME="n8n_db"
N8N_DB_USER="n8n_user"
N8N_DB_PASS=$(pwgen -s 16 1)
POSTGRES_PASSWORD=$(pwgen -s 16 1)
MYSQL_ROOT_PASSWORD=$(pwgen -s 20 1)

# Generate SMTP password if not already set
MAUTIC_MAILER_PASSWORD=$(pwgen -s 16 1)

echo -e "${YELLOW}Generating secure credentials...${NC}"
echo "Admin Username: $ADMIN_USER" | tee -a $LOG_FILE
echo "Admin Password: $ADMIN_PASS" | tee -a $LOG_FILE
echo "MySQL Root Password: $MYSQL_ROOT_PASSWORD" >> $LOG_FILE
echo "WordPress DB Name: $WP_DB_NAME" >> $LOG_FILE
echo "WordPress DB User: $WP_DB_USER" >> $LOG_FILE
echo "WordPress DB Password: $WP_DB_PASS" >> $LOG_FILE
echo "Mautic DB Name: $MAUTIC_DB_NAME" >> $LOG_FILE
echo "Mautic DB User: $MAUTIC_DB_USER" >> $LOG_FILE
echo "Mautic DB Password: $MAUTIC_DB_PASS" >> $LOG_FILE
echo "n8n DB Name: $N8N_DB_NAME" >> $LOG_FILE
echo "n8n DB User: $N8N_DB_USER" >> $LOG_FILE
echo "n8n DB Password: $N8N_DB_PASS" >> $LOG_FILE
echo "Postgres Password: $POSTGRES_PASSWORD" >> $LOG_FILE
echo "Mautic Email User: $MAUTIC_MAILER_USER" >> $LOG_FILE
echo "Mautic Email Password: $MAUTIC_MAILER_PASSWORD" >> $LOG_FILE

# =============== COMPOSE FILE ===============
echo -e "${BLUE}Creating docker-compose.yml file...${NC}"
cat <<EOF > docker-compose.yml
version: '3.8'

services:

  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    command:
      - "--log.level=INFO"
      - "--api.dashboard=true"
      - "--api.insecure=false"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--certificatesresolvers.myresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.myresolver.acme.email=$EMAIL_SSL"
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./letsencrypt:/letsencrypt"
      - "./logs/traefik:/var/log/traefik"
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`$DOMAIN_TRAEFIK\`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=myresolver"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.middlewares=traefik-auth"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=$ADMIN_USER:$(htpasswd -nb $ADMIN_USER $ADMIN_PASS | sed 's/\$/\$\$/g')"
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 30s
      timeout: 10s
      retries: 3

  wp-db:
    image: mysql:5.7
    container_name: wordpress-db
    restart: unless-stopped
    volumes:
      - "./data/mysql/wordpress:/var/lib/mysql"
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_DATABASE: $WP_DB_NAME
      MYSQL_USER: $WP_DB_USER
      MYSQL_PASSWORD: $WP_DB_PASS
    networks:
      - traefik-network
    command: --default-authentication-plugin=mysql_native_password
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p$MYSQL_ROOT_PASSWORD"]
      interval: 30s
      timeout: 10s
      retries: 3

  wordpress:
    image: wordpress:latest
    container_name: wordpress
    restart: unless-stopped
    volumes:
      - "./data/wordpress:/var/www/html"
    environment:
      WORDPRESS_DB_HOST: wp-db
      WORDPRESS_DB_USER: $WP_DB_USER
      WORDPRESS_DB_PASSWORD: $WP_DB_PASS
      WORDPRESS_DB_NAME: $WP_DB_NAME
      WORDPRESS_TABLE_PREFIX: wp_
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wp.rule=Host(\`$DOMAIN_WP\`)"
      - "traefik.http.routers.wp.entrypoints=websecure"
      - "traefik.http.routers.wp.tls.certresolver=myresolver"
      - "traefik.http.services.wp.loadbalancer.server.port=80"
    networks:
      - traefik-network
    depends_on:
      - wp-db
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3

  mautic-db:
    image: mariadb:10.6
    container_name: mautic-db
    restart: unless-stopped
    volumes:
      - "./data/mysql/mautic:/var/lib/mysql"
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_DATABASE: $MAUTIC_DB_NAME
      MYSQL_USER: $MAUTIC_DB_USER
      MYSQL_PASSWORD: $MAUTIC_DB_PASS
    networks:
      - traefik-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p$MYSQL_ROOT_PASSWORD"]
      interval: 30s
      timeout: 10s
      retries: 3

  mautic:
    image: mautic/mautic:latest
    container_name: mautic
    restart: unless-stopped
    volumes:
      - "./data/mautic:/var/www/html"
    environment:
      MAUTIC_DB_HOST: mautic-db
      MAUTIC_DB_USER: $MAUTIC_DB_USER
      MAUTIC_DB_PASSWORD: $MAUTIC_DB_PASS
      MAUTIC_DB_NAME: $MAUTIC_DB_NAME
      MAUTIC_RUN_CRON_JOBS: "true"
      # Mautic email configuration
      MAUTIC_EMAIL_FROM_NAME: $MAUTIC_EMAIL_FROM_NAME
      MAUTIC_EMAIL_FROM_ADDRESS: $MAUTIC_EMAIL_FROM_ADDRESS
      MAUTIC_MAILER_TRANSPORT: $MAUTIC_MAILER_TRANSPORT
      MAUTIC_MAILER_HOST: $MAUTIC_MAILER_HOST
      MAUTIC_MAILER_PORT: $MAUTIC_MAILER_PORT
      MAUTIC_MAILER_ENCRYPTION: $MAUTIC_MAILER_ENCRYPTION
      MAUTIC_MAILER_USER: $MAUTIC_MAILER_USER
      MAUTIC_MAILER_PASSWORD: $MAUTIC_MAILER_PASSWORD
      MAUTIC_SPOOL_TYPE: $MAUTIC_SPOOL_TYPE
      MAUTIC_MAILER_SPOOL_PATH: "/var/www/html/var/spool"
      MAUTIC_MAILER_BATCH_SLEEP_TIME: 1
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mautic.rule=Host(\`$DOMAIN_MAUTIC\`)"
      - "traefik.http.routers.mautic.entrypoints=websecure"
      - "traefik.http.routers.mautic.tls.certresolver=myresolver"
      - "traefik.http.services.mautic.loadbalancer.server.port=80"
    networks:
      - traefik-network
    depends_on:
      - mautic-db
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Email spooler for Mautic
  mautic-cron:
    image: mautic/mautic:latest
    container_name: mautic-cron
    restart: unless-stopped
    volumes:
      - "./data/mautic:/var/www/html"
    environment:
      MAUTIC_DB_HOST: mautic-db
      MAUTIC_DB_USER: $MAUTIC_DB_USER
      MAUTIC_DB_PASSWORD: $MAUTIC_DB_PASS
      MAUTIC_DB_NAME: $MAUTIC_DB_NAME
    entrypoint: |
      bash -c 'while true; do
        php /var/www/html/bin/console mautic:emails:send --quiet
        sleep 300
      done'
    networks:
      - traefik-network
    depends_on:
      - mautic

  n8n-db:
    image: postgres:15-alpine
    container_name: n8n-db
    restart: unless-stopped
    volumes:
      - "./data/postgres:/var/lib/postgresql/data"
    environment:
      POSTGRES_USER: $N8N_DB_USER
      POSTGRES_PASSWORD: $N8N_DB_PASS
      POSTGRES_DB: $N8N_DB_NAME
    networks:
      - traefik-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $N8N_DB_USER -d $N8N_DB_NAME"]
      interval: 30s
      timeout: 10s
      retries: 3

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    volumes:
      - "./data/n8n:/home/node/.n8n"
    environment:
      - N8N_HOST=$DOMAIN_N8N
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - NODE_ENV=production
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=n8n-db
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=$N8N_DB_NAME
      - DB_POSTGRESDB_USER=$N8N_DB_USER
      - DB_POSTGRESDB_PASSWORD=$N8N_DB_PASS
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=$ADMIN_USER
      - N8N_BASIC_AUTH_PASSWORD=$ADMIN_PASS
      - N8N_SMTP_HOST=$MAUTIC_MAILER_HOST
      - N8N_SMTP_PORT=$MAUTIC_MAILER_PORT
      - N8N_SMTP_USER=$MAUTIC_MAILER_USER
      - N8N_SMTP_PASS=$MAUTIC_MAILER_PASSWORD
      - N8N_SMTP_SENDER=$MAUTIC_EMAIL_FROM_ADDRESS
      - N8N_LOG_LEVEL=info
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`$DOMAIN_N8N\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - traefik-network
    depends_on:
      - n8n-db
    healthcheck:
      test: ["CMD", "wget", "--spider", "--quiet", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Optional: Mailhog for testing emails in development (accessible at port 8025)
  mailhog:
    image: mailhog/mailhog
    container_name: mailhog
    restart: unless-stopped
    ports:
      - "8025:8025"
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mailhog.rule=Host(\`mail.$PRIMARY_DOMAIN\`)"
      - "traefik.http.routers.mailhog.entrypoints=websecure"
      - "traefik.http.routers.mailhog.tls.certresolver=myresolver"
      - "traefik.http.services.mailhog.loadbalancer.server.port=8025"

networks:
  traefik-network:
    external: true
EOF

# =============== CREATE MAUTIC CRON JOBS ===============
echo -e "${BLUE}Setting up Mautic cron jobs...${NC}"
cat <<EOF > ./configs/mautic-cron.conf
# Mautic Cron Jobs

# Run the segment update cron job every 1 minute
* * * * * php /var/www/html/bin/console mautic:segments:update --env=prod

# Process email queue every 5 minutes
*/5 * * * * php /var/www/html/bin/console mautic:emails:send --env=prod

# Process webhooks every 5 minutes
*/5 * * * * php /var/www/html/bin/console mautic:webhooks:process --env=prod

# Process broadcasts every 15 minutes
*/15 * * * * php /var/www/html/bin/console mautic:broadcasts:send --env=prod

# Process campaign triggers every 15 minutes
*/15 * * * * php /var/www/html/bin/console mautic:campaigns:trigger --env=prod

# Process campaign events every 15 minutes
*/15 * * * * php /var/www/html/bin/console mautic:campaigns:execute --env=prod

# Update email stats hourly
0 * * * * php /var/www/html/bin/console mautic:email:fetch --env=prod

# Cleanup old data twice daily
0 */12 * * * php /var/www/html/bin/console mautic:maintenance:cleanup --days-old=365 --env=prod
EOF

# =============== CONFIGURE POSTFIX FOR EMAIL (OPTIONAL) ===============
echo -e "${BLUE}Creating Postfix configuration for outbound email...${NC}"
cat <<EOF > ./configs/postfix-setup.sh
#!/bin/bash
# Script to set up Postfix for email sending
# Run this script manually if you decide to set up a full mail server

# Get domain from user input if not provided
if [ -z "\$1" ]; then
  read -p "Enter your domain name: " DOMAIN
else
  DOMAIN="\$1"
fi

apt-get update
apt-get install -y postfix postfix-mysql postfix-doc dovecot-core dovecot-imapd dovecot-lmtpd dovecot-mysql mailutils opendkim opendkim-tools

# Generate DKIM keys
mkdir -p /etc/opendkim/keys/\$DOMAIN
cd /etc/opendkim/keys/\$DOMAIN
opendkim-genkey -d \$DOMAIN -s mail
chown -R opendkim:opendkim /etc/opendkim/keys

# Basic Postfix config
postconf -e "myhostname = \$DOMAIN"
postconf -e "mydomain = \$DOMAIN"
postconf -e 'myorigin = \$mydomain'
postconf -e 'inet_interfaces = all'
postconf -e 'inet_protocols = ipv4'
postconf -e 'mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128'
postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/\$DOMAIN/fullchain.pem"
postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/\$DOMAIN/privkey.pem"
postconf -e 'smtpd_use_tls = yes'
postconf -e 'smtpd_tls_auth_only = yes'
postconf -e 'smtp_tls_security_level = may'
postconf -e 'smtpd_tls_security_level = may'

# Restart services
systemctl restart postfix
systemctl restart opendkim

SERVER_IP=\$(curl -s ifconfig.me)

echo "================================================================"
echo "Postfix installed. You need to configure DNS records for proper delivery:"
echo "1. Add SPF record: v=spf1 mx ip4:\$SERVER_IP ~all"
echo "2. Add DKIM record from /etc/opendkim/keys/\$DOMAIN/mail.txt"
echo "3. Add DMARC record: _dmarc.\$DOMAIN. IN TXT \"v=DMARC1; p=none; rua=mailto:admin@\$DOMAIN\""
echo "================================================================"
EOF
chmod +x ./configs/postfix-setup.sh

# =============== START STACK ===============
echo -e "${YELLOW}Starting the MW8 Stack...${NC}"
docker-compose up -d
echo "Initial deployment at $(date)" | tee -a $LOG_FILE

# Give services time to start
echo -e "${BLUE}Waiting for services to start up (60 seconds)...${NC}"
sleep 60

# =============== HEALTH CHECK ===============
echo -e "${YELLOW}Performing health checks...${NC}" | tee -a $LOG_FILE
containers=("traefik" "wordpress-db" "wordpress" "mautic-db" "mautic" "mautic-cron" "n8n-db" "n8n" "mailhog")

for container in "${containers[@]}"; do
  echo -n "Checking $container: " | tee -a $LOG_FILE
  
  health_status=$(docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null || echo "No health check")
  
  if [ "$health_status" = "healthy" ]; then
    echo -e "${GREEN}HEALTHY${NC}" | tee -a $LOG_FILE
  elif [ "$health_status" = "No health check" ]; then
    container_status=$(docker inspect --format='{{.State.Status}}' $container 2>/dev/null || echo "not found")
    if [ "$container_status" = "running" ]; then
      echo -e "${YELLOW}RUNNING (no health check)${NC}" | tee -a $LOG_FILE
    else
      echo -e "${RED}$container_status${NC}" | tee -a $LOG_FILE
    fi
  else
    echo -e "${RED}$health_status${NC}" | tee -a $LOG_FILE
    echo "Container logs for $container:" | tee -a $LOG_FILE
    docker logs $container --tail 20 | tee -a $LOG_FILE
  fi
done

# =============== CHECK N8N CONNECTION ===============
echo -e "${BLUE}Checking n8n database connection specifically...${NC}" | tee -a $LOG_FILE
n8n_logs=$(docker logs n8n 2>&1 | grep -i "error\|connection\|database" | tail -20)
if [ -n "$n8n_logs" ]; then
  echo -e "${YELLOW}Found potential issues with n8n:${NC}" | tee -a $LOG_FILE
  echo "$n8n_logs" | tee -a $LOG_FILE
  
  # If there's a specific database connection issue
  if echo "$n8n_logs" | grep -qi "connection\|database"; then
    echo -e "${YELLOW}Attempting to fix n8n database issues...${NC}" | tee -a $LOG_FILE
    docker-compose stop n8n
    sleep 5
    docker-compose start n8n
    sleep 15
    
    # Check again after restart
    n8n_status=$(docker inspect --format='{{.State.Health.Status}}' n8n 2>/dev/null || echo "Unknown")
    echo "n8n status after restart: $n8n_status" | tee -a $LOG_FILE
  fi
else
  echo -e "${GREEN}No obvious issues found with n8n database connection${NC}" | tee -a $LOG_FILE
fi

# =============== FINAL STATUS ===============
echo -e "${BLUE}Final container status:${NC}" | tee -a $LOG_FILE
docker ps -a | tee -a $LOG_FILE

# =============== CREATE EMAIL WARMUP SCRIPT ===============
echo -e "${BLUE}Creating email warmup script...${NC}" | tee -a $LOG_FILE
cat <<EOF > ./scripts/email-warmup.sh
#!/bin/bash
# Email Warmup Script for Mautic
# This script helps with email warmup by sending a small number of emails daily
# and gradually increasing the volume

LOG_FILE="./logs/email-warmup.log"
mkdir -p ./logs
touch \$LOG_FILE

echo "===========================================" >> \$LOG_FILE
echo "Email Warmup Started: \$(date)" >> \$LOG_FILE

# Configuration - Edit these variables
START_EMAILS=5      # Number of emails to send on first day
INCREMENT=5         # Increase by this many each day
MAX_EMAILS=100      # Maximum number of emails per day
WARMUP_DAYS=21      # Total warmup period in days

# Track the current day
if [ -f "./warmup_day.txt" ]; then
  CURRENT_DAY=\$(cat ./warmup_day.txt)
else
  CURRENT_DAY=1
  echo \$CURRENT_DAY > ./warmup_day.txt
fi

# Calculate emails to send today
EMAILS_TODAY=\$START_EMAILS
if [ \$CURRENT_DAY -gt 1 ]; then
  EMAILS_TODAY=\$((START_EMAILS + (CURRENT_DAY - 1) * INCREMENT))
  if [ \$EMAILS_TODAY -gt \$MAX_EMAILS ]; then
    EMAILS_TODAY=\$MAX_EMAILS
  fi
fi

echo "Day $CURRENT_DAY of $WARMUP_DAYS: Sending $EMAILS_TODAY emails" >> $LOG_FILE

# Trigger Mautic to send emails
# You can customize this command based on your Mautic setup
echo "Triggering Mautic email send..." >> $LOG_FILE
docker exec mautic php /var/www/html/bin/console mautic:campaigns:trigger --env=prod >> $LOG_FILE 2>&1
docker exec mautic php /var/www/html/bin/console mautic:emails:send --limit=$EMAILS_TODAY --env=prod >> $LOG_FILE 2>&1

# Update the day counter if we're still in the warmup period
if [ $CURRENT_DAY -lt $WARMUP_DAYS ]; then
  CURRENT_DAY=$((CURRENT_DAY + 1))
  echo $CURRENT_DAY > ./warmup_day.txt
  echo "Warmup continues. Next day: $CURRENT_DAY" >> $LOG_FILE
else
  echo "Warmup complete! Continuing with max emails ($MAX_EMAILS)" >> $LOG_FILE
fi

echo "Email Warmup Completed: $(date)" >> $LOG_FILE
echo "===========================================" >> $LOG_FILE
