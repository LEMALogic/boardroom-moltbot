#!/bin/bash
# =============================================================================
# Multi-Architecture Build Script for Boardroom Console
# =============================================================================
# This script builds ARM64 and AMD64 images using native builds on each
# platform, then combines them into a multi-arch manifest.
#
# Strategy:
#   - ARM64: Built natively on Mac (fast)
#   - AMD64: Built natively on Hetzner server (fast)
#   - Avoids QEMU emulation which would take 2-4+ hours
#
# Prerequisites:
#   - Docker with buildx enabled
#   - SSH access to Hetzner server (configured in ~/.ssh/config as boardroom.prod)
#   - Authenticated to ghcr.io: echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
#
# Usage:
#   ./scripts/build-multiarch.sh [--console-only] [--proxy-only] [--multi-arch]
#
# Default: AMD64-only (builds on Hetzner, ~3 min total)
# Use --multi-arch to build both ARM64+AMD64 (~13 min, requires Mac upload)
# =============================================================================

set -e

# Configuration
REGISTRY="ghcr.io/lemalogic"
HETZNER_HOST="boardroom.prod"
HETZNER_BUILD_DIR="/tmp/boardroom-build"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
BUILD_CONSOLE=true
BUILD_PROXY=true
AMD64_ONLY=true  # Default to AMD64-only (faster, test on server)

for arg in "$@"; do
    case $arg in
        --console-only)
            BUILD_PROXY=false
            ;;
        --proxy-only)
            BUILD_CONSOLE=false
            ;;
        --multi-arch)
            AMD64_ONLY=false
            ;;
        --help)
            echo "Usage: $0 [--console-only] [--proxy-only] [--multi-arch]"
            echo ""
            echo "Options:"
            echo "  --console-only   Only build the console image"
            echo "  --proxy-only     Only build the proxy image"
            echo "  --multi-arch     Build both ARM64+AMD64 (default: AMD64-only)"
            exit 0
            ;;
    esac
done

# Track timing
TOTAL_START=$(date +%s)

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1"
    exit 1
}

# Ensure buildx builder exists
ensure_builder() {
    if ! docker buildx inspect multiarch &>/dev/null; then
        log "Creating multiarch builder..."
        docker buildx create --name multiarch --driver docker-container --bootstrap --use
    else
        docker buildx use multiarch
    fi
}

# Copy build context to Hetzner
copy_to_hetzner() {
    local dockerfile=$1
    log "Copying build context to Hetzner..."

    ssh "$HETZNER_HOST" "rm -rf $HETZNER_BUILD_DIR && mkdir -p $HETZNER_BUILD_DIR/docker $HETZNER_BUILD_DIR/patches $HETZNER_BUILD_DIR/api-proxy"

    scp "$PROJECT_ROOT/docker/$dockerfile" "$HETZNER_HOST:$HETZNER_BUILD_DIR/docker/"

    if [ -d "$PROJECT_ROOT/patches" ]; then
        scp -r "$PROJECT_ROOT/patches/"* "$HETZNER_HOST:$HETZNER_BUILD_DIR/patches/" 2>/dev/null || true
    fi

    if [ -d "$PROJECT_ROOT/api-proxy" ]; then
        scp -r "$PROJECT_ROOT/api-proxy/"* "$HETZNER_HOST:$HETZNER_BUILD_DIR/api-proxy/" 2>/dev/null || true
    fi
}

# Build and push ARM64 image (on Mac)
build_arm64() {
    local image_name=$1
    local dockerfile=$2
    local context=$3

    if [ "$AMD64_ONLY" = true ]; then
        log "Skipping ARM64 build (--amd64-only specified)"
        return 0
    fi

    log "Building ARM64 $image_name on Mac..."
    local start=$(date +%s)

    docker buildx build \
        --platform linux/arm64 \
        -t "$REGISTRY/$image_name:arm64" \
        -f "$PROJECT_ROOT/docker/$dockerfile" \
        --push \
        "$context"

    local end=$(date +%s)
    log "ARM64 $image_name completed in $((end - start)) seconds"
}

# Build and push AMD64 image (on Hetzner)
build_amd64() {
    local image_name=$1
    local dockerfile=$2

    log "Building AMD64 $image_name on Hetzner..."
    local start=$(date +%s)

    ssh "$HETZNER_HOST" "cd $HETZNER_BUILD_DIR && docker build -t $REGISTRY/$image_name:amd64 -f docker/$dockerfile . && docker push $REGISTRY/$image_name:amd64"

    local end=$(date +%s)
    log "AMD64 $image_name completed in $((end - start)) seconds"
}

# Create multi-arch manifest
create_manifest() {
    local image_name=$1

    log "Creating multi-arch manifest for $image_name..."

    if [ "$AMD64_ONLY" = true ]; then
        # Just tag amd64 as latest
        docker buildx imagetools create -t "$REGISTRY/$image_name:latest" "$REGISTRY/$image_name:amd64"
    else
        docker buildx imagetools create -t "$REGISTRY/$image_name:latest" \
            "$REGISTRY/$image_name:arm64" \
            "$REGISTRY/$image_name:amd64"
    fi

    log "Manifest created: $REGISTRY/$image_name:latest"
}

# Main build flow
main() {
    log "Starting multi-architecture build"
    log "Project root: $PROJECT_ROOT"

    ensure_builder

    # Build Console
    if [ "$BUILD_CONSOLE" = true ]; then
        log "=== Building boardroom-console ==="
        copy_to_hetzner "Dockerfile.console"

        # Run builds in parallel
        if [ "$AMD64_ONLY" = true ]; then
            build_amd64 "boardroom-console" "Dockerfile.console"
        else
            build_arm64 "boardroom-console" "Dockerfile.console" "$PROJECT_ROOT" &
            ARM64_PID=$!
            build_amd64 "boardroom-console" "Dockerfile.console" &
            AMD64_PID=$!

            wait $ARM64_PID || error "ARM64 console build failed"
            wait $AMD64_PID || error "AMD64 console build failed"
        fi

        create_manifest "boardroom-console"
    fi

    # Build Proxy
    if [ "$BUILD_PROXY" = true ]; then
        log "=== Building boardroom-proxy ==="
        copy_to_hetzner "Dockerfile.proxy"

        if [ "$AMD64_ONLY" = true ]; then
            build_amd64 "boardroom-proxy" "Dockerfile.proxy"
        else
            build_arm64 "boardroom-proxy" "Dockerfile.proxy" "$PROJECT_ROOT/api-proxy" &
            ARM64_PID=$!
            build_amd64 "boardroom-proxy" "Dockerfile.proxy" &
            AMD64_PID=$!

            wait $ARM64_PID || error "ARM64 proxy build failed"
            wait $AMD64_PID || error "AMD64 proxy build failed"
        fi

        create_manifest "boardroom-proxy"
    fi

    # Summary
    TOTAL_END=$(date +%s)
    TOTAL_TIME=$((TOTAL_END - TOTAL_START))

    echo ""
    echo "=============================================="
    log "Build complete!"
    echo "=============================================="
    echo "Total time: ${TOTAL_TIME} seconds"
    echo ""
    echo "Images pushed:"
    [ "$BUILD_CONSOLE" = true ] && echo "  - $REGISTRY/boardroom-console:latest"
    [ "$BUILD_PROXY" = true ] && echo "  - $REGISTRY/boardroom-proxy:latest"
    echo ""
    echo "To pull on any platform:"
    echo "  docker pull $REGISTRY/boardroom-console:latest"
    echo ""
}

main
