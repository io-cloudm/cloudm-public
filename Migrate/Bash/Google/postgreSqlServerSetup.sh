#!/bin/bash

exec > >(tee -a /var/log/startup-script.log /dev/console) 2>&1

PG_USER=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_user" -H "Metadata-Flavor: Google")
PG_PASSWORD=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/attributes/pg_password" -H "Metadata-Flavor: Google")

if [[ -z "$PG_USER" || -z "$PG_PASSWORD" ]]; then
    echo "ERROR: PG_USER and PG_PASSWORD must be set in instance metadata."
    exit 1
fi

echo "Updating system and installing dependencies..."
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl gnupg2 ufw

echo "Adding PostgreSQL repository..."
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/postgresql.asc > /dev/null
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

echo "Installing PostgreSQL 17.4..."
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y -qq postgresql-17

echo "Starting and enabling PostgreSQL service..."
systemctl enable --now postgresql

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

echo "Configuring PostgreSQL for remote access..."
PG_CONF="/etc/postgresql/17/main/postgresql.conf"
HBA_CONF="/etc/postgresql/17/main/pg_hba.conf"

sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" $PG_CONF
sed -i "s/^max_connections = 100/max_connections = 1500/" $PG_CONF
echo "host all all 0.0.0.0/0 md5" >> $HBA_CONF

echo "Restarting PostgreSQL..."
systemctl restart postgresql

echo "Allowing PostgreSQL traffic through firewall..."
ufw allow 5432/tcp > /dev/null

echo "Installing pgAdmin 4..."
curl -fsSL https://www.pgadmin.org/static/packages_pgadmin_org.pub | apt-key add
echo "deb https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list
apt update -qq && apt install -y -qq pgadmin4

echo "PostgreSQL 17.4 and pgAdmin 4 setup completed!"
