#!/usr/bin/env bash
#
# remove-user.sh - Remove a Boardroom user environment
#
# Stops and removes Docker containers, network, and optionally volumes for a user.
#
# Usage: ./remove-user.sh <username> [--keep-data] [--force]
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_BASE_DIR="${PROJECT_ROOT}/data/logs"
CONFIG_BASE_DIR="${PROJECT_ROOT}/data/config"

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
Usage: $(basename "$0") <username> [options]

Remove a Boardroom user environment and its Docker resources.

Arguments:
    username        The username of the environment to remove

Options:
    --keep-data     Keep log and config directories (don't delete user data)
    --force, -f     Skip confirmation prompt
    --help, -h      Show this help message

Examples:
    $(basename "$0") john-doe                  # Remove with confirmation
    $(basename "$0") john-doe --force          # Remove without confirmation
    $(basename "$0") john-doe --keep-data      # Remove containers but keep data
    $(basename "$0") john-doe -f --keep-data   # Both options combined
EOF
    exit 1
}

# Check if Docker is running
check_docker() {
    if ! docker info &>/dev/null; then
        log_error "Docker is not running or not accessible"
        exit 1
    fi
}

# Check if user environment exists
check_exists() {
    local username="$1"
    local network_name="boardroom-${username}-network"
    local console_name="boardroom-${username}-console"
    local proxy_name="boardroom-${username}-proxy"

    local exists=false

    if docker network inspect "$network_name" &>/dev/null; then
        exists=true
    fi

    if docker container inspect "$console_name" &>/dev/null; then
        exists=true
    fi

    if docker container inspect "$proxy_name" &>/dev/null; then
        exists=true
    fi

    if [[ "$exists" == "false" ]]; then
        log_error "No user environment found for: ${username}"
        exit 1
    fi
}

# Display current state of user resources
display_current_state() {
    local username="$1"
    local network_name="boardroom-${username}-network"
    local console_name="boardroom-${username}-console"
    local proxy_name="boardroom-${username}-proxy"
    local log_dir="${LOG_BASE_DIR}/${username}"
    local config_dir="${CONFIG_BASE_DIR}/${username}"

    echo ""
    echo "Current state for user: ${username}"
    echo "----------------------------------------"

    # Check network
    if docker network inspect "$network_name" &>/dev/null; then
        echo -e "Network:    ${GREEN}exists${NC} - ${network_name}"
    else
        echo -e "Network:    ${YELLOW}not found${NC} - ${network_name}"
    fi

    # Check console container
    if docker container inspect "$console_name" &>/dev/null; then
        local state
        state=$(docker container inspect -f '{{.State.Status}}' "$console_name" 2>/dev/null || echo "unknown")
        echo -e "Console:    ${GREEN}exists${NC} (${state}) - ${console_name}"
    else
        echo -e "Console:    ${YELLOW}not found${NC} - ${console_name}"
    fi

    # Check proxy container
    if docker container inspect "$proxy_name" &>/dev/null; then
        local state
        state=$(docker container inspect -f '{{.State.Status}}' "$proxy_name" 2>/dev/null || echo "unknown")
        echo -e "Proxy:      ${GREEN}exists${NC} (${state}) - ${proxy_name}"
    else
        echo -e "Proxy:      ${YELLOW}not found${NC} - ${proxy_name}"
    fi

    # Check data directories
    if [[ -d "$log_dir" ]]; then
        local log_size
        log_size=$(du -sh "$log_dir" 2>/dev/null | cut -f1 || echo "unknown")
        echo -e "Log dir:    ${GREEN}exists${NC} (${log_size}) - ${log_dir}"
    else
        echo -e "Log dir:    ${YELLOW}not found${NC} - ${log_dir}"
    fi

    if [[ -d "$config_dir" ]]; then
        local config_size
        config_size=$(du -sh "$config_dir" 2>/dev/null | cut -f1 || echo "unknown")
        echo -e "Config dir: ${GREEN}exists${NC} (${config_size}) - ${config_dir}"
    else
        echo -e "Config dir: ${YELLOW}not found${NC} - ${config_dir}"
    fi

    echo "----------------------------------------"
    echo ""
}

# Confirm deletion with user
confirm_deletion() {
    local username="$1"
    local keep_data="$2"

    echo -e "${YELLOW}WARNING: This will permanently remove the user environment for '${username}'${NC}"

    if [[ "$keep_data" == "false" ]]; then
        echo -e "${YELLOW}WARNING: User data (logs and config) will also be deleted${NC}"
    else
        echo -e "${BLUE}NOTE: User data will be preserved (--keep-data flag)${NC}"
    fi

    echo ""
    read -r -p "Are you sure you want to proceed? (yes/no): " response

    case "$response" in
        yes|YES|Yes)
            return 0
            ;;
        *)
            log_info "Cancelled by user"
            exit 0
            ;;
    esac
}

