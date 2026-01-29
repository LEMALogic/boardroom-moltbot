#!/usr/bin/env bash
#
# create-user.sh - Create a new Boardroom user environment
#
# Creates isolated Docker network, console container, and proxy container for a user.
# Each user gets their own proxy for complete API key isolation.
#
# Usage: ./create-user.sh <company> <username> [--test] [--remote <host>]
#
# Naming Convention:
#   Network:   {username}-network
#   Console:   {username}-{company}-console
#   Proxy:     {username}-{company}-proxy
#   Data:      /home/boardroom/data/{username}-console
#              /home/boardroom/data/{username}-proxy
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_BASE_DIR="${DATA_BASE_DIR:-/home/boardroom/data}"
CONSOLE_IMAGE="${CONSOLE_IMAGE:-ghcr.io/lemalogic/boardroom-console:amd64}"
PROXY_IMAGE="${PROXY_IMAGE:-boardroom-api-proxy:latest}"
COMPANY=""  # Required argument

# Remote execution
REMOTE_HOST=""
SSH_KEY="${SSH_KEY:-$HOME/.ssh/hetzner-boardroom}"
SSH_USER="${SSH_USER:-root}"

# SSH port allocation (start at 2224, brian=2222, dan=2223)
SSH_PORT_BASE=2224
GATEWAY_PORT_BASE=19003

# Execute command locally or remotely
run_cmd() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh -i "$SSH_KEY" "${SSH_USER}@${REMOTE_HOST}" "$@"
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
Usage: $(basename "$0") <company> <username> [--test] [--remote <host>]

Create a new Boardroom user environment with isolated Docker containers.

Arguments:
    company             Company/org identifier (e.g., lemalogic, acme)
    username            Username for the new environment (lowercase alphanumeric and hyphens)

Options:
    --test              Run end-to-end test after creation
    --remote <host>     Execute on remote server via SSH (e.g., --remote 46.224.211.238)
    --help, -h          Show this help message

Environment Variables:
    DATA_BASE_DIR       Base directory for user data (default: /home/boardroom/data)
    CONSOLE_IMAGE       Docker image for console (default: ghcr.io/lemalogic/boardroom-console:amd64)
    PROXY_IMAGE         Docker image for proxy (default: boardroom-api-proxy:latest)
    SSH_KEY             SSH key for remote execution (default: ~/.ssh/hetzner-boardroom)
    SSH_USER            SSH user for remote execution (default: root)

Examples:
    # Local execution (on server)
    $(basename "$0") lemalogic alice
    $(basename "$0") lemalogic bob --test

    # Remote execution (from local machine)
    $(basename "$0") lemalogic alice --remote 46.224.211.238
    $(basename "$0") acme carol --remote boardroom.example.com --test

    # Custom SSH key
    SSH_KEY=~/.ssh/my-key $(basename "$0") lemalogic dan --remote 10.0.0.5

Architecture:
    Each user gets:
    - Isolated Docker network ({username}-network)
    - Dedicated proxy container with API keys ({username}-{company}-proxy)
    - Console container without API keys ({username}-{company}-console)

    The console can ONLY communicate with its own proxy (network isolation).

Container Naming:
    company=lemalogic, username=alice creates:
    - alice-network
    - alice-lemalogic-console
    - alice-lemalogic-proxy
EOF
    exit 1
}

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
            log_error "Check SSH connection to ${REMOTE_HOST}"
        fi
        exit 1
    fi
}

# Check if user environment already exists
check_existing() {
    local username="$1"
    local network_name="${username}-network"

    if docker_cmd "network inspect '$network_name'" &>/dev/null; then
        log_error "User environment for '${username}' already exists"
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
    user_count=$(docker_cmd "network ls --filter 'name=-network$' --format '{{.Name}}'" | grep -v "brian-network\|dan-network\|admin-network" | wc -l | tr -d ' ')

    SSH_PORT=$((SSH_PORT_BASE + user_count))
    GATEWAY_PORT=$((GATEWAY_PORT_BASE + user_count))

    log_info "Allocated ports - SSH: ${SSH_PORT}, Gateway: ${GATEWAY_PORT}"
}

