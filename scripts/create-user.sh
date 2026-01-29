#!/usr/bin/env bash
#
# create-user.sh - Create a new Boardroom user environment
#
# Creates isolated Docker network, console container, and proxy container for a user.
# Each user gets their own proxy for complete API key isolation.
#
# Usage: ./create-user.sh <company> <username> [--email <email>] [--test] [--remote <host>]
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
CONSOLE_IMAGE="${CONSOLE_IMAGE:-ghcr.io/lemalogic/boardroom-console:amd64}"
PROXY_IMAGE="${PROXY_IMAGE:-boardroom-api-proxy:latest}"
COMPANY=""  # Required argument

# OpenRouter API key provisioning
OPENROUTER_PROVISIONING_KEY="${OPENROUTER_PROVISIONING_KEY:-}"
OPENROUTER_API_BASE="https://openrouter.ai/api/v1/keys"
OPENROUTER_DEFAULT_LIMIT=100  # $100/month default

# Remote execution (uses ~/.ssh/config for host resolution)
REMOTE_HOST=""

# User email (displayed in UI header)
USER_EMAIL=""

# SSH port allocation (start at 2224, brian=2222, dan=2223)
SSH_PORT_BASE=2224
GATEWAY_PORT_BASE=19003

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

# Create file on remote or local
create_file() {
    local filepath="$1"
    local content="$2"

    if [[ -n "$REMOTE_HOST" ]]; then
        echo "$content" | ssh -i "$SSH_KEY" "${SSH_USER}@${REMOTE_HOST}" "cat > '$filepath'"
    else
        echo "$content" > "$filepath"
    fi
}

# Check if directory exists
dir_exists() {
    local dirpath="$1"
    run_cmd "test -d '$dirpath'" 2>/dev/null
}

