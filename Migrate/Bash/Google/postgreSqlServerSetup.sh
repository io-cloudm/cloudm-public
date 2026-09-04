#!/bin/bash

exec > >(tee -a /var/log/startup-script.log /dev/console) 2>&1

set -o pipefail

PG_MAJOR=18

PG_USER=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_user" -H "Metadata-Flavor: Google")
PG_PASSWORD=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_password" -H "Metadata-Flavor: Google")

if [[ -z "$PG_USER" || -z "$PG_PASSWORD" ]]; then
    echo "ERROR: PG_USER and PG_PASSWORD must be set in instance metadata."
    exit 1
fi

echo "Updating system and installing dependencies..."
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl gnupg2 ufw locales

echo "Generating locales..."
# Dumps taken on a Windows-hosted PostgreSQL carry Windows locale names such as
# 'English_United States.1252', which glibc cannot resolve under any circumstances.
# These generate the closest usable equivalents; the restoring tool is responsible
# for not replaying the source locale (pg_restore --create does replay it).
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
sed -i 's/^# *\(en_GB.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

echo "Adding PostgreSQL repository..."
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/postgresql.asc > /dev/null
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

echo "Installing PostgreSQL ${PG_MAJOR}..."
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y -qq "postgresql-${PG_MAJOR}"

echo "Starting and enabling PostgreSQL service..."
systemctl enable --now postgresql

echo "Configuring PostgreSQL for remote access..."
PG_CONF="/etc/postgresql/${PG_MAJOR}/main/postgresql.conf"
HBA_CONF="/etc/postgresql/${PG_MAJOR}/main/pg_hba.conf"

# Match the setting whether the shipped default is commented out or not.
sed -i "s/^#\? *listen_addresses = .*/listen_addresses = '*'/" "$PG_CONF"
sed -i "s/^#\? *max_connections = .*/max_connections = 1500/" "$PG_CONF"

# md5 authentication is kept deliberately for client compatibility. PostgreSQL 14+
# defaults password_encryption to scram-sha-256, and an md5 hba line cannot
# authenticate a role whose stored password is a scram hash - so the encryption
# method is pinned to md5 and applied BEFORE the superuser's password is set.
sed -i "s/^#\? *password_encryption = .*/password_encryption = md5/" "$PG_CONF"
if ! grep -qE '^host\s+all\s+all\s+0\.0\.0\.0/0\s+md5' "$HBA_CONF"; then
    echo "host all all 0.0.0.0/0 md5" >> "$HBA_CONF"
fi

echo "Restarting PostgreSQL to apply authentication settings..."
systemctl restart postgresql

echo "Creating PostgreSQL superuser '$PG_USER'..."
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_USER') THEN
        CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD' SUPERUSER;
    END IF;
END
\$\$;
EOF

echo "Allowing PostgreSQL traffic through firewall..."
ufw allow 5432/tcp > /dev/null

echo "Installing pgAdmin 4..."
# apt-key is absent on Ubuntu 22.04+, so the key must be dearmored into
# trusted.gpg.d directly or the repository is added unverified.
curl -fsSL https://www.pgadmin.org/static/packages_pgadmin_org.pub \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgadmin.gpg
echo "deb https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list
apt update -qq && apt install -y -qq pgadmin4

INSTALLED_VERSION=$(sudo -u postgres psql -tAc 'SHOW server_version;' 2>/dev/null)
echo "PostgreSQL ${INSTALLED_VERSION} and pgAdmin 4 setup completed!"
