#!/bin/bash

set -o pipefail

PG_MAJOR=18

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <username> <password>"
    exit 1
fi

PG_USER="$1"
PG_PASSWORD="$2"

echo "Updating system and installing dependencies..."
sudo apt update -qq && sudo apt upgrade -y -qq
sudo apt install -y -qq curl gnupg2 ufw locales

echo "Generating locales..."
# A dump taken on a Windows-hosted PostgreSQL records a Windows locale name such
# as 'English_United States.1252', which glibc cannot resolve. These generate the
# closest usable equivalents so the server has a real UTF-8 locale to fall back on.
sudo sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sudo sed -i 's/^# *\(en_GB.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=en_US.UTF-8

echo "Adding PostgreSQL repository..."
wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/trusted.gpg.d/postgresql.asc > /dev/null
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null

echo "Installing PostgreSQL ${PG_MAJOR}..."
sudo apt update -qq
sudo DEBIAN_FRONTEND=noninteractive apt install -y -qq "postgresql-${PG_MAJOR}"

echo "Starting and enabling PostgreSQL service..."
sudo systemctl enable --now postgresql

echo "Configuring PostgreSQL for remote access..."
PG_CONF="/etc/postgresql/${PG_MAJOR}/main/postgresql.conf"
HBA_CONF="/etc/postgresql/${PG_MAJOR}/main/pg_hba.conf"

# Match the setting whether the shipped default is commented out or not.
sudo sed -i "s/^#\? *listen_addresses = .*/listen_addresses = '*'/" "$PG_CONF"
sudo sed -i "s/^#\? *max_connections = .*/max_connections = 1500/" "$PG_CONF"

# md5 authentication is kept for client compatibility. PostgreSQL 14+ defaults
# password_encryption to scram-sha-256, and an md5 hba line cannot authenticate a
# role whose stored password is a scram hash - so the encryption method is pinned
# and applied BEFORE the superuser's password is set.
sudo sed -i "s/^#\? *password_encryption = .*/password_encryption = md5/" "$PG_CONF"
if ! sudo grep -qE '^host\s+all\s+all\s+0\.0\.0\.0/0\s+md5' "$HBA_CONF"; then
    echo "host all all 0.0.0.0/0 md5" | sudo tee -a "$HBA_CONF" > /dev/null
fi

echo "Restarting PostgreSQL to apply authentication settings..."
sudo systemctl restart postgresql

echo "Configuring PostgreSQL superuser '$PG_USER'..."
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_USER') THEN
        CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD' SUPERUSER;
    END IF;
END
\$\$;
EOF

echo "Opening PostgreSQL port 5432 in firewall..."
sudo ufw allow 5432/tcp > /dev/null

echo "Installing pgAdmin 4..."
# apt-key was removed in Ubuntu 22.04, so the key must be dearmored into
# trusted.gpg.d directly or the repository is added unverified.
curl -fsSL https://www.pgadmin.org/static/packages_pgadmin_org.pub \
    | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/pgadmin.gpg
sudo sh -c 'echo "deb https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list'
sudo apt update -qq && sudo apt install -y -qq pgadmin4

INSTALLED_VERSION=$(sudo -u postgres psql -tAc 'SHOW server_version;' 2>/dev/null)
echo "PostgreSQL ${INSTALLED_VERSION} and pgAdmin 4 setup completed!"
