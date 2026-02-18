#!/bin/bash

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo "This script must be run with root privileges"
       exit 1
    fi
}

# Validate action (init or join)
validate_action() {
    if [[ "$ACTION" != "init" && "$ACTION" != "join" ]]; then
        echo "Error: First argument must be 'init' or 'join' subcommand"
        exit 1
    fi
}

# Check required arguments for join
validate_join_args() {
    if [[ "$ACTION" == "join" ]]; then
        if [[ -z "$JOIN_TOKEN" || -z "$JOIN_ADDRESS" || -z "$DISCOVERY_TOKEN_HASH" ]]; then
            echo "Error: join requires --join-token, --join-address, and --discovery-token-hash"
            exit 1
        fi
        # Validate HA control-plane join args
        if [ "$JOIN_AS_CONTROL_PLANE" = true ] && [ -z "$CERTIFICATE_KEY" ]; then
            echo "Error: --control-plane requires --certificate-key"
            exit 1
        fi
    fi
}

# Validate CRI selection
validate_cri() {
    local supported_cris=("containerd" "crio")
    local is_supported=false

    for supported in "${supported_cris[@]}"; do
        if [[ "$CRI" == "$supported" ]]; then
            is_supported=true
            break
        fi
    done

    if [[ "$is_supported" == false ]]; then
        echo "Error: Unsupported CRI '$CRI'. Supported options are: ${supported_cris[*]}"
        exit 1
    fi
}

# Validate shell completion options
validate_completion_options() {
    if [[ "$ENABLE_COMPLETION" != "true" && "$ENABLE_COMPLETION" != "false" ]]; then
        echo "Error: --enable-completion must be 'true' or 'false'"
        exit 1
    fi

    if [[ "$INSTALL_HELM" != "true" && "$INSTALL_HELM" != "false" ]]; then
        echo "Error: --install-helm must be 'true' or 'false'"
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
                echo "Error: Invalid shell '$shell_name' in --completion-shells. Valid options are: ${valid_shells[*]} or 'auto'"
                exit 1
            fi
        done
    fi
}

# Validate proxy mode selection
validate_proxy_mode() {
    if [[ "$PROXY_MODE" != "iptables" && "$PROXY_MODE" != "ipvs" && "$PROXY_MODE" != "nftables" ]]; then
        echo "Error: Proxy mode must be 'iptables', 'ipvs', or 'nftables'"
        exit 1
    fi

    if [[ "$PROXY_MODE" == "nftables" ]]; then
        if [[ -z "$K8S_VERSION" ]]; then
            echo "Warning: Kubernetes version not yet determined, skipping nftables version check"
            return 0
        fi

        local k8s_major k8s_minor
        k8s_major=$(echo "$K8S_VERSION" | cut -d. -f1)
        k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)

        if [[ "$k8s_major" -lt 1 ]] || [[ "$k8s_major" -eq 1 && "$k8s_minor" -lt 29 ]]; then
            echo "Error: nftables proxy mode requires Kubernetes 1.29 or higher"
            echo "Current version: $K8S_VERSION"
            echo "Please use --kubernetes-version 1.29 or higher, or choose a different proxy mode"
            exit 1
        fi

        if [[ "$k8s_major" -eq 1 && "$k8s_minor" -lt 31 ]]; then
            echo "Warning: nftables is in alpha status in Kubernetes $K8S_VERSION (beta from 1.31+)"
        fi
    fi
}

