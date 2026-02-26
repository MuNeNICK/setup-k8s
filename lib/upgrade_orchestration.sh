#!/bin/sh

# Remote upgrade orchestration: multi-node upgrade via SSH.
# Local upgrade logic -> commands/upgrade.sh
# Version helpers, rollback -> lib/upgrade_helpers.sh

# Helper: drain a node
_upgrade_drain_node() {
    local user="$1" host="$2" node_name="$3"
    local pfx; pfx=$(_sudo_prefix "$user")
    log_info "  [${node_name}] Draining node..."
    if ! _deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf drain '$node_name' --ignore-daemonsets --delete-emptydir-data --timeout=300s"; then
        log_error "  [${node_name}] Drain failed"
        return 1
    fi
    log_info "  [${node_name}] Node drained"
}

# Helper: uncordon a node
_upgrade_uncordon_node() {
    local user="$1" host="$2" node_name="$3"
    local pfx; pfx=$(_sudo_prefix "$user")
    log_info "  [${node_name}] Uncordoning node..."
    if ! _deploy_ssh "$user" "$host" "${pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf uncordon '$node_name'"; then
        log_error "  [${node_name}] Uncordon failed"
        return 1
    fi
    log_info "  [${node_name}] Node uncordoned"
}

# Upgrade a single node: resolve, drain, execute, uncordon, rollback on error.
# Usage: _upgrade_single_node <node_csv_entry> <state_label> <is_first_cp> [pre_hook] [post_hook]
# Requires: cp1_user, cp1_host (set by upgrade_cluster before calling)
_upgrade_single_node() {
    local node="$1" state_label="$2" is_first_cp="$3"
    local pre_hook="${4:-}" post_hook="${5:-}"

    _parse_node_address "$node"
    local node_user="$_NODE_USER" node_host="$_NODE_HOST"

    if _state_is_step_done "${state_label}_${node_host}"; then
        log_info "  [${node_host}] ${state_label} upgrade... (skipped, resumed)"
        return 0
    fi

    local node_bundle
    node_bundle="$(_bundle_dir_lookup "$node_host")/setup-k8s.sh"
    local node_sudo; node_sudo=$(_sudo_prefix "$node_user")

    local node_name
    node_name=$(_get_node_name "$cp1_user" "$cp1_host" "$node_host")
    if [ -z "$node_name" ]; then
        log_warn "Could not resolve node name for ${node_host}, using host as node name"
        node_name="$node_host"
    fi

    _record_pre_upgrade_versions "$node_user" "$node_host"

    if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
        if ! _upgrade_drain_node "$cp1_user" "$cp1_host" "$node_name"; then
            log_error "Drain failed for ${node_host}."
            return 1
        fi
    fi

    # Pre-hook (e.g., worker admin.conf transfer)
    local _hook_data=""
    if [ -n "$pre_hook" ]; then
        if ! _hook_data=$("$pre_hook" "$node_user" "$node_host" "$node_sudo" "$node_bundle"); then
            return 1
        fi
    fi

    local upgrade_cmd
    upgrade_cmd="${node_sudo}${_hook_data:+env UPGRADE_ADMIN_CONF=${_hook_data} }sh ${node_bundle} upgrade --kubernetes-version $(_posix_shell_quote "$UPGRADE_TARGET_VERSION")"
    if [ "$is_first_cp" = true ]; then
        upgrade_cmd="${upgrade_cmd} --first-control-plane"
    fi
    upgrade_cmd=$(_append_passthrough_filtered "$upgrade_cmd" "$UPGRADE_PASSTHROUGH_ARGS" "--kubernetes-version" "--skip-drain")

    if ! _deploy_exec_remote "$node_user" "$node_host" "upgrade ${state_label}" "$upgrade_cmd"; then
        log_error "Upgrade failed for ${node_host}."
        if [ "${COLLECT_DIAGNOSTICS:-false}" = true ]; then
            _collect_diagnostics "$node_user" "$node_host" "/tmp/setup-k8s-diag-upgrade-${state_label}-$(date +%s)" || true
        fi
        [ -n "$post_hook" ] && "$post_hook" "$node_user" "$node_host" "$node_sudo" "${_hook_data}" "cleanup" || true
        if [ "$UPGRADE_NO_ROLLBACK" != true ] && [ -n "${_PRE_UPGRADE_VERSION:-}" ]; then
            _rollback_node "$node_user" "$node_host" "$node_name" "$node_bundle" "$_PRE_UPGRADE_VERSION" || true
            [ "$UPGRADE_SKIP_DRAIN" != true ] && _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name" || true
        fi
        return 1
    fi

    [ -n "$post_hook" ] && "$post_hook" "$node_user" "$node_host" "$node_sudo" "${_hook_data}" "success" || true

    if [ "$UPGRADE_SKIP_DRAIN" != true ]; then
        if ! _upgrade_uncordon_node "$cp1_user" "$cp1_host" "$node_name"; then
            log_warn "Uncordon failed for ${node_host}. Continuing..."
        fi
    fi

    _state_mark_step "${state_label}_${node_host}" "done"
    log_info "  [${node_host}] ${state_label} upgrade complete"
}

