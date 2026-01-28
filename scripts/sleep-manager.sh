#!/usr/bin/env bash
#
# sleep-manager.sh - Monitor and manage container sleep states
#
# Monitors Boardroom container activity and stops containers that have been
# idle for more than the configured timeout period. Includes placeholder
# for wake-on-request webhook integration.
#
# Usage: ./sleep-manager.sh [options]
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-30}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-60}"
STATE_DIR="${PROJECT_ROOT}/data/state"
ACTIVITY_LOG="${STATE_DIR}/activity.log"
WEBHOOK_PORT="${WEBHOOK_PORT:-8080}"
WEBHOOK_ENABLED="${WEBHOOK_ENABLED:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[INFO]${NC} [${timestamp}] $1"
}

log_success() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[SUCCESS]${NC} [${timestamp}] $1"
}

log_warn() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[WARN]${NC} [${timestamp}] $1"
}

log_error() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ERROR]${NC} [${timestamp}] $1" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "${CYAN}[DEBUG]${NC} [${timestamp}] $1"
    fi
}

# Display usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [options]

Monitor Boardroom container activity and manage sleep states.

Options:
    --daemon, -d        Run as daemon (continuous monitoring)
    --once              Run once and exit (check all containers)
    --status            Show status of all Boardroom containers
    --wake <username>   Wake a sleeping user's containers
    --webhook           Start webhook server for wake-on-request (placeholder)
    --help, -h          Show this help message

Environment Variables:
    IDLE_TIMEOUT_MINUTES    Minutes before container is considered idle (default: 30)
    CHECK_INTERVAL_SECONDS  Seconds between activity checks in daemon mode (default: 60)
    WEBHOOK_PORT            Port for wake-on-request webhook (default: 8080)
    WEBHOOK_ENABLED         Enable webhook server (default: false)
    DEBUG                   Enable debug logging (default: false)

Examples:
    $(basename "$0") --status              # Show all container status
    $(basename "$0") --once                # Check and sleep idle containers once
    $(basename "$0") --daemon              # Run continuously
    $(basename "$0") --wake john-doe       # Wake up a user's containers
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

# Initialize state directory
init_state_dir() {
    mkdir -p "$STATE_DIR"
    touch "$ACTIVITY_LOG"
}

# Get all Boardroom containers
get_boardroom_containers() {
    docker ps -a \
        --filter "label=boardroom.user" \
        --format "{{.Names}}" 2>/dev/null || true
}

# Get running Boardroom containers
get_running_containers() {
    docker ps \
        --filter "label=boardroom.user" \
        --filter "status=running" \
        --format "{{.Names}}" 2>/dev/null || true
}

# Get stopped Boardroom containers (sleeping)
get_sleeping_containers() {
    docker ps -a \
        --filter "label=boardroom.user" \
        --filter "status=exited" \
        --format "{{.Names}}" 2>/dev/null || true
}

# Extract username from container name
get_username_from_container() {
    local container_name="$1"
    # Container names are: boardroom-{username}-console or boardroom-{username}-proxy
    echo "$container_name" | sed -E 's/^boardroom-(.+)-(console|proxy)$/\1/'
}

# Get container role (console or proxy)
get_container_role() {
    local container_name="$1"
    echo "$container_name" | sed -E 's/^boardroom-.+-(console|proxy)$/\1/'
}

# Get last activity time for a container
get_last_activity() {
    local container_name="$1"
    local activity_file="${STATE_DIR}/${container_name}.last_activity"

    if [[ -f "$activity_file" ]]; then
        cat "$activity_file"
    else
        # If no activity file, use container start time
        docker inspect -f '{{.State.StartedAt}}' "$container_name" 2>/dev/null | \
            xargs -I {} date -j -f "%Y-%m-%dT%H:%M:%S" "{}" "+%s" 2>/dev/null || \
            date "+%s"
    fi
}

# Update last activity time for a container
update_activity() {
    local container_name="$1"
    local activity_file="${STATE_DIR}/${container_name}.last_activity"
    local timestamp
    timestamp=$(date "+%s")

    echo "$timestamp" > "$activity_file"
    log_debug "Updated activity for ${container_name}: ${timestamp}"
}

