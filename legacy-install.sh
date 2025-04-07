#!/bin/bash

set -e

default_email="rajeshvyas71@gmail.com"
default_user="pixsoladmin"
log_file="/root/pixerio-install.log"

DOMAINS=("auto.pixerio.in" "maui.pixerio.in" "kb.pixerio.in")
declare -A APPS
APPS["auto.pixerio.in"]="n8n"
APPS["maui.pixerio.in"]="mautic"
APPS["kb.pixerio.in"]="wordpress"

function log() {
  echo -e "\e[92m$1\e[0m"
  echo "$1" >> "$log_file"
}

function gen_pass() {
  tr -dc A-Za-z0-9_@#%+= | head -c 16
}

function install_base() {
  log "Installing base packages..."

  apt update -y
  apt install -y software-properties-common curl unzip wget gnupg2 ca-certificates lsb-release apt-transport-https

  # Add PHP repo
  add-apt-repository ppa:ondrej/php -y
  apt update -y

  # Install PHP 8.2 and extensions
  apt install -y php8.2 php8.2-cli php8.2-common php8.2-mysql php8.2-xml php8.2-gd php8.2-curl php8.2-mbstring php8.2-zip php8.2-fpm

  # Other core services
  apt install -y nginx mariadb-server certbot python3-certbot-nginx
}


function install_node() {
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs
}

function secure_db() {
  mysql_secure_installation <<EOF

y
$(gen_pass)
$(gen_pass)
y
y
y
y
EOF
}

function create_site() {
  domain=$1
  app=${APPS[$domain]}
  root_dir="/var/www/$domain"
  creds_file="/root/${domain}-creds.txt"
  db_name="pix_${app//[^a-zA-Z0-9]/_}"
  db_user="${default_user}"
  db_pass=$(gen_pass)

  mkdir -p "$root_dir"
  chown -R www-data:www-data "$root_dir"
  chmod -R 755 "$root_dir"

  mysql -e "CREATE DATABASE IF NOT EXISTS ${db_name};"
  mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
  mysql -e "GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"

  case $app in
    wordpress)
      log "Installing WordPress for $domain"
      wget -q https://wordpress.org/latest.zip -O /tmp/wordpress.zip
      unzip -q /tmp/wordpress.zip -d /tmp/
      rsync -a /tmp/wordpress/ "$root_dir/"
      ;;
    mautic)
      log "Installing Mautic for $domain"
      wget -q https://www.mautic.org/download/latest -O /tmp/mautic.zip
      unzip -q /tmp/mautic.zip -d "$root_dir"
      ;;
    n8n)
      log "Installing n8n for $domain"
      npm install -g n8n
      cat <<EOF > /etc/systemd/system/n8n@$domain.service
[Unit]
Description=n8n for $domain
After=network.target

[Service]
Type=simple
User=www-data
Environment=PORT=5678
Environment=DB_TYPE=sqlite
Environment=DB_SQLITE_DATABASE_PATH=$root_dir/n8n.sqlite
Environment=WEBHOOK_URL=https://$domain/
ExecStart=/usr/bin/n8n
Restart=always

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reexec
      systemctl enable n8n@$domain
      systemctl start n8n@$domain
      ;;
  esac

  cat <<EOF > /etc/nginx/sites-available/$domain
server {
    listen 80;
    server_name $domain;
    root $root_dir;

    index index.php index.html;

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

  ln -s /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  certbot --nginx --non-interactive --agree-tos --redirect -d $domain -m $default_email

  echo -e "Domain: $domain\nApp: $app\nDB Name: $db_name\nDB User: $db_user\nDB Pass: $db_pass\nWeb Root: $root_dir" > "$creds_file"
  chmod 600 "$creds_file"
}

install_base
install_node
secure_db

for domain in "${DOMAINS[@]}"; do
  create_site "$domain"
done

log "🎉 All apps installed successfully."
log "Passwords stored in /root/<domain>-creds.txt"
