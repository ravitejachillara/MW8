#!/bin/bash

set -euo pipefail
LOG_FILE="/var/log/site-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "------ Quantocos Web Setup Script ------"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

# Check root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Run this script as root (sudo).${NC}"
  exit 1
fi

# Prompt user
read -p "Enter domains (comma separated): " domains_raw
IFS=',' read -ra DOMAINS <<< "$domains_raw"

read -p "Enter SSL email [default: rajeshvyas71@gmail.com]: " ssl_email
ssl_email="${ssl_email:-rajeshvyas71@gmail.com}"

read -p "MySQL root password (leave empty to auto-generate): " mysql_root_pass
if [ -z "$mysql_root_pass" ]; then
  mysql_root_pass=$(openssl rand -base64 16)
  echo "Generated MySQL root password: $mysql_root_pass"
fi

read -p "Generate DB credentials per domain? (y/n) [default: y]: " db_gen_creds
db_gen_creds="${db_gen_creds:-y}"

echo "Updating system & installing required packages..."

# Update & install stack
apt update && apt upgrade -y
apt install -y nginx php8.2 php8.2-fpm php8.2-mysql php8.2-cli php8.2-curl php8.2-xml php8.2-mbstring php8.2-zip php8.2-bcmath php8.2-gd php8.2-soap php8.2-intl php8.2-common mariadb-server unzip curl ufw certbot python3-certbot-nginx

# Start services
systemctl enable --now nginx php8.2-fpm mariadb

# Secure MySQL
mysql -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${mysql_root_pass}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# Loop over each domain
for domain in "${DOMAINS[@]}"; do
  domain=$(echo "$domain" | xargs)  # trim
  web_root="/var/www/${domain}"
  echo -e "\n${GREEN}Setting up ${domain}...${NC}"

  # Create directory
  mkdir -p "$web_root"
  chown -R www-data:www-data "$web_root"
  chmod -R 755 "$web_root"

  # Default index
  if [ ! -f "$web_root/index.php" ]; then
    echo "<?php phpinfo(); ?>" > "$web_root/index.php"
  fi

  # Generate DB credentials
  if [[ "$db_gen_creds" =~ ^[Yy]$ ]]; then
    db_name="${domain//./_}_db"
    db_user="${domain//./_}_user"
    db_pass=$(openssl rand -base64 12)
  else
    read -p "DB Name for $domain: " db_name
    read -p "DB User for $domain: " db_user
    read -p "DB Password for $domain: " db_pass
  fi

  # MySQL: Create DB & user if not exists
  mysql -uroot -p"${mysql_root_pass}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${db_name}\`;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF

  # Nginx config
  nginx_conf="/etc/nginx/sites-available/${domain}"
  if [ ! -f "$nginx_conf" ]; then
    cat > "$nginx_conf" <<EOF
server {
    listen 80;
    server_name ${domain} www.${domain};
    root ${web_root};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    ln -s "$nginx_conf" /etc/nginx/sites-enabled/
  fi

  # Check config
  nginx -t && systemctl reload nginx

  # Certbot SSL
  echo -e "${GREEN}Getting SSL cert for ${domain}...${NC}"
  certbot --nginx -d "${domain}" -d "www.${domain}" --non-interactive --agree-tos -m "$ssl_email"

done

# Setup auto-renew
echo -e "\n${GREEN}Setting up certbot renewal cron...${NC}"
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -

# Output summary
echo -e "\n${GREEN}------ Setup Complete ------${NC}"
echo "MySQL root password: $mysql_root_pass"
for domain in "${DOMAINS[@]}"; do
  domain=$(echo "$domain" | xargs)
  db_name="${domain//./_}_db"
  db_user="${domain//./_}_user"
  echo -e "\n${domain}"
  echo "  Web Root: /var/www/${domain}"
  echo "  DB Name: ${db_name}"
  echo "  DB User: ${db_user}"
done

echo -e "\nAll logs saved to: ${LOG_FILE}"
