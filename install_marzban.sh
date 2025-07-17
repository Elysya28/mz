marzneshin#!/bin/bash

set -e
# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g., with sudo su)" >&2
  exit 1
fi
# Define the domain for your Marzban instance
read -p "Enter your domain for Marzban: " DOMAIN
read -p "Enter your email for SSL certificate: " MAIL


# Update the system and install necessary packages
apt update -qq -y && apt upgrade -y
apt install curl wget git ufw gnupg2 lsb-release socat tree net-tools vnstat iptables xz-utils apt-transport-https dnsutils cron bash-completion -y

# Install speedtest
echo "Checking for existing speedtest installation..."
if command -v speedtest >/dev/null 2>&1; then
    echo "speedtest is already installed. Skipping installation."
else
    echo "Installing speedtest..."
    wget -q https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz > /dev/null 2>&1
    tar xzf ookla-speedtest-1.2.0-linux-x86_64.tgz > /dev/null 2>&1
    mv speedtest /usr/bin/
    rm -f ookla-* speedtest.* > /dev/null 2>&1
fi

# Enable BBR
echo "Enabling BBR congestion control..."
modprobe tcp_bbr >/dev/null 2>&1
echo "tcp_bbr" | tee -a /etc/modules-load.d/modules.conf
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "BBR has been enabled."
else
  echo "Failed to enable BBR."
fi
sysctl -p >/dev/null 2>&1

rm -Rf /opt/marzban >/dev/null 2>&1 || true
# Install Marzban
marzban down >/dev/null 2>&1 || true

rm -Rf /opt/marzban >/dev/null 2>&1 || true
rm -Rf /var/lib/marzban >/dev/null 2>&1 || true

bash -c "$(curl -sL https://github.com/nationpwned/mz/raw/refs/heads/main/marzban)" @ install
sleep 50

marzban cli admin create --sudo

[ -f /$HOME/reality.txt ] && rm -f /$HOME/reality.txt
[ -f /$HOME/shortIds.txt ] && rm -f /$HOME/shortIds.txt
[ -f /$HOME/xray_uuid.txt ] && rm -f /$HOME/xray_uuid.txt

# Generate Reality keys
echo "Generating Reality keys..."
docker exec marzban-marzban-1 xray x25519 genkey > /$HOME/reality.txt
PRIVATE_KEY=$(grep -oP 'Private key: \K\S+' /$HOME/reality.txt)
PUBLIC_KEY=$(grep -oP 'Public key: \K\S+' /$HOME/reality.txt)

# Generate shortIds
echo "Generating shortIds..."
openssl rand -hex 8 > /$HOME/shortIds.txt
SHORTIDS=$(cat /$HOME/shortIds.txt)

# Generating uuid for Reality
echo "Generating UUID for Reality..."
if ! docker ps | grep -q marzban-marzban-1; then
  echo "Marzban container not running! Exiting."
  exit 1
fi
docker exec marzban-marzban-1 xray uuid > /$HOME/xray_uuid.txt
XRAY_UUID=$(cat /$HOME/xray_uuid.txt)
if [[ -z "$XRAY_UUID" ]]; then
  echo "Failed to generate UUID. Exiting."
  exit 1
fi

# Check if certificate already exists
rm -Rf /var/lib/marzban/certs >/dev/null 2>&1 || true
if [[ -f "/var/lib/marzban/certs/fullchain.pem" && -f "/var/lib/marzban/certs/key.pem" ]]; then
    echo "SSL certificate already exists. Skipping certificate installation."
else
    # Install Certificate using acme.sh
    su -c "curl https://get.acme.sh | sh -s email=$MAIL"
    mkdir -p /var/lib/marzban/certs
    su -c "~/.acme.sh/acme.sh --issue --force --standalone -d \"$DOMAIN\" --fullchain-file \"/var/lib/marzban/certs/fullchain.pem\" --key-file \"/var/lib/marzban/certs/key.pem\""
    marzban down

    # Set proper permissions
    chmod 600 "/var/lib/marzban/certs/key.pem"
    chmod 644 "/var/lib/marzban/certs/fullchain.pem"
fi

