#!/bin/bash

set -e

# Help message
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --force         Skip confirmation prompt"
    echo "  --preserve-cni  Preserve CNI configurations"
    echo "  --node-type    Specify node type (master/worker) to override auto-detection"
    echo "  --help         Display this help message"
    exit 0
}

# Parse command line arguments
FORCE=false
PRESERVE_CNI=false
NODE_TYPE=""
while [[ $# -gt 0 ]]; do 
    case $1 in
        --help)
            show_help
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
            show_help
            ;;
    esac
done

# Check root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with root privileges"
   exit 1
fi

# Check if script is running in a terminal
if [ -t 0 ]; then
    IS_TERMINAL=true
else
    IS_TERMINAL=false
fi

# Confirmation prompt unless --force is used or running via pipe
if [ "$FORCE" = false ] && [ "$IS_TERMINAL" = true ]; then
    echo "WARNING: This script will remove Kubernetes configurations."
    echo "Are you sure you want to continue? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[yY]$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
elif [ "$FORCE" = false ]; then
    echo "WARNING: This script will remove Kubernetes configurations."
    echo "Running in non-interactive mode. Use --force to suppress this warning."
    sleep 2
fi

echo "Starting Kubernetes cleanup..."

# Stop services first
echo "Stopping Kubernetes services..."
systemctl stop kubelet || true
systemctl disable kubelet || true

# Remove package holds
echo "Removing package holds..."
for pkg in kubeadm kubectl kubelet kubernetes-cni; do
    apt-mark unhold $pkg 2>/dev/null || true
done

# First round: Remove packages normally
echo "Removing packages (first round)..."
apt-get remove -y kubeadm kubectl kubelet kubernetes-cni || true

# Second round: Purge packages
echo "Purging packages (second round)..."
apt-get purge -y kubeadm kubectl kubelet kubernetes-cni || true

# Third round: Force purge with dpkg
echo "Force purging packages (third round)..."
for pkg in kubeadm kubectl kubelet kubernetes-cni; do
    dpkg --force-all --purge $pkg 2>/dev/null || true
done

# Fourth round: Clean up any remaining configuration packages
echo "Cleaning up remaining configurations..."
dpkg -l | awk '/^rc.*kube|kubernetes/ {print $2}' | xargs -r dpkg --force-all --purge

# Clean up dependencies
echo "Removing unnecessary dependencies..."
apt-get autoremove -y || true

# Remove repository files
echo "Removing Kubernetes repository files..."
rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Remove configuration files
echo "Removing specific configuration files..."
rm -f /etc/default/kubelet
rm -rf /etc/kubernetes
rm -rf /etc/systemd/system/kubelet.service.d
rm -f /var/lib/dpkg/info/kubelet.*

# Update package lists
echo "Updating package lists..."
apt-get update || true

# Final cleanup
echo "Performing final cleanup..."
apt-get clean
systemctl daemon-reload
apt-get autoremove -y || true

echo "Cleanup complete! Please reboot the system for all changes to take effect."

# Verify cleanup
echo -e "\nVerifying cleanup..."
remaining_files=0

# Check for remaining packages
if dpkg -l | grep -E "kube|kubernetes" > /dev/null; then
    echo "Warning: Some Kubernetes packages still remain:"
    dpkg -l | grep -E "kube|kubernetes"
    remaining_files=1
fi

# Check for remaining files
for file in "/etc/apt/sources.list.d/kubernetes.list" \
           "/etc/apt/keyrings/kubernetes-apt-keyring.gpg" \
           "/etc/default/kubelet"; do
    if [ -f "$file" ]; then
        echo "Warning: File still exists: $file"
        remaining_files=1
    fi
done

if [ $remaining_files -eq 1 ]; then
    echo -e "\nSome files or packages could not be removed. You may want to remove them manually."
else
    echo -e "\nAll specified components have been successfully removed."
fi
