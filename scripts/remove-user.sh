#!/usr/bin/env bash
#
# remove-user.sh - Remove a Boardroom user environment
#
# Stops and removes Docker containers, network, and optionally data for a user.
#
# Usage: ./remove-user.sh <company> <username> [--keep-data] [--force] [--remote <host>]
#
# Naming Convention:
#   Network:   {company}-{username}-network
#   Console:   {company}-{username}-console
#   Proxy:     {company}-{username}-proxy
#   Data:      /home/boardroom/data/{company}-{username}-console
#              /home/boardroom/data/{company}-{username}-proxy
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_BASE_DIR="${DATA_BASE_DIR:-/home/boardroom/data}"
COMPANY=""  # Required argument

# OpenRouter API key management
OPENROUTER_PROVISIONING_KEY="${OPENROUTER_PROVISIONING_KEY:-}"
OPENROUTER_API_BASE="https://openrouter.ai/api/v1/keys"

# Remote execution (uses ~/.ssh/config for host resolution)
REMOTE_HOST=""

# Execute command locally or remotely
# Uses ~/.ssh/config for host resolution (HostName, User, IdentityFile)
run_cmd() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh "$REMOTE_HOST" "$@"
    else
        eval "$@"
    fi
}

# Execute docker command
docker_cmd() {
    run_cmd "docker $*"
}

# Remove directory
remove_dir() {
    local dirpath="$1"
    run_cmd "rm -rf '$dirpath'"
}

# Check if directory exists
dir_exists() {
    local dirpath="$1"
    run_cmd "test -d '$dirpath'" 2>/dev/null
}

# Get directory size
dir_size() {
    local dirpath="$1"
    run_cmd "du -sh '$dirpath' 2>/dev/null | cut -f1" || echo "unknown"
}

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

# =============================================================================
# OpenRouter API Key Management
# =============================================================================

# Check if OpenRouter provisioning is available
openrouter_available() {
    [[ -n "$OPENROUTER_PROVISIONING_KEY" ]]
}

# Get OpenRouter key name for this user
get_openrouter_key_name() {
    local username="$1"
    echo "${COMPANY}-${username}-boardroom"
}

# Get OpenRouter key hash by name
openrouter_get_key_hash() {
    local key_name="$1"
    local response hash

    response=$(curl -s "$OPENROUTER_API_BASE" \
        -H "Authorization: Bearer $OPENROUTER_PROVISIONING_KEY" 2>/dev/null)

    if [[ -z "$response" ]]; then
        return 1
    fi

    # Extract hash for key with matching name
    hash=$(echo "$response" | jq -r --arg name "$key_name" \
        '.data[] | select(.name == $name) | .hash' 2>/dev/null)

    if [[ -n "$hash" && "$hash" != "null" ]]; then
        echo "$hash"
        return 0
    fi
    return 1
}

# Disable OpenRouter key (does NOT delete - can be re-enabled later)
openrouter_disable_key() {
    local key_hash="$1"

    curl -s -X PATCH "${OPENROUTER_API_BASE}/${key_hash}" \
        -H "Authorization: Bearer $OPENROUTER_PROVISIONING_KEY" \
        -H "Content-Type: application/json" \
        -d '{"disabled": true}' 2>/dev/null
}

# Disable OpenRouter API key for user (not delete - preserves for reactivation)
disable_openrouter_key() {
    local username="$1"
    local key_name key_hash

    if ! openrouter_available; then
        log_warn "OPENROUTER_PROVISIONING_KEY not set, skipping OpenRouter key management"
        return 1
    fi

    key_name=$(get_openrouter_key_name "$username")
    log_info "Checking for OpenRouter key: ${key_name}"

    if key_hash=$(openrouter_get_key_hash "$key_name"); then
        log_info "Found OpenRouter key (hash: ${key_hash:0:8}...), disabling..."
        if openrouter_disable_key "$key_hash"; then
            log_success "Disabled OpenRouter API key: ${key_name}"
            log_info "Key can be re-enabled when user is recreated"
            return 0
        else
            log_warn "Failed to disable OpenRouter key"
            return 1
        fi
    else
        log_info "No OpenRouter key found for: ${key_name}"
        return 1
    fi
}

# =============================================================================
# Usage and Help
# =============================================================================

