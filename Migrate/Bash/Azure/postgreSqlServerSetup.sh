if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <username> <password>"
    exit 1
fi

PG_USER="$1"
PG_PASSWORD="$2"

echo "Updating system and installing dependencies..."
sudo apt update -qq && sudo apt upgrade -y -qq
sudo apt install -y -qq curl gnupg2

echo "Adding PostgreSQL repository..."
wget -qO - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/trusted.gpg.d/postgresql.asc > /dev/null
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null

echo "Installing PostgreSQL 17.4..."
sudo apt update -qq
sudo DEBIAN_FRONTEND=noninteractive apt install -y -qq postgresql-17

echo "Starting and enabling PostgreSQL service..."
sudo systemctl enable --now postgresql

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

echo "Configuring PostgreSQL for remote access..."
PG_CONF="/etc/postgresql/17/main/postgresql.conf"
HBA_CONF="/etc/postgresql/17/main/pg_hba.conf"

sudo sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" $PG_CONF
sudo sed -i "s/^max_connections = 100/max_connections = 1500/" $PG_CONF
echo "host all all 0.0.0.0/0 md5" | sudo tee -a $HBA_CONF > /dev/null

echo "Restarting PostgreSQL..."
sudo systemctl restart postgresql

echo "Opening PostgreSQL port 5432 in firewall..."
sudo ufw allow 5432/tcp > /dev/null

echo "Installing pgAdmin 4..."
sudo curl https://www.pgadmin.org/static/packages_pgadmin_org.pub | sudo apt-key add
sudo sh -c 'echo "deb https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list'
sudo apt update -qq && sudo apt install -y -qq pgadmin4

echo "PostgreSQL 17.4 and pgAdmin 4 setup completed!"
