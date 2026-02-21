#!/bin/bash

# Check required arguments for join
validate_join_args() {
    if [[ "$ACTION" == "join" ]]; then
        if [[ -z "$JOIN_TOKEN" || -z "$JOIN_ADDRESS" || -z "$DISCOVERY_TOKEN_HASH" ]]; then
            log_error "join requires --join-token, --join-address, and --discovery-token-hash"
            exit 1
        fi
        # Validate join token format: 6 alphanumeric chars, dot, 16 alphanumeric chars
        if ! [[ "$JOIN_TOKEN" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]; then
            log_error "--join-token format is invalid (expected: [a-z0-9]{6}.[a-z0-9]{16}, got: $JOIN_TOKEN)"
            exit 1
        fi
        # Validate discovery token hash format: sha256:<64 hex chars>
        if ! [[ "$DISCOVERY_TOKEN_HASH" =~ ^sha256:[a-f0-9]{64}$ ]]; then
            log_error "--discovery-token-hash format is invalid (expected: sha256:<64 hex chars>, got: $DISCOVERY_TOKEN_HASH)"
            exit 1
        fi
        # Validate join address format: host:port (host part must be non-empty)
        if ! [[ "$JOIN_ADDRESS" =~ ^.+:[0-9]+$ ]]; then
            log_error "--join-address should include a port (e.g., 192.168.1.10:6443, got: $JOIN_ADDRESS)"
            exit 1
        fi
        local _join_port="${JOIN_ADDRESS##*:}"
        if [ "$_join_port" -lt 1 ] || [ "$_join_port" -gt 65535 ]; then
            log_error "--join-address port out of range (1-65535, got: $_join_port)"
            exit 1
        fi
        # Validate HA control-plane join args
        if [ "$JOIN_AS_CONTROL_PLANE" = true ] && [ -z "$CERTIFICATE_KEY" ]; then
            log_error "--control-plane requires --certificate-key"
            exit 1
        fi
    fi
}

# Validate CRI selection
validate_cri() {
    case "$CRI" in
        containerd|crio) ;;
        *) log_error "Unsupported CRI '$CRI'. Supported options are: containerd, crio"; exit 1 ;;
    esac
}

# Validate shell completion options
validate_completion_options() {
    if [[ "$ENABLE_COMPLETION" != "true" && "$ENABLE_COMPLETION" != "false" ]]; then
        log_error "--enable-completion must be 'true' or 'false'"
        exit 1
    fi

    if [[ "$INSTALL_HELM" != "true" && "$INSTALL_HELM" != "false" ]]; then
        log_error "--install-helm must be 'true' or 'false'"
        exit 1
    fi

    if [[ "$COMPLETION_SHELLS" != "auto" ]]; then
        local valid_shells=("bash" "zsh" "fish")
        IFS=',' read -ra shells <<< "$COMPLETION_SHELLS"
        for shell_name in "${shells[@]}"; do
            shell_name=$(echo "$shell_name" | tr -d ' ')
            local is_valid=false
            for valid in "${valid_shells[@]}"; do
                if [[ "$shell_name" == "$valid" ]]; then
                    is_valid=true
                    break
                fi
            done
            if [[ "$is_valid" == false ]]; then
                log_error "Invalid shell '$shell_name' in --completion-shells. Valid options are: ${valid_shells[*]} or 'auto'"
                exit 1
            fi
        done
    fi
}

# Validate proxy mode selection
validate_proxy_mode() {
    if [[ "$PROXY_MODE" != "iptables" && "$PROXY_MODE" != "ipvs" && "$PROXY_MODE" != "nftables" ]]; then
        log_error "Proxy mode must be 'iptables', 'ipvs', or 'nftables'"
        exit 1
    fi

    if [[ "$PROXY_MODE" == "nftables" ]]; then
        local k8s_major k8s_minor
        k8s_major=$(echo "$K8S_VERSION" | cut -d. -f1)
        k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)

        if [[ "$k8s_major" -lt 1 ]] || [[ "$k8s_major" -eq 1 && "$k8s_minor" -lt 29 ]]; then
            log_error "nftables proxy mode requires Kubernetes 1.29 or higher"
            log_error "Current version: $K8S_VERSION"
            log_error "Please use --kubernetes-version 1.29 or higher, or choose a different proxy mode"
            exit 1
        fi

        if [[ "$k8s_major" -eq 1 && "$k8s_minor" -lt 31 ]]; then
            log_warn "nftables is in alpha status in Kubernetes $K8S_VERSION (beta from 1.31+)"
        fi
    fi
}

