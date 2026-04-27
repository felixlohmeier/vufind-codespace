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
SOLR_USER="codespace"

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
echo "vufind vufind/solr-user string ${SOLR_USER}" | sudo debconf-set-selections

# ── 4. Download VuFind DEB package ────────────────────────────────────────────
echo "--- Downloading VuFind DEB ---"
wget -q \
    "https://github.com/vufind-org/vufind/releases/download/v${VUFIND_VERSION}/vufind_${VUFIND_VERSION}.deb" \
    -O /tmp/vufind.deb

# ── 5. Install VuFind DEB via apt (resolves dependencies automatically) ───────
echo "--- Installing VuFind DEB ---"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q /tmp/vufind.deb

# ── 6. Run VuFind installer to create local configuration files ────────────────
# Accepts all defaults (VUFIND_HOME, VUFIND_LOCAL_DIR, base URL /vufind).
echo "--- Running VuFind installer ---"
cd "${VUFIND_HOME}"
printf '\n\n\n\n\n' | sudo php install.php || true

# If install.php did not create config.ini (e.g. because it ran non-interactively
# without fully completing), fall back to copying the global config template.
if [ ! -f "${VUFIND_LOCAL_DIR}/config/vufind/config.ini" ]; then
    sudo mkdir -p "${VUFIND_LOCAL_DIR}/config/vufind"
    sudo install -o www-data -g www-data -m 644 \
        "${VUFIND_HOME}/config/vufind/config.ini" \
        "${VUFIND_LOCAL_DIR}/config/vufind/config.ini"
fi

# ── 7. Set file permissions for Apache ────────────────────────────────────────
echo "--- Setting file permissions ---"
sudo chown -R www-data:www-data "${VUFIND_LOCAL_DIR}/cache"
sudo chown -R www-data:www-data "${VUFIND_LOCAL_DIR}/config"
sudo mkdir -p "${VUFIND_LOCAL_DIR}/cache/cli"
sudo chmod 777 "${VUFIND_LOCAL_DIR}/cache/cli"

# Ensure the non-root app user can start Solr and write logs/index data.
sudo mkdir -p "${VUFIND_HOME}/solr/vufind/logs"
SOLR_GROUP="$(id -gn "${SOLR_USER}" 2>/dev/null || true)"
if [ -z "${SOLR_GROUP}" ]; then
    SOLR_GROUP="${SOLR_USER}"
fi
sudo chown -R "${SOLR_USER}:${SOLR_GROUP}" "${VUFIND_HOME}/solr/vufind"

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

if ! sudo mysql -uroot "${DB_NAME}" < "${VUFIND_HOME}/module/VuFind/sql/mysql.sql"; then
    echo "WARNING: Initial schema import returned a non-zero status (often because tables already exist)."
    echo "         Continuing setup so config rewriting and service startup still run."
fi

# ── 11. Configure VuFind database connection in config.ini ────────────────────
echo "--- Configuring VuFind ---"
VUFIND_CONFIG="${VUFIND_LOCAL_DIR}/config/vufind/config.ini"
if [ -f "${VUFIND_CONFIG}" ]; then
    # Apply key values that are otherwise left for /Install/Home fixes.
    # Use a line-based section-aware rewrite to avoid brittle regex side effects.
    ILS_ENCRYPTION_KEY="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
    TMP_CONFIG="$(mktemp)"
    awk \
        -v db_user="${DB_USER}" \
        -v db_pass="${DB_PASS}" \
        -v db_name="${DB_NAME}" \
        -v ils_key="${ILS_ENCRYPTION_KEY}" '
            BEGIN {
                in_catalog = 0
                in_database = 0
            }

            {
                line = $0
                # Normalise optional CR from CRLF files so strict matches still work.
                sub(/\r$/, "", line)
            }

            line ~ /^\[[^]]+\][[:space:]]*$/ {
                in_catalog = (line == "[Catalog]")
                in_database = (line == "[Database]")
            }

            line ~ /^[[:space:]]*autoConfigure[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
                print "autoConfigure = false"
                next
            }

            line ~ /^[[:space:]]*available[[:space:]]*=[[:space:]]*false[[:space:]]*$/ {
                print "available       = true"
                next
            }

            line ~ /^[[:space:]]*url[[:space:]]*=[[:space:]]*"?http:\/\/library\.myuniversity\.edu\/vufind"?[[:space:]]*$/ {
                print "url = http://localhost/vufind"
                next
            }

            in_catalog && line ~ /^[[:space:]]*driver[[:space:]]*=/ {
                print "driver          = NoILS"
                next
            }

            in_database && line ~ /^[[:space:]]*database[[:space:]]*=/ {
                print "database          = mysql://" db_user ":" db_pass "@localhost/" db_name
                next
            }

            line ~ /^[[:space:]]*encrypt_ils_password[[:space:]]*=/ {
                print "encrypt_ils_password = true"
                next
            }

            line ~ /^[[:space:]]*ils_encryption_key[[:space:]]*=/ {
                print "ils_encryption_key = \"" ils_key "\""
                next
            }

            {
                print line
            }
        ' "${VUFIND_CONFIG}" > "${TMP_CONFIG}"
    sudo install -o www-data -g www-data -m 644 "${TMP_CONFIG}" "${VUFIND_CONFIG}"
    rm -f "${TMP_CONFIG}"
