#!/bin/bash
# Generate CA certificate for HTTPS MITM proxy
# This CA will be used to sign certificates for intercepted HTTPS connections

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Generate CA private key
openssl genrsa -out ca.key 4096

# Generate CA certificate (valid for 10 years)
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/C=IM/ST=Isle of Man/L=Douglas/O=LEMA Logic/OU=Boardroom Proxy/CN=Boardroom MITM CA"

# Create combined PEM file
cat ca.crt ca.key > ca.pem

echo "CA certificate generated:"
echo "  - ca.key (private key)"
echo "  - ca.crt (certificate)"
echo "  - ca.pem (combined)"
echo ""
echo "Install ca.crt in the console container to trust MITM connections."
