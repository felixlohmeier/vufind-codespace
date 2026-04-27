#!/bin/bash
# Fully automated VuFind installation for GitHub Codespaces testing.
# Installs VuFind via the official DEB package, sets up MariaDB, Apache and Solr.

set -e

VUFIND_VERSION="11.0.2"
VUFIND_HOME="/usr/local/vufind"
VUFIND_LOCAL_DIR="${VUFIND_HOME}/local"
DB_NAME="vufind"
DB_USER="vufind"
DB_PASS="vufind"

echo "=== Installing VuFind ${VUFIND_VERSION} ==="

# ── 1. Update package lists ────────────────────────────────────────────────────
echo "--- Updating package lists ---"
# Set DEBIAN_FRONTEND early so it is in the environment for all subsequent commands.
# Pass it explicitly to every sudo call so it is not stripped by sudo's env sanitiser.
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -q

# ── 2. Install MariaDB before VuFind DEB so it is preferred over MySQL ─────────
echo "--- Installing MariaDB ---"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q mariadb-server

# ── 3. Pre-seed debconf answers to avoid interactive prompts ──────────────────
# The VuFind DEB post-install script asks for a username to run Solr under.
# Pre-seeding the answer prevents the prompt from blocking the installation.
echo "--- Pre-seeding debconf ---"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q debconf-utils
echo "vufind vufind/solr-user string solr" | sudo debconf-set-selections

# ── 4. Download VuFind DEB package ────────────────────────────────────────────
echo "--- Downloading VuFind DEB ---"
wget -q \
    "https://github.com/vufind-org/vufind/releases/download/v${VUFIND_VERSION}/vufind_${VUFIND_VERSION}.deb" \
    -O /tmp/vufind.deb

# ── 5. Install VuFind DEB (first pass may fail with unresolved dependencies) ──
echo "--- Installing VuFind DEB ---"
sudo DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/vufind.deb || true
sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y -q

# ── 6. Run VuFind installer to create local configuration files ────────────────
# Accepts all defaults (VUFIND_HOME, VUFIND_LOCAL_DIR, base URL /vufind).
echo "--- Running VuFind installer ---"
cd "${VUFIND_HOME}"
printf '\n\n\n\n\n' | sudo php install.php || true

# ── 7. Set file permissions for Apache ────────────────────────────────────────
echo "--- Setting file permissions ---"
sudo chown -R www-data:www-data "${VUFIND_LOCAL_DIR}/cache"
sudo chown -R www-data:www-data "${VUFIND_LOCAL_DIR}/config"
sudo mkdir -p "${VUFIND_LOCAL_DIR}/cache/cli"
sudo chmod 777 "${VUFIND_LOCAL_DIR}/cache/cli"

# ── 8. Link Apache configuration (DEB may already have done this) ─────────────
echo "--- Configuring Apache ---"
if [ ! -f /etc/apache2/conf-enabled/vufind.conf ]; then
    sudo ln -s "${VUFIND_LOCAL_DIR}/httpd-vufind.conf" /etc/apache2/conf-enabled/vufind.conf
fi
sudo a2enmod rewrite

# ── 9. Write environment variables to profile.d ───────────────────────────────
echo "--- Setting environment variables ---"
sudo tee /etc/profile.d/vufind.sh > /dev/null << 'EOF'
export JAVA_HOME="/usr/lib/jvm/default-java"
export VUFIND_HOME="/usr/local/vufind"
export VUFIND_LOCAL_DIR="/usr/local/vufind/local"
EOF
# shellcheck disable=SC1091
source /etc/profile.d/vufind.sh

# ── 10. Start MariaDB and set up database ─────────────────────────────────────
echo "--- Starting MariaDB ---"
sudo service mariadb start
sleep 2

echo "--- Setting up VuFind database ---"
sudo mysql -uroot << SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT,INSERT,UPDATE,DELETE ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

sudo mysql -uroot "${DB_NAME}" < "${VUFIND_HOME}/module/VuFind/sql/mysql.sql"

# ── 11. Configure VuFind database connection in config.ini ────────────────────
echo "--- Configuring VuFind ---"
VUFIND_CONFIG="${VUFIND_LOCAL_DIR}/config/vufind/config.ini"
if [ -f "${VUFIND_CONFIG}" ]; then
    # Uncomment and update the connection line (handles both commented/uncommented variants)
    sudo sed -i \
        -e 's|^;connection = mysql://root@localhost/vufind|connection = mysql://vufind:vufind@localhost/vufind|' \
        -e 's|^connection = mysql://.*|connection = mysql://vufind:vufind@localhost/vufind|' \
        "${VUFIND_CONFIG}"
fi

# ── 12. Start Apache ──────────────────────────────────────────────────────────
echo "--- Starting Apache ---"
sudo service apache2 restart

# ── 13. Start Solr ────────────────────────────────────────────────────────────
echo "--- Starting Solr ---"
cd "${VUFIND_HOME}"
sudo SOLR_ULIMIT_CHECKS=false ./solr.sh start \
    || echo "WARNING: Solr could not be started. Run manually: cd /usr/local/vufind && sudo SOLR_ULIMIT_CHECKS=false ./solr.sh start"

echo ""
echo "=== VuFind ${VUFIND_VERSION} installation complete! ==="
echo "  VuFind:   http://localhost/vufind"
echo "  Solr UI:  http://localhost:8983/solr"