# Validate swap enabled option (requires K8s 1.28+)
validate_swap_enabled() {
    if [ "$SWAP_ENABLED" = true ] && [ -n "$K8S_VERSION" ]; then
        local k8s_minor
        k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)
        if [ -n "$k8s_minor" ] && [ "$k8s_minor" -lt 28 ]; then
            log_error "--swap-enabled requires Kubernetes 1.28+ (got: $K8S_VERSION)"
            exit 1
        fi
    fi
}

# Validate CIDR format (IPv4)
_validate_cidr() {
    local cidr="$1" label="$2"
    if [[ ! "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        log_error "Invalid CIDR format for $label: $cidr"
        log_error "Expected format: x.x.x.x/y (e.g., 192.168.0.0/16)"
        exit 1
    fi
    # Validate octet ranges (0-255) and prefix length (0-32)
    local o1 o2 o3 o4 prefix
    IFS='./' read -r o1 o2 o3 o4 prefix <<< "$cidr"
    if (( 10#$o1>255 || 10#$o2>255 || 10#$o3>255 || 10#$o4>255 || 10#$prefix>32 )); then
        log_error "CIDR values out of range for $label: $cidr"
        exit 1
    fi
}

# Validate HA arguments
validate_ha_args() {
    if [ "$HA_ENABLED" = true ]; then
        if [ "$ACTION" != "init" ]; then
            log_error "--ha is only valid with the 'init' subcommand"
            exit 1
        fi
        if [ -z "$HA_VIP_ADDRESS" ]; then
            log_error "--ha requires --ha-vip ADDRESS"
            exit 1
        fi
    fi

    # On init, --ha-vip requires --ha (otherwise kube-vip is not deployed)
    if [ -n "$HA_VIP_ADDRESS" ] && [ "$ACTION" = "init" ] && [ "$HA_ENABLED" = false ]; then
        log_error "--ha-vip with init requires --ha flag"
        exit 1
    fi

    # VIP address applies to both init --ha and join --control-plane
    if [ -n "$HA_VIP_ADDRESS" ]; then
        # Validate VIP address format (IPv4)
        if ! [[ "$HA_VIP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_error "--ha-vip must be a valid IPv4 address (got: $HA_VIP_ADDRESS)"
            exit 1
        fi
        local _vo1 _vo2 _vo3 _vo4
        IFS='.' read -r _vo1 _vo2 _vo3 _vo4 <<< "$HA_VIP_ADDRESS"
        if (( 10#$_vo1>255 || 10#$_vo2>255 || 10#$_vo3>255 || 10#$_vo4>255 )); then
            log_error "--ha-vip octets out of range (got: $HA_VIP_ADDRESS)"
            exit 1
        fi
        # On join, --ha-vip requires --control-plane
        if [ "$ACTION" = "join" ] && [ "$JOIN_AS_CONTROL_PLANE" != true ]; then
            log_error "--ha-vip on join requires --control-plane"
            exit 1
        fi
        # Auto-detect interface if not specified
        if [ -z "$HA_VIP_INTERFACE" ]; then
            local _iproute_out
            if ! _iproute_out=$(ip route get 1 2>&1); then
                log_error "Could not auto-detect network interface. Please specify --ha-interface"
                [ -n "$_iproute_out" ] && log_error "  ip route error: $_iproute_out"
                exit 1
            fi
            HA_VIP_INTERFACE=$(echo "$_iproute_out" | awk '{print $5; exit}')
            if [ -z "$HA_VIP_INTERFACE" ]; then
                log_error "Could not auto-detect network interface. Please specify --ha-interface"
                exit 1
            fi
        fi
        # Validate interface name (alphanumeric, hyphens, dots; typical Linux interface names)
        if ! [[ "$HA_VIP_INTERFACE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            log_error "--ha-interface contains invalid characters (got: $HA_VIP_INTERFACE)"
            exit 1
        fi
        # Auto-set --control-plane-endpoint for init
        if [ "$ACTION" = "init" ] && [ -z "$KUBEADM_CP_ENDPOINT" ]; then
            KUBEADM_CP_ENDPOINT="${HA_VIP_ADDRESS}:6443"
        fi
    fi
}

# Guard for options requiring a value argument
_require_value() {
    if [[ $1 -lt 2 ]]; then
        log_error "$2 requires a value"
        exit 1
    fi
    # Reject flag-like values (starting with -) to catch missing arguments
    if [[ "${3:-}" == -* ]]; then
        log_error "$2 requires a value, got '$3' (looks like a flag)"
        exit 1
    fi
}

# Parse command line arguments for setup
parse_setup_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cri)
                _require_value $# "$1" "${2:-}"
                CRI="$2"
                shift 2
                ;;
            --kubernetes-version)
                _require_value $# "$1" "${2:-}"
                # Strict format validation: must be MAJOR.MINOR (e.g., 1.29, 1.32)
                if ! [[ "$2" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    log_error "--kubernetes-version must be in MAJOR.MINOR format (e.g., 1.29, 1.32), got '$2'"
                    exit 1
                fi
                K8S_VERSION="$2"
                shift 2
                ;;
            --join-token)
                _require_value $# "$1" "${2:-}"
                JOIN_TOKEN="$2"
                shift 2
                ;;
            --join-address)
                _require_value $# "$1" "${2:-}"
                JOIN_ADDRESS="$2"
                shift 2
                ;;
            --discovery-token-hash)
                _require_value $# "$1" "${2:-}"
                DISCOVERY_TOKEN_HASH="$2"
                shift 2
                ;;
            --proxy-mode)
                _require_value $# "$1" "${2:-}"
                PROXY_MODE="$2"
                shift 2
                ;;
            --control-plane)
                JOIN_AS_CONTROL_PLANE=true
                shift
                ;;
            --certificate-key)
                _require_value $# "$1" "${2:-}"
                CERTIFICATE_KEY="$2"
                shift 2
                ;;
            --ha)
                HA_ENABLED=true
                shift
                ;;
            --ha-vip)
                _require_value $# "$1" "${2:-}"
                HA_VIP_ADDRESS="$2"
                shift 2
                ;;
            --ha-interface)
                _require_value $# "$1" "${2:-}"
                HA_VIP_INTERFACE="$2"
                shift 2
                ;;
            --enable-completion)
                _require_value $# "$1" "${2:-}"
                ENABLE_COMPLETION="$2"
                shift 2
                ;;
            --install-helm)
                _require_value $# "$1" "${2:-}"
                INSTALL_HELM="$2"
                shift 2
                ;;
            --completion-shells)
                _require_value $# "$1" "${2:-}"
                COMPLETION_SHELLS="$2"
                shift 2
                ;;
            --pod-network-cidr)
                _require_value $# "$1" "${2:-}"
                _validate_cidr "$2" "$1"
                # shellcheck disable=SC2034 # used by helpers.sh
                KUBEADM_POD_CIDR="$2"
                shift 2
                ;;
            --service-cidr)
                _require_value $# "$1" "${2:-}"
                _validate_cidr "$2" "$1"
                # shellcheck disable=SC2034 # used by helpers.sh
                KUBEADM_SERVICE_CIDR="$2"
                shift 2
                ;;
            --apiserver-advertise-address)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by helpers.sh
                KUBEADM_API_ADDR="$2"
                shift 2
                ;;
            --control-plane-endpoint)
                _require_value $# "$1" "${2:-}"
                KUBEADM_CP_ENDPOINT="$2"
                shift 2
                ;;
            --swap-enabled)
                SWAP_ENABLED=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Run with --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Help message for deploy
