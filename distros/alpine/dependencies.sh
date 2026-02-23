#!/bin/sh

# Ensure the Alpine community repository is enabled (required for K8s packages).
_ensure_alpine_community_repo() {
    local repo_file="/etc/apk/repositories"
    if grep -qE '^\s*#.*community' "$repo_file" 2>/dev/null; then
        log_info "Enabling Alpine community repository..."
        sed -i 's|^#\(.*community\)|\1|' "$repo_file"
        apk update
    elif ! grep -q 'community' "$repo_file" 2>/dev/null; then
        log_info "Adding Alpine community repository..."
        local mirror
        mirror=$(grep -m1 '^http' "$repo_file" | sed 's|/main.*|/main|; s|/main|/community|')
        if [ -n "$mirror" ]; then
            echo "$mirror" >> "$repo_file"
            apk update
        else
            log_warn "Could not determine community repo URL; packages may be unavailable"
        fi
    fi
}

# Alpine Linux specific: Install dependencies
install_dependencies_alpine() {
    log_info "Installing dependencies for Alpine Linux..."

    _ensure_alpine_community_repo

    apk update

    # Install base dependencies
    apk add --no-cache \
        bash curl ca-certificates \
        conntrack-tools socat ethtool \
        iproute2 iptables kmod \
        cni-plugins cri-tools \
        cgroup-tools

    # Enable and start cgroups service
    if [ -x /etc/init.d/cgroups ]; then
        rc-update add cgroups boot 2>/dev/null || true
        rc-service cgroups start 2>/dev/null || true
    fi

    # Generate /etc/machine-id if missing (required by kubelet)
    if [ ! -f /etc/machine-id ] || [ ! -s /etc/machine-id ]; then
        log_info "Generating /etc/machine-id..."
        if command -v dbus-uuidgen >/dev/null 2>&1; then
            dbus-uuidgen > /etc/machine-id
        else
            cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id
        fi
    fi

    # Ensure mount propagation is shared (required by kubelet)
    mount --make-rshared / 2>/dev/null || true

    # Persist shared mount propagation across reboots
    local startup_script="/etc/local.d/k8s-shared-mount.start"
    if [ ! -f "$startup_script" ]; then
        log_info "Persisting shared mount propagation..."
        mkdir -p /etc/local.d
        cat > "$startup_script" <<'EOF'
#!/bin/sh
mount --make-rshared /
EOF
        chmod +x "$startup_script"
        rc-update add local default 2>/dev/null || true
    fi

    # Install proxy-mode-specific packages
    install_proxy_mode_packages apk add --no-cache
}
