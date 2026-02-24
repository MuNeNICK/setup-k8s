#!/bin/sh

# Certificate renewal module: renew or check kubeadm-managed certificates.
# Wraps `kubeadm certs renew` and `kubeadm certs check-expiration`.

# Valid certificate names for kubeadm certs renew
_VALID_CERT_NAMES="apiserver apiserver-kubelet-client front-proxy-client apiserver-etcd-client etcd-healthcheck-client etcd-peer etcd-server admin.conf controller-manager.conf scheduler.conf super-admin.conf"

# Validate certificate names in RENEW_CERTS.
# Usage: _validate_cert_names
_validate_cert_names() {
    if [ "$RENEW_CERTS" = "all" ]; then
        return 0
    fi

    _old_ifs="$IFS"; IFS=','
    for cert_name in $RENEW_CERTS; do
        IFS="$_old_ifs"
        cert_name="${cert_name#"${cert_name%%[![:space:]]*}"}"
        cert_name="${cert_name%"${cert_name##*[![:space:]]}"}"
        if [ -z "$cert_name" ]; then
            continue
        fi
        local valid=false
        for known in $_VALID_CERT_NAMES; do
            if [ "$cert_name" = "$known" ]; then
                valid=true
                break
            fi
        done
        if [ "$valid" = false ]; then
            log_error "Unknown certificate name: '$cert_name'"
            log_error "Valid names: $_VALID_CERT_NAMES"
            return 1
        fi
        IFS=','
    done
    IFS="$_old_ifs"
    return 0
}

# Check if any etcd certificates are included in the renewal set.
# Returns 0 if etcd certs are present, 1 otherwise.
_has_etcd_certs() {
    if [ "$RENEW_CERTS" = "all" ]; then
        return 0
    fi
    _old_ifs="$IFS"; IFS=','
    for cert_name in $RENEW_CERTS; do
        IFS="$_old_ifs"
        case "$cert_name" in
            etcd-*) return 0 ;;
            apiserver-etcd-client) return 0 ;;
        esac
        IFS=','
    done
    IFS="$_old_ifs"
    return 1
}

# Restart control-plane static pod components after certificate renewal.
# kubelet watches manifests and restarts pods, but crictl stop forces immediate restart.
_restart_control_plane_components() {
    log_info "Restarting control-plane components..."

    if ! command -v crictl >/dev/null 2>&1; then
        log_warn "crictl not found, skipping component restart"
        log_warn "Restart kubelet manually: systemctl restart kubelet"
        return 0
    fi

    local components="kube-apiserver kube-controller-manager kube-scheduler"
    if _has_etcd_certs; then
        components="$components etcd"
    fi

    for component in $components; do
        local cid
        cid=$(crictl ps --name="$component" --state=running -q 2>/dev/null | head -1) || true
        if [ -n "$cid" ]; then
            log_info "  Restarting $component (container $cid)..."
            crictl stop "$cid" >/dev/null 2>&1 || true
        else
            log_debug "  $component container not found (may not be running)"
        fi
    done

    # Wait for API server to become ready
    log_info "Waiting for API server to become ready..."
    local elapsed=0 timeout=120
    while [ "$elapsed" -lt "$timeout" ]; do
        if kubectl get --raw /readyz >/dev/null 2>&1; then
            log_info "API server is ready"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_warn "API server did not become ready within ${timeout}s (may still be starting)"
    return 0
}

# --- Local renewal ---

