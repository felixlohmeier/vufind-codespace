#!/bin/bash
# Start VuFind services after a Codespace has been resumed.
# This script is run automatically via postStartCommand in devcontainer.json.

export JAVA_HOME="/usr/lib/jvm/default-java"
export VUFIND_HOME="/usr/local/vufind"
export VUFIND_LOCAL_DIR="/usr/local/vufind/local"

# Start database
sudo service mariadb start 2>/dev/null || sudo service mysql start 2>/dev/null || true

# Start web server
sudo service apache2 start 2>/dev/null || true

# Start Solr (only when VuFind is already installed)
if [ -f "${VUFIND_HOME}/solr.sh" ]; then
    cd "${VUFIND_HOME}"
    sudo SOLR_ULIMIT_CHECKS=false ./solr.sh start 2>/dev/null \
        || true
fi
