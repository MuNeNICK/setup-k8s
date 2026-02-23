#!/bin/sh

# Remove module: orchestrate node removal from a Kubernetes cluster via SSH

# Show dry-run removal plan
remove_dry_run() {
    log_info "=== Remove Dry-Run Plan ==="
    log_info ""

    _parse_node_address "$REMOVE_CONTROL_PLANE"
    log_info "Control-Plane (orchestrator): ${_NODE_USER}@${_NODE_HOST}"
    log_info ""

    local node_count
    node_count=$(_csv_count "$REMOVE_NODES")
    log_info "Nodes to Remove (${node_count}):"
    local _i=0
    while [ "$_i" -lt "$node_count" ]; do
        local node
        node=$(_csv_get "$REMOVE_NODES" "$_i")
        _parse_node_address "$node"
        log_info "  - ${_NODE_USER}@${_NODE_HOST}"
        _i=$((_i + 1))
    done
    log_info ""

    log_info "SSH Settings:"
    log_info "  Default user: $DEPLOY_SSH_USER"
    log_info "  Port: $DEPLOY_SSH_PORT"
    [ -n "$DEPLOY_SSH_KEY" ] && log_info "  Key: $DEPLOY_SSH_KEY"
    [ -n "$DEPLOY_SSH_PASSWORD" ] && log_info "  Auth: password (sshpass)"
    log_info ""

    log_info "Orchestration Plan:"
    log_info "  1. Check SSH connectivity to all nodes"
    log_info "  2. For each target node:"
    _i=0
    while [ "$_i" -lt "$node_count" ]; do
        local node
        node=$(_csv_get "$REMOVE_NODES" "$_i")
        _parse_node_address "$node"
        log_info "     [${_NODE_HOST}]"
        log_info "       a. Resolve Kubernetes node name"
        log_info "       b. kubectl drain (from control-plane)"
        log_info "       c. kubectl delete node (from control-plane)"
        log_info "       d. kubeadm reset -f (on target node)"
        _i=$((_i + 1))
    done
    log_info "  3. Show summary"
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# Confirmation prompt for remove
_confirm_remove() {
    if [ "$FORCE" = true ]; then
        return 0
    fi

    local node_count
    node_count=$(_csv_count "$REMOVE_NODES")

    log_warn "The following ${node_count} node(s) will be removed from the cluster:"
    local _i=0
    while [ "$_i" -lt "$node_count" ]; do
        local node
        node=$(_csv_get "$REMOVE_NODES" "$_i")
        _parse_node_address "$node"
        log_warn "  - ${_NODE_USER}@${_NODE_HOST}"
        _i=$((_i + 1))
    done
    echo ""
    echo "Are you sure you want to continue? (y/N)"
    if [ -t 0 ]; then
        read -r response
    elif [ -r /dev/tty ]; then
        read -r response < /dev/tty || {
            log_error "Non-interactive environment detected. Use --force to skip confirmation."
            exit 1
        }
    else
        log_error "Non-interactive environment detected. Use --force to skip confirmation."
        exit 1
    fi
    case "$response" in
        [yY]) ;;
        *)
            echo "Operation cancelled."
            exit 0
            ;;
    esac
}