# Worker pre-hook: transfer admin.conf from CP to worker node.
# Outputs remote admin.conf path on success.
# Requires: cp1_user, cp1_host (set by upgrade_cluster)
_worker_pre_hook() {
    local user="$1" host="$2" sudo_pfx="$3"
    local remote_admin_conf
    remote_admin_conf=$(_deploy_ssh "$user" "$host" "${sudo_pfx}mktemp /tmp/upgrade-admin-XXXXXX")
    remote_admin_conf=$(echo "$remote_admin_conf" | tr -d '[:space:]')
    local tmp_admin_conf
    tmp_admin_conf=$(mktemp /tmp/admin-conf-XXXXXX)
    chmod 600 "$tmp_admin_conf"
    if ! _deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}cat /etc/kubernetes/admin.conf" > "$tmp_admin_conf" 2>/dev/null; then
        log_error "  [${host}] Failed to download admin.conf from control-plane ${cp1_host}"
        rm -f "$tmp_admin_conf"
        _deploy_ssh "$user" "$host" "${sudo_pfx}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
        return 1
    fi
    if [ ! -s "$tmp_admin_conf" ]; then
        log_error "  [${host}] Downloaded admin.conf is empty"
        rm -f "$tmp_admin_conf"
        _deploy_ssh "$user" "$host" "${sudo_pfx}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
        return 1
    fi
    _deploy_scp "$tmp_admin_conf" "$user" "$host" "$remote_admin_conf" >/dev/null 2>&1
    _deploy_ssh "$user" "$host" "${sudo_pfx}chmod 600 '$remote_admin_conf'" >/dev/null 2>&1
    rm -f "$tmp_admin_conf"
    echo "$remote_admin_conf"
}

# Worker post-hook: clean up remote admin.conf.
_worker_post_hook() {
    local user="$1" host="$2" sudo_pfx="$3" remote_admin_conf="$4"
    [ -n "$remote_admin_conf" ] && _deploy_ssh "$user" "$host" "${sudo_pfx}rm -f '$remote_admin_conf'" >/dev/null 2>&1 || true
}