wget -O /opt/marzban/.env https://github.com/nationpwned/mz/raw/refs/heads/main/env-marzban
# Download docker-compose.yml
wget -O /opt/marzban/docker-compose.yml https://github.com/nationpwned/mz/raw/refs/heads/main/docker-compose_marzban.yml

wget -O /opt/marzban/.env https://raw.githubusercontent.com/nationpwned/mz/refs/heads/main/env-marzban
# Download nginx.conf
wget -O /opt/marzban/nginx.conf https://raw.githubusercontent.com/nationpwned/mz/refs/heads/main/nginx_marzban.conf
# Replace placeholders in nginx.conf with user input
sed -i "s/server_name \$DOMAIN;/server_name $DOMAIN;/" /opt/marzban/nginx.conf

# Download xray_config.json
wget -O /var/lib/marzban/xray_config.json https://raw.githubusercontent.com/nationpwned/mz/refs/heads/main/nginx_marzban.conf

sed -i "s/YOUR_UUID/$XRAY_UUID/" /var/lib/marzban/xray_config.json

# Download the subscribers Marzban
mkdir -p /var/lib/marzban/templates/subscription/
wget -N -P /var/lib/marzban/templates/subscription/ https://github.com/nationpwned/mz/raw/refs/heads/main/index.html

ufw --force enable
# Firewall configuration
echo "Configuring firewall..."
ufw allow 8000/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
ufw allow 2021/tcp
ufw allow 2022/tcp
ufw allow 2023/tcp
ufw allow 2024/tcp
ufw allow 51820/tcp
ufw allow 51821/tcp
ufw allow 51822/tcp
ufw allow 51823/tcp
ufw allow 51824/tcp
ufw allow 51825/tcp

ufw --force enable

# Cloudflare Warp installation
echo "Installing Cloudflare Warp..."
docker compose -f /opt/marzban/docker-compose.yml up -d

# Ensure /opt/marzban/wgcf directory is fresh
if [ -d /opt/marzban/wgcf ]; then
  rm -rf /opt/marzban/wgcf
fi
mkdir -p /opt/marzban/wgcf

# Download wgcf binary
WGCF_LATEST_URL=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep "browser_download_url" | grep "linux_amd64" | cut -d '"' -f 4)
wget "$WGCF_LATEST_URL" -O /usr/local/bin/wgcf

chmod +x /usr/local/bin/wgcf
# Configure Cloudflare Warp
echo "Configuring Cloudflare Warp..."
wgcf register --accept-tos
wgcf generate
mv wgcf-profile.conf /opt/marzban/wgcf/wg0.conf
mv wgcf-account.toml /opt/marzban/wgcf/
sed -i -E 's/, [0-9a-f:]+\/128//; s/, ::\/0//' /opt/marzban/wgcf/wg0.conf
sleep 3
docker restart wgcf-warp
sleep 5

echo "==============================================="
# Check Cloudflare Warp status (Cloudflare and ip-api.com)
if docker exec wgcf-warp curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    echo "Cloudflare Warp is ON (Cloudflare trace)."
else
    echo "Cloudflare Warp is OFF (Cloudflare trace)."
fi

if docker exec wgcf-warp curl -s http://ip-api.com/json | grep -q 'Cloudflare WARP'; then
    echo "Cloudflare Warp is ON (ip-api.com check)."
else
    echo "Cloudflare Warp is OFF or not detected by ip-api.com."
fi

echo "==============================================="
echo "private key: $PRIVATE_KEY"
echo "public key: $PUBLIC_KEY"
echo "ShortIds: $SHORTIDS"
echo "UUID: $XRAY_UUID"
echo "==============================================="

echo "Marzban installation and configuration completed successfully!"
echo "You can access Marzban at https://$DOMAIN"
echo "Make sure to configure your Xray clients with the provided Reality keys and UUID."
echo "==============================================="


read -p "Do you want to reboot now? [Y/n]: " answer
answer=${answer:-Y}
if [[ "$answer" =~ ^[Yy]$ ]]; then
  echo "Rebooting system..."
  reboot
else
  echo "Reboot cancelled. Please reboot manually if needed."
fi

