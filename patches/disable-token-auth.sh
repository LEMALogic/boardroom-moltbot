#!/bin/bash
# =============================================================================
# Disable Token Authentication for Control UI
# =============================================================================
# This script patches moltbot to allow anonymous access to the Control UI
# when dangerouslyDisableDeviceAuth and allowInsecureAuth are both enabled.
#
# Security Note: Only use this when the gateway is behind authenticated
# reverse proxy (e.g., Cloudflare Tunnel with Access SSO).
#
# Usage: ./patches/disable-token-auth.sh /path/to/moltbot
# =============================================================================

set -e

MOLTBOT_DIR="${1:-/app/moltbot}"
MESSAGE_HANDLER="$MOLTBOT_DIR/src/gateway/server/ws-connection/message-handler.ts"

if [ ! -f "$MESSAGE_HANDLER" ]; then
    echo "Error: message-handler.ts not found: $MESSAGE_HANDLER"
    exit 1
fi

echo "Applying token auth bypass patch to $MOLTBOT_DIR..."

# Patch 1: Skip device identity check when allowControlUiBypass is true
# Original: const canSkipDevice = allowControlUiBypass ? hasSharedAuth : hasTokenAuth;
# Patched:  const canSkipDevice = allowControlUiBypass ? true : hasTokenAuth;
if grep -q 'const canSkipDevice = allowControlUiBypass ? hasSharedAuth : hasTokenAuth;' "$MESSAGE_HANDLER"; then
    sed -i 's/const canSkipDevice = allowControlUiBypass ? hasSharedAuth : hasTokenAuth;/const canSkipDevice = allowControlUiBypass ? true : hasTokenAuth;/' "$MESSAGE_HANDLER"
    echo "  - Patched: canSkipDevice bypass"
else
    echo "  - Warning: canSkipDevice patch target not found (may already be patched)"
fi

# Patch 2: Skip token auth check when allowControlUiBypass is true
# Original: let authOk = authResult.ok;
# Patched:  let authOk = authResult.ok || allowControlUiBypass;
if grep -q 'let authOk = authResult.ok;$' "$MESSAGE_HANDLER"; then
    sed -i 's/let authOk = authResult.ok;$/let authOk = authResult.ok || allowControlUiBypass;/' "$MESSAGE_HANDLER"
    echo "  - Patched: authOk bypass"
else
    echo "  - Warning: authOk patch target not found (may already be patched)"
fi

echo ""
echo "Token auth bypass patches applied successfully!"
echo ""
echo "IMPORTANT: Rebuild moltbot after patching:"
echo "  cd $MOLTBOT_DIR && pnpm build"
echo ""
echo "Required gateway config:"
echo '  "controlUi": {'
echo '    "dangerouslyDisableDeviceAuth": true,'
echo '    "allowInsecureAuth": true'
echo '  }'
