#!/usr/bin/env bash
#
# create-user.sh - Create a new Boardroom user environment
#
# Creates Docker network, console container, and proxy container for a user.
# Sets up volume mounts for logs and config, and configures Cloudflare Tunnel route.
#
# Usage: ./create-user.sh <username>
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_BASE_DIR="${PROJECT_ROOT}/data/logs"
CONFIG_BASE_DIR="${PROJECT_ROOT}/data/config"
CONSOLE_IMAGE="${CONSOLE_IMAGE:-boardroom-console:latest}"
PROXY_IMAGE="${PROXY_IMAGE:-boardroom-proxy:latest}"
CLOUDFLARE_DOMAIN="${CLOUDFLARE_DOMAIN:-boardroom.example.com}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Display usage information
usage() {
    cat << EOF
Usage: $(basename "$0") <username>

Create a new Boardroom user environment with Docker containers.

Arguments:
    username    The username for the new environment (alphanumeric and hyphens only)

Environment Variables:
    CONSOLE_IMAGE       Docker image for console container (default: boardroom-console:latest)
    PROXY_IMAGE         Docker image for proxy container (default: boardroom-proxy:latest)
    CLOUDFLARE_DOMAIN   Base domain for Cloudflare Tunnel (default: boardroom.example.com)

Examples:
    $(basename "$0") john-doe
    CLOUDFLARE_DOMAIN=app.mycompany.com $(basename "$0") jane-smith
EOF
    exit 1
}

