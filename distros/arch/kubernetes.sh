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
            
            # Clone and build yay as the temporary user with retry logic
            YAY_BUILD_SUCCESS=false
            su - "$TEMP_USER" -c "
                cd /tmp
                # Try to clone with retry logic for network issues
                for attempt in 1 2 3; do
                    if git clone https://aur.archlinux.org/yay-bin.git 2>/dev/null; then
                        cd yay-bin
                        if makepkg --noconfirm; then
                            exit 0
                        fi
                    fi
                    echo \"Attempt \$attempt failed. Retrying in 5 seconds...\"
                    sleep 5
                done
                exit 1
            " && YAY_BUILD_SUCCESS=true
            
            # Install the built package as root if successful
            if [ "$YAY_BUILD_SUCCESS" = true ] && compgen -G "/tmp/yay-bin/yay-bin-*.pkg.tar.*" >/dev/null; then
                pacman -U --noconfirm /tmp/yay-bin/yay-bin-*.pkg.tar.* || YAY_BUILD_SUCCESS=false
            fi
            
            if [ "$YAY_BUILD_SUCCESS" = false ]; then
                echo "Failed to install yay package, will fallback to direct binary download"
            fi
            
            # Clean up temporary user
            userdel -r "$TEMP_USER" 2>/dev/null || true
            
            if command -v yay &> /dev/null; then
                AUR_HELPER="yay"
                echo "yay installed successfully."
            else
                echo "yay installation failed. Will try direct binary download later."
                AUR_HELPER=""
            fi
        fi
        
        if [ -n "$AUR_HELPER" ]; then
            echo "Using AUR helper: $AUR_HELPER"
            
            # Create another temporary user for installing Kubernetes packages
            KUBE_USER="kube_installer_$$"
            useradd -m -s /bin/bash "$KUBE_USER"
            
            # Give the temporary user sudo privileges without password for pacman
            local sudoers_file="/etc/sudoers.d/99-${KUBE_USER}"
            echo "$KUBE_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" > "$sudoers_file"
            chmod 0440 "$sudoers_file"
            if ! visudo -cf "$sudoers_file" >/dev/null 2>&1; then
                echo "Error: Generated sudoers file is invalid" >&2
                rm -f "$sudoers_file"
                userdel -r "$KUBE_USER" 2>/dev/null || true
                return 1
            fi

            # Install Kubernetes components as the temporary user
            echo "Installing Kubernetes components from AUR..."
            su - "$KUBE_USER" -c "
                $AUR_HELPER -S --noconfirm --needed kubeadm-bin kubelet-bin kubectl-bin
            " || echo "Warning: AUR installation of Kubernetes components failed, will try direct binary download" >&2

            # Remove sudo privileges and clean up
            rm -f "$sudoers_file"
            userdel -r "$KUBE_USER"
        else
            echo "No AUR helper available. Will use direct binary download."
        fi
        
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

        # Resolve full version from K8S_VERSION (minor) or fall back to latest stable
        if [ -n "${K8S_VERSION:-}" ]; then
            KUBE_VERSION=$(curl -sSL --retry 3 --retry-delay 2 "https://dl.k8s.io/release/stable-${K8S_VERSION}.txt")
        else
            KUBE_VERSION=$(curl -sSL --retry 3 --retry-delay 2 "https://dl.k8s.io/release/stable.txt")
        fi
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

        # Download and install binaries with SHA256 verification
        for binary in kubeadm kubelet kubectl; do
            echo "Downloading $binary for arch $KARCH..."
            curl -fsSLo "/usr/local/bin/$binary" --retry 3 --retry-delay 2 \
                "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${KARCH}/$binary"

            echo "Verifying SHA256 checksum for $binary..."
            local expected_sha256
            expected_sha256=$(curl -fsSL --retry 3 --retry-delay 2 \
                "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${KARCH}/$binary.sha256")
            local actual_sha256
            actual_sha256=$(sha256sum "/usr/local/bin/$binary" | awk '{print $1}')
            if [ "$expected_sha256" != "$actual_sha256" ]; then
                echo "Error: SHA256 checksum mismatch for $binary (expected=$expected_sha256, actual=$actual_sha256)" >&2
                rm -f "/usr/local/bin/$binary"
                return 1
            fi

            chmod +x "/usr/local/bin/$binary"
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