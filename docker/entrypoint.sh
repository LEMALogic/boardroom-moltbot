#!/bin/bash
# =============================================================================
# Boardroom Console Container Entrypoint
# =============================================================================
# This script runs at container startup and:
# 1. Installs the MITM proxy CA cert (mounted at runtime)
# 2. Runs runtime patches via /patches/patch_server.sh
# 3. Starts the SSH daemon
# 4. Starts the moltbot gateway
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Install MITM Proxy CA Certificate
# -----------------------------------------------------------------------------
CA_CERT="/etc/boardroom-proxy-certs/certs/ca.pem"
if [ -f "$CA_CERT" ]; then
    echo "Installing MITM proxy CA certificate..."
    cp "$CA_CERT" /usr/local/share/ca-certificates/boardroom-proxy.crt
    update-ca-certificates
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
else
    echo "Warning: MITM proxy CA cert not found at $CA_CERT"
    echo "HTTPS traffic may not be intercepted correctly."
fi

# -----------------------------------------------------------------------------
# Run Runtime Patches
# -----------------------------------------------------------------------------
if [ -f "/patches/patch_server.sh" ]; then
    /patches/patch_server.sh
fi

# -----------------------------------------------------------------------------
# Start SSH Daemon
# -----------------------------------------------------------------------------
echo "Starting SSH daemon..."
/usr/sbin/sshd

# -----------------------------------------------------------------------------
# Start Moltbot Gateway
# -----------------------------------------------------------------------------
echo "Starting Boardroom Command Center..."
cd /app/moltbot

exec su - boardroom -c "\
    export CLAWDBOT_GATEWAY_TOKEN=$CLAWDBOT_GATEWAY_TOKEN && \
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt && \
    export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt && \
    export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt && \
    source ~/.nvm/nvm.sh && \
    cd /app/moltbot && \
    pnpm run gateway:dev"
