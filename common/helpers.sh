#!/bin/bash

# Helper: Get Debian/Ubuntu codename without lsb_release
get_debian_codename() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ -n "$VERSION_CODENAME" ]; then
            echo "$VERSION_CODENAME"
            return 0
        fi
        if [ -n "$UBUNTU_CODENAME" ]; then
            echo "$UBUNTU_CODENAME"
            return 0
        fi
        # Fallback mapping for some well-known VERSION_ID values
        case "$ID:$VERSION_ID" in
            ubuntu:24.04) echo "noble" ; return 0 ;;
            ubuntu:22.04) echo "jammy" ; return 0 ;;
            ubuntu:20.04) echo "focal" ; return 0 ;;
            debian:12) echo "bookworm" ; return 0 ;;
            debian:11) echo "bullseye" ; return 0 ;;
        esac
    fi
    # Last resort
    echo "stable"
}

# Helper: configure containerd TOML with v2 layout, SystemdCgroup=true, sandbox_image
configure_containerd_toml() {
    echo "Generating and tuning containerd config..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # Ensure SystemdCgroup=true for runc
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml || true

    # Ensure version = 2 is present
    if ! grep -q '^version *= *2' /etc/containerd/config.toml 2>/dev/null; then
        sed -i '1s/^/version = 2\n/' /etc/containerd/config.toml || true
    fi

    # Set sandbox_image to registry.k8s.io/pause:3.10
    if grep -q '^\s*sandbox_image\s*=\s*"' /etc/containerd/config.toml; then
        sed -i 's#^\s*sandbox_image\s*=\s*".*"#  sandbox_image = "registry.k8s.io/pause:3.10"#' /etc/containerd/config.toml || true
    else
        # Insert under the CRI plugin section
        awk '
            BEGIN{inserted=0}
            {print}
            $0 ~ /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\]/ && inserted==0 {print "  sandbox_image = \"registry.k8s.io/pause:3.10\""; inserted=1}
        ' /etc/containerd/config.toml > /etc/containerd/config.toml.tmp 2>/dev/null && mv /etc/containerd/config.toml.tmp /etc/containerd/config.toml || true
    fi

    systemctl daemon-reload || true
    systemctl enable containerd || true
    systemctl restart containerd || true
}

# Helper: configure crictl runtime endpoint
configure_crictl() {
    local runtime="$1"  # containerd|crio
    local endpoint=""
    if [ "$runtime" = "containerd" ]; then
        endpoint="unix:///run/containerd/containerd.sock"
    else
        endpoint="unix:///var/run/crio/crio.sock"
    fi
    echo "Configuring crictl at /etc/crictl.yaml (endpoint: $endpoint)"
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: $endpoint
image-endpoint: $endpoint
timeout: 10
debug: false
pull-image-on-create: false
EOF
}

# Helper: Initialize Kubernetes cluster (master node)
initialize_master() {
    echo "Initializing master node..."
    # Append CRI socket if CRI-O is selected
    if [ "$CRI" = "crio" ]; then
        KUBEADM_ARGS="$KUBEADM_ARGS --cri-socket unix:///var/run/crio/crio.sock"
    fi
    echo "Using kubeadm init arguments: $KUBEADM_ARGS"
    kubeadm init $KUBEADM_ARGS

    # Configure kubectl
    echo "Configuring kubectl..."
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        # If run with sudo by a non-root user
        USER_HOME="/home/$SUDO_USER"
        mkdir -p "$USER_HOME/.kube"
        cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$USER_HOME/.kube"
        echo "Created kubectl configuration for user $SUDO_USER"
    else
        # If run directly as root 
        mkdir -p /root/.kube
        cp -f /etc/kubernetes/admin.conf /root/.kube/config
        echo "Created kubectl configuration for root user at /root/.kube/config"
    fi

    # Display join command
    echo "Displaying join command for worker nodes..."
    kubeadm token create --print-join-command

    echo "Master node initialization complete!"
    echo "Next steps:"
    echo "1. Install a CNI plugin"
    echo "2. For single-node clusters, remove the taint with:"
    echo "   kubectl taint nodes --all node-role.kubernetes.io/control-plane-"
}

# Helper: Join worker node to cluster
join_worker() {
    echo "Joining worker node to cluster..."
    JOIN_ARGS="${JOIN_ADDRESS} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${DISCOVERY_TOKEN_HASH}"
    if [ "$CRI" = "crio" ]; then
        JOIN_ARGS="$JOIN_ARGS --cri-socket unix:///var/run/crio/crio.sock"
    fi
    kubeadm join $JOIN_ARGS
    
    echo "Worker node has joined the cluster!"
}

# Helper: Clean up .kube directories
cleanup_kube_configs() {
    # Clean up .kube directory
    if [ -n "$SUDO_USER" ]; then
        USER_HOME="/home/$SUDO_USER"
        echo "Cleanup: Removing .kube directory and config for user $SUDO_USER"
        rm -rf "$USER_HOME/.kube" || true
        rm -f "$USER_HOME/.kube/config" || true
    fi

    # Clean up root's .kube directory
    ROOT_HOME=$(eval echo ~root)
    echo "Cleanup: Removing .kube directory and config for root user at $ROOT_HOME"
    rm -rf "$ROOT_HOME/.kube" || true
    rm -f "$ROOT_HOME/.kube/config" || true

    # Clean up all users' .kube/config files
    for user_home in /home/*; do
        if [ -d "$user_home" ]; then
            echo "Cleanup: Removing .kube directory and config for user directory $user_home"
            rm -rf "$user_home/.kube" || true
            rm -f "$user_home/.kube/config" || true
        fi
    done
}

# Helper: Reset containerd configuration
reset_containerd_config() {
    if [ -f /etc/containerd/config.toml ]; then
        echo "Resetting containerd configuration to default..."
        if command -v containerd &> /dev/null; then
            # Backup current config
            cp /etc/containerd/config.toml /etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)
            # Generate default config
            containerd config default > /etc/containerd/config.toml
            # Restart containerd if it's running
            if systemctl is-active containerd &>/dev/null; then
                echo "Restarting containerd with default configuration..."
                systemctl restart containerd
            fi
        fi
    fi
}

# Show installed versions
show_versions() {
    echo "Installed versions:"
    kubectl version --client || true
    kubeadm version || true
}