# Validate username format
validate_username() {
    local username="$1"

    if [[ -z "$username" ]]; then
        log_error "Username cannot be empty"
        return 1
    fi

    if [[ ! "$username" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
        log_error "Username must contain only lowercase letters, numbers, and hyphens"
        log_error "Username must start and end with a letter or number"
        return 1
    fi

    if [[ ${#username} -gt 32 ]]; then
        log_error "Username must be 32 characters or less"
        return 1
    fi

    return 0
}

# Check if Docker is running
check_docker() {
    if ! docker info &>/dev/null; then
        log_error "Docker is not running or not accessible"
        exit 1
    fi
}

# Check if user environment already exists
check_existing() {
    local username="$1"
    local network_name="boardroom-${username}-network"

    if docker network inspect "$network_name" &>/dev/null; then
        log_error "User environment for '${username}' already exists"
        log_error "Use remove-user.sh to delete it first, or choose a different username"
        exit 1
    fi
}

# Create directories for user data
create_directories() {
    local username="$1"
    local log_dir="${LOG_BASE_DIR}/${username}"
    local config_dir="${CONFIG_BASE_DIR}/${username}"

    log_info "Creating directories for user: ${username}"

    mkdir -p "$log_dir"
    mkdir -p "$config_dir"

    log_success "Created log directory: ${log_dir}"
    log_success "Created config directory: ${config_dir}"
}

# Create Docker network
create_network() {
    local username="$1"
    local network_name="boardroom-${username}-network"

    log_info "Creating Docker network: ${network_name}"

    docker network create \
        --driver bridge \
        --label "boardroom.user=${username}" \
        --label "boardroom.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$network_name"

    log_success "Created network: ${network_name}"
}

# Create console container
create_console_container() {
    local username="$1"
    local container_name="boardroom-${username}-console"
    local network_name="boardroom-${username}-network"
    local log_dir="${LOG_BASE_DIR}/${username}"
    local config_dir="${CONFIG_BASE_DIR}/${username}"

    log_info "Creating console container: ${container_name}"

    docker create \
        --name "$container_name" \
        --network "$network_name" \
        --hostname "${username}-console" \
        --restart unless-stopped \
        --label "boardroom.user=${username}" \
        --label "boardroom.role=console" \
        --label "boardroom.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --volume "${log_dir}:/var/log/boardroom:rw" \
        --volume "${config_dir}:/etc/boardroom:ro" \
        --env "BOARDROOM_USER=${username}" \
        --env "BOARDROOM_ROLE=console" \
        "$CONSOLE_IMAGE"

    log_success "Created console container: ${container_name}"
}

# Create proxy container
create_proxy_container() {
    local username="$1"
    local container_name="boardroom-${username}-proxy"
    local network_name="boardroom-${username}-network"
    local console_name="boardroom-${username}-console"
    local log_dir="${LOG_BASE_DIR}/${username}"
    local config_dir="${CONFIG_BASE_DIR}/${username}"

    log_info "Creating proxy container: ${container_name}"

    docker create \
        --name "$container_name" \
        --network "$network_name" \
        --hostname "${username}-proxy" \
        --restart unless-stopped \
        --label "boardroom.user=${username}" \
        --label "boardroom.role=proxy" \
        --label "boardroom.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --volume "${log_dir}:/var/log/boardroom:rw" \
        --volume "${config_dir}:/etc/boardroom:ro" \
        --env "BOARDROOM_USER=${username}" \
        --env "BOARDROOM_ROLE=proxy" \
        --env "BOARDROOM_CONSOLE_HOST=${console_name}" \
        "$PROXY_IMAGE"

    log_success "Created proxy container: ${container_name}"
}

# Start containers
start_containers() {
    local username="$1"
    local console_name="boardroom-${username}-console"
    local proxy_name="boardroom-${username}-proxy"

    log_info "Starting containers..."

    docker start "$console_name"
    log_success "Started console container: ${console_name}"

    docker start "$proxy_name"
    log_success "Started proxy container: ${proxy_name}"
}

# Configure Cloudflare Tunnel route (placeholder)
configure_cloudflare_tunnel() {
    local username="$1"
    local subdomain="${username}.${CLOUDFLARE_DOMAIN}"

    log_info "Configuring Cloudflare Tunnel route..."
    log_warn "PLACEHOLDER: Cloudflare Tunnel configuration not yet implemented"
    log_warn "Manual configuration required for: ${subdomain}"

    # TODO: Implement Cloudflare Tunnel configuration
    # This would typically involve:
    # 1. Adding a route to the cloudflared config
    # 2. Restarting cloudflared or using the API to add the route
    # 3. Configuring DNS if not using Cloudflare's automatic DNS
    #
    # Example cloudflared config entry:
    # ingress:
    #   - hostname: ${subdomain}
    #     service: http://boardroom-${username}-proxy:8080

    cat << EOF

    Cloudflare Tunnel Configuration (manual steps):
    ------------------------------------------------
    1. Add to cloudflared config.yml:

       ingress:
         - hostname: ${subdomain}
           service: http://boardroom-${username}-proxy:8080

    2. Restart cloudflared or reload configuration

    3. Verify DNS record exists for: ${subdomain}

EOF
}

# Display success summary
display_summary() {
    local username="$1"
    local subdomain="${username}.${CLOUDFLARE_DOMAIN}"

    echo ""
    echo "=============================================="
    echo -e "${GREEN}User Environment Created Successfully${NC}"
    echo "=============================================="
    echo ""
    echo "Username:        ${username}"
    echo ""
    echo "Resources Created:"
    echo "  Network:       boardroom-${username}-network"
    echo "  Console:       boardroom-${username}-console"
    echo "  Proxy:         boardroom-${username}-proxy"
    echo ""
    echo "Data Directories:"
    echo "  Logs:          ${LOG_BASE_DIR}/${username}"
    echo "  Config:        ${CONFIG_BASE_DIR}/${username}"
    echo ""
    echo "Access URLs (after Cloudflare Tunnel configuration):"
    echo "  Console:       https://${subdomain}/"
    echo "  WebSocket:     wss://${subdomain}/ws"
    echo ""
    echo "Container Management:"
    echo "  View logs:     docker logs -f boardroom-${username}-console"
    echo "  Stop:          docker stop boardroom-${username}-console boardroom-${username}-proxy"
    echo "  Remove:        ./remove-user.sh ${username}"
    echo ""
}

# Main function
main() {
    # Check for help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
    fi

    # Validate arguments
    if [[ $# -ne 1 ]]; then
        log_error "Missing required argument: username"
        echo ""
        usage
    fi

    local username="$1"

    # Validate username
    if ! validate_username "$username"; then
        exit 1
    fi

    # Pre-flight checks
    check_docker
    check_existing "$username"

    log_info "Creating user environment for: ${username}"
    echo ""

    # Create user environment
    create_directories "$username"
    create_network "$username"
    create_console_container "$username"
    create_proxy_container "$username"
    start_containers "$username"
    configure_cloudflare_tunnel "$username"

    # Display summary
    display_summary "$username"
}

# Run main function
main "$@"
