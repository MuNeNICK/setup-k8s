#!/bin/bash

# Disable swap
disable_swap() {
    echo "Disabling swap..."
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
}

# Disable zram swap (especially for Fedora and Arch)
disable_zram_swap() {
    echo "Checking and disabling zram swap if present..."
    if grep -q zram /proc/swaps || [ "$DISTRO_NAME" = "fedora" ] || [ "$DISTRO_NAME" = "arch" ] || [ "$DISTRO_NAME" = "manjaro" ]; then
        echo "zram swap detected or Fedora/Arch system, disabling..."
        # Stop and disable all potential zram swap services
        for service in zram-swap.service systemd-zram-setup@zram0.service dev-zram0.swap; do
            if systemctl is-active $service &>/dev/null; then
                echo "Stopping and disabling $service..."
                systemctl stop $service
                systemctl disable $service
            fi
            # Mask the service to prevent it from being started again
            echo "Masking $service to prevent automatic activation..."
            systemctl mask $service 2>/dev/null || true
        done
        
        # Handle zram-generator configuration
        if [ -f /usr/lib/systemd/zram-generator.conf ] || [ -d /etc/systemd/zram-generator.conf.d ]; then
            echo "Disabling zram swap configuration..."
            # Remove any existing configuration directory and recreate it
            if [ -d /etc/systemd/zram-generator.conf.d ]; then
                rm -rf /etc/systemd/zram-generator.conf.d
            fi
            mkdir -p /etc/systemd/zram-generator.conf.d
            
            # Create configuration to disable zram
            cat > /etc/systemd/zram-generator.conf.d/disable.conf <<EOF
[zram0]
zram-fraction=0
max-zram-size=0
EOF
        fi
        
        # Unload zram kernel module if loaded
        if lsmod | grep -q zram; then
            echo "Unloading zram kernel module..."
            swapoff -a  # Make sure all swap is off before unloading
            modprobe -r zram || true
        fi
        
        # Make sure all swap is disabled
        echo "Making sure all swap is disabled..."
        swapoff -a
        
        # Find and disable all swap entries
        echo "Checking for any remaining active swap..."
        if [ -n "$(swapon --show 2>/dev/null)" ]; then
            echo "Additional swap devices found, disabling them individually:"
            swapon --show
            for swap_device in $(swapon --show=NAME --noheadings 2>/dev/null); do
                echo "Disabling swap on $swap_device"
                swapoff "$swap_device" || true
            done
        fi
        
        # Verify swap is truly off
        if [ -n "$(swapon --show 2>/dev/null)" ]; then
            echo "WARNING: Some swap devices could not be disabled:"
            swapon --show
            echo "You may need to disable swap manually or set --fail-swap-on=false in kubelet configuration."
        else
            echo "All swap has been successfully disabled."
        fi
    fi
}

# Restore zram swap during cleanup
restore_zram_swap() {
    echo "Checking and restoring zram swap if it was disabled..."
    if [ "$DISTRO_NAME" = "fedora" ] || [ "$DISTRO_NAME" = "arch" ] || [ "$DISTRO_NAME" = "manjaro" ]; then
        echo "Restoring zram swap services..."
        
        # Stop and disable all potential zram swap services
        for service in zram-swap.service systemd-zram-setup@zram0.service dev-zram0.swap; do
            # Unmask the service during cleanup to restore normal system state
            echo "Unmasking $service if it was masked..."
            systemctl unmask $service 2>/dev/null || true
        done
        
        # Remove any zram-generator custom configuration
        if [ -d /etc/systemd/zram-generator.conf.d ]; then
            echo "Removing zram swap configuration..."
            rm -rf /etc/systemd/zram-generator.conf.d
        fi
        
        # Unload zram kernel module if loaded
        if lsmod | grep -q zram; then
            echo "Unloading zram kernel module..."
            swapoff -a  # Make sure all swap is off before unloading
            modprobe -r zram || true
        fi
        
        # Make sure all swap is disabled
        echo "Making sure all swap is disabled..."
        swapoff -a
        
        # Find and disable all swap entries
        echo "Checking for any remaining active swap..."
        if [ -n "$(swapon --show 2>/dev/null)" ]; then
            echo "Additional swap devices found, disabling them individually:"
            swapon --show
            for swap_device in $(swapon --show=NAME --noheadings 2>/dev/null); do
                echo "Disabling swap on $swap_device"
                swapoff "$swap_device" || true
            done
        fi
        
        # Verify swap is truly off
        if [ -n "$(swapon --show 2>/dev/null)" ]; then
            echo "WARNING: Some swap devices could not be disabled:"
            swapon --show
        else
            echo "All swap has been successfully disabled."
        fi
    fi
}