# Check if container has network activity (simplified check)
check_container_activity() {
    local container_name="$1"

    # Get container stats - check for network I/O
    # This is a simplified check; in production you might want more sophisticated monitoring
    local stats
    stats=$(docker stats --no-stream --format "{{.NetIO}}" "$container_name" 2>/dev/null || echo "0B / 0B")

    # Parse network I/O (format: "XXkB / YYkB" or "XXMB / YYMB")
    local rx_bytes tx_bytes
    rx_bytes=$(echo "$stats" | awk -F' / ' '{print $1}' | sed 's/[^0-9.]//g')
    tx_bytes=$(echo "$stats" | awk -F' / ' '{print $2}' | sed 's/[^0-9.]//g')

    # If there's any significant network activity, consider it active
    # This is a simple heuristic; adjust thresholds as needed
    if [[ -n "$rx_bytes" && -n "$tx_bytes" ]]; then
        local total
        total=$(echo "$rx_bytes + $tx_bytes" | bc 2>/dev/null || echo "0")
        if (( $(echo "$total > 0" | bc -l) )); then
            return 0  # Active
        fi
    fi

    return 1  # Inactive
}

# Check if container is idle (no activity for timeout period)
is_container_idle() {
    local container_name="$1"
    local current_time
    local last_activity
    local idle_seconds
    local timeout_seconds

    current_time=$(date "+%s")
    last_activity=$(get_last_activity "$container_name")
    idle_seconds=$((current_time - last_activity))
    timeout_seconds=$((IDLE_TIMEOUT_MINUTES * 60))

    log_debug "${container_name}: idle for ${idle_seconds}s (timeout: ${timeout_seconds}s)"

    if [[ $idle_seconds -ge $timeout_seconds ]]; then
        return 0  # Idle
    else
        return 1  # Not idle
    fi
}

# Sleep a user's containers
sleep_user_containers() {
    local username="$1"
    local console_name="boardroom-${username}-console"
    local proxy_name="boardroom-${username}-proxy"

    log_info "Putting user '${username}' to sleep (idle for ${IDLE_TIMEOUT_MINUTES}+ minutes)"

    # Stop proxy first
    if docker ps --filter "name=${proxy_name}" --filter "status=running" -q | grep -q .; then
        docker stop "$proxy_name" >/dev/null 2>&1 || true
        log_success "Stopped proxy: ${proxy_name}"
    fi

    # Stop console
    if docker ps --filter "name=${console_name}" --filter "status=running" -q | grep -q .; then
        docker stop "$console_name" >/dev/null 2>&1 || true
        log_success "Stopped console: ${console_name}"
    fi

    # Log the sleep event
    echo "$(date '+%Y-%m-%d %H:%M:%S') SLEEP ${username}" >> "$ACTIVITY_LOG"
}

# Wake a user's containers
wake_user_containers() {
    local username="$1"
    local console_name="boardroom-${username}-console"
    local proxy_name="boardroom-${username}-proxy"

    log_info "Waking user '${username}' containers"

    # Check if containers exist
    if ! docker container inspect "$console_name" &>/dev/null; then
        log_error "Console container not found: ${console_name}"
        return 1
    fi

    # Start console first
    if docker ps --filter "name=${console_name}" --filter "status=exited" -q | grep -q .; then
        docker start "$console_name" >/dev/null 2>&1 || true
        log_success "Started console: ${console_name}"
        update_activity "$console_name"
    else
        log_info "Console already running: ${console_name}"
    fi

    # Start proxy
    if docker ps --filter "name=${proxy_name}" --filter "status=exited" -q | grep -q .; then
        docker start "$proxy_name" >/dev/null 2>&1 || true
        log_success "Started proxy: ${proxy_name}"
        update_activity "$proxy_name"
    else
        log_info "Proxy already running: ${proxy_name}"
    fi

    # Log the wake event
    echo "$(date '+%Y-%m-%d %H:%M:%S') WAKE ${username}" >> "$ACTIVITY_LOG"

    return 0
}

