#!/bin/bash

# Source common helpers (only when not already loaded by the entry script)
if ! type -t configure_crictl &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/helpers.sh" 2>/dev/null || true
    source "${SCRIPT_DIR}/../../common/variables.sh" 2>/dev/null || true
fi

# Setup CRI-O on Debian/Ubuntu using new isv:/cri-o repositories (2025)
setup_crio_debian() {
    echo "Setting up CRI-O for Debian/Ubuntu..."

    # Determine K8s minor series (e.g., 1.32)
    local crio_series
    crio_series=$(echo "$K8S_VERSION" | awk -F. '{print $1"."$2}')
    if [ -z "$crio_series" ]; then
        crio_series="1.32"
    fi
    
    echo "Installing CRI-O v${crio_series}..."

    # Ensure keyrings directory exists
    mkdir -p /etc/apt/keyrings

    # Clean any previous CRI-O sources
    rm -f /etc/apt/sources.list.d/*cri-o*.list 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/*libcontainers*.list 2>/dev/null || true

    # Use the new isv:/cri-o:/stable repository structure (available for v1.30+)
    echo "Adding CRI-O v${crio_series} repository..."
    
    # Download and add GPG key (skip if already present)
    if [ ! -f /etc/apt/keyrings/crio-apt-keyring.gpg ]; then
        echo "Adding repository GPG key..."
        curl -fsSL --retry 3 --retry-delay 2 "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v${crio_series}/deb/Release.key" | \
            gpg --batch --yes --dearmor -o /etc/apt/keyrings/crio-apt-keyring.gpg 2>/dev/null || {
                echo "Failed to add GPG key for CRI-O v${crio_series}"
                return 1
            }
    fi
    
    # Add repository
    echo "deb [signed-by=/etc/apt/keyrings/crio-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v${crio_series}/deb/ /" | \
        tee /etc/apt/sources.list.d/cri-o.list
    
    # Update package lists and install CRI-O
    echo "Updating package lists..."
    apt-get update
    
    echo "Installing CRI-O and related packages..."
    apt-get install -y cri-o cri-o-runc || apt-get install -y cri-o
    
    # Ensure CRI-O config uses systemd cgroups and modern pause image
    mkdir -p /etc/crio/crio.conf.d
    cat > /etc/crio/crio.conf.d/02-kubernetes.conf <<'CRIOCONF'
[crio.runtime]
cgroup_manager = "systemd"

[crio.image]
pause_image = "registry.k8s.io/pause:3.10"
CRIOCONF

    # Reload and start CRI-O
    systemctl daemon-reload || true
    systemctl enable --now crio || true

    # Configure crictl to talk to CRI-O
    configure_crictl

    # Quick sanity check
    if ! systemctl is-active --quiet crio; then
        echo "Warning: CRI-O service is not active"
        systemctl status crio --no-pager || true
        journalctl -u crio -n 100 --no-pager || true
    fi
}