show_deploy_help() {
    echo "Usage: $0 deploy [options]"
    echo ""
    echo "Deploy a Kubernetes cluster across remote nodes via SSH."
    echo ""
    echo "Required:"
    echo "  --control-planes IPs    Comma-separated list of control-plane nodes (user@ip or ip)"
    echo ""
    echo "Optional:"
    echo "  --workers IPs           Comma-separated list of worker nodes (user@ip or ip)"
    echo "  --ssh-user USER         Default SSH user (default: root)"
    echo "  --ssh-port PORT         SSH port (default: 22)"
    echo "  --ssh-key PATH          Path to SSH private key"
    echo "  --ssh-password PASS     SSH password (requires sshpass; prefer DEPLOY_SSH_PASSWORD env var)"
    echo "  --ssh-known-hosts FILE  Pre-seeded known_hosts for strict host key verification"
    echo "  --ssh-host-key-check MODE  SSH host key policy: yes, no, or accept-new (default: yes)"
    echo "  --ha-vip ADDRESS        VIP address for HA (required when >1 control-plane)"
    echo "  --ha-interface IFACE    Network interface for VIP (auto-detected on remote)"
    echo "  --cri RUNTIME           Container runtime (containerd or crio)"
    echo "  --proxy-mode MODE       Kube-proxy mode (iptables, ipvs, or nftables)"
    echo "  --swap-enabled          Keep swap enabled (K8s 1.28+)"
    echo "  --kubernetes-version VER Kubernetes version (e.g., 1.32)"
    echo "  --pod-network-cidr CIDR Pod network CIDR"
    echo "  --service-cidr CIDR     Service CIDR"
    echo "  --dry-run               Show deployment plan and exit"
    echo "  --verbose               Enable debug logging"
    echo "  --quiet                 Suppress informational messages"
    echo "  --help                  Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0 deploy --control-planes 10.0.0.1 --workers 10.0.0.2,10.0.0.3 --ssh-key ~/.ssh/id_rsa"
    echo "  $0 deploy --control-planes 10.0.0.1,10.0.0.2,10.0.0.3 --workers 10.0.0.4 --ha-vip 10.0.0.100"
    echo "  $0 deploy --control-planes admin@10.0.0.1 --workers ubuntu@10.0.0.2"
    exit "${1:-0}"
}