# Display usage information
usage() {
    cat << EOF
Usage: $(basename "$0") <company> <username> [options]

Remove a Boardroom user environment and its Docker resources.

Arguments:
    company             Company/org identifier (e.g., lemalogic, acme)
    username            Username of the environment to remove

Options:
    --keep-data         Keep data directories (don't delete user data)
    --force, -f         Skip confirmation prompt
    --remote <host>     Execute on remote server via SSH config host name
    --help, -h          Show this help message

Environment Variables:
    DATA_BASE_DIR   Base directory for user data (default: /home/boardroom/data)

Examples:
    # Local execution
    $(basename "$0") lemalogic alice                  # Remove with confirmation
    $(basename "$0") lemalogic alice --force          # Remove without confirmation
    $(basename "$0") lemalogic alice --keep-data      # Remove containers but keep data

    # Remote execution using SSH config host name
    $(basename "$0") lemalogic alice --remote boardroom.prod
    $(basename "$0") acme bob --remote boardroom.prod --force

    The --remote option uses ~/.ssh/config for host resolution.
EOF
    exit 1
}

# Check if Docker is running
check_docker() {
    if ! docker_cmd info &>/dev/null; then
        log_error "Docker is not running or not accessible"
        if [[ -n "$REMOTE_HOST" ]]; then
            log_error "Check SSH connection to ${REMOTE_HOST}"
        fi
        exit 1
    fi
}

# Check if user environment exists
check_exists() {
    local username="$1"
    local network_name="${COMPANY}-${username}-network"
    local console_name="${COMPANY}-${username}-console"
    local proxy_name="${COMPANY}-${username}-proxy"

    local exists=false

    if docker_cmd "network inspect '${network_name}'" &>/dev/null; then
        exists=true
    fi

    if docker_cmd "container inspect '${console_name}'" &>/dev/null; then
        exists=true
    fi

    if docker_cmd "container inspect '${proxy_name}'" &>/dev/null; then
        exists=true
    fi

    if [[ "$exists" == "false" ]]; then
        log_error "No user environment found for: ${COMPANY}/${username}"
        log_error "Expected network: ${network_name}"
        log_error "Expected console: ${console_name}"
        log_error "Expected proxy: ${proxy_name}"
        exit 1
    fi
}

# Display current state of user resources
display_current_state() {
    local username="$1"
    local network_name="${COMPANY}-${username}-network"
    local console_name="${COMPANY}-${username}-console"
    local proxy_name="${COMPANY}-${username}-proxy"
    local console_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-console"
    local proxy_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-proxy"

    echo ""
    echo "Current state for user: ${COMPANY}/${username}"
    echo "----------------------------------------"

    # Check network
    if docker_cmd "network inspect '${network_name}'" &>/dev/null; then
        echo -e "Network:     ${GREEN}exists${NC} - ${network_name}"
    else
        echo -e "Network:     ${YELLOW}not found${NC} - ${network_name}"
    fi

    # Check console container
    if docker_cmd "container inspect '${console_name}'" &>/dev/null; then
        local state
        state=$(docker_cmd "container inspect -f '{{.State.Status}}' '${console_name}'" 2>/dev/null || echo "unknown")
        echo -e "Console:     ${GREEN}exists${NC} (${state}) - ${console_name}"
    else
        echo -e "Console:     ${YELLOW}not found${NC} - ${console_name}"
    fi

    # Check proxy container
    if docker_cmd "container inspect '${proxy_name}'" &>/dev/null; then
        local state
        state=$(docker_cmd "container inspect -f '{{.State.Status}}' '${proxy_name}'" 2>/dev/null || echo "unknown")
        echo -e "Proxy:       ${GREEN}exists${NC} (${state}) - ${proxy_name}"
    else
        echo -e "Proxy:       ${YELLOW}not found${NC} - ${proxy_name}"
    fi

    # Check data directories
    if dir_exists "$console_dir"; then
        local size
        size=$(dir_size "$console_dir")
        echo -e "Console dir: ${GREEN}exists${NC} (${size}) - ${console_dir}"
    else
        echo -e "Console dir: ${YELLOW}not found${NC} - ${console_dir}"
    fi

    if dir_exists "$proxy_dir"; then
        local size
        size=$(dir_size "$proxy_dir")
        echo -e "Proxy dir:   ${GREEN}exists${NC} (${size}) - ${proxy_dir}"
    else
        echo -e "Proxy dir:   ${YELLOW}not found${NC} - ${proxy_dir}"
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
        echo -e "${YELLOW}WARNING: User data (console and proxy dirs) will also be deleted${NC}"
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
    local console_name="${COMPANY}-${username}-console"
    local proxy_name="${COMPANY}-${username}-proxy"

    log_info "Stopping containers..."

    # Stop console first
    if docker_cmd "container inspect '${console_name}'" &>/dev/null; then
        local state
        state=$(docker_cmd "container inspect -f '{{.State.Status}}' '${console_name}'" 2>/dev/null || echo "unknown")
        if [[ "$state" == "running" ]]; then
            docker_cmd "stop '${console_name}'" >/dev/null 2>&1 || true
            log_success "Stopped console container: ${console_name}"
        else
            log_info "Console container already stopped: ${console_name}"
        fi
    fi

    # Stop proxy
    if docker_cmd "container inspect '${proxy_name}'" &>/dev/null; then
        local state
        state=$(docker_cmd "container inspect -f '{{.State.Status}}' '${proxy_name}'" 2>/dev/null || echo "unknown")
        if [[ "$state" == "running" ]]; then
            docker_cmd "stop '${proxy_name}'" >/dev/null 2>&1 || true
            log_success "Stopped proxy container: ${proxy_name}"
        else
            log_info "Proxy container already stopped: ${proxy_name}"
        fi
    fi
}

# Remove containers
remove_containers() {
    local username="$1"
    local console_name="${COMPANY}-${username}-console"
    local proxy_name="${COMPANY}-${username}-proxy"
    local removed_count=0

    log_info "Removing containers..."

    # Remove console container
    if docker_cmd "container inspect '${console_name}'" &>/dev/null; then
        docker_cmd "rm '${console_name}'" >/dev/null 2>&1 || true
        log_success "Removed console container: ${console_name}"
        ((removed_count++))
    else
        log_info "Console container not found: ${console_name}"
    fi

    # Remove proxy container
    if docker_cmd "container inspect '${proxy_name}'" &>/dev/null; then
        docker_cmd "rm '${proxy_name}'" >/dev/null 2>&1 || true
        log_success "Removed proxy container: ${proxy_name}"
        ((removed_count++))
    else
        log_info "Proxy container not found: ${proxy_name}"
    fi

    echo "$removed_count"
}

# Remove network
remove_network() {
    local username="$1"
    local network_name="${COMPANY}-${username}-network"

    log_info "Removing network..."

    if docker_cmd "network inspect '${network_name}'" &>/dev/null; then
        docker_cmd "network rm '${network_name}'" >/dev/null 2>&1 || true
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
    local console_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-console"
    local proxy_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-proxy"
    local removed_count=0

    log_info "Removing data directories..."

    if dir_exists "$console_dir"; then
        remove_dir "$console_dir"
        log_success "Removed console directory: ${console_dir}"
        ((removed_count++))
    else
        log_info "Console directory not found: ${console_dir}"
    fi

    if dir_exists "$proxy_dir"; then
        remove_dir "$proxy_dir"
        log_success "Removed proxy directory: ${proxy_dir}"
        ((removed_count++))
    else
        log_info "Proxy directory not found: ${proxy_dir}"
    fi

    echo "$removed_count"
}

# Remove Cloudflare Access application
remove_cloudflare_access() {
    local username="$1"
    local subdomain="${COMPANY}-${username}.boardroom.site"

    # Check for Cloudflare credentials
    local env_file="/Users/brian/Sites/github/boardroom/.env"
    if [[ ! -f "$env_file" ]]; then
        log_warn "Cloudflare .env file not found at $env_file"
        log_warn "Skipping Cloudflare Access removal"
        echo "skipped"
        return 0
    fi

    local cf_token=$(grep "^CLOUDFLARE_API_TOKEN=" "$env_file" | cut -d'=' -f2)
    local cf_account=$(grep "^CLOUDFLARE_ACCOUNT_ID=" "$env_file" | cut -d'=' -f2)

    if [[ -z "$cf_token" || -z "$cf_account" ]]; then
        log_warn "Cloudflare credentials not found in .env"
        log_warn "Skipping Cloudflare Access removal"
        echo "skipped"
        return 0
    fi

    log_info "Looking for Cloudflare Access application for $subdomain..."

    # Find Access app by domain
    local apps_response=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$cf_account/access/apps" \
        -H "Authorization: Bearer $cf_token")

    local app_id=$(echo "$apps_response" | jq -r ".result[] | select(.domain == \"$subdomain\") | .id")

    if [[ -z "$app_id" || "$app_id" == "null" ]]; then
        log_info "No Access application found for $subdomain"
        echo "not_found"
        return 0
    fi

    log_info "Deleting Access application: $app_id"
    local delete_response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/$cf_account/access/apps/$app_id" \
        -H "Authorization: Bearer $cf_token")

    local delete_success=$(echo "$delete_response" | jq -r '.success')
    if [[ "$delete_success" == "true" ]]; then
        log_success "Deleted Cloudflare Access application"
        echo "yes"
    else
        log_error "Failed to delete Access application"
        echo "$delete_response" | jq .
        echo "failed"
    fi
}

# Display cleanup summary
display_summary() {
    local username="$1"
    local containers_removed="$2"
    local network_removed="$3"
    local data_removed="$4"
    local keep_data="$5"
    local openrouter_disabled="${6:-no}"
    local access_removed="${7:-skipped}"

    echo ""
    echo "=============================================="
    echo -e "${GREEN}User Environment Removed Successfully${NC}"
    echo "=============================================="
    echo ""
    echo "Company:             ${COMPANY}"
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

    if [[ "$openrouter_disabled" == "yes" ]]; then
        echo -e "  OpenRouter key:     ${YELLOW}disabled (not deleted)${NC}"
    fi

    if [[ "$access_removed" == "yes" ]]; then
        echo "  Access app removed: yes"
    elif [[ "$access_removed" == "not_found" ]]; then
        echo -e "  Access app:         ${YELLOW}not found${NC}"
    elif [[ "$access_removed" == "skipped" ]]; then
        echo -e "  Access app:         ${YELLOW}skipped (no credentials)${NC}"
    elif [[ "$access_removed" == "failed" ]]; then
        echo -e "  Access app:         ${RED}removal failed${NC}"
    fi

    echo ""

    if [[ "$keep_data" == "true" ]]; then
        echo "Note: User data was preserved (git history intact). To remove it later:"
        echo "  rm -rf ${DATA_BASE_DIR}/${COMPANY}-${username}-console"
        echo "  rm -rf ${DATA_BASE_DIR}/${COMPANY}-${username}-proxy"
        echo ""
    fi

    if [[ "$openrouter_disabled" == "yes" ]]; then
        echo "Note: OpenRouter API key was disabled, not deleted."
        echo "      If you recreate this user, the key will be automatically re-enabled."
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
    local positional_args=()

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
            --remote)
                if [[ -z "${2:-}" ]]; then
                    log_error "--remote requires a host argument"
                    usage
                fi
                REMOTE_HOST="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                positional_args+=("$1")
                shift
                ;;
        esac
    done

    # Extract company and username from positional args
    if [[ ${#positional_args[@]} -lt 2 ]]; then
        log_error "Missing required arguments: company and username"
        echo ""
        echo "Usage: $(basename "$0") <company> <username> [--force] [--keep-data] [--remote <host>]"
        echo ""
        echo "Example: $(basename "$0") lemalogic alice --remote 46.224.211.238"
        exit 1
    fi

    if [[ ${#positional_args[@]} -gt 2 ]]; then
        log_error "Too many positional arguments"
        usage
    fi

    COMPANY="${positional_args[0]}"
    username="${positional_args[1]}"

    # Show remote mode info
    if [[ -n "$REMOTE_HOST" ]]; then
        log_info "Remote mode: executing on ${REMOTE_HOST} via SSH"
    fi

    log_info "Company: ${COMPANY}"
    log_info "Username: ${username}"

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

    # Disable OpenRouter API key (does not delete - can be re-enabled)
    local openrouter_disabled="no"
    if disable_openrouter_key "$username"; then
        openrouter_disabled="yes"
    fi

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

    # Remove Cloudflare Access application
    access_removed=$(remove_cloudflare_access "$username")

    # Display summary
    display_summary "$username" "$containers_removed" "$network_removed" "$data_removed" "$keep_data" "$openrouter_disabled" "$access_removed"
}

# Run main function
main "$@"
