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
    if [[ "$CRI" != "containerd" && "$CRI" != "crio" ]]; then
        echo "Error: CRI must be either 'containerd' or 'crio'"
        exit 1
    fi
}

# Help message for setup
show_setup_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --node-type    Node type (master or worker)"
    echo "  --cri          Container runtime (containerd or crio). Default: containerd"
    echo "  --pod-network-cidr   Pod network CIDR (e.g., 192.168.0.0/16)"
    echo "  --apiserver-advertise-address   API server advertise address"
    echo "  --control-plane-endpoint   Control plane endpoint"
    echo "  --service-cidr    Service CIDR (e.g., 10.96.0.0/12)"
    echo "  --kubernetes-version   Kubernetes version (e.g., 1.29, 1.28)"
    echo "  --join-token    Join token for worker nodes"
    echo "  --join-address  Master node address for worker nodes"
    echo "  --discovery-token-hash  Discovery token hash for worker nodes"
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