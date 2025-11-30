#!/bin/bash

# ============================================
#  AUTO INSTALL PAYMENTER — ORBYTE OPTIMIZED
# ============================================

echo "Melakukan pengecekan sistem..."
sleep 5
echo "Pengecekan selesai!"

OS=""
VERSION_ID=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
else
    echo "Tidak dapat mendeteksi OS. Instalasi dibatalkan."
    exit 1
fi

SUPPORTED=false

# --- UBUNTU SUPPORTED ---
if [ "$OS" == "ubuntu" ]; then
    if [[ "$VERSION_ID" == "24.04" || "$VERSION_ID" == "22.04" || "$VERSION_ID" == "20.04" ]]; then
        SUPPORTED=true
        echo "✔ Sistem terdeteksi: Ubuntu $VERSION_ID (Supported)"
    else
        echo "❌ Ubuntu versi $VERSION_ID tidak didukung!"
        exit 1
    fi
fi

# --- DEBIAN SUPPORTED ---
if [ "$OS" == "debian" ]; then
    if [[ "$VERSION_ID" == "11" || "$VERSION_ID" == "10" ]]; then
        SUPPORTED=true
        echo "✔ Sistem terdeteksi: Debian $VERSION_ID (Supported)"
    else
        echo "❌ Debian versi $VERSION_ID tidak didukung!"
        exit 1
    fi
fi

# --- CENTOS SUPPORTED ---
if [ "$OS" == "centos" ]; then
    if [[ "$VERSION_ID" == "8" || "$VERSION_ID" == "7" ]]; then
        SUPPORTED=true
        echo "✔ Sistem terdeteksi: CentOS $VERSION_ID (Supported)"
    else
        echo "❌ CentOS versi $VERSION_ID tidak didukung!"
        exit 1
    fi
fi

if [ "$SUPPORTED" != true ]; then
    echo "❌ Sistem operasi '$OS $VERSION_ID' tidak didukung!"
    exit 1
fi

echo ""
echo "=========================================="
echo "     AUTO INSTALL PAYMENTER BY ORBYTE.ID"
echo "=========================================="
echo ""

# --- ASK DOMAIN ---
read -p "Masukkan domain (contoh: bill.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo "Domain tidak boleh kosong!"
    exit 1
fi

echo "Domain digunakan: $DOMAIN"

# UPDATE SYSTEM
apt update && apt upgrade -y

# INSTALL DEPENDENCIES
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release

LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
    | sudo bash -s -- --mariadb-server-version="mariadb-10.11"

apt update

apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} \
mariadb-server nginx tar unzip git redis-server

# INSTALL DIRECTORY
mkdir -p /var/www/paymenter
cd /var/www/paymenter

# DOWNLOAD PAYMENTER
curl -Lo paymenter.tar.gz https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz
tar -xzvf paymenter.tar.gz

chmod -R 755 storage bootstrap/cache

# --- DATABASE SETUP ---
echo ""
echo "=============================="
echo "  SET PASSWORD DATABASE"
echo "=============================="
read -p "Masukkan password database untuk user paymenter: " DBPASS

mysql -u root <<MYSQL
DROP USER IF EXISTS 'paymenter'@'127.0.0.1';
DROP DATABASE IF EXISTS paymenter;

CREATE USER 'paymenter'@'127.0.0.1' IDENTIFIED BY '$DBPASS';
CREATE DATABASE paymenter;
GRANT ALL PRIVILEGES ON paymenter.* TO 'paymenter'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL

# --- ENV ---
rm -f .env
cp .env.example .env

sed -i "s/DB_DATABASE=.*/DB_DATABASE=paymenter/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=paymenter/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$DBPASS/" .env

php artisan key:generate --force
php artisan storage:link
php artisan migrate --force --seed
php artisan app:init
php artisan app:user:create

# CRONJOB
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/paymenter/artisan schedule:run >> /dev/null 2>&1") | crontab -

# --- QUEUE WORKER SERVICE ---
cat <<EOF >/etc/systemd/system/paymenter.service
[Unit]
Description=Paymenter Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/paymenter/artisan queue:work --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now paymenter.service
systemctl enable --now redis-server

# --- NGINX CONFIG ---
cat <<EOF >/etc/nginx/sites-available/paymenter.conf
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root /var/www/paymenter/public;
    index index.php;
    client_max_body_size 50M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_buffer_size 32k;
        fastcgi_buffers 4 32k;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/paymenter.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

apt install -y python3-certbot-nginx

# --- SSL ---
echo ""
echo "=============================="
echo "GENERATING SSL UNTUK $DOMAIN"
echo "PASTIKAN PROXY CLOUDFLARE DIMATIKAN!"
echo "=============================="
echo ""

certbot --nginx -d $DOMAIN --redirect --non-interactive --agree-tos -m admin@$DOMAIN

systemctl reload nginx
chown -R www-data:www-data /var/www/paymenter

echo ""
echo "========================================="
echo "         INSTALL PAYMENTER SELESAI!"
echo "========================================="
echo "URL: https://$DOMAIN"
echo "Login menggunakan akun admin yang barusan dibuat."
echo "Jika mengalami error atau kegagalan: systemctl status paymenter"
echo ""