# Parse command line arguments for deploy
parse_deploy_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_deploy_help
                ;;
            --control-planes)
                _require_value $# "$1" "${2:-}"
                DEPLOY_CONTROL_PLANES="$2"
                shift 2
                ;;
            --workers)
                _require_value $# "$1" "${2:-}"
                DEPLOY_WORKERS="$2"
                shift 2
                ;;
            --ssh-user)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by common/deploy.sh after sourcing
                DEPLOY_SSH_USER="$2"
                shift 2
                ;;
            --ssh-port)
                _require_value $# "$1" "${2:-}"
                DEPLOY_SSH_PORT="$2"
                shift 2
                ;;
            --ssh-key)
                _require_value $# "$1" "${2:-}"
                DEPLOY_SSH_KEY="$2"
                shift 2
                ;;
            --ssh-password)
                if [[ $# -lt 2 ]]; then
                    log_error "$1 requires a value"
                    exit 1
                fi
                log_warn "--ssh-password exposes the password in the process list. Prefer DEPLOY_SSH_PASSWORD env var."
                DEPLOY_SSH_PASSWORD="$2"
                shift 2
                ;;
            --ssh-known-hosts)
                _require_value $# "$1" "${2:-}"
                DEPLOY_SSH_KNOWN_HOSTS_FILE="$2"
                shift 2
                ;;
            --ssh-host-key-check)
                _require_value $# "$1" "${2:-}"
                if [[ "$2" != "yes" && "$2" != "no" && "$2" != "accept-new" ]]; then
                    log_error "--ssh-host-key-check must be 'yes', 'no', or 'accept-new'"
                    exit 1
                fi
                if [[ "$2" == "no" ]]; then
                    log_warn "Disabling SSH host key verification allows MITM attacks. Consider 'accept-new' instead."
                fi
                # shellcheck disable=SC2034 # used by common/deploy.sh after sourcing
                DEPLOY_SSH_HOST_KEY_CHECK="$2"
                shift 2
                ;;
            --ha-vip)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS+=("--ha-vip" "$2")
                shift 2
                ;;
            --ha-interface)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS+=("--ha-interface" "$2")
                shift 2
                ;;
            --cri|--proxy-mode|--kubernetes-version|--pod-network-cidr|--service-cidr|--apiserver-advertise-address|--control-plane-endpoint)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS+=("$1" "$2")
                shift 2
                ;;
            --swap-enabled)
                DEPLOY_PASSTHROUGH_ARGS+=("$1")
                shift
                ;;
            --enable-completion|--install-helm|--completion-shells)
                _require_value $# "$1" "${2:-}"
                DEPLOY_PASSTHROUGH_ARGS+=("$1" "$2")
                shift 2
                ;;
            *)
                log_error "Unknown deploy option: $1"
                show_deploy_help 1
                ;;
        esac
    done
}