else
    echo "WARNING: VuFind config not found at expected path: ${VUFIND_CONFIG}"
fi

# Configure NoILS to avoid global offline mode message on the homepage.
echo "--- Configuring NoILS ---"
VUFIND_NOILS_LOCAL="${VUFIND_LOCAL_DIR}/config/vufind/NoILS.ini"
VUFIND_NOILS_TEMPLATE="${VUFIND_HOME}/config/vufind/NoILS.ini"
if [ ! -f "${VUFIND_NOILS_LOCAL}" ] && [ -f "${VUFIND_NOILS_TEMPLATE}" ]; then
    sudo install -o www-data -g www-data -m 644 \
        "${VUFIND_NOILS_TEMPLATE}" \
        "${VUFIND_NOILS_LOCAL}"
fi

if [ -f "${VUFIND_NOILS_LOCAL}" ]; then
    TMP_NOILS="$(mktemp)"
    awk '
        /^[[:space:]]*mode[[:space:]]*=/ {
            print "mode = ils-none"
            next
        }

        {
            print $0
        }
    ' "${VUFIND_NOILS_LOCAL}" > "${TMP_NOILS}"
    sudo install -o www-data -g www-data -m 644 "${TMP_NOILS}" "${VUFIND_NOILS_LOCAL}"
    rm -f "${TMP_NOILS}"
else
    echo "WARNING: NoILS config not found at expected path: ${VUFIND_NOILS_LOCAL}"
fi

# ── 12. Start Apache ──────────────────────────────────────────────────────────
echo "--- Starting Apache ---"
sudo service apache2 restart

# ── 13. Start Solr ────────────────────────────────────────────────────────────
echo "--- Starting Solr ---"
cd "${VUFIND_HOME}"
sudo mkdir -p "${VUFIND_HOME}/solr/vufind/logs" 2>/dev/null || true
sudo chown -R "${SOLR_USER}:${SOLR_USER}" "${VUFIND_HOME}/solr/vufind" 2>/dev/null || true

if [ "$(id -un)" = "${SOLR_USER}" ]; then
    env SOLR_ULIMIT_CHECKS=false SOLR_ADDITIONAL_START_OPTIONS="--force" ./solr.sh start
    SOLR_EXIT_CODE=$?
else
    sudo -n -u "${SOLR_USER}" env SOLR_ULIMIT_CHECKS=false SOLR_ADDITIONAL_START_OPTIONS="--force" ./solr.sh start
    SOLR_EXIT_CODE=$?
fi

if [ "${SOLR_EXIT_CODE}" -ne 0 ]; then
    echo "WARNING: Solr could not be started."
    echo "         Run manually: cd /usr/local/vufind && SOLR_ULIMIT_CHECKS=false SOLR_ADDITIONAL_START_OPTIONS=\"--force\" ./solr.sh start"
fi

# ── 14. Index test records ────────────────────────────────────────────────────
echo "--- Waiting for Solr to be ready ---"
for i in $(seq 1 30); do
    if curl -sf http://localhost:8983/solr/ > /dev/null 2>&1; then
        echo "Solr is ready."
        break
    fi
    sleep 2
done

echo "--- Indexing test records ---"
export JAVA_HOME="/usr/lib/jvm/default-java"
export VUFIND_HOME="/usr/local/vufind"
export VUFIND_LOCAL_DIR="/usr/local/vufind/local"
sudo -E "${VUFIND_HOME}/import-marc.sh" "${VUFIND_HOME}/tests/data/journals.mrc"      || true
sudo -E "${VUFIND_HOME}/import-marc.sh" "${VUFIND_HOME}/tests/data/geo.mrc"           || true
sudo -E "${VUFIND_HOME}/import-marc.sh" "${VUFIND_HOME}/tests/data/authoritybibs.mrc" || true

echo ""
echo "=== VuFind ${VUFIND_VERSION} installation complete! ==="
echo "  VuFind:   http://localhost/vufind"
echo "  Solr UI:  http://localhost:8983/solr"
