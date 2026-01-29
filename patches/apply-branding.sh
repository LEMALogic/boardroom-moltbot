#!/bin/bash
# =============================================================================
# Boardroom Branding Patches
# =============================================================================
# This script applies branding changes to transform Moltbot into Boardroom.
# Run this BEFORE building the UI assets (pnpm ui:build).
#
# Usage: ./patches/apply-branding.sh /path/to/moltbot
# =============================================================================

set -e

MOLTBOT_DIR="${1:-/app/moltbot}"

if [ ! -d "$MOLTBOT_DIR" ]; then
    echo "Error: Moltbot directory not found: $MOLTBOT_DIR"
    exit 1
fi

echo "Applying Boardroom branding to $MOLTBOT_DIR..."

# -----------------------------------------------------------------------------
# UI Header Branding
# -----------------------------------------------------------------------------
UI_APP_RENDER="$MOLTBOT_DIR/ui/src/ui/app-render.ts"

if [ -f "$UI_APP_RENDER" ]; then
    echo "  - Patching header branding..."

    # Simple text replacements - these are the exact strings in the file
    sed -i 's/>MOLTBOT</>BOARDROOM</g' "$UI_APP_RENDER"

    # Replace subtitle with dynamic user email from BOARDROOM_CONFIG
    # Falls back to "Boardroom Dashboard" if no email configured
    sed -i 's/>Gateway Dashboard</${(window as any).BOARDROOM_CONFIG?.userEmail || "Boardroom Dashboard"}</g' "$UI_APP_RENDER"

    # Remove the lobster logo (whole line containing mintcdn)
    sed -i '/mintcdn\.com/d' "$UI_APP_RENDER"

    # Remove the brand-logo div but keep brand-text structure intact
    # The original structure is:
    #   <div class="brand">
    #     <div class="brand-logo">...</div>
    #     <div class="brand-text">
    # We remove brand-logo div lines, leaving:
    #   <div class="brand">
    #     <div class="brand-text">
    sed -i '/<div class="brand-logo">/d' "$UI_APP_RENDER"

    echo "    Done: app-render.ts"
else
    echo "  - Warning: $UI_APP_RENDER not found, skipping header branding"
fi

# -----------------------------------------------------------------------------
# Page Title
# -----------------------------------------------------------------------------
UI_INDEX_HTML="$MOLTBOT_DIR/ui/index.html"

if [ -f "$UI_INDEX_HTML" ]; then
    echo "  - Patching page title..."
    # Replace Moltbot Control with Boardroom
    sed -i 's/Moltbot Control/Boardroom/g' "$UI_INDEX_HTML"
    echo "    Done: index.html"
else
    echo "  - Warning: $UI_INDEX_HTML not found, skipping page title"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "Branding patches applied successfully!"
echo ""
echo "Changes made:"
echo "  - Header: MOLTBOT -> BOARDROOM"
echo "  - Subtitle: Dynamic from BOARDROOM_CONFIG.userEmail (falls back to 'Boardroom Dashboard')"
echo "  - Page title: Moltbot Control -> Boardroom"
echo "  - Removed lobster logo"
echo ""
echo "Next step: Run 'pnpm ui:build' to rebuild UI"

# -----------------------------------------------------------------------------
# Logout Button (FUTURE)
# -----------------------------------------------------------------------------
# To add a logout button in the future, you'll need to:
# 1. Add renderLogoutButton function to app-render.ts
# 2. Add logout icon to icons.ts
# 3. Add logout styles to CSS
# 4. Call renderLogoutButton in the topbar-status section
#
# The file to modify is: /app/moltbot/ui/src/ui/app-render.ts
# Look for the topbar-status section and add the button before renderThemeToggle
