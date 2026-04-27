#!/bin/bash
# Start VuFind services after a Codespace has been resumed.
# This script is run automatically via postStartCommand in devcontainer.json.

export JAVA_HOME="/usr/lib/jvm/default-java"
export VUFIND_HOME="/usr/local/vufind"
export VUFIND_LOCAL_DIR="/usr/local/vufind/local"
APP_USER="codespace"
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    APP_USER="$(id -un)"
fi

# Start database
sudo service mariadb start 2>/dev/null || sudo service mysql start 2>/dev/null || true

# Start web server
sudo service apache2 start 2>/dev/null || true

# Start Solr (only when VuFind is already installed)
if [ -f "${VUFIND_HOME}/solr.sh" ]; then
    cd "${VUFIND_HOME}"
    if [ "$(id -u)" -eq 0 ]; then
        runuser -u "${APP_USER}" -- env SOLR_ULIMIT_CHECKS=false SOLR_ADDITIONAL_START_OPTIONS="--force" ./solr.sh start 2>/dev/null \
            || true
    else
        env SOLR_ULIMIT_CHECKS=false SOLR_ADDITIONAL_START_OPTIONS="--force" ./solr.sh start 2>/dev/null \
            || true
    fi
fi
