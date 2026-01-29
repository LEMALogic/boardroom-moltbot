#!/bin/bash
# =============================================================================
# Inject User Email into BOARDROOM_CONFIG
# =============================================================================
# This script injects the BOARDROOM_USER_EMAIL env var into the built UI's
# index.html at container startup time.
#
# Usage: Called by entrypoint.sh on container start
# Env: BOARDROOM_USER_EMAIL - email to display in header
# =============================================================================

INDEX_HTML="/app/moltbot/dist/control-ui/index.html"

if [ -z "$BOARDROOM_USER_EMAIL" ]; then
    echo "BOARDROOM_USER_EMAIL not set, using default 'Boardroom Dashboard'"
    exit 0
fi

if [ ! -f "$INDEX_HTML" ]; then
    echo "Warning: $INDEX_HTML not found, skipping email injection"
    exit 0
fi

echo "Injecting user email into UI: $BOARDROOM_USER_EMAIL"

# Replace the empty BOARDROOM_CONFIG with one containing the email
sed -i "s/window.BOARDROOM_CONFIG = window.BOARDROOM_CONFIG || {};/window.BOARDROOM_CONFIG = {userEmail: \"$BOARDROOM_USER_EMAIL\"};/" "$INDEX_HTML"

echo "Done: User email injected into header"