renew_certs_local() {
    _audit_log "renew" "started" "certs=${RENEW_CERTS} check_only=${RENEW_CHECK_ONLY}"
    log_info "Starting certificate renewal..."

    # Verify this is a control-plane node
    if [ ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        log_error "This node does not appear to be a control-plane node"
        log_error "  (missing /etc/kubernetes/manifests/kube-apiserver.yaml)"
        _audit_log "renew" "failed" "reason=not_control_plane_node"
        return 1
    fi

    # Validate certificate names
    if ! _validate_cert_names; then
        _audit_log "renew" "failed" "reason=invalid_cert_names"
        return 1
    fi

    # Show current certificate expiration
    log_info "Current certificate expiration:"
    kubeadm certs check-expiration 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done

    # If check-only mode, stop here
    if [ "$RENEW_CHECK_ONLY" = true ]; then
        log_info "Check-only mode: no certificates were renewed"
        return 0
    fi

    # Renew certificates
    if [ "$RENEW_CERTS" = "all" ]; then
        log_info "Renewing all certificates..."
        if ! kubeadm certs renew all; then
            log_error "Certificate renewal failed"
            _audit_log "renew" "failed" "reason=kubeadm_renew_all_failed"
            return 1
        fi
    else
        _old_ifs="$IFS"; IFS=','
        for cert_name in $RENEW_CERTS; do
            IFS="$_old_ifs"
            cert_name="${cert_name#"${cert_name%%[![:space:]]*}"}"
            cert_name="${cert_name%"${cert_name##*[![:space:]]}"}"
            [ -z "$cert_name" ] && continue
            log_info "Renewing certificate: $cert_name..."
            if ! kubeadm certs renew "$cert_name"; then
                log_error "Failed to renew certificate: $cert_name"
                _audit_log "renew" "failed" "reason=kubeadm_renew_failed cert=${cert_name}"
                IFS="$_old_ifs"
                return 1
            fi
            IFS=','
        done
        IFS="$_old_ifs"
    fi

    # Restart control-plane components
    _restart_control_plane_components

    # Show updated certificate expiration
    log_info ""
    log_info "Updated certificate expiration:"
    kubeadm certs check-expiration 2>&1 | while IFS= read -r line; do
        log_info "  $line"
    done

    _audit_log "renew" "completed" "certs=${RENEW_CERTS}"
    log_info "Certificate renewal complete!"
    return 0
}

# --- Dry-run ---

renew_dry_run() {
    log_info "=== Renew Dry-Run Plan ==="
    log_info ""

    if [ -n "$DEPLOY_CONTROL_PLANES" ]; then
        log_info "Mode: Remote"
        log_info "Control-plane nodes: $DEPLOY_CONTROL_PLANES"
        log_info ""
        _log_ssh_settings
        log_info ""
        log_info "Certificates: $RENEW_CERTS"
        if [ "$RENEW_CHECK_ONLY" = true ]; then
            log_info "Action: Check expiration only (no renewal)"
        else
            log_info "Action: Renew certificates"
        fi
        log_info ""
        log_info "Orchestration Plan:"
        log_info "  1. Check SSH connectivity to all nodes"
        log_info "  2. Generate and transfer bundle"
        log_info "  3. Execute renewal on each node sequentially"
        log_info "  4. Display summary"
    else
        log_info "Mode: Local"
        log_info "Certificates: $RENEW_CERTS"
        if [ "$RENEW_CHECK_ONLY" = true ]; then
            log_info "Action: Check expiration only (no renewal)"
        else
            log_info "Action: Renew certificates"
        fi
        log_info ""
        log_info "Steps:"
        log_info "  1. Verify control-plane node"
        log_info "  2. Show current certificate expiration"
        if [ "$RENEW_CHECK_ONLY" != true ]; then
            log_info "  3. Renew certificates via kubeadm"
            log_info "  4. Restart control-plane components"
            log_info "  5. Show updated certificate expiration"
        fi
    fi
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# --- Remote orchestration ---

# Global state for remote cleanup handlers
_RENEW_REMOTE_NODES=""
_RENEW_REMOTE_DIRS=""

_cleanup_renew_remote_dirs() {
    if [ -n "$_RENEW_REMOTE_DIRS" ] && [ -n "$_RENEW_REMOTE_NODES" ]; then
        local i=0
        printf '%s\n' "$_RENEW_REMOTE_NODES" | while IFS= read -r node; do
            i=$((i + 1))
            local rdir
            rdir=$(printf '%s\n' "$_RENEW_REMOTE_DIRS" | sed -n "${i}p")
            [ -z "$rdir" ] && continue
            _parse_node_address "$node"
            _deploy_ssh "$_NODE_USER" "$_NODE_HOST" "rm -rf '$rdir'" >/dev/null 2>&1 || true
        done
    fi
}
renew_cluster() {
    local cp_count
    cp_count=$(_csv_count "$DEPLOY_CONTROL_PLANES")
    log_info "Starting remote certificate renewal on $cp_count control-plane node(s)..."
    log_info "Certificates: $RENEW_CERTS"
    if [ "$RENEW_CHECK_ONLY" = true ]; then
        log_info "Mode: check-only"
    fi
    log_info ""

    # Setup known_hosts
    _setup_session_known_hosts "renew"

    # Step 1: Check SSH connectivity to all nodes
    log_info "Step 1: Checking SSH connectivity..."
    local _i=0
    _old_ifs="$IFS"; IFS=','
    for node in $DEPLOY_CONTROL_PLANES; do
        IFS="$_old_ifs"
        _i=$((_i + 1))
        _parse_node_address "$node"
        local _ssh_err
        if ! _ssh_err=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "echo ok" 2>&1 >/dev/null); then
            log_error "SSH connection failed: ${_NODE_USER}@${_NODE_HOST}:${DEPLOY_SSH_PORT}"
            [ -n "$_ssh_err" ] && log_error "  ${_ssh_err}"
            return 1
        fi
        log_info "  [${_NODE_HOST}] SSH OK"

        # Pre-check sudo for non-root users
        if [ "$_NODE_USER" != "root" ]; then
            if ! _deploy_ssh "$_NODE_USER" "$_NODE_HOST" "sudo -n true" >/dev/null 2>&1; then
                log_error "sudo -n failed -- NOPASSWD sudo required for ${_NODE_USER}@${_NODE_HOST}"
                return 1
            fi
        fi
        IFS=','
    done
    IFS="$_old_ifs"

    # Step 2: Generate bundle
    log_info "Step 2: Generating bundle..."
    local bundle_path
    bundle_path=$(mktemp /tmp/setup-k8s-renew-XXXXXX)
    chmod 600 "$bundle_path"
    generate_deploy_bundle "$bundle_path"

    # Step 3: Transfer bundle and execute on each node sequentially
    log_info "Step 3: Renewing certificates on each node sequentially..."
    local success_count=0 fail_count=0
    _RENEW_REMOTE_NODES=""
    _RENEW_REMOTE_DIRS=""

    _i=0
    _old_ifs="$IFS"; IFS=','
    for node in $DEPLOY_CONTROL_PLANES; do
        IFS="$_old_ifs"
        _i=$((_i + 1))
        _parse_node_address "$node"
        log_info ""
        log_info "--- Node $_i/$cp_count: ${_NODE_HOST} ---"

        # Create remote temp directory
        local rdir
        rdir=$(_deploy_ssh "$_NODE_USER" "$_NODE_HOST" "d=\$(mktemp -d) && chmod 700 \"\$d\" && echo \"\$d\"") || true
        rdir=$(echo "$rdir" | tr -d '[:space:]')
        if [ -z "$rdir" ]; then
            log_error "Failed to create remote temp directory on ${_NODE_HOST}"
            fail_count=$((fail_count + 1))
            IFS=','
            continue
        fi
        _RENEW_REMOTE_NODES="${_RENEW_REMOTE_NODES}${_RENEW_REMOTE_NODES:+
}${node}"
        _RENEW_REMOTE_DIRS="${_RENEW_REMOTE_DIRS}${_RENEW_REMOTE_DIRS:+
}${rdir}"

        # Transfer bundle
        if ! _deploy_scp "$bundle_path" "$_NODE_USER" "$_NODE_HOST" "${rdir}/setup-k8s.sh"; then
            log_error "Failed to transfer bundle to ${_NODE_HOST}"
            fail_count=$((fail_count + 1))
            IFS=','
            continue
        fi

        # Execute renewal
        local sudo_pfx=""
        [ "$_NODE_USER" != "root" ] && sudo_pfx="sudo -n "
        local cmd="${sudo_pfx}sh ${rdir}/setup-k8s.sh renew"
        if [ -n "$RENEW_PASSTHROUGH_ARGS" ]; then
            cmd=$(_append_passthrough_to_cmd "$cmd" "$RENEW_PASSTHROUGH_ARGS")
        fi

        if _deploy_exec_remote "$_NODE_USER" "$_NODE_HOST" "cert renew" "$cmd"; then
            success_count=$((success_count + 1))
        else
            log_error "Certificate renewal failed on ${_NODE_HOST}"
            fail_count=$((fail_count + 1))
        fi

        # Cleanup remote temp directory
        _deploy_ssh "$_NODE_USER" "$_NODE_HOST" "rm -rf '$rdir'" >/dev/null 2>&1 || true
        IFS=','
    done
    IFS="$_old_ifs"
    rm -f "$bundle_path"

    # Clear remote state (already cleaned up inline)
    _RENEW_REMOTE_NODES=""
    _RENEW_REMOTE_DIRS=""

    # Cleanup known_hosts
    _teardown_session_known_hosts
    _pop_cleanup

    # Summary
    log_info ""
    log_info "=== Certificate Renewal Summary ==="
    log_info "  Total nodes: $cp_count"
    log_info "  Succeeded: $success_count"
    if [ "$fail_count" -gt 0 ]; then
        log_error "  Failed: $fail_count"
        return 1
    else
        log_info "  Failed: 0"
    fi
    log_info "Certificate renewal complete!"
    return 0
}