# Validate HA arguments
validate_ha_args() {
    if [ "$HA_ENABLED" = true ]; then
        if [ "$ACTION" != "init" ]; then
            echo "Error: --ha is only valid with the 'init' subcommand" >&2
            exit 1
        fi
        if [ -z "$HA_VIP_ADDRESS" ]; then
            echo "Error: --ha requires --ha-vip ADDRESS" >&2
            exit 1
        fi
    fi

    # VIP address applies to both init --ha and join --control-plane
    if [ -n "$HA_VIP_ADDRESS" ]; then
        # On join, --ha-vip requires --control-plane
        if [ "$ACTION" = "join" ] && [ "$JOIN_AS_CONTROL_PLANE" != true ]; then
            echo "Error: --ha-vip on join requires --control-plane" >&2
            exit 1
        fi
        # Auto-detect interface if not specified
        if [ -z "$HA_VIP_INTERFACE" ]; then
            HA_VIP_INTERFACE=$(ip route get 1 2>/dev/null | awk '{print $5; exit}')
            if [ -z "$HA_VIP_INTERFACE" ]; then
                echo "Error: Could not auto-detect network interface. Please specify --ha-interface" >&2
                exit 1
            fi
        fi
        # Auto-set --control-plane-endpoint for init
        if [ "$ACTION" = "init" ]; then
            local cp_endpoint_set=false
            local i=0
            while [ $i -lt ${#KUBEADM_ARGS[@]} ]; do
                if [ "${KUBEADM_ARGS[$i]}" = "--control-plane-endpoint" ]; then
                    cp_endpoint_set=true
                    break
                fi
                ((i+=1))
            done
            if [ "$cp_endpoint_set" = false ]; then
                KUBEADM_ARGS+=(--control-plane-endpoint "${HA_VIP_ADDRESS}:6443")
            fi
        fi
    fi
}

# Help message for setup (accepts optional exit code, default 0)
show_setup_help() {
    echo "Usage: $0 <init|join> [options]"
    echo ""
    echo "Subcommands:"
    echo "  init                    Initialize a new Kubernetes cluster"
    echo "  join                    Join an existing cluster as a worker or control-plane node"
    echo ""
    echo "Options:"
    echo "  --cri RUNTIME           Container runtime (containerd or crio). Default: containerd"
    echo "  --proxy-mode MODE       Kube-proxy mode (iptables, ipvs, or nftables). Default: iptables"
    echo "  --pod-network-cidr CIDR Pod network CIDR (e.g., 192.168.0.0/16)"
    echo "  --apiserver-advertise-address ADDR  API server advertise address"
    echo "  --control-plane-endpoint ENDPOINT   Control plane endpoint"
    echo "  --service-cidr CIDR     Service CIDR (e.g., 10.96.0.0/12)"
    echo "  --kubernetes-version VER Kubernetes version (e.g., 1.29, 1.28)"
    echo "  --join-token TOKEN      Join token (join only)"
    echo "  --join-address ADDR     Control plane address (join only)"
    echo "  --discovery-token-hash HASH  Discovery token hash (join only)"
    echo "  --control-plane         Join as control-plane node (join only, HA cluster)"
    echo "  --certificate-key KEY   Certificate key for control-plane join"
    echo "  --ha                    Enable HA mode with kube-vip (init only)"
    echo "  --ha-vip ADDRESS        VIP address (required when --ha; also for join --control-plane)"
    echo "  --ha-interface IFACE    Network interface for VIP (auto-detected if omitted)"
    echo "  --enable-completion BOOL  Enable shell completion setup (default: true)"
    echo "  --completion-shells LIST  Shells to configure (auto, bash, zsh, fish, or comma-separated)"
    echo "  --install-helm BOOL     Install Helm package manager (default: false)"
    echo "  --dry-run               Show configuration summary and exit"
    echo "  --verbose               Enable debug logging"
    echo "  --quiet                 Suppress informational messages"
    echo "  --help                  Display this help message"
    exit "${1:-0}"
}

# Help message for cleanup (accepts optional exit code, default 0)
show_cleanup_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --force         Skip confirmation prompt"
    echo "  --preserve-cni  Preserve CNI configurations"
    echo "  --remove-helm   Remove Helm binary and configuration"
    echo "  --verbose       Enable debug logging"
    echo "  --quiet         Suppress informational messages"
    echo "  --help          Display this help message"
    exit "${1:-0}"
}

# Guard for options requiring a value argument
_require_value() {
    if [[ $1 -lt 2 ]]; then
        echo "Error: $2 requires a value" >&2
        exit 1
    fi
}

# Parse command line arguments for setup
parse_setup_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_setup_help
                ;;
            --cri)
                _require_value $# "$1"
                CRI="$2"
                shift 2
                ;;
            --kubernetes-version)
                _require_value $# "$1"
                K8S_VERSION="$2"
                shift 2
                ;;
            --join-token)
                _require_value $# "$1"
                JOIN_TOKEN="$2"
                shift 2
                ;;
            --join-address)
                _require_value $# "$1"
                JOIN_ADDRESS="$2"
                shift 2
                ;;
            --discovery-token-hash)
                _require_value $# "$1"
                DISCOVERY_TOKEN_HASH="$2"
                shift 2
                ;;
            --proxy-mode)
                _require_value $# "$1"
                PROXY_MODE="$2"
                shift 2
                ;;
            --control-plane)
                JOIN_AS_CONTROL_PLANE=true
                shift
                ;;
            --certificate-key)
                _require_value $# "$1"
                CERTIFICATE_KEY="$2"
                shift 2
                ;;
            --ha)
                HA_ENABLED=true
                shift
                ;;
            --ha-vip)
                _require_value $# "$1"
                HA_VIP_ADDRESS="$2"
                shift 2
                ;;
            --ha-interface)
                _require_value $# "$1"
                HA_VIP_INTERFACE="$2"
                shift 2
                ;;
            --enable-completion)
                _require_value $# "$1"
                ENABLE_COMPLETION="$2"
                shift 2
                ;;
            --install-helm)
                _require_value $# "$1"
                INSTALL_HELM="$2"
                shift 2
                ;;
            --completion-shells)
                _require_value $# "$1"
                COMPLETION_SHELLS="$2"
                shift 2
                ;;
            --pod-network-cidr|--apiserver-advertise-address|--control-plane-endpoint|--service-cidr)
                _require_value $# "$1"
                KUBEADM_ARGS+=("$1" "$2")
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_setup_help 1
                ;;
        esac
    done
}

# Parse command line arguments for cleanup
parse_cleanup_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_cleanup_help
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --preserve-cni)
                export PRESERVE_CNI=true
                shift
                ;;
            --remove-helm)
                REMOVE_HELM=true
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_cleanup_help 1
                ;;
        esac
    done
}

# Confirmation prompt for cleanup
confirm_cleanup() {
    if [ "$FORCE" = false ]; then
        echo "WARNING: This script will remove Kubernetes configurations."
        echo "Are you sure you want to continue? (y/N)"
        if [ -t 0 ]; then
            read -r response
        else
            read -r response < /dev/tty
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
        echo "WARNING: Docker is installed on this system."
        echo "This cleanup script will reset containerd configuration but will NOT remove containerd."
        echo "Docker should continue to work normally after cleanup."
    fi
}