# Show status of all containers
show_status() {
    echo ""
    echo "=============================================="
    echo "Boardroom Container Status"
    echo "=============================================="
    echo ""
    echo "Idle timeout: ${IDLE_TIMEOUT_MINUTES} minutes"
    echo ""

    # Get unique users
    local users
    users=$(get_boardroom_containers | sed -E 's/^boardroom-(.+)-(console|proxy)$/\1/' | sort -u)

    if [[ -z "$users" ]]; then
        echo "No Boardroom containers found."
        echo ""
        return
    fi

    printf "%-20s %-12s %-12s %-20s\n" "USERNAME" "CONSOLE" "PROXY" "IDLE TIME"
    printf "%-20s %-12s %-12s %-20s\n" "--------" "-------" "-----" "---------"

    for username in $users; do
        local console_name="boardroom-${username}-console"
        local proxy_name="boardroom-${username}-proxy"
        local console_status="missing"
        local proxy_status="missing"
        local idle_time="N/A"

        # Check console status
        if docker container inspect "$console_name" &>/dev/null; then
            console_status=$(docker container inspect -f '{{.State.Status}}' "$console_name" 2>/dev/null || echo "unknown")

            if [[ "$console_status" == "running" ]]; then
                console_status="${GREEN}running${NC}"

                # Calculate idle time
                local current_time last_activity idle_seconds
                current_time=$(date "+%s")
                last_activity=$(get_last_activity "$console_name")
                idle_seconds=$((current_time - last_activity))

                if [[ $idle_seconds -lt 60 ]]; then
                    idle_time="${idle_seconds}s"
                elif [[ $idle_seconds -lt 3600 ]]; then
                    idle_time="$((idle_seconds / 60))m"
                else
                    idle_time="$((idle_seconds / 3600))h $((idle_seconds % 3600 / 60))m"
                fi
            elif [[ "$console_status" == "exited" ]]; then
                console_status="${YELLOW}sleeping${NC}"
                idle_time="sleeping"
            else
                console_status="${RED}${console_status}${NC}"
            fi
        fi

        # Check proxy status
        if docker container inspect "$proxy_name" &>/dev/null; then
            proxy_status=$(docker container inspect -f '{{.State.Status}}' "$proxy_name" 2>/dev/null || echo "unknown")

            if [[ "$proxy_status" == "running" ]]; then
                proxy_status="${GREEN}running${NC}"
            elif [[ "$proxy_status" == "exited" ]]; then
                proxy_status="${YELLOW}sleeping${NC}"
            else
                proxy_status="${RED}${proxy_status}${NC}"
            fi
        fi

        printf "%-20s %-12b %-12b %-20s\n" "$username" "$console_status" "$proxy_status" "$idle_time"
    done

    echo ""
}

# Run one check cycle
run_check_cycle() {
    log_debug "Starting check cycle"

    local running_containers
    running_containers=$(get_running_containers)

    if [[ -z "$running_containers" ]]; then
        log_debug "No running containers to check"
        return
    fi

    # Get unique users with running containers
    local users
    users=$(echo "$running_containers" | sed -E 's/^boardroom-(.+)-(console|proxy)$/\1/' | sort -u)

    for username in $users; do
        local console_name="boardroom-${username}-console"

        # Check for activity
        if check_container_activity "$console_name" 2>/dev/null; then
            update_activity "$console_name"
            log_debug "Activity detected for user: ${username}"
        else
            # Check if idle timeout exceeded
            if is_container_idle "$console_name"; then
                sleep_user_containers "$username"
            fi
        fi
    done
}

# Run as daemon
run_daemon() {
    log_info "Starting sleep manager daemon"
    log_info "Idle timeout: ${IDLE_TIMEOUT_MINUTES} minutes"
    log_info "Check interval: ${CHECK_INTERVAL_SECONDS} seconds"
    echo ""

    # Trap signals for graceful shutdown
    trap 'log_info "Shutting down..."; exit 0' SIGINT SIGTERM

    while true; do
        run_check_cycle
        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

# Webhook server placeholder
start_webhook_server() {
    log_info "Starting wake-on-request webhook server on port ${WEBHOOK_PORT}"
    log_warn "PLACEHOLDER: Webhook server not yet implemented"

    cat << EOF

    Wake-on-Request Webhook (placeholder)
    --------------------------------------

    The webhook server would provide an HTTP endpoint for waking sleeping containers.

    Planned endpoints:

    POST /wake/{username}
        Wake a user's containers
        Response: { "status": "waking", "username": "..." }

    GET /status/{username}
        Get container status for a user
        Response: { "status": "running|sleeping|missing", "username": "..." }

    GET /health
        Health check endpoint
        Response: { "status": "ok" }

    Implementation notes:
    - Could use netcat, socat, or a lightweight HTTP server
    - Should integrate with Cloudflare Tunnel for external access
    - Should authenticate requests (API key, JWT, etc.)
    - Should rate-limit wake requests

    For now, use the --wake option to wake containers manually:
        $(basename "$0") --wake <username>

EOF
}

# Main function
main() {
    local mode="status"
    local wake_username=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -d|--daemon)
                mode="daemon"
                shift
                ;;
            --once)
                mode="once"
                shift
                ;;
            --status)
                mode="status"
                shift
                ;;
            --wake)
                mode="wake"
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing username for --wake"
                    usage
                fi
                wake_username="$2"
                shift 2
                ;;
            --webhook)
                mode="webhook"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *)
                log_error "Unexpected argument: $1"
                usage
                ;;
        esac
    done

    # Pre-flight checks
    check_docker
    init_state_dir

    # Execute based on mode
    case "$mode" in
        status)
            show_status
            ;;
        once)
            log_info "Running single check cycle"
            run_check_cycle
            log_success "Check cycle complete"
            ;;
        daemon)
            run_daemon
            ;;
        wake)
            wake_user_containers "$wake_username"
            ;;
        webhook)
            start_webhook_server
            ;;
    esac
}

# Run main function
main "$@"
