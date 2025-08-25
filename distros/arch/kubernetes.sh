#!/bin/bash

# Setup Kubernetes for Arch Linux
setup_kubernetes_arch() {
    echo "Setting up Kubernetes for Arch-based distribution..."
    
    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        # If running as root, we need to handle AUR installation differently
        echo "Running as root. Setting up AUR helper for Kubernetes installation..."
        
        # Check if an AUR helper is already installed
        AUR_HELPER=""
        if command -v yay &> /dev/null; then
            AUR_HELPER="yay"
        elif command -v paru &> /dev/null; then
            AUR_HELPER="paru"
        else
            echo "No AUR helper found. Installing yay..."
            
            # Create a temporary user for building AUR packages
            TEMP_USER="aur_builder_$$"
            useradd -m -s /bin/bash "$TEMP_USER"
            
            # Install base-devel and git if not present
            pacman -Sy --needed --noconfirm base-devel git
            
            # Clone and build yay as the temporary user
            su - "$TEMP_USER" -c "
                cd /tmp
                git clone https://aur.archlinux.org/yay-bin.git
                cd yay-bin
                makepkg --noconfirm
            "
            
            # Install the built package as root
            pacman -U --noconfirm /tmp/yay-bin/yay-bin-*.pkg.tar.* || {
                echo "Failed to install yay package"
                userdel -r "$TEMP_USER"
                exit 1
            }
            
            # Clean up temporary user
            userdel -r "$TEMP_USER"
            
            if command -v yay &> /dev/null; then
                AUR_HELPER="yay"
                echo "yay installed successfully."
            else
                echo "Failed to install yay. Please install Kubernetes components manually."
                exit 1
            fi
        fi
        
        echo "Using AUR helper: $AUR_HELPER"
        
        # Create another temporary user for installing Kubernetes packages
        KUBE_USER="kube_installer_$$"
        useradd -m -s /bin/bash "$KUBE_USER"
        
        # Give the temporary user sudo privileges without password for pacman
        echo "$KUBE_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" >> /etc/sudoers
        
        # Install Kubernetes components as the temporary user
        echo "Installing Kubernetes components from AUR..."
        su - "$KUBE_USER" -c "
            $AUR_HELPER -S --noconfirm --needed kubeadm-bin kubelet-bin kubectl-bin
        " || true
        
        # Remove sudo privileges and clean up
        sed -i "/$KUBE_USER/d" /etc/sudoers
        userdel -r "$KUBE_USER"
        
    else
        # If not running as root (should not happen since we check at the beginning of the script)
        echo "This script must be run as root. Exiting."
        exit 1
    fi
    
    # Verify installation
    if command -v kubeadm &> /dev/null && command -v kubelet &> /dev/null && command -v kubectl &> /dev/null; then
        echo "Kubernetes components installed successfully."
    else
        # Try alternative approach: directly downloading binaries
        echo "AUR installation failed. Trying direct binary download..."
        
        # Get the latest stable version
        KUBE_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
        echo "Downloading Kubernetes version: $KUBE_VERSION"

        # Detect architecture mapping for Kubernetes binaries
        UNAME_ARCH=$(uname -m)
        case "$UNAME_ARCH" in
            x86_64) KARCH="amd64" ;;
            aarch64) KARCH="arm64" ;;
            armv7l) KARCH="arm" ;;
            ppc64le) KARCH="ppc64le" ;;
            s390x) KARCH="s390x" ;;
            *) KARCH="amd64" ; echo "Unknown arch $UNAME_ARCH, defaulting to amd64" ;;
        esac

        # Download and install binaries
        for binary in kubeadm kubelet kubectl; do
            echo "Downloading $binary for arch $KARCH..."
            curl -Lo /usr/local/bin/$binary "https://storage.googleapis.com/kubernetes-release/release/${KUBE_VERSION}/bin/linux/${KARCH}/$binary"
            chmod +x /usr/local/bin/$binary
        done
        
        # Create kubelet service file if it doesn't exist
        if [ ! -f /etc/systemd/system/kubelet.service ]; then
            cat > /etc/systemd/system/kubelet.service <<'KUBELET_SERVICE'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
KUBELET_SERVICE
        fi
        
        # Create kubelet service drop-in directory
        mkdir -p /etc/systemd/system/kubelet.service.d
        
        # Create kubeadm config for kubelet
        cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<'KUBEADM_CONF'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
KUBEADM_CONF
        
        # Reload systemd
        systemctl daemon-reload
    fi
    
    # Enable and start kubelet
    systemctl enable kubelet
    systemctl start kubelet
    
    echo "Kubernetes setup completed for Arch Linux."
}