# Main upgrade orchestration (remote mode)
upgrade_cluster() {
    local cp_count w_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    w_count=0
    [ -n "$DEPLOY_WORKERS" ] && w_count=$(_csv_count "$DEPLOY_WORKERS")

    # State/resume support (only when --resume is enabled)
    if [ "${RESUME_ENABLED:-false}" = true ]; then
        local resume_file
        resume_file=$(_state_find_resume "upgrade")
        if [ -n "$resume_file" ]; then
            _state_load "$resume_file"
            log_info "Resuming previous upgrade operation..."
        else
            log_info "No resumable upgrade state found, starting fresh."
            _state_init "upgrade"
        fi
    fi
    _state_set "target_version" "$UPGRADE_TARGET_VERSION"

    _audit_log "upgrade" "started" "target=${UPGRADE_TARGET_VERSION} cp=${cp_count} workers=${w_count}"
    log_info "Upgrading Kubernetes cluster to v${UPGRADE_TARGET_VERSION}: ${cp_count} control-plane(s), ${w_count} worker(s)"

    # Build combined node list and initialize remote session
    local all_nodes="$DEPLOY_CONTROL_PLANES"
    [ -n "$DEPLOY_WORKERS" ] && all_nodes="${all_nodes},${DEPLOY_WORKERS}"

    local _step=0

    # --- Step 1: SSH connectivity check ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Checking SSH connectivity to all nodes..."
    if ! _init_remote_session "upgrade" "$all_nodes"; then
        return 1
    fi

    # --- Step 2: Generate and transfer bundle to all nodes ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Generating and transferring bundle to all nodes..."
    if ! _generate_and_transfer_bundle "upgrade"; then
        return 1
    fi

    # --- Step 3: Get current version from first CP ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Checking current cluster version..."
    local cp0
    cp0=$(_csv_get "$DEPLOY_CONTROL_PLANES" 0)
    _parse_node_address "$cp0"
    # cp1_user/cp1_host used by _upgrade_single_node, _worker_pre_hook (closure-like)
    cp1_user="$_NODE_USER"; cp1_host="$_NODE_HOST"
    local sudo_pfx; sudo_pfx=$(_sudo_prefix "$cp1_user")

    local current_version
    current_version=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubeadm version -o short" | sed 's/^v//' | tr -d '[:space:]')
    if [ -z "$current_version" ]; then
        log_error "Failed to get current Kubernetes version from ${cp1_host}"
        return 1
    fi
    log_info "Current cluster version: v${current_version}"
    log_info "Target version: v${UPGRADE_TARGET_VERSION}"

    # Auto-step-upgrade: compute intermediate versions if minor gap > 1
    if [ "${UPGRADE_AUTO_STEP:-false}" = true ]; then
        local cur_minor tar_minor
        cur_minor=$(echo "$current_version" | cut -d. -f2)
        tar_minor=$(echo "$UPGRADE_TARGET_VERSION" | cut -d. -f2)
        if [ "$tar_minor" -gt $((cur_minor + 1)) ]; then
            local steps final_target="$UPGRADE_TARGET_VERSION"
            steps=$(_compute_upgrade_steps "$current_version" "$UPGRADE_TARGET_VERSION")
            local step_count=0
            for _sv in $steps; do step_count=$((step_count + 1)); done
            log_info "Auto-step-upgrade: ${step_count} step(s) to reach v${final_target}"
            # Clean up current bundle setup before stepping
            _cleanup_remote_bundle_dirs
            _pop_cleanup
            # Step through each intermediate version using recursive calls
            UPGRADE_AUTO_STEP=false  # prevent recursion
            for step_version in $steps; do
                log_info ""
                log_info "========================================="
                log_info "Auto-step: upgrading to v${step_version}"
                log_info "========================================="
                UPGRADE_TARGET_VERSION="$step_version"
                if ! upgrade_cluster; then
                    log_error "Auto-step upgrade failed at v${step_version}"
                    UPGRADE_TARGET_VERSION="$final_target"
                    UPGRADE_AUTO_STEP=true
                    return 1
                fi
                log_info "Auto-step: v${step_version} complete"
            done
            UPGRADE_TARGET_VERSION="$final_target"
            UPGRADE_AUTO_STEP=true
            log_info ""
            log_info "Auto-step upgrade to v${UPGRADE_TARGET_VERSION} completed successfully!"
            return 0
        fi
    fi

    # Validate version constraints (single minor version step)
    _validate_upgrade_version "$current_version" "$UPGRADE_TARGET_VERSION"

    # --- Pre-upgrade health check ---
    log_info ""
    _health_check_cluster "$cp1_user" "$cp1_host" --pre || true
    log_info ""

    # --- Step 5: Run kubeadm upgrade plan (informational) ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Running kubeadm upgrade plan..."
    local plan_output
    plan_output=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubeadm upgrade plan" 2>&1) || true
    log_info "$plan_output"

    # --- Step 6: Upgrade control-plane nodes (sequential) ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Upgrading control-plane nodes..."
    local upgrade_failed=false

    _i=0
    while [ "$_i" -lt "$cp_count" ]; do
        node=$(_csv_get "$DEPLOY_CONTROL_PLANES" "$_i")
        is_first=$([ "$_i" -eq 0 ] && echo true || echo false)
        if ! _upgrade_single_node "$node" "upgrade_cp" "$is_first"; then
            upgrade_failed=true; break
        fi
        _i=$((_i + 1))
    done

    if [ "$upgrade_failed" = true ]; then
        log_error "Control-plane upgrade failed. Check logs above for details."
        log_error "Some nodes may be in mixed-version state (this is allowed by K8s skew policy)."
        _cleanup_remote_bundle_dirs
        _pop_cleanup
        return 1
    fi

    # --- Step 7: Upgrade worker nodes (sequential) ---
    if [ "$w_count" -gt 0 ]; then
        _step=$((_step + 1))
        log_info "Step ${_step}: Upgrading worker nodes..."

        _i=0
        while [ "$_i" -lt "$w_count" ]; do
            node=$(_csv_get "$DEPLOY_WORKERS" "$_i")
            if ! _upgrade_single_node "$node" "upgrade_worker" false _worker_pre_hook _worker_post_hook; then
                upgrade_failed=true; break
            fi
            _i=$((_i + 1))
        done
    fi

    # --- Step 8: Verify ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Verifying cluster state..."
    local verify_output
    verify_output=$(_deploy_ssh "$cp1_user" "$cp1_host" "${sudo_pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide" 2>&1) || true
    log_info "$verify_output"

    # --- Post-upgrade health check ---
    log_info ""
    _health_check_cluster "$cp1_user" "$cp1_host" --post || true

    # --- Step 9: Clean up remote bundle directories ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Cleaning up remote bundle directories..."
    _cleanup_remote_bundle_dirs
    _pop_cleanup

    # --- Step 10: Summary ---
    log_info ""
    log_info "=== Upgrade Summary ==="
    log_info ""
    log_info "Target Version: v${UPGRADE_TARGET_VERSION}"
    log_info ""
    _log_node_list "Control-Plane Nodes" "$DEPLOY_CONTROL_PLANES"
    if [ "$w_count" -gt 0 ]; then
        log_info ""
        _log_node_list "Worker Nodes" "$DEPLOY_WORKERS"
    fi
    log_info ""
    log_info "=========================="

    # Clean up known_hosts
    _teardown_session_known_hosts
    _pop_cleanup

    if [ "$upgrade_failed" = true ]; then
        _state_set "status" "failed"
        _audit_log "upgrade" "failed" "target=${UPGRADE_TARGET_VERSION}"
        log_error "Some worker upgrades failed. Check logs above."
        return 1
    fi

    _state_complete
    _audit_log "upgrade" "completed" "target=${UPGRADE_TARGET_VERSION}"
    log_info "Cluster upgrade completed successfully!"
    return 0
}