# Validate deploy arguments
validate_deploy_args() {
    # --control-planes is required
    if [ -z "$DEPLOY_CONTROL_PLANES" ]; then
        log_error "--control-planes is required for deploy"
        exit 1
    fi

    # Normalize node lists early: trim whitespace and remove empty tokens.
    # Write back to source variables so all subsequent logic sees clean values.
    _normalize_node_list() {
        local raw="$1" result=() cleaned=() token
        IFS=',' read -ra result <<< "$raw"
        for token in "${result[@]}"; do
            token="${token#"${token%%[![:space:]]*}"}"  # trim leading whitespace
            token="${token%"${token##*[![:space:]]}"}"  # trim trailing whitespace
            [ -n "$token" ] && cleaned+=("$token")
        done
        local IFS=','
        echo "${cleaned[*]}"
    }
    DEPLOY_CONTROL_PLANES=$(_normalize_node_list "$DEPLOY_CONTROL_PLANES")
    [ -n "$DEPLOY_WORKERS" ] && DEPLOY_WORKERS=$(_normalize_node_list "$DEPLOY_WORKERS")

    # Re-check after normalization (e.g., ",,," normalizes to empty)
    if [ -z "$DEPLOY_CONTROL_PLANES" ]; then
        log_error "--control-planes contains no valid node addresses"
        exit 1
    fi

    # Validate SSH user if specified
    if [ -n "$DEPLOY_SSH_USER" ] && ! [[ "$DEPLOY_SSH_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]]; then
        log_error "Invalid SSH user: $DEPLOY_SSH_USER"
        exit 1
    fi

    # Count control-plane nodes
    local cp_count
    IFS=',' read -ra _cp_nodes <<< "$DEPLOY_CONTROL_PLANES"
    cp_count=${#_cp_nodes[@]}

    # Check --ha-vip in passthrough args
    local has_ha_vip=false
    for arg in "${DEPLOY_PASSTHROUGH_ARGS[@]}"; do
        if [ "$arg" = "--ha-vip" ]; then
            has_ha_vip=true
            break
        fi
    done

    # If >1 CP, --ha-vip is required
    if [ "$cp_count" -gt 1 ] && [ "$has_ha_vip" = false ]; then
        log_error "--ha-vip is required when using multiple control-plane nodes"
        exit 1
    fi

    # If only 1 CP, --ha-vip is not applicable
    if [ "$cp_count" -eq 1 ] && [ "$has_ha_vip" = true ]; then
        log_error "--ha-vip requires multiple control-plane nodes (got 1)"
        exit 1
    fi

    # Validate SSH key file exists if specified
    if [ -n "$DEPLOY_SSH_KEY" ] && [ ! -f "$DEPLOY_SSH_KEY" ]; then
        log_error "SSH key file not found: $DEPLOY_SSH_KEY"
        exit 1
    fi

    # Validate known_hosts file exists if specified
    if [ -n "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] && [ ! -f "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        log_error "Known hosts file not found: $DEPLOY_SSH_KNOWN_HOSTS_FILE"
        exit 1
    fi

    # Check sshpass if password authentication is used
    if [ -n "$DEPLOY_SSH_PASSWORD" ] && ! command -v sshpass &>/dev/null; then
        log_error "sshpass is required for --ssh-password. Install it with your package manager."
        exit 1
    fi

    # Validate port number
    if ! [[ "$DEPLOY_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$DEPLOY_SSH_PORT" -lt 1 ] || [ "$DEPLOY_SSH_PORT" -gt 65535 ]; then
        log_error "Invalid SSH port: $DEPLOY_SSH_PORT"
        exit 1
    fi

    # Validate node addresses (IP or hostname format)
    local all_addrs="$DEPLOY_CONTROL_PLANES"
    [ -n "$DEPLOY_WORKERS" ] && all_addrs="$all_addrs,$DEPLOY_WORKERS"
    IFS=',' read -ra _all_nodes <<< "$all_addrs"

    # Check for duplicate host addresses
    local -A _seen_hosts=()
    for addr in "${_all_nodes[@]}"; do
        local host="${addr#*@}"
        if [ -n "${_seen_hosts[$host]:-}" ]; then
            log_error "Duplicate node address: $host"
            exit 1
        fi
        _seen_hosts[$host]="$addr"
    done

    for addr in "${_all_nodes[@]}"; do
        # Validate optional user@ prefix
        if [[ "$addr" == *@* ]]; then
            local username="${addr%%@*}"
            if [ -z "$username" ]; then
                log_error "Empty username in node address: $addr"
                exit 1
            fi
            # Reject usernames starting with '-' (SSH option injection)
            if [[ "$username" == -* ]]; then
                log_error "Invalid username (starts with '-'): $username"
                exit 1
            fi
            # Only allow safe characters in usernames
            if ! [[ "$username" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                log_error "Invalid username: $username"
                exit 1
            fi
        fi
        # Strip optional user@ prefix
        local host="${addr#*@}"
        if [ -z "$host" ]; then
            log_error "Empty node address in list"
            exit 1
        fi
        # Validate host: IPv4, hostname, or bracketed IPv6 (e.g., [::1])
        if [[ "$host" =~ ^\[.*\]$ ]]; then
            # Bracketed IPv6: strip brackets and validate hex/colons
            local ipv6_inner="${host:1:${#host}-2}"
            if ! [[ "$ipv6_inner" =~ ^[a-fA-F0-9:]+$ ]]; then
                log_error "Invalid IPv6 address: $host"
                exit 1
            fi
        elif [[ "$host" == *:* ]]; then
            # Raw IPv6 without brackets: require brackets for SCP compatibility
            log_error "IPv6 addresses must be enclosed in brackets, e.g., [$host]"
            exit 1
        elif ! [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
            log_error "Invalid node address: $host"
            exit 1
        fi
    done
}

# Parse command line arguments for cleanup
parse_cleanup_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE=true
                shift
                ;;
            --preserve-cni)
                # shellcheck disable=SC2034 # used by helpers.sh
                PRESERVE_CNI=true
                shift
                ;;
            --remove-helm)
                # shellcheck disable=SC2034 # used by cleanup-k8s.sh after sourcing
                REMOVE_HELM=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Run with --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Confirmation prompt for cleanup
confirm_cleanup() {
    if [ "$FORCE" = false ]; then
        log_warn "This script will remove Kubernetes configurations."
        echo "Are you sure you want to continue? (y/N)"
        if [ -t 0 ]; then
            read -r response
        elif [ -r /dev/tty ]; then
            read -r response < /dev/tty || {
                log_error "Non-interactive environment detected. Use --force to skip confirmation."
                exit 1
            }
        else
            log_error "Non-interactive environment detected. Use --force to skip confirmation."
            exit 1
        fi
        if [[ ! "$response" =~ ^[yY]$ ]]; then
            echo "Operation cancelled."
            exit 0
        fi
    fi
}

# Check if Docker is installed and warn about containerd
check_docker_warning() {
    if command -v docker &> /dev/null; then
        log_warn "Docker is installed on this system."
        log_warn "This cleanup script will reset containerd configuration but will NOT remove containerd."
        log_warn "Docker should continue to work normally after cleanup."
    fi
}
