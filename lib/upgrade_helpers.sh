#!/bin/sh

# Upgrade helpers: version utilities and node role detection.
# Used by commands/upgrade.sh for both local and remote upgrade operations.

# Get current kubeadm version as MAJOR.MINOR.PATCH
_get_current_k8s_version() {
    kubeadm version -o short | sed 's/^v//'
}

# Validate upgrade version constraints
# - No downgrade
# - No minor version skip (target minor <= current minor + 1)
# - Target must differ from current
_validate_upgrade_version() {
    local current="$1" target="$2"

    # Validate MAJOR.MINOR.PATCH format
    if ! echo "$current" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        log_error "Invalid current version format: '${current}' (expected MAJOR.MINOR.PATCH)"
        return 1
    fi
    if ! echo "$target" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        log_error "Invalid target version format: '${target}' (expected MAJOR.MINOR.PATCH)"
        return 1
    fi

    local cur_major cur_minor cur_patch tar_major tar_minor tar_patch
    cur_major=$(echo "$current" | cut -d. -f1)
    cur_minor=$(echo "$current" | cut -d. -f2)
    cur_patch=$(echo "$current" | cut -d. -f3)
    tar_major=$(echo "$target" | cut -d. -f1)
    tar_minor=$(echo "$target" | cut -d. -f2)
    tar_patch=$(echo "$target" | cut -d. -f3)

    # Same version
    if [ "$cur_major" -eq "$tar_major" ] && [ "$cur_minor" -eq "$tar_minor" ] && [ "$cur_patch" -eq "$tar_patch" ]; then
        log_error "Current version ($current) is already at target version ($target)"
        return 1
    fi

    # Downgrade check
    if [ "$tar_major" -lt "$cur_major" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -lt "$cur_minor" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -eq "$cur_minor" ] && [ "$tar_patch" -lt "$cur_patch" ]; then
        log_error "Downgrade not supported: $current -> $target"
        return 1
    fi

    # Minor version skip check (only +1 minor allowed)
    if [ "$tar_major" -eq "$cur_major" ] && [ "$tar_minor" -gt $((cur_minor + 1)) ]; then
        log_error "Cannot skip minor versions: $current -> $target (max +1 minor version at a time)"
        return 1
    fi

    # Major version jump
    if [ "$tar_major" -gt "$cur_major" ]; then
        log_error "Major version upgrade not supported: $current -> $target"
        return 1
    fi

    return 0
}

# --- Multi-Version Step Computation ---

# Compute intermediate upgrade steps for auto-step-upgrade.
# Fetches the latest patch version for each intermediate minor from dl.k8s.io.
# Output: newline-separated list of versions (MAJOR.MINOR.PATCH), one per line.
# Usage: _compute_upgrade_steps <current_version> <target_version>
_compute_upgrade_steps() {
    local current="$1" target="$2"
    local cur_minor tar_minor
    cur_minor=$(echo "$current" | cut -d. -f2)
    tar_minor=$(echo "$target" | cut -d. -f2)
    local major
    major=$(echo "$current" | cut -d. -f1)

    local steps=""
    local m=$((cur_minor + 1))
    while [ "$m" -lt "$tar_minor" ]; do
        local latest
        latest=$(curl -fsSL --retry 2 --max-time 10 "https://dl.k8s.io/release/stable-${major}.${m}.txt" 2>/dev/null | sed 's/^v//') || true
        if [ -z "$latest" ]; then
            log_error "Failed to fetch latest patch version for ${major}.${m}.x from dl.k8s.io"
            return 1
        fi
        steps="${steps}${steps:+
}${latest}"
        m=$((m + 1))
    done
    # Final target
    steps="${steps}${steps:+
}${target}"
    echo "$steps"
}

# --- Node Role Detection ---

# Detect whether this node is a control-plane or worker
_detect_node_role() {
    if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        if [ "$UPGRADE_FIRST_CONTROL_PLANE" = true ]; then
            echo "first-control-plane"
        else
            echo "control-plane"
        fi
    else
        echo "worker"
    fi
}

# --- Rollback helpers ---

# Record pre-upgrade package versions from a remote node.
# Sets _PRE_UPGRADE_VERSION with the current kubeadm version.
# Usage: _record_pre_upgrade_versions <user> <host>
_record_pre_upgrade_versions() {
    local user="$1" host="$2"
    local pfx; pfx=$(_sudo_prefix "$user")

    _PRE_UPGRADE_VERSION=""
    _PRE_UPGRADE_VERSION=$(_deploy_ssh "$user" "$host" "${pfx}kubeadm version -o short" 2>/dev/null | sed 's/^v//' | tr -d '[:space:]') || true
    if [ -n "$_PRE_UPGRADE_VERSION" ]; then
        log_debug "  [${host}] Pre-upgrade version: v${_PRE_UPGRADE_VERSION}"
    fi
}

# Attempt to rollback a failed node to the pre-upgrade version.
# Usage: _rollback_node <user> <host> <node_name> <bundle_path> <pre_version>
_rollback_node() {
    local user="$1" host="$2" node_name="$3" bundle_path="$4" pre_version="$5"
    local pfx; pfx=$(_sudo_prefix "$user")

    if [ -z "$pre_version" ]; then
        log_warn "  [${host}] No pre-upgrade version recorded, cannot rollback"
        return 1
    fi

    log_warn "  [${host}] Attempting rollback to v${pre_version}..."

    # Downgrade packages to pre-upgrade version
    local rollback_cmd
    rollback_cmd="${pfx}sh ${bundle_path} upgrade --kubernetes-version $(_posix_shell_quote "$pre_version")"
    rollback_cmd=$(_append_passthrough_filtered "$rollback_cmd" "$UPGRADE_PASSTHROUGH_ARGS" "--kubernetes-version" "--skip-drain")

    if _deploy_exec_remote "$user" "$host" "rollback" "$rollback_cmd"; then
        log_info "  [${host}] Rollback to v${pre_version} succeeded"

        # Restart kubelet
        _deploy_ssh "$user" "$host" "${pfx}systemctl daemon-reload && systemctl restart kubelet" >/dev/null 2>&1 || true

        return 0
    else
        log_error "  [${host}] Rollback failed. Manual intervention required."
        return 1
    fi
}