# Main remove orchestration (remote mode)
remove_cluster() {
    local node_count
    node_count=$(_csv_count "$REMOVE_NODES")

    # Confirmation prompt
    _confirm_remove

    log_info "Removing ${node_count} node(s) from the cluster"

    # Parse control-plane address
    _parse_node_address "$REMOVE_CONTROL_PLANE"
    local cp_user="$_NODE_USER" cp_host="$_NODE_HOST"
    local sudo_pfx=""
    [ "$cp_user" != "root" ] && sudo_pfx="sudo -n "

    # Build combined node list for SSH connectivity and _get_node_name
    _DEPLOY_ALL_NODES="${REMOVE_CONTROL_PLANE},${REMOVE_NODES}"

    # Inform about SSH host key policy
    if [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "yes" ] && [ -z "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        log_info "SSH strict host key checking is enabled."
        log_info "Provide known_hosts with --ssh-known-hosts to proceed:"
        log_info "  ssh-keyscan -H <node-ip> >> known_hosts"
        log_info "  setup-k8s.sh remove --ssh-known-hosts known_hosts ..."
    elif [ "${DEPLOY_SSH_HOST_KEY_CHECK}" = "accept-new" ]; then
        log_info "SSH host key check: accept-new (TOFU)."
    fi

    # Create session-scoped known_hosts
    if [ -n "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] && [ -f "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        _DEPLOY_KNOWN_HOSTS=$(mktemp /tmp/remove-known-hosts-XXXXXX)
        chmod 600 "$_DEPLOY_KNOWN_HOSTS"
        cp "$DEPLOY_SSH_KNOWN_HOSTS_FILE" "$_DEPLOY_KNOWN_HOSTS"
    else
        _DEPLOY_KNOWN_HOSTS=$(mktemp /tmp/remove-known-hosts-XXXXXX)
        chmod 600 "$_DEPLOY_KNOWN_HOSTS"
    fi
    _cleanup_remove_known_hosts() { rm -f "$_DEPLOY_KNOWN_HOSTS"; }
    _push_cleanup _cleanup_remove_known_hosts

    local _step=0

    # --- Step 1: SSH connectivity check ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Checking SSH connectivity..."
    local _conn_nodes="" _i=0
    local all_count
    all_count=$(_csv_count "$_DEPLOY_ALL_NODES")
    while [ "$_i" -lt "$all_count" ]; do
        local _n
        _n=$(_csv_get "$_DEPLOY_ALL_NODES" "$_i")
        _conn_nodes="${_conn_nodes} ${_n}"
        _i=$((_i + 1))
    done
    # shellcheck disable=SC2086 # intentional word splitting
    if ! _check_ssh_connectivity $_conn_nodes; then
        log_error "SSH connectivity check failed. Aborting remove."
        return 1
    fi

    # --- Step 2: Process each target node ---
    _step=$((_step + 1))
    log_info "Step ${_step}: Removing nodes..."
    local remove_failed=false
    local removed_nodes="" failed_nodes=""

    _i=0
    while [ "$_i" -lt "$node_count" ]; do
        local node
        node=$(_csv_get "$REMOVE_NODES" "$_i")
        _parse_node_address "$node"
        local node_user="$_NODE_USER" node_host="$_NODE_HOST"
        local node_sudo=""
        [ "$node_user" != "root" ] && node_sudo="sudo -n "

        log_info ""
        log_info "  [${node_host}] Processing node removal..."

        # a. Resolve Kubernetes node name
        local node_name
        node_name=$(_get_node_name "$cp_user" "$cp_host" "$node_host")
        if [ -z "$node_name" ]; then
            log_warn "  [${node_host}] Could not resolve node name, using host as node name"
            node_name="$node_host"
        fi
        log_info "  [${node_host}] Kubernetes node name: ${node_name}"

        # b. kubectl drain
        log_info "  [${node_host}] Draining node ${node_name}..."
        if ! _deploy_ssh "$cp_user" "$cp_host" "${sudo_pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf drain '${node_name}' --ignore-daemonsets --delete-emptydir-data --force --timeout=300s" 2>&1; then
            log_warn "  [${node_host}] Drain failed (node may already be drained or not ready). Continuing..."
        fi

        # c. kubectl delete node
        log_info "  [${node_host}] Deleting node ${node_name} from cluster..."
        if ! _deploy_ssh "$cp_user" "$cp_host" "${sudo_pfx}kubectl --kubeconfig=/etc/kubernetes/admin.conf delete node '${node_name}'" 2>&1; then
            log_warn "  [${node_host}] Delete node failed. Continuing with reset..."
        fi

        # d. kubeadm reset on target node
        log_info "  [${node_host}] Running kubeadm reset on target node..."
        if ! _deploy_ssh "$node_user" "$node_host" "${node_sudo}kubeadm reset -f" 2>&1; then
            log_error "  [${node_host}] kubeadm reset failed"
            remove_failed=true
            failed_nodes="${failed_nodes}${failed_nodes:+, }${node_host}"
            _i=$((_i + 1))
            continue
        fi

        log_info "  [${node_host}] Node removed successfully"
        removed_nodes="${removed_nodes}${removed_nodes:+, }${node_host}"
        _i=$((_i + 1))
    done

    # --- Step 3: Summary ---
    log_info ""
    log_info "=== Remove Summary ==="
    log_info ""
    _parse_node_address "$REMOVE_CONTROL_PLANE"
    log_info "Control-Plane: ${_NODE_USER}@${_NODE_HOST}"
    log_info ""
    if [ -n "$removed_nodes" ]; then
        log_info "Removed: ${removed_nodes}"
    fi
    if [ -n "$failed_nodes" ]; then
        log_error "Failed: ${failed_nodes}"
    fi
    log_info ""
    log_info "=========================="

    # Clean up known_hosts
    _cleanup_remove_known_hosts
    _pop_cleanup
    _DEPLOY_KNOWN_HOSTS=""

    if [ "$remove_failed" = true ]; then
        log_error "Some node removals failed. Check logs above."
        return 1
    fi

    log_info "All nodes removed successfully!"
    return 0
}
