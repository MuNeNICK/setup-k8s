#!/bin/bash

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
       echo "This script must be run with root privileges"
       exit 1
    fi
}

# Validate node type
validate_node_type() {
    if [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "worker" ]]; then
        echo "Error: Node type must be either 'master' or 'worker'"
        exit 1
    fi
}

# Check required arguments for worker nodes
validate_worker_args() {
    if [[ "$NODE_TYPE" == "worker" ]]; then
        if [[ -z "$JOIN_TOKEN" || -z "$JOIN_ADDRESS" || -z "$DISCOVERY_TOKEN_HASH" ]]; then
            echo "Error: Worker nodes require --join-token, --join-address, and --discovery-token-hash"
            exit 1
        fi
    fi
}

# Validate CRI selection
validate_cri() {
    # List of supported CRIs
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
    # Validate ENABLE_COMPLETION is boolean
    if [[ "$ENABLE_COMPLETION" != "true" && "$ENABLE_COMPLETION" != "false" ]]; then
        echo "Error: --enable-completion must be 'true' or 'false'"
        exit 1
    fi
    
    # Validate INSTALL_HELM is boolean
    if [[ "$INSTALL_HELM" != "true" && "$INSTALL_HELM" != "false" ]]; then
        echo "Error: --install-helm must be 'true' or 'false'"
        exit 1
    fi
    
    # Validate COMPLETION_SHELLS
    if [[ "$COMPLETION_SHELLS" != "auto" ]]; then
        # Check if it's a valid shell or comma-separated list of shells
        local valid_shells=("bash" "zsh" "fish")
        IFS=',' read -ra shells <<< "$COMPLETION_SHELLS"
        for shell in "${shells[@]}"; do
            shell=$(echo "$shell" | tr -d ' ')  # Remove spaces
            local is_valid=false
            for valid in "${valid_shells[@]}"; do
                if [[ "$shell" == "$valid" ]]; then
                    is_valid=true
                    break
                fi
            done
            if [[ "$is_valid" == false ]]; then
                echo "Error: Invalid shell '$shell' in --completion-shells. Valid options are: ${valid_shells[*]} or 'auto'"
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
    
    # Check Kubernetes version requirement for nftables
    if [[ "$PROXY_MODE" == "nftables" ]]; then
        # Extract major and minor version numbers
        local k8s_major=$(echo "$K8S_VERSION" | cut -d. -f1)
        local k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f2)
        
        # nftables requires Kubernetes 1.29 or higher
        if [[ "$k8s_major" -lt 1 ]] || [[ "$k8s_major" -eq 1 && "$k8s_minor" -lt 29 ]]; then
            echo "Error: nftables proxy mode requires Kubernetes 1.29 or higher"
            echo "Current version: $K8S_VERSION"
            echo "Please use --kubernetes-version 1.29 or higher, or choose a different proxy mode"
            exit 1
        fi
        
        # Warn if using alpha version
        if [[ "$k8s_major" -eq 1 && "$k8s_minor" -lt 31 ]]; then
            echo "Warning: nftables is in alpha status in Kubernetes $K8S_VERSION (beta from 1.31+)"
        fi
    fi
}

# Help message for setup
show_setup_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --node-type    Node type (master or worker)"
    echo "  --cri          Container runtime (containerd or crio). Default: containerd"
    echo "  --proxy-mode   Kube-proxy mode (iptables, ipvs, or nftables). Default: iptables"
    echo "  --pod-network-cidr   Pod network CIDR (e.g., 192.168.0.0/16)"
    echo "  --apiserver-advertise-address   API server advertise address"
    echo "  --control-plane-endpoint   Control plane endpoint"
    echo "  --service-cidr    Service CIDR (e.g., 10.96.0.0/12)"
    echo "  --kubernetes-version   Kubernetes version (e.g., 1.29, 1.28)"
    echo "  --join-token    Join token for worker nodes"
    echo "  --join-address  Master node address for worker nodes"
    echo "  --discovery-token-hash  Discovery token hash for worker nodes"
    echo "  --enable-completion  Enable shell completion setup (default: true)"
    echo "  --completion-shells  Shells to configure (auto, bash, zsh, fish, or comma-separated)"
    echo "  --install-helm     Install Helm package manager (default: false)"
    echo "  --help            Display this help message"
    exit 0
}

# Help message for cleanup
show_cleanup_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --force         Skip confirmation prompt"
    echo "  --preserve-cni  Preserve CNI configurations"
    echo "  --node-type    Specify node type (master/worker) to override auto-detection"
    echo "  --help         Display this help message"
    exit 0
}

# Parse command line arguments for setup
parse_setup_args() {
    while [[ $# -gt 0 ]]; do 
        case $1 in
            --help)
                show_setup_help
                ;;
            --cri)
                CRI=$2
                shift 2
                ;;
            --node-type)
                NODE_TYPE=$2
                shift 2
                ;;
            --kubernetes-version)
                K8S_VERSION=$2
                K8S_VERSION_USER_SET="true"
                shift 2
                ;;
            --join-token)
                JOIN_TOKEN=$2
                shift 2
                ;;
            --join-address)
                JOIN_ADDRESS=$2
                shift 2
                ;;
            --discovery-token-hash)
                DISCOVERY_TOKEN_HASH=$2
                shift 2
                ;;
            --proxy-mode)
                PROXY_MODE=$2
                shift 2
                ;;
            --enable-completion)
                ENABLE_COMPLETION=$2
                shift 2
                ;;
            --install-helm)
                INSTALL_HELM=$2
                shift 2
                ;;
            --completion-shells)
                COMPLETION_SHELLS=$2
                shift 2
                ;;
            --pod-network-cidr|--apiserver-advertise-address|--control-plane-endpoint|--service-cidr)
                KUBEADM_ARGS="$KUBEADM_ARGS $1 $2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                show_setup_help
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
                PRESERVE_CNI=true
                shift
                ;;
            --node-type)
                NODE_TYPE=$2
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                show_cleanup_help
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