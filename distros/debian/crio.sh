#!/bin/sh

# Setup CRI-O on Debian/Ubuntu using new isv:/cri-o repositories (2025)
setup_crio_debian() {
    log_info "Setting up CRI-O for Debian/Ubuntu..."

    # Determine K8s minor series (e.g., 1.32)
    local crio_series
    crio_series=$(_k8s_minor_version "$K8S_VERSION")
    
    log_info "Installing CRI-O v${crio_series}..."

    # Ensure keyrings directory exists
    mkdir -p /etc/apt/keyrings

    # Clean any previous CRI-O sources
    rm -f /etc/apt/sources.list.d/*cri-o*.list
    rm -f /etc/apt/sources.list.d/*libcontainers*.list

    # Use the new isv:/cri-o:/stable repository structure (available for v1.30+)
    log_info "Adding CRI-O v${crio_series} repository..."
    
    # Download and add GPG key (always refresh to pick up key rotation)
    log_info "Adding repository GPG key..."
    curl -fsSL --retry 3 --retry-delay 2 "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v${crio_series}/deb/Release.key" | \
        gpg --batch --yes --dearmor -o /etc/apt/keyrings/crio-apt-keyring.gpg || {
            log_error "Failed to add GPG key for CRI-O v${crio_series}"
            return 1
        }
    chmod 0644 /etc/apt/keyrings/crio-apt-keyring.gpg
    
    # Add repository
    echo "deb [signed-by=/etc/apt/keyrings/crio-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v${crio_series}/deb/ /" | \
        tee /etc/apt/sources.list.d/cri-o.list
    
    # Update package lists and install CRI-O
    log_info "Updating package lists..."
    apt-get update
    
    log_info "Installing CRI-O and related packages..."
    apt-get install -y cri-o
    
    # Ensure CRI-O config uses systemd cgroups and modern pause image
    _write_crio_config "02-kubernetes.conf" "systemd"

    # Start CRI-O and configure crictl
    _finalize_crio_setup
}