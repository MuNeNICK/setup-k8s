#!/bin/bash

# Source common helpers (only when not already loaded by the entry script)
if ! type -t configure_crictl &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/helpers.sh" 2>/dev/null || true
fi

# Arch: setup CRI-O via pacman or AUR fallback
setup_crio_arch() {
    echo "Installing CRI-O on Arch..."
    
    # Ensure iptables-nft is installed (should already be done in dependencies.sh for CRI-O)
    if ! pacman -Qi iptables-nft &>/dev/null; then
        # If somehow iptables-nft is not installed yet, install it now
        if pacman -Qi iptables &>/dev/null; then
            echo "Replacing iptables with iptables-nft to resolve conflicts..."
            pacman -Rdd --noconfirm iptables || true
        fi
        pacman -S --noconfirm iptables-nft || true
    else
        echo "iptables-nft already installed (as expected for CRI-O)"
    fi
    
    # Always use AUR path to avoid repo-driven iptables-nft conflicts
    # Ensure AUR helper yay exists
    if ! command -v yay &>/dev/null; then
        echo "Installing yay (AUR helper)..."
        local TEMP_USER="aur_builder_$$"
        useradd -m -s /bin/bash "$TEMP_USER"
        pacman -Sy --needed --noconfirm base-devel git
        su - "$TEMP_USER" -c "
            cd /tmp
            git clone https://aur.archlinux.org/yay-bin.git
            cd yay-bin
            makepkg --noconfirm
        "
        pacman -U --noconfirm /tmp/yay-bin/yay-bin-*.pkg.tar.* || {
            echo "Failed to install yay from AUR"
            userdel -r "$TEMP_USER"
            return 1
        }
        userdel -r "$TEMP_USER" || true
    fi

    # Use a temporary unprivileged user to run yay for CRI-O
    local CRIO_USER="crio_installer_$$"
    useradd -m -s /bin/bash "$CRIO_USER"
    echo "$CRIO_USER ALL=(ALL) NOPASSWD: /usr/bin/pacman" >> /etc/sudoers
    echo "Installing CRI-O and runtime dependencies from AUR..."
    su - "$CRIO_USER" -c "
        yay -S --noconfirm --needed --removemake --cleanafter cri-o conmon crun cni-plugins
    " || {
        echo "Failed to install CRI-O from AUR"
        sed -i "/$CRIO_USER/d" /etc/sudoers || true
        userdel -r "$CRIO_USER" || true
        return 1
    }
    sed -i "/$CRIO_USER/d" /etc/sudoers || true
    userdel -r "$CRIO_USER" || true

    # Configure CRI-O before starting
    echo "Configuring CRI-O..."
    mkdir -p /etc/crio /etc/crio/crio.conf.d
    
    # Generate default configuration if not exists
    if [ ! -f /etc/crio/crio.conf ]; then
        crio config > /etc/crio/crio.conf || true
    fi
    
    # Create CNI configuration directory
    mkdir -p /etc/cni/net.d
    
    # Enable and start CRI-O
    systemctl daemon-reload
    systemctl enable crio || true
    systemctl start crio || {
        echo "Failed to start CRI-O service. Checking status..."
        systemctl status crio --no-pager || true
        journalctl -xeu crio --no-pager | tail -50 || true
        return 1
    }
    
    # Wait for CRI-O to be ready
    echo "Waiting for CRI-O to be ready..."
    for _ in {1..30}; do
        if [ -S /var/run/crio/crio.sock ]; then
            echo "CRI-O is ready"
            break
        fi
        sleep 1
    done
    
    if [ ! -S /var/run/crio/crio.sock ]; then
        echo "CRI-O socket not found after 30 seconds"
        return 1
    fi
    
    configure_crictl
}