#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status

# Update system and install dependencies
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common fail2ban

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.23.3/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Create Docker network
sudo docker network create --driver bridge traefik-net || true

# Create directory structure
mkdir -p {traefik,wordpress,langflow,n8n}/{data,config}

# Generate random credentials with pixsol prefix/suffix
generate_password() {
    openssl rand -base64 12 | tr -d '+/='
}

WP_DB_NAME="pixsolwp"
WP_DB_USER="pixsolwp_user"
WP_DB_PASS=$(generate_password)

LF_DB_USER="pixsollf_user"
LF_DB_PASS=$(generate_password)

N8N_DB_USER="pixsoln8n_user"
N8N_DB_PASS=$(generate_password)

TRAEFIK_USER="admin"
TRAEFIK_PASS=$(generate_password)

# Create traefik configuration
cat > traefik/config/traefik.yml <<EOF
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: rajeshvyas71@gmail.com
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    network: traefik-net
    exposedByDefault: false

log:
  level: INFO

accessLog: {}
EOF

# Create traefik docker-compose.yml
cat > traefik/docker-compose.yml <<EOF
version: '3'

services:
  reverse-proxy:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    networks:
      - traefik-net
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./config/traefik.yml:/etc/traefik/traefik.yml
      - ./data/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`dash.pixerio.in\`)"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=${TRAEFIK_USER}:${TRAEFIK_PASS}"

networks:
  traefik-net:
    external: true
EOF

# Create WordPress configuration
cat > wordpress/docker-compose.yml <<EOF
version: '3'

services:
  wordpress:
    image: wordpress:latest
    restart: unless-stopped
    networks:
      - traefik-net
    environment:
      WORDPRESS_DB_HOST: wordpress-db
      WORDPRESS_DB_USER: ${WP_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WP_DB_PASS}
      WORDPRESS_DB_NAME: ${WP_DB_NAME}
    volumes:
      - ./data:/var/www/html
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wordpress.rule=Host(\`kb.pixerio.in\`)"
      - "traefik.http.routers.wordpress.tls.certresolver=letsencrypt"

  wordpress-db:
    image: mariadb:latest
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: $(generate_password)
      MYSQL_DATABASE: ${WP_DB_NAME}
      MYSQL_USER: ${WP_DB_USER}
      MYSQL_PASSWORD: ${WP_DB_PASS}
    volumes:
      - ./db_data:/var/lib/mysql

networks:
  traefik-net:
    external: true
EOF

# Create Langflow configuration
cat > langflow/docker-compose.yml <<EOF
version: '3'

services:
  langflow:
    image: langflowai/langflow:latest
    restart: unless-stopped
    networks:
      - traefik-net
    environment:
      - LANGFLOW_DATABASE_URL=mysql+pymysql://${LF_DB_USER}:${LF_DB_PASS}@langflow-db/langflow
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.langflow.rule=Host(\`flow.pixerio.in\`)"
      - "traefik.http.routers.langflow.tls.certresolver=letsencrypt"

  langflow-db:
    image: mariadb:latest
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: $(generate_password)
      MYSQL_USER: ${LF_DB_USER}
      MYSQL_PASSWORD: ${LF_DB_PASS}
      MYSQL_DATABASE: langflow
    volumes:
      - ./db_data:/var/lib/mysql

networks:
  traefik-net:
    external: true
EOF

# Create n8n configuration
cat > n8n/docker-compose.yml <<EOF
version: '3'

services:
  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    networks:
      - traefik-net
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=n8n.pixerio.in
      - N8N_PROTOCOL=https
      - N8N_WEBHOOK_URL=https://n8n.pixerio.in
      - DB_TYPE=mysql
      - DB_MYSQLDB_DATABASE=n8n
      - DB_MYSQLDB_HOST=n8n-db
      - DB_MYSQLDB_USER=${N8N_DB_USER}
      - DB_MYSQLDB_PASSWORD=${N8N_DB_PASS}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`n8n.pixerio.in\`)"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

  n8n-db:
    image: mariadb:latest
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: $(generate_password)
      MYSQL_USER: ${N8N_DB_USER}
      MYSQL_PASSWORD: ${N8N_DB_PASS}
      MYSQL_DATABASE: n8n
    volumes:
      - ./db_data:/var/lib/mysql

networks:
  traefik-net:
    external: true
EOF

# Create cadvisor for monitoring
cat > cadvisor.yml <<EOF
version: '3'

services:
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    networks:
      - traefik-net
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.cadvisor.rule=Host(\`dash.pixerio.in\`) && PathPrefix(\`/cadvisor\`)"
      - "traefik.http.routers.cadvisor.tls.certresolver=letsencrypt"

networks:
  traefik-net:
    external: true
EOF

# Start all services
cd traefik && docker-compose up -d
cd ../wordpress && docker-compose up -d
cd ../langflow && docker-compose up -d
cd ../n8n && docker-compose up -d
cd .. && docker-compose -f cadvisor.yml up -d

# Configure fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Create credentials file
cat > /root/credentials.txt <<EOF
=== Traefik Dashboard ===
URL: https://dash.pixerio.in
Username: ${TRAEFIK_USER}
Password: ${TRAEFIK_PASS}

=== WordPress ===
URL: https://kb.pixerio.in
DB Name: ${WP_DB_NAME}
DB User: ${WP_DB_USER}
DB Password: ${WP_DB_PASS}

=== Langflow ===
URL: https://flow.pixerio.in
DB User: ${LF_DB_USER}
DB Password: ${LF_DB_PASS}

=== n8n ===
URL: https://n8n.pixerio.in
DB User: ${N8N_DB_USER}
DB Password: ${N8N_DB_PASS}

=== Monitoring ===
CAdvisor: https://dash.pixerio.in/cadvisor
EOF

# Display credentials
echo "Installation complete! Here are your credentials:"
cat /root/credentials.txt
