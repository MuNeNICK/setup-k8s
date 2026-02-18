#!/bin/bash

# Source common helpers and variables (only when not already loaded by the entry script)
if ! type -t configure_crictl &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/../../common/helpers.sh" 2>/dev/null || true
    source "${SCRIPT_DIR}/../../common/variables.sh" 2>/dev/null || true
fi

# Helper: Get OBS target for RHEL family distributions
get_obs_target_rhel() {
    local target=""
    local major
    major=$(echo "$DISTRO_VERSION" | cut -d. -f1)
    case "$DISTRO_NAME" in
        centos)
            if [[ "$DISTRO_VERSION" == 9* ]]; then target="CentOS_9_Stream"; else target="CentOS_${major}"; fi ;;
        rhel)
            target="RHEL_${major}" ;;
        rocky)
            target="Rocky_${major}" ;;
        almalinux)
            target="AlmaLinux_${major}" ;;
        fedora)
            target="Fedora_${major}" ;;
        *)
            target="" ;;
    esac
    echo -n "$target"
}

# Setup CRI-O for RHEL/CentOS/Rocky/Alma/Fedora
setup_crio_rhel() {
    echo "Setting up CRI-O for RHEL-based distribution..."
    # Determine K8s minor series (e.g., 1.32)
    local crio_series
    crio_series=$(echo "$K8S_VERSION" | awk -F. '{print $1"."$2}')
    if [ -z "$crio_series" ]; then crio_series="1.32"; fi

    # Determine package manager (dnf or yum)
    local PKG_MGR
    if command -v dnf &> /dev/null; then PKG_MGR=dnf; else PKG_MGR=yum; fi

    # Clean previous repo
    rm -f /etc/yum.repos.d/cri-o.repo 2>/dev/null || true

    # Probe downwards for available repo (no hardcoded list)
    local selected=""
    local minor_num
    minor_num=$(echo "$crio_series" | cut -d. -f2)
    for offset in $(seq 0 12); do
        local candidate_minor=$((minor_num - offset))
        if [ $candidate_minor -lt 10 ]; then break; fi
        local series="1.${candidate_minor}"
        echo "Probing CRI-O rpm repo on pkgs.k8s.io for v${series}..."
        local pkgs_key="https://pkgs.k8s.io/addons:/cri-o:/stable:/v${series}/rpm/repodata/repomd.xml.key"
        if curl -fsI --retry 3 --retry-delay 2 "$pkgs_key" >/dev/null 2>&1; then
            cat > /etc/yum.repos.d/cri-o.repo <<EOF
[cri-o]
name=CRI-O v${series}
baseurl=https://pkgs.k8s.io/addons:/cri-o:/stable:/v${series}/rpm/
enabled=1
gpgcheck=1
gpgkey=$pkgs_key
EOF
            selected="$series"
            break
        fi
        echo "pkgs.k8s.io repo not available for v${series}; trying OBS..."
        local target
        target=$(get_obs_target_rhel)
        if [ -n "$target" ]; then
            local obs_base="https://download.opensuse.org/repositories/devel:/kubic:/cri-o:/${series}/${target}/"
            local obs_key="${obs_base}repodata/repomd.xml.key"
            if curl -fsI --retry 3 --retry-delay 2 "$obs_key" >/dev/null 2>&1; then
                cat > /etc/yum.repos.d/cri-o.repo <<EOF
[cri-o]
name=CRI-O v${series} (${target})
baseurl=${obs_base}
enabled=1
gpgcheck=1
gpgkey=${obs_key}
EOF
                selected="$series"
                break
            fi
        fi
    done

    if [ -z "$selected" ]; then
        echo "ERROR: No available CRI-O repository detected for ${crio_series} or lower minors on pkgs.k8s.io/OBS for $DISTRO_NAME $DISTRO_VERSION."
        return 1
    fi

    # Install CRI-O
    $PKG_MGR makecache -y || true
    $PKG_MGR install -y cri-o || {
        echo "ERROR: Failed to install cri-o from configured repository"
        return 1
    }

    # Ensure CRI-O runs and configure crictl
    systemctl daemon-reload || true
    systemctl enable --now crio || true
    configure_crictl

    if ! systemctl is-active --quiet crio; then
        echo "Warning: CRI-O service is not active"
        systemctl status crio --no-pager || true
        journalctl -u crio -n 100 --no-pager || true
    fi

    return 0
}