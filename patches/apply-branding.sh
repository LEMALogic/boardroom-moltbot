#!/bin/bash
# =============================================================================
# Boardroom Branding Patches
# =============================================================================
# This script applies all branding changes to transform Moltbot into Boardroom.
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
# File: ui/src/ui/app-render.ts
# Changes the header brand text from Moltbot to Boardroom

UI_APP_RENDER="$MOLTBOT_DIR/ui/src/ui/app-render.ts"

if [ -f "$UI_APP_RENDER" ]; then
    echo "  - Patching header branding..."

    # Brand title: MOLTBOT -> Boardroom
    sed -i 's/<div class="brand-title">MOLTBOT<\/div>/<div class="brand-title">Boardroom<\/div>/g' "$UI_APP_RENDER"

    # Brand subtitle: Gateway Dashboard -> for LEMA Logic
    sed -i 's/<div class="brand-sub">Gateway Dashboard<\/div>/<div class="brand-sub">for LEMA Logic<\/div>/g' "$UI_APP_RENDER"

    echo "    Done: app-render.ts"
else
    echo "  - Warning: $UI_APP_RENDER not found, skipping header branding"
fi

# -----------------------------------------------------------------------------
# Page Title (Future)
# -----------------------------------------------------------------------------
# TODO: Patch index.html or vite config to change page title from "Moltbot Control"
# to "Boardroom Command Center"

# -----------------------------------------------------------------------------
# Logo/Favicon (Future)
# -----------------------------------------------------------------------------
# TODO: Replace moltbot logo with Boardroom logo
# Files: ui/public/favicon.ico, ui/src/assets/logo.svg (if exists)

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "Branding patches applied successfully!"
echo ""
echo "Remaining manual steps:"
echo "  1. Run 'pnpm ui:build' to rebuild UI with new branding"
echo "  2. (Future) Replace logo/favicon assets"
echo "  3. (Future) Update page title in HTML template"