# Create directories for user data
create_directories() {
    local username="$1"
    local console_dir="${DATA_BASE_DIR}/${username}-console"
    local proxy_dir="${DATA_BASE_DIR}/${username}-proxy"

    log_info "Creating data directories for user: ${username}"

    make_dir "$console_dir"
    make_dir "$proxy_dir"

    log_success "Created console directory: ${console_dir}"
    log_success "Created proxy directory: ${proxy_dir}"
}

# Create Docker network
create_network() {
    local username="$1"
    local network_name="${username}-network"
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
    local console_dir="${DATA_BASE_DIR}/${username}-console"
    local proxy_hostname="${username}-proxy"
    local config_file="${console_dir}/moltbot.json"

    log_info "Creating moltbot configuration..."

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
        "apiKey": "not-needed-proxy-injects",
        "baseUrl": "http://'"${proxy_hostname}"':8080/v1/openrouter",
        "models": []
      },
      "anthropic": {
        "apiKey": "not-needed-proxy-injects",
        "baseUrl": "http://'"${proxy_hostname}"':8080/v1/anthropic",
        "models": []
      },
      "openai": {
        "apiKey": "not-needed-proxy-injects",
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
    local container_name="${username}-${COMPANY}-proxy"
    local network_name="${username}-network"
    local proxy_dir="${DATA_BASE_DIR}/${username}-proxy"
    local created_at
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log_info "Creating proxy container: ${container_name}"

    docker_cmd "create \
        --name '${container_name}' \
        --network '${network_name}' \
        --hostname '${username}-proxy' \
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
    local container_name="${username}-${COMPANY}-console"
    local network_name="${username}-network"
    local console_dir="${DATA_BASE_DIR}/${username}-console"
    local created_at
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log_info "Creating console container: ${container_name}"

    docker_cmd "create \
        --name '${container_name}' \
        --network '${network_name}' \
        --hostname '${username}-console' \
        --restart unless-stopped \
        --label 'boardroom.user=${username}' \
        --label 'boardroom.company=${COMPANY}' \
        --label 'boardroom.role=console' \
        --label 'boardroom.created=${created_at}' \
        --publish '${SSH_PORT}:22' \
        --publish '${GATEWAY_PORT}:19001' \
        --volume '${console_dir}:/home/boardroom/.clawdbot-dev:rw' \
        --env 'CLAWDBOT_GATEWAY_TOKEN=${gateway_token}' \
        '${CONSOLE_IMAGE}'"

    log_success "Created console container: ${container_name}"
}

# Start containers in correct order (proxy first, then console)
start_containers() {
    local username="$1"
    local proxy_name="${username}-${COMPANY}-proxy"
    local console_name="${username}-${COMPANY}-console"

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
    local subdomain="${username}-${COMPANY}.boardroom.site"

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
    local console_name="${username}-${COMPANY}-console"

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
    local subdomain="${username}-${COMPANY}.boardroom.site"

    echo ""
    echo "=============================================="
    echo -e "${GREEN}User Environment Created Successfully${NC}"
    echo "=============================================="
    echo ""
    echo "Username:        ${username}"
    echo "Gateway Token:   ${gateway_token}"
    echo ""
    echo "Resources Created:"
    echo "  Network:       ${username}-network"
    echo "  Console:       ${username}-${COMPANY}-console"
    echo "  Proxy:         ${username}-${COMPANY}-proxy"
    echo ""
    echo "Data Directories:"
    echo "  Console:       ${DATA_BASE_DIR}/${username}-console"
    echo "  Proxy:         ${DATA_BASE_DIR}/${username}-proxy"
    echo ""
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
    echo "  View logs:     docker logs -f ${username}-${COMPANY}-console"
    echo "  Shell:         docker exec -it ${username}-${COMPANY}-console bash"
    echo "  Stop:          docker stop ${username}-${COMPANY}-console ${username}-${COMPANY}-proxy"
    echo "  Remove:        ./remove-user.sh ${username}"
    echo ""
    echo "Add to docker-compose.lemalogic.yml for persistence (see existing entries)"
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
        echo "Usage: $(basename "$0") <company> <username> [--test] [--remote <host>]"
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
        log_info "Remote mode: executing on ${REMOTE_HOST} via SSH"
        log_info "SSH key: ${SSH_KEY}"
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
    create_moltbot_config "$username" "$gateway_token"
    create_proxy_container "$username"
    create_console_container "$username" "$gateway_token"
    start_containers "$username"

    # Display summary first
    display_summary "$username" "$gateway_token"

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