# Stop containers
stop_containers() {
    local username="$1"
    local console_name="boardroom-${username}-console"
    local proxy_name="boardroom-${username}-proxy"

    log_info "Stopping containers..."

    # Stop proxy first (depends on console)
    if docker container inspect "$proxy_name" &>/dev/null; then
        local state
        state=$(docker container inspect -f '{{.State.Status}}' "$proxy_name" 2>/dev/null || echo "unknown")
        if [[ "$state" == "running" ]]; then
            docker stop "$proxy_name" >/dev/null 2>&1 || true
            log_success "Stopped proxy container: ${proxy_name}"
        else
            log_info "Proxy container already stopped: ${proxy_name}"
        fi
    fi

    # Stop console
    if docker container inspect "$console_name" &>/dev/null; then
        local state
        state=$(docker container inspect -f '{{.State.Status}}' "$console_name" 2>/dev/null || echo "unknown")
        if [[ "$state" == "running" ]]; then
            docker stop "$console_name" >/dev/null 2>&1 || true
            log_success "Stopped console container: ${console_name}"
        else
            log_info "Console container already stopped: ${console_name}"
        fi
    fi
}

# Remove containers
remove_containers() {
    local username="$1"
    local console_name="boardroom-${username}-console"
    local proxy_name="boardroom-${username}-proxy"
    local removed_count=0

    log_info "Removing containers..."

    # Remove proxy container
    if docker container inspect "$proxy_name" &>/dev/null; then
        docker rm "$proxy_name" >/dev/null 2>&1 || true
        log_success "Removed proxy container: ${proxy_name}"
        ((removed_count++))
    else
        log_info "Proxy container not found: ${proxy_name}"
    fi

    # Remove console container
    if docker container inspect "$console_name" &>/dev/null; then
        docker rm "$console_name" >/dev/null 2>&1 || true
        log_success "Removed console container: ${console_name}"
        ((removed_count++))
    else
        log_info "Console container not found: ${console_name}"
    fi

    echo "$removed_count"
}

# Remove network
remove_network() {
    local username="$1"
    local network_name="boardroom-${username}-network"

    log_info "Removing network..."

    if docker network inspect "$network_name" &>/dev/null; then
        docker network rm "$network_name" >/dev/null 2>&1 || true
        log_success "Removed network: ${network_name}"
        return 0
    else
        log_info "Network not found: ${network_name}"
        return 1
    fi
}

# Remove data directories
remove_data() {
    local username="$1"
    local log_dir="${LOG_BASE_DIR}/${username}"
    local config_dir="${CONFIG_BASE_DIR}/${username}"
    local removed_count=0

    log_info "Removing data directories..."

    if [[ -d "$log_dir" ]]; then
        rm -rf "$log_dir"
        log_success "Removed log directory: ${log_dir}"
        ((removed_count++))
    else
        log_info "Log directory not found: ${log_dir}"
    fi

    if [[ -d "$config_dir" ]]; then
        rm -rf "$config_dir"
        log_success "Removed config directory: ${config_dir}"
        ((removed_count++))
    else
        log_info "Config directory not found: ${config_dir}"
    fi

    echo "$removed_count"
}

# Display cleanup summary
display_summary() {
    local username="$1"
    local containers_removed="$2"
    local network_removed="$3"
    local data_removed="$4"
    local keep_data="$5"

    echo ""
    echo "=============================================="
    echo -e "${GREEN}User Environment Removed Successfully${NC}"
    echo "=============================================="
    echo ""
    echo "Username:            ${username}"
    echo ""
    echo "Cleanup Summary:"
    echo "  Containers removed: ${containers_removed}"
    echo "  Network removed:    ${network_removed}"

    if [[ "$keep_data" == "true" ]]; then
        echo -e "  Data directories:   ${YELLOW}preserved (--keep-data)${NC}"
    else
        echo "  Data dirs removed:  ${data_removed}"
    fi

    echo ""

    if [[ "$keep_data" == "true" ]]; then
        echo "Note: User data was preserved. To remove it later:"
        echo "  rm -rf ${LOG_BASE_DIR}/${username}"
        echo "  rm -rf ${CONFIG_BASE_DIR}/${username}"
        echo ""
    fi

    log_warn "Remember to remove Cloudflare Tunnel route for this user if configured"
    echo ""
}

# Main function
main() {
    local username=""
    local keep_data=false
    local force=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -f|--force)
                force=true
                shift
                ;;
            --keep-data)
                keep_data=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                if [[ -z "$username" ]]; then
                    username="$1"
                else
                    log_error "Unexpected argument: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    # Validate arguments
    if [[ -z "$username" ]]; then
        log_error "Missing required argument: username"
        echo ""
        usage
    fi

    # Pre-flight checks
    check_docker
    check_exists "$username"

    # Display current state
    display_current_state "$username"

    # Confirm deletion (unless --force)
    if [[ "$force" == "false" ]]; then
        confirm_deletion "$username" "$keep_data"
    fi

    log_info "Removing user environment for: ${username}"
    echo ""

    # Stop and remove containers
    stop_containers "$username"
    containers_removed=$(remove_containers "$username")

    # Remove network
    if remove_network "$username"; then
        network_removed="yes"
    else
        network_removed="no"
    fi

    # Remove data directories (unless --keep-data)
    if [[ "$keep_data" == "false" ]]; then
        data_removed=$(remove_data "$username")
    else
        data_removed="0"
        log_info "Keeping data directories (--keep-data flag)"
    fi

    # Display summary
    display_summary "$username" "$containers_removed" "$network_removed" "$data_removed" "$keep_data"
}

# Run main function
main "$@"