# Create directory
make_dir() {
    local dirpath="$1"
    run_cmd "mkdir -p '$dirpath'"
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

# Display usage information
usage() {
    cat << EOF
Usage: $(basename "$0") <company> <username> [--email <email>] [--test] [--remote <ssh-host>]

Create a new Boardroom user environment with isolated Docker containers.

Arguments:
    company             Company/org identifier (e.g., lemalogic, acme)
    username            Username for the new environment (lowercase alphanumeric, hyphens, underscores)

Options:
    --email <email>     User email to display in UI header
    --test              Run end-to-end test after creation
    --remote <host>     Execute on remote server via SSH config host name
    --help, -h          Show this help message

Environment Variables:
    DATA_BASE_DIR       Base directory for user data (default: /home/boardroom/data)
    CONSOLE_IMAGE       Docker image for console (default: ghcr.io/lemalogic/boardroom-console:amd64)
    PROXY_IMAGE         Docker image for proxy (default: boardroom-api-proxy:latest)

Examples:
    # Local execution (on server)
    $(basename "$0") lemalogic alice
    $(basename "$0") lemalogic bob --test

    # Remote execution using SSH config host name
    $(basename "$0") lemalogic alice --remote boardroom.prod
    $(basename "$0") acme carol --remote boardroom.prod --test

    The --remote option uses ~/.ssh/config for host resolution:

    # Example ~/.ssh/config entry:
    Host boardroom.prod
        HostName 46.224.211.238
        User root
        IdentityFile ~/.ssh/hetzner-boardroom

Architecture:
    Each user gets:
    - Isolated Docker network ({company}-{username}-network)
    - Dedicated proxy container with API keys ({company}-{username}-proxy)
    - Console container without API keys ({company}-{username}-console)
    - Git-versioned persistent storage for settings, config, and history

    The console can ONLY communicate with its own proxy (network isolation).

Container Naming:
    company=lemalogic, username=alice creates:
    - lemalogic-alice-network
    - lemalogic-alice-console
    - lemalogic-alice-proxy
    - /home/boardroom/data/lemalogic-alice-console (git repo)
EOF
    exit 1
}

# =============================================================================
# OpenRouter API Key Provisioning
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

# Check if OpenRouter key exists by name, returns key hash if found
openrouter_key_exists() {
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

# Create new OpenRouter API key with spending limit
openrouter_create_key() {
    local key_name="$1"
    local limit="${2:-$OPENROUTER_DEFAULT_LIMIT}"

    local response
    response=$(curl -s -X POST "$OPENROUTER_API_BASE" \
        -H "Authorization: Bearer $OPENROUTER_PROVISIONING_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$key_name\",
            \"limit\": $limit,
            \"limit_reset\": \"monthly\"
        }" 2>/dev/null)

    echo "$response"
}

# Enable a disabled OpenRouter key
openrouter_enable_key() {
    local key_hash="$1"

    curl -s -X PATCH "${OPENROUTER_API_BASE}/${key_hash}" \
        -H "Authorization: Bearer $OPENROUTER_PROVISIONING_KEY" \
        -H "Content-Type: application/json" \
        -d '{"disabled": false}' 2>/dev/null
}

# Check if key is disabled
openrouter_key_disabled() {
    local key_hash="$1"
    local response disabled

    response=$(curl -s "${OPENROUTER_API_BASE}/${key_hash}" \
        -H "Authorization: Bearer $OPENROUTER_PROVISIONING_KEY" 2>/dev/null)

    disabled=$(echo "$response" | jq -r '.data.disabled' 2>/dev/null)
    [[ "$disabled" == "true" ]]
}

# Provision OpenRouter API key for user
# Returns: the actual API key (only shown once at creation)
provision_openrouter_key() {
    local username="$1"
    local key_name api_key key_hash response

    if ! openrouter_available; then
        log_warn "OPENROUTER_PROVISIONING_KEY not set, skipping OpenRouter key provisioning"
        return 1
    fi

    key_name=$(get_openrouter_key_name "$username")
    log_info "Checking for existing OpenRouter key: ${key_name}"

    # Check if key already exists
    if key_hash=$(openrouter_key_exists "$key_name"); then
        log_info "Found existing OpenRouter key (hash: ${key_hash:0:8}...)"

        # Check if it's disabled and re-enable it
        if openrouter_key_disabled "$key_hash"; then
            log_info "Key is disabled, re-enabling..."
            openrouter_enable_key "$key_hash"
            log_success "Re-enabled OpenRouter key"
        fi

        # Note: We cannot retrieve the actual key after creation
        # User must have stored it previously
        log_warn "Cannot retrieve existing key value - key was created previously"
        log_warn "If key is lost, delete and recreate the user environment"
        return 2  # Key exists but we don't have the value
    fi

    # Create new key
    log_info "Creating new OpenRouter key with \$${OPENROUTER_DEFAULT_LIMIT}/month limit..."
    response=$(openrouter_create_key "$key_name" "$OPENROUTER_DEFAULT_LIMIT")

    # Extract the actual API key (only returned at creation time!)
    api_key=$(echo "$response" | jq -r '.key' 2>/dev/null)
    key_hash=$(echo "$response" | jq -r '.data.hash' 2>/dev/null)

    if [[ -z "$api_key" || "$api_key" == "null" ]]; then
        log_error "Failed to create OpenRouter key"
        log_error "Response: $response"
        return 1
    fi

    log_success "Created OpenRouter API key (hash: ${key_hash:0:8}...)"

    # Return the key
    echo "$api_key"
    return 0
}

# Deploy OpenRouter key to proxy container's keys.json
deploy_openrouter_key_to_proxy() {
    local username="$1"
    local api_key="$2"
    local proxy_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-proxy"
    local keys_file="${proxy_dir}/keys.json"
    local stub_key="stub-openrouter-${COMPANY}-${username}"

    log_info "Deploying OpenRouter key to proxy..."

    # Create or update keys.json with the OpenRouter key
    # The stub format allows the proxy to replace it with the real key
    local keys_content

    # Check if keys.json already exists
    if run_cmd "test -f '$keys_file'" 2>/dev/null; then
        # Update existing file - add/update the OpenRouter key
        run_cmd "cat '$keys_file' | jq --arg stub '$stub_key' --arg key '$api_key' '. + {(\$stub): \$key}' > '${keys_file}.tmp' && mv '${keys_file}.tmp' '$keys_file'"
    else
        # Create new keys.json
        keys_content="{\"${stub_key}\": \"${api_key}\"}"
        if [[ -n "$REMOTE_HOST" ]]; then
            ssh "$REMOTE_HOST" "echo '$keys_content' > '$keys_file'"
        else
            echo "$keys_content" > "$keys_file"
        fi
    fi

    log_success "Deployed OpenRouter key to: ${keys_file}"

    # Return the stub key name for use in moltbot config
    echo "$stub_key"
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate company format
validate_company() {
    local company="$1"

    if [[ -z "$company" ]]; then
        log_error "Company cannot be empty"
        return 1
    fi

    if [[ ! "$company" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        log_error "Company must start with a letter and contain only lowercase letters, numbers, hyphens, and underscores"
        return 1
    fi

    if [[ ${#company} -gt 16 ]]; then
        log_error "Company must be 16 characters or less"
        return 1
    fi

    return 0
}

# Validate username format
validate_username() {
    local username="$1"

    if [[ -z "$username" ]]; then
        log_error "Username cannot be empty"
        return 1
    fi

    if [[ ! "$username" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        log_error "Username must start with a letter and contain only lowercase letters, numbers, hyphens, and underscores"
        return 1
    fi

    if [[ ${#username} -gt 16 ]]; then
        log_error "Username must be 16 characters or less"
        return 1
    fi

    # Reserved names
    if [[ "$username" == "admin" || "$username" == "root" || "$username" == "boardroom" ]]; then
        log_error "Username '${username}' is reserved"
        return 1
    fi

    return 0
}

# Check if Docker is running
check_docker() {
    if ! docker_cmd info &>/dev/null; then
        log_error "Docker is not running or not accessible"
        if [[ -n "$REMOTE_HOST" ]]; then
            log_error "Check SSH config for host '${REMOTE_HOST}' and ensure Docker is running on the remote server"
        fi
        exit 1
    fi
}

# Check if user environment already exists
check_existing() {
    local username="$1"
    local network_name="${COMPANY}-${username}-network"

    if docker_cmd "network inspect '$network_name'" &>/dev/null; then
        log_error "User environment for '${COMPANY}/${username}' already exists"
        log_error "Use remove-user.sh to delete it first, or choose a different username"
        exit 1
    fi
}

# Generate a gateway token
generate_token() {
    openssl rand -hex 16
}

# Find next available ports
find_available_ports() {
    local username="$1"

    # Count existing user networks to determine port offset
    local user_count
    user_count=$(docker_cmd "network ls --filter 'name=-network$' --format '{{.Name}}'" | grep -v "lemalogic-brian-network\|lemalogic-dan-network\|lemalogic-admin-network" | wc -l | tr -d ' ')

    SSH_PORT=$((SSH_PORT_BASE + user_count))
    GATEWAY_PORT=$((GATEWAY_PORT_BASE + user_count))

    log_info "Allocated ports - SSH: ${SSH_PORT}, Gateway: ${GATEWAY_PORT}"
}

# Create directories for user data
create_directories() {
    local username="$1"
    local console_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-console"
    local proxy_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-proxy"

    log_info "Creating data directories for user: ${COMPANY}/${username}"

    make_dir "$console_dir"
    make_dir "$proxy_dir"

    # Initialize console directory as git repo for versioning
    init_git_repo "$console_dir" "$username"

    log_success "Created console directory: ${console_dir}"
    log_success "Created proxy directory: ${proxy_dir}"
}

# Initialize git repository for versioning user data
init_git_repo() {
    local dir="$1"
    local username="$2"

    log_info "Initializing git repository for versioning..."

    # Create .gitignore for caches and runtime data
    local gitignore_content='# Caches and runtime data (do not version)
.cache/
.npm/
.nvm/
.local/
*.log
*.tmp
node_modules/
__pycache__/
.DS_Store

# Large binary files
*.zip
*.tar.gz
*.tgz
'

    if [[ -n "$REMOTE_HOST" ]]; then
        ssh "$REMOTE_HOST" "cd '$dir' && git init && git config user.email 'boardroom@lemalogic.com' && git config user.name 'Boardroom System' && echo '$gitignore_content' > .gitignore && git add .gitignore && git commit -m 'Initialize user data repository for ${username}'"
    else
        cd "$dir"
        git init
        git config user.email "boardroom@lemalogic.com"
        git config user.name "Boardroom System"
        echo "$gitignore_content" > .gitignore
        git add .gitignore
        git commit -m "Initialize user data repository for ${username}"
    fi

    log_success "Initialized git repository with .gitignore"
}

# Create Docker network
create_network() {
    local username="$1"
    local network_name="${COMPANY}-${username}-network"
    local created_at
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log_info "Creating isolated Docker network: ${network_name}"

    docker_cmd "network create \
        --driver bridge \
        --label 'boardroom.user=${username}' \
        --label 'boardroom.company=${COMPANY}' \
        --label 'boardroom.created=${created_at}' \
        '${network_name}'"

    log_success "Created network: ${network_name}"
}

# Create moltbot configuration
create_moltbot_config() {
    local username="$1"
    local gateway_token="$2"
    local openrouter_stub="${3:-stub-openrouter-${COMPANY}-${username}}"
    local console_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-console"
    local proxy_hostname="${COMPANY}-${username}-proxy"
    local config_file="${console_dir}/.clawdbot-dev/moltbot.json"

    log_info "Creating moltbot configuration..."

    # Create .clawdbot-dev directory (moltbot expects config here)
    make_dir "${console_dir}/.clawdbot-dev"

    local config_content='{
  "gateway": {
    "bind": "lan",
    "port": 19001,
    "mode": "local",
    "trustedProxies": ["172.0.0.0/8", "10.0.0.0/8", "192.168.0.0/16"],
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true
    }
  },
  "models": {
    "providers": {
      "openrouter": {
        "apiKey": "'"${openrouter_stub}"'",
        "baseUrl": "http://'"${proxy_hostname}"':8080/v1/openrouter",
        "models": []
      },
      "anthropic": {
        "apiKey": "stub-anthropic-'"${COMPANY}"'-'"${username}"'",
        "baseUrl": "http://'"${proxy_hostname}"':8080/v1/anthropic",
        "models": []
      },
      "openai": {
        "apiKey": "stub-openai-'"${COMPANY}"'-'"${username}"'",
        "baseUrl": "http://'"${proxy_hostname}"':8080/v1/openai",
        "models": []
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openrouter/anthropic/claude-opus-4"
      }
    }
  }
}'

    create_file "$config_file" "$config_content"

    log_success "Created moltbot config: ${config_file}"
}

# Create proxy container
create_proxy_container() {
    local username="$1"
    local container_name="${COMPANY}-${username}-proxy"
    local network_name="${COMPANY}-${username}-network"
    local proxy_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-proxy"
    local created_at
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log_info "Creating proxy container: ${container_name}"

    docker_cmd "create \
        --name '${container_name}' \
        --network '${network_name}' \
        --network-alias '${COMPANY}-${username}-proxy' \
        --hostname '${COMPANY}-${username}-proxy' \
        --restart unless-stopped \
        --label 'boardroom.user=${username}' \
        --label 'boardroom.company=${COMPANY}' \
        --label 'boardroom.role=proxy' \
        --label 'boardroom.created=${created_at}' \
        --volume '${proxy_dir}:/data:rw' \
        '${PROXY_IMAGE}'"

    log_success "Created proxy container: ${container_name}"
}

# Create console container
create_console_container() {
    local username="$1"
    local gateway_token="$2"
    local container_name="${COMPANY}-${username}-console"
    local network_name="${COMPANY}-${username}-network"
    local console_dir="${DATA_BASE_DIR}/${COMPANY}-${username}-console"
    local created_at
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log_info "Creating console container: ${container_name}"

    docker_cmd "create \
        --name '${container_name}' \
        --network '${network_name}' \
        --network-alias '${COMPANY}-${username}-console' \
        --hostname '${COMPANY}-${username}-console' \
        --restart unless-stopped \
        --label 'boardroom.user=${username}' \
        --label 'boardroom.company=${COMPANY}' \
        --label 'boardroom.role=console' \
        --label 'boardroom.created=${created_at}' \
        --publish '${SSH_PORT}:22' \
        --publish '${GATEWAY_PORT}:19001' \
        --volume '${console_dir}:/home/boardroom:rw' \
        --env 'CLAWDBOT_GATEWAY_TOKEN=${gateway_token}' \
        --env 'BOARDROOM_USER_EMAIL=${USER_EMAIL}' \
        '${CONSOLE_IMAGE}'"

    log_success "Created console container: ${container_name}"
}

# Start containers in correct order (proxy first, then console)
start_containers() {
    local username="$1"
    local proxy_name="${COMPANY}-${username}-proxy"
    local console_name="${COMPANY}-${username}-console"

    log_info "Starting proxy container..."
    docker_cmd "start '${proxy_name}'"

    # Wait for proxy health check
    log_info "Waiting for proxy to be healthy..."
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if docker_cmd "exec '${proxy_name}' node -e \"fetch('http://localhost:8080/health').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))\"" 2>/dev/null; then
            log_success "Proxy is healthy"
            break
        fi
        sleep 1
        ((attempt++))
    done

    if [[ $attempt -eq $max_attempts ]]; then
        log_warn "Proxy health check timed out, continuing anyway..."
    fi

    log_info "Starting console container..."
    docker_cmd "start '${console_name}'"
    log_success "Started containers"
}

# Configure Cloudflare Tunnel route
configure_cloudflare_tunnel() {
    local username="$1"
    local subdomain="${COMPANY}-${username}.boardroom.site"

    log_info "Cloudflare Tunnel configuration required"

    cat << EOF

    Cloudflare Tunnel Configuration (manual steps):
    ------------------------------------------------
    1. Add to cloudflared config.yml:

       - hostname: ${subdomain}
         service: http://localhost:${GATEWAY_PORT}

    2. Restart cloudflared:
       pkill cloudflared && cloudflared tunnel run boardroom-${username} &

    3. Verify DNS record exists for: ${subdomain}

EOF
}

# Run end-to-end test
run_test() {
    local username="$1"
    local gateway_token="$2"
    local console_name="${COMPANY}-${username}-console"

    log_info "Running end-to-end test..."

    # Determine gateway URL based on local/remote execution
    local gateway_host="localhost"
    if [[ -n "$REMOTE_HOST" ]]; then
        gateway_host="$REMOTE_HOST"
    fi
    local gateway_url="http://${gateway_host}:${GATEWAY_PORT}"

    # Wait for gateway to be ready
    local max_attempts=30
    local attempt=0

    log_info "Waiting for gateway at ${gateway_url}..."
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s "${gateway_url}/" >/dev/null 2>&1; then
            log_success "Gateway is responding"
            break
        fi
        sleep 1
        ((attempt++))
    done

    if [[ $attempt -eq $max_attempts ]]; then
        log_error "Gateway did not respond after ${max_attempts} seconds"
        log_error "Check logs: docker logs ${console_name}"
        return 1
    fi

    # Test that page loads
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" "${gateway_url}/?token=${gateway_token}")

    if [[ "$response" == "200" ]]; then
        log_success "Web UI is accessible (HTTP 200)"
    else
        log_error "Web UI returned HTTP ${response}"
        return 1
    fi

    # Test container isolation (console should NOT reach other networks)
    log_info "Verifying network isolation..."
    if docker_cmd "exec '${console_name}' timeout 2 curl -s http://admin-proxy:8080/health" 2>/dev/null; then
        log_error "SECURITY VIOLATION: Console can reach admin-proxy!"
        return 1
    else
        log_success "Network isolation verified (cannot reach admin-proxy)"
    fi

    log_success "All tests passed!"
    return 0
}

# Display success summary
display_summary() {
    local username="$1"
    local gateway_token="$2"
    local openrouter_provisioned="${3:-false}"
    local subdomain="${COMPANY}-${username}.boardroom.site"

    echo ""
    echo "=============================================="
    echo -e "${GREEN}User Environment Created Successfully${NC}"
    echo "=============================================="
    echo ""
    echo "Company:         ${COMPANY}"
    echo "Username:        ${username}"
    echo "Gateway Token:   ${gateway_token}"
    echo ""
    echo "Resources Created:"
    echo "  Network:       ${COMPANY}-${username}-network"
    echo "  Console:       ${COMPANY}-${username}-console"
    echo "  Proxy:         ${COMPANY}-${username}-proxy"
    echo ""
    echo "Data Directories (git versioned):"
    echo "  Console:       ${DATA_BASE_DIR}/${COMPANY}-${username}-console"
    echo "  Proxy:         ${DATA_BASE_DIR}/${COMPANY}-${username}-proxy"
    echo ""
    if [[ "$openrouter_provisioned" == "true" ]]; then
        echo "OpenRouter API:"
        echo "  Key Name:      ${COMPANY}-${username}-boardroom"
        echo "  Limit:         \$${OPENROUTER_DEFAULT_LIMIT}/month"
        echo "  Status:        Active"
        echo ""
    fi
    echo "Ports:"
    echo "  SSH:           ${SSH_PORT}"
    echo "  Gateway:       ${GATEWAY_PORT}"
    echo ""
    echo "Local Access:"
    echo "  Console:       http://localhost:${GATEWAY_PORT}/?token=${gateway_token}"
    echo ""
    echo "Remote Access (after Cloudflare Tunnel config):"
    echo "  Console:       https://${subdomain}/?token=${gateway_token}"
    echo ""
    echo "Container Management:"
    echo "  View logs:     docker logs -f ${COMPANY}-${username}-console"
    echo "  Shell:         docker exec -it ${COMPANY}-${username}-console bash"
    echo "  Stop:          docker stop ${COMPANY}-${username}-console ${COMPANY}-${username}-proxy"
    echo "  Remove:        ./remove-user.sh ${COMPANY} ${username}"
    echo ""
    echo "Version Control:"
    echo "  View history:  cd ${DATA_BASE_DIR}/${COMPANY}-${username}-console && git log --oneline"
    echo "  Commit:        cd ${DATA_BASE_DIR}/${COMPANY}-${username}-console && git add -A && git commit -m 'description'"
    echo ""
}

# Main function
main() {
    local run_test_flag=false

    # Check for help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
    fi

    # Parse arguments - company and username are positional
    local username=""
    local positional_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --test)
                run_test_flag=true
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
            --email)
                if [[ -z "${2:-}" ]]; then
                    log_error "--email requires an email address argument"
                    usage
                fi
                USER_EMAIL="$2"
                shift 2
                ;;
            -h|--help)
                usage
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
        echo "Usage: $(basename "$0") <company> <username> [--email <email>] [--test] [--remote <host>]"
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

    # Validate inputs
    if ! validate_company "$COMPANY"; then
        exit 1
    fi

    if ! validate_username "$username"; then
        exit 1
    fi

    # Show remote mode info
    if [[ -n "$REMOTE_HOST" ]]; then
        log_info "Remote mode: executing on ${REMOTE_HOST} via SSH (using ~/.ssh/config)"
    fi

    log_info "Company: ${COMPANY}"
    log_info "Username: ${username}"

    # Pre-flight checks
    check_docker
    check_existing "$username"

    # Generate gateway token
    local gateway_token
    gateway_token=$(generate_token)

    # Find available ports
    find_available_ports "$username"

    log_info "Creating user environment for: ${username}"
    echo ""

    # Create user environment
    create_directories "$username"
    create_network "$username"

    # Provision OpenRouter API key (if provisioning key available)
    local openrouter_stub="stub-openrouter-${COMPANY}-${username}"
    local openrouter_api_key=""
    local openrouter_provisioned="false"
    if openrouter_available; then
        openrouter_api_key=$(provision_openrouter_key "$username") || true
        if [[ -n "$openrouter_api_key" && "$openrouter_api_key" != "" ]]; then
            openrouter_stub=$(deploy_openrouter_key_to_proxy "$username" "$openrouter_api_key")
            openrouter_provisioned="true"
        fi
    else
        log_warn "OpenRouter provisioning skipped (set OPENROUTER_PROVISIONING_KEY to enable)"
    fi

    create_moltbot_config "$username" "$gateway_token" "$openrouter_stub"
    create_proxy_container "$username"
    create_console_container "$username" "$gateway_token"
    start_containers "$username"

    # Display summary first
    display_summary "$username" "$gateway_token" "$openrouter_provisioned"

    # Run tests if requested
    if [[ "$run_test_flag" == true ]]; then
        echo ""
        if run_test "$username" "$gateway_token"; then
            echo ""
            log_success "User environment is fully operational!"
        else
            echo ""
            log_error "Tests failed - check logs for details"
            exit 1
        fi
    fi

    # Show Cloudflare config info
    configure_cloudflare_tunnel "$username"
}

# Run main function
main "$@"
