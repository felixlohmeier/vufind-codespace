#!/bin/bash
# Start VuFind services after a Codespace has been resumed.
# This script is run automatically via postStartCommand in devcontainer.json.

export JAVA_HOME="/usr/lib/jvm/default-java"
export VUFIND_HOME="/usr/local/vufind"
export VUFIND_LOCAL_DIR="/usr/local/vufind/local"
SOLR_USER="codespace"

# Start database
sudo service mariadb start 2>/dev/null || sudo service mysql start 2>/dev/null || true

# Start web server
sudo service apache2 start 2>/dev/null || true

# Start Solr (only when VuFind is already installed)
if [ -f "${VUFIND_HOME}/solr.sh" ]; then
    cd "${VUFIND_HOME}"
    sudo mkdir -p "${VUFIND_HOME}/solr/vufind/logs" 2>/dev/null || true
    sudo chown -R "${SOLR_USER}:${SOLR_USER}" "${VUFIND_HOME}/solr/vufind" 2>/dev/null || true

    if [ "$(id -un)" = "${SOLR_USER}" ]; then
        env SOLR_ULIMIT_CHECKS=false SOLR_ADDITIONAL_START_OPTIONS="--force" ./solr.sh start 2>/dev/null || true
    else
        sudo -n -u "${SOLR_USER}" env SOLR_ULIMIT_CHECKS=false SOLR_ADDITIONAL_START_OPTIONS="--force" ./solr.sh start 2>/dev/null \
            || true
    fi
fi
