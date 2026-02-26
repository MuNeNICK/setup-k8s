#!/bin/sh

# Etcd backup module: create etcd snapshots locally or via SSH.
# Shared helpers (container discovery, remote transport, CLI parsing) → lib/etcd_helpers.sh

# --- Local backup ---

backup_etcd_local() {
    _audit_log "backup" "started" "path=${ETCD_SNAPSHOT_PATH}"
    log_info "Starting etcd backup..."

    # Find etcd container
    local cid
    if ! cid=$(_find_etcd_container); then
        _audit_log "backup" "failed" "reason=etcd_container_not_found"
        return 1
    fi

    # Create output directory
    local snapshot_dir
    snapshot_dir=$(dirname "$ETCD_SNAPSHOT_PATH")
    if [ ! -d "$snapshot_dir" ]; then
        mkdir -p "$snapshot_dir"
    fi

    # Save snapshot inside the container
    local container_snapshot="/var/lib/etcd/snapshot-tmp-$$.db"
    log_info "Creating etcd snapshot..."
    if ! _etcdctl_exec "$cid" snapshot save "$container_snapshot"; then
        log_error "etcdctl snapshot save failed"
        _audit_log "backup" "failed" "reason=etcdctl_snapshot_save_failed"
        return 1
    fi

    # Copy snapshot from host (etcd's /var/lib/etcd is a hostPath mount)
    log_info "Copying snapshot to $ETCD_SNAPSHOT_PATH..."
    if ! cp "$container_snapshot" "$ETCD_SNAPSHOT_PATH"; then
        log_error "Failed to copy snapshot from $container_snapshot"
        _audit_log "backup" "failed" "reason=snapshot_copy_failed"
        return 1
    fi

    # Clean up temp snapshot
    rm -f "$container_snapshot" >/dev/null 2>&1 || true

    # Verify snapshot size
    local snapshot_size
    snapshot_size=$(wc -c < "$ETCD_SNAPSHOT_PATH")
    if [ "$snapshot_size" -lt 100 ]; then
        log_error "Snapshot file is too small ($snapshot_size bytes), backup may have failed"
        _audit_log "backup" "failed" "reason=snapshot_too_small size=${snapshot_size}"
        return 1
    fi

    _audit_log "backup" "completed" "path=${ETCD_SNAPSHOT_PATH} size=${snapshot_size}"
    log_info "Etcd backup complete: $ETCD_SNAPSHOT_PATH ($snapshot_size bytes)"
    return 0
}

# --- Dry-run ---

backup_dry_run() {
    log_info "=== Backup Dry-Run Plan ==="
    log_info ""

    if [ -n "$ETCD_CONTROL_PLANES" ]; then
        log_info "Mode: Remote"
        log_info "Target Node: $ETCD_CONTROL_PLANES"
        log_info ""
        _log_ssh_settings
        log_info ""
        log_info "Orchestration Plan:"
        log_info "  1. Check SSH connectivity"
        log_info "  2. Generate and transfer bundle"
        log_info "  3. Execute backup on remote node"
        log_info "  4. Download snapshot to: $ETCD_SNAPSHOT_PATH"
    else
        log_info "Mode: Local"
        log_info "Snapshot Output: $ETCD_SNAPSHOT_PATH"
        log_info ""
        log_info "Steps:"
        log_info "  1. Find etcd container via crictl"
        log_info "  2. Run etcdctl snapshot save inside container"
        log_info "  3. Copy snapshot to host"
        log_info "  4. Verify snapshot"
    fi
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# --- Remote backup ---

_backup_etcd_remote_callback() {
    local remote_snapshot="${_ETCD_BUNDLE_DIR}/etcd-snapshot.db"

    log_info "Step 3: Executing backup on remote node..."
    if ! _exec_etcd_remote "backup" "etcd backup" "$_ETCD_REMOTE_BUNDLE_PATH" --snapshot-path "$remote_snapshot"; then
        return 1
    fi

    log_info "Step 4: Downloading snapshot to $ETCD_SNAPSHOT_PATH..."
    if [ "$_ETCD_REMOTE_USER" != "root" ]; then
        _deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "sudo -n chmod 644 '${remote_snapshot}'" >/dev/null 2>&1 || true
    fi
    if ! _deploy_scp_from "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "$remote_snapshot" "$ETCD_SNAPSHOT_PATH"; then
        log_error "Failed to download snapshot"
        return 1
    fi

    local snapshot_size
    snapshot_size=$(wc -c < "$ETCD_SNAPSHOT_PATH")
    if [ "$snapshot_size" -lt 100 ]; then
        log_error "Downloaded snapshot is too small ($snapshot_size bytes), backup may have failed"
        return 1
    fi
    log_info "Snapshot downloaded: $ETCD_SNAPSHOT_PATH ($snapshot_size bytes)"
}

backup_etcd_remote() {
    log_info "Remote etcd backup from ${ETCD_CONTROL_PLANES}..."
    _with_etcd_remote "backup" _backup_etcd_remote_callback
    local rc=$?
    [ $rc -eq 0 ] && log_info "Remote etcd backup complete!"
    return $rc
}
