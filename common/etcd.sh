#!/bin/bash

# Etcd backup/restore module: snapshot management for kubeadm clusters
# Uses crictl exec to run etcdctl inside the etcd container (no binary install needed).
# For restore, etcdctl is extracted from the container before stopping it.

# TLS cert paths inside etcd container (and on host via hostPath mounts)
_ETCD_CERT="/etc/kubernetes/pki/etcd/server.crt"
_ETCD_KEY="/etc/kubernetes/pki/etcd/server.key"
_ETCD_CACERT="/etc/kubernetes/pki/etcd/ca.crt"

# --- Container helpers ---

# Find etcd container ID via crictl
# Returns: container ID on stdout, non-zero on failure
_find_etcd_container() {
    local cid
    cid=$(crictl ps --name=etcd --state=running -q 2>/dev/null | head -1)
    if [ -z "$cid" ]; then
        log_error "etcd container not found (is this a control-plane node?)"
        return 1
    fi
    echo "$cid"
}

# Run etcdctl inside the etcd container with TLS args
# Usage: _etcdctl_exec <container_id> <etcdctl_args...>
_etcdctl_exec() {
    local cid="$1"; shift
    crictl exec "$cid" etcdctl \
        --cacert="$_ETCD_CACERT" \
        --cert="$_ETCD_CERT" \
        --key="$_ETCD_KEY" \
        "$@"
}

# Extract etcd binaries (etcdctl + etcdutl) from the container image.
# Strategy: export image as OCI tar, extract binaries from filesystem layers.
# This avoids depending on shell commands inside the container (distroless images).
# etcdutl is needed for snapshot restore in etcd 3.6+.
# Usage: _extract_etcd_binaries <container_id> <output_dir>
_extract_etcd_binaries() {
    local cid="$1" output_dir="$2"
    log_info "Extracting etcd binaries from container image..."

    # Get the image ref from container inspect
    local image_ref
    image_ref=$(crictl inspect --output json "$cid" 2>/dev/null | grep -o '"image":\s*"[^"]*"' | head -1 | sed 's/.*"image":\s*"\([^"]*\)".*/\1/') || true

    if [ -z "$image_ref" ]; then
        image_ref=$(crictl inspect "$cid" 2>/dev/null | grep -o '"imageRef":\s*"[^"]*"' | head -1 | sed 's/.*"imageRef":\s*"\([^"]*\)".*/\1/') || true
    fi

    if [ -z "$image_ref" ]; then
        log_error "Failed to determine etcd container image ref"
        return 1
    fi

    log_debug "etcd image ref: $image_ref"
    local export_dir
    export_dir=$(mktemp -d -t etcd-export-XXXXXX)

    local image_tar="${export_dir}/image.tar"
    if ! ctr -n k8s.io images export "$image_tar" "$image_ref" >/dev/null 2>&1; then
        log_error "Failed to export etcd image: $image_ref"
        rm -rf "$export_dir"
        return 1
    fi

    local oci_dir="${export_dir}/oci"
    mkdir -p "$oci_dir"
    tar -xf "$image_tar" -C "$oci_dir" 2>/dev/null || true

    # Search through blobs for layers containing etcd binaries
    local found_etcdctl=false found_etcdutl=false
    while IFS= read -r blob; do
        [ "$found_etcdctl" = true ] && [ "$found_etcdutl" = true ] && break
        local blob_type
        blob_type=$(file -b "$blob" 2>/dev/null) || true
        case "$blob_type" in
            *gzip*|*tar*)
                # Try to list and extract relevant binaries from this layer
                local listing
                listing=$(tar -tzf "$blob" 2>/dev/null || tar -tf "$blob" 2>/dev/null) || continue

                if [ "$found_etcdctl" = false ] && echo "$listing" | grep -q 'usr/local/bin/etcdctl$'; then
                    tar -xzf "$blob" -C "$export_dir" usr/local/bin/etcdctl 2>/dev/null || \
                    tar -xzf "$blob" -C "$export_dir" ./usr/local/bin/etcdctl 2>/dev/null || \
                    tar -xf "$blob" -C "$export_dir" usr/local/bin/etcdctl 2>/dev/null || \
                    tar -xf "$blob" -C "$export_dir" ./usr/local/bin/etcdctl 2>/dev/null || true
                    if [ -f "$export_dir/usr/local/bin/etcdctl" ]; then
                        cp "$export_dir/usr/local/bin/etcdctl" "$output_dir/etcdctl"
                        chmod +x "$output_dir/etcdctl"
                        found_etcdctl=true
                    fi
                fi
                if [ "$found_etcdutl" = false ] && echo "$listing" | grep -q 'usr/local/bin/etcdutl$'; then
                    tar -xzf "$blob" -C "$export_dir" usr/local/bin/etcdutl 2>/dev/null || \
                    tar -xzf "$blob" -C "$export_dir" ./usr/local/bin/etcdutl 2>/dev/null || \
                    tar -xf "$blob" -C "$export_dir" usr/local/bin/etcdutl 2>/dev/null || \
                    tar -xf "$blob" -C "$export_dir" ./usr/local/bin/etcdutl 2>/dev/null || true
                    if [ -f "$export_dir/usr/local/bin/etcdutl" ]; then
                        cp "$export_dir/usr/local/bin/etcdutl" "$output_dir/etcdutl"
                        chmod +x "$output_dir/etcdutl"
                        found_etcdutl=true
                    fi
                fi
                ;;
        esac
    done < <(find "$oci_dir/blobs" -type f 2>/dev/null)

    rm -rf "$export_dir"

    if [ "$found_etcdctl" = false ]; then
        log_error "Failed to extract etcdctl from image"
        return 1
    fi
    log_info "etcd binaries extracted to $output_dir (etcdctl: yes, etcdutl: $found_etcdutl)"
    return 0
}

# --- Local backup ---

backup_etcd_local() {
    log_info "Starting etcd backup..."

    # Find etcd container
    local cid
    cid=$(_find_etcd_container) || return 1

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
        return 1
    fi

    # Copy snapshot from host (etcd's /var/lib/etcd is a hostPath mount)
    log_info "Copying snapshot to $ETCD_SNAPSHOT_PATH..."
    if ! cp "$container_snapshot" "$ETCD_SNAPSHOT_PATH"; then
        log_error "Failed to copy snapshot from $container_snapshot"
        return 1
    fi

    # Clean up temp snapshot
    rm -f "$container_snapshot" >/dev/null 2>&1 || true

    # Verify snapshot size
    local snapshot_size
    snapshot_size=$(wc -c < "$ETCD_SNAPSHOT_PATH")
    if [ "$snapshot_size" -lt 100 ]; then
        log_error "Snapshot file is too small ($snapshot_size bytes), backup may have failed"
        return 1
    fi

    log_info "Etcd backup complete: $ETCD_SNAPSHOT_PATH ($snapshot_size bytes)"
    return 0
}

# --- Local restore ---

# Cleanup handler for etcd manifest restore (uses fixed paths, not local variables)
_ETCD_MANIFEST_PATH="/etc/kubernetes/manifests/etcd.yaml"
_ETCD_MANIFEST_TMP="/tmp/etcd.yaml"

_restore_etcd_manifest() {
    if [ -f "$_ETCD_MANIFEST_TMP" ] && [ ! -f "$_ETCD_MANIFEST_PATH" ]; then
        log_warn "Restoring etcd manifest from backup..."
        mv "$_ETCD_MANIFEST_TMP" "$_ETCD_MANIFEST_PATH"
    fi
}

restore_etcd_local() {
    log_info "Starting etcd restore from $ETCD_SNAPSHOT_PATH..."

    # Validate snapshot file
    if [ ! -f "$ETCD_SNAPSHOT_PATH" ]; then
        log_error "Snapshot file not found: $ETCD_SNAPSHOT_PATH"
        return 1
    fi

    # Find etcd container and extract binaries before stopping
    local cid
    local etcd_bin_dir
    etcd_bin_dir=$(mktemp -d -t etcd-restore-bin-XXXXXX)
    cid=$(_find_etcd_container) || { rm -rf "$etcd_bin_dir"; return 1; }
    _extract_etcd_binaries "$cid" "$etcd_bin_dir" || { rm -rf "$etcd_bin_dir"; return 1; }

    # Move etcd static pod manifest to stop the etcd container
    if [ ! -f "$_ETCD_MANIFEST_PATH" ]; then
        log_error "etcd manifest not found: $_ETCD_MANIFEST_PATH"
        return 1
    fi

    log_info "Moving etcd manifest to stop etcd container..."
    mv "$_ETCD_MANIFEST_PATH" "$_ETCD_MANIFEST_TMP"

    # Register cleanup handler to restore manifest on failure
    _push_cleanup _restore_etcd_manifest

    # Wait for etcd container to stop
    log_info "Waiting for etcd container to stop..."
    local wait_elapsed=0 wait_timeout=60
    while [ $wait_elapsed -lt $wait_timeout ]; do
        if ! crictl ps --name=etcd --state=running -q 2>/dev/null | grep -q .; then
            break
        fi
        sleep 2
        wait_elapsed=$((wait_elapsed + 2))
    done
    if [ $wait_elapsed -ge $wait_timeout ]; then
        log_error "Timeout waiting for etcd container to stop"
        return 1
    fi
    log_info "etcd container stopped"

    # Backup existing data directory
    local etcd_data_dir="/var/lib/etcd"
    if [ -d "$etcd_data_dir" ]; then
        local backup_dir
        backup_dir="${etcd_data_dir}.bak.$(date +%Y%m%d-%H%M%S)"
        log_info "Backing up existing etcd data to $backup_dir..."
        mv "$etcd_data_dir" "$backup_dir"
    fi

    # Restore snapshot — use etcdutl for etcd 3.6+ (etcdctl snapshot restore was removed)
    log_info "Restoring etcd snapshot..."
    local restore_ok=false
    if [ -x "$etcd_bin_dir/etcdutl" ]; then
        log_info "Using etcdutl for snapshot restore"
        if "$etcd_bin_dir/etcdutl" snapshot restore "$ETCD_SNAPSHOT_PATH" \
            --data-dir "$etcd_data_dir"; then
            restore_ok=true
        fi
    fi

    # Fallback to etcdctl (etcd 3.5 and earlier)
    if [ "$restore_ok" = false ] && [ -x "$etcd_bin_dir/etcdctl" ]; then
        log_info "Trying etcdctl for snapshot restore"
        if "$etcd_bin_dir/etcdctl" snapshot restore "$ETCD_SNAPSHOT_PATH" \
            --data-dir "$etcd_data_dir"; then
            restore_ok=true
        fi
    fi

    if [ "$restore_ok" = false ]; then
        log_error "Snapshot restore failed"
        # Restore original data directory if backup exists
        if [ -n "${backup_dir:-}" ] && [ -d "$backup_dir" ]; then
            log_warn "Restoring original etcd data from $backup_dir..."
            rm -rf "$etcd_data_dir" 2>/dev/null || true
            mv "$backup_dir" "$etcd_data_dir"
        fi
        rm -rf "$etcd_bin_dir"
        return 1
    fi
    log_info "Snapshot restored to $etcd_data_dir"

    # Restore etcd manifest
    log_info "Restoring etcd manifest to start etcd..."
    mv "$_ETCD_MANIFEST_TMP" "$_ETCD_MANIFEST_PATH"
    _pop_cleanup

    # Wait for etcd to start and become healthy
    log_info "Waiting for etcd to start..."
    local start_elapsed=0 start_timeout=120
    while [ $start_elapsed -lt $start_timeout ]; do
        local new_cid
        new_cid=$(crictl ps --name=etcd --state=running -q 2>/dev/null | head -1) || true
        if [ -n "$new_cid" ]; then
            # Health check
            if _etcdctl_exec "$new_cid" endpoint health >/dev/null 2>&1; then
                log_info "etcd is healthy"
                break
            fi
        fi
        sleep 3
        start_elapsed=$((start_elapsed + 3))
    done

    if [ $start_elapsed -ge $start_timeout ]; then
        log_warn "Timeout waiting for etcd health check. etcd may still be starting."
    fi

    # Clean up
    rm -rf "$etcd_bin_dir"

    log_info "Etcd restore complete!"
    return 0
}

# --- Dry-run ---

_log_ssh_settings() {
    log_info "SSH Settings:"
    log_info "  Default user: $DEPLOY_SSH_USER"
    log_info "  Port: $DEPLOY_SSH_PORT"
    [ -n "$DEPLOY_SSH_KEY" ] && log_info "  Key: $DEPLOY_SSH_KEY"
    [ -n "$DEPLOY_SSH_PASSWORD" ] && log_info "  Auth: password (sshpass)"
}

backup_dry_run() {
    log_info "=== Backup Dry-Run Plan ==="
    log_info ""

    if [ -n "$ETCD_CONTROL_PLANE" ]; then
        log_info "Mode: Remote"
        log_info "Target Node: $ETCD_CONTROL_PLANE"
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

restore_dry_run() {
    log_info "=== Restore Dry-Run Plan ==="
    log_info ""

    if [ -n "$ETCD_CONTROL_PLANE" ]; then
        log_info "Mode: Remote"
        log_info "Target Node: $ETCD_CONTROL_PLANE"
        log_info "Snapshot: $ETCD_SNAPSHOT_PATH"
        log_info ""
        _log_ssh_settings
        log_info ""
        log_info "Orchestration Plan:"
        log_info "  1. Check SSH connectivity"
        log_info "  2. Upload snapshot to remote node"
        log_info "  3. Generate and transfer bundle"
        log_info "  4. Execute restore on remote node"
    else
        log_info "Mode: Local"
        log_info "Snapshot: $ETCD_SNAPSHOT_PATH"
        log_info ""
        log_info "Steps:"
        log_info "  1. Find etcd container, extract etcdctl binary"
        log_info "  2. Stop etcd (move static pod manifest)"
        log_info "  3. Backup existing etcd data directory"
        log_info "  4. Run etcdctl snapshot restore"
        log_info "  5. Restore etcd manifest, wait for etcd to start"
        log_info "  6. Verify etcd health"
    fi
    log_info ""
    log_info "=== End of dry-run (no changes made) ==="
}

# --- Remote backup ---

# Global state for remote cleanup handlers (closures don't capture locals in bash)
_ETCD_REMOTE_USER=""
_ETCD_REMOTE_HOST=""
_ETCD_REMOTE_DIR=""

_cleanup_etcd_remote_dir() {
    if [ -n "$_ETCD_REMOTE_DIR" ]; then
        _deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "rm -rf '$_ETCD_REMOTE_DIR'" >/dev/null 2>&1 || true
    fi
}
_cleanup_etcd_known_hosts() { rm -f "$_DEPLOY_KNOWN_HOSTS"; }

# Common setup for remote backup/restore: known_hosts, SSH check, sudo check, temp dir
# Sets: _ETCD_REMOTE_USER, _ETCD_REMOTE_HOST, _ETCD_REMOTE_DIR
_setup_etcd_remote() {
    local node="$ETCD_CONTROL_PLANE"
    _parse_node_address "$node"
    _ETCD_REMOTE_USER="$_NODE_USER"
    _ETCD_REMOTE_HOST="$_NODE_HOST"

    # Setup known_hosts
    _DEPLOY_KNOWN_HOSTS=$(mktemp -t etcd-known-hosts-XXXXXX)
    chmod 600 "$_DEPLOY_KNOWN_HOSTS"
    if [ -n "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ] && [ -f "$DEPLOY_SSH_KNOWN_HOSTS_FILE" ]; then
        cp "$DEPLOY_SSH_KNOWN_HOSTS_FILE" "$_DEPLOY_KNOWN_HOSTS"
    fi
    _push_cleanup _cleanup_etcd_known_hosts

    # SSH connectivity check
    log_info "Step 1: Checking SSH connectivity..."
    local _ssh_err
    if ! _ssh_err=$(_deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "echo ok" 2>&1 >/dev/null); then
        log_error "SSH connection failed (${_ETCD_REMOTE_USER}@${_ETCD_REMOTE_HOST}:${DEPLOY_SSH_PORT})"
        [ -n "$_ssh_err" ] && log_error "  ${_ssh_err}"
        return 1
    fi
    log_info "  [${_ETCD_REMOTE_HOST}] SSH OK"

    # Pre-check sudo for non-root users
    if [ "$_ETCD_REMOTE_USER" != "root" ]; then
        if ! _deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "sudo -n true" >/dev/null 2>&1; then
            log_error "sudo -n failed -- NOPASSWD sudo required for ${_ETCD_REMOTE_USER}"
            return 1
        fi
    fi

    # Create remote temp directory
    _ETCD_REMOTE_DIR=$(_deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "d=\$(mktemp -d) && chmod 700 \"\$d\" && echo \"\$d\"") || true
    _ETCD_REMOTE_DIR=$(echo "$_ETCD_REMOTE_DIR" | tr -d '[:space:]')
    if [ -z "$_ETCD_REMOTE_DIR" ] || [[ "$_ETCD_REMOTE_DIR" != /* ]]; then
        log_error "Failed to create remote temp directory"
        return 1
    fi
    _push_cleanup _cleanup_etcd_remote_dir
}

_teardown_etcd_remote() {
    _cleanup_etcd_remote_dir
    _pop_cleanup
    _cleanup_etcd_known_hosts
    _pop_cleanup
    _DEPLOY_KNOWN_HOSTS=""
    _ETCD_REMOTE_USER=""
    _ETCD_REMOTE_HOST=""
    _ETCD_REMOTE_DIR=""
}

# Generate bundle and transfer to remote node
_transfer_etcd_bundle() {
    local bundle_path
    bundle_path=$(mktemp -t setup-k8s-etcd-XXXXXX.sh)
    chmod 600 "$bundle_path"
    generate_deploy_bundle "$bundle_path"

    if ! _deploy_scp "$bundle_path" "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "${_ETCD_REMOTE_DIR}/setup-k8s.sh"; then
        log_error "Failed to transfer bundle"
        rm -f "$bundle_path"
        return 1
    fi
    rm -f "$bundle_path"
}

# Build and execute a remote etcd subcommand
# Usage: _exec_etcd_remote <subcommand> <label> <extra_args...>
_exec_etcd_remote() {
    local subcmd="$1" label="$2"; shift 2
    local sudo_pfx=""
    [ "$_ETCD_REMOTE_USER" != "root" ] && sudo_pfx="sudo -n "
    local cmd="${sudo_pfx}bash ${_ETCD_REMOTE_DIR}/setup-k8s.sh ${subcmd}"
    for arg in "$@"; do
        cmd+=" $(printf '%q' "$arg")"
    done
    if [ ${#ETCD_PASSTHROUGH_ARGS[@]} -gt 0 ]; then
        for arg in "${ETCD_PASSTHROUGH_ARGS[@]}"; do
            cmd+=" $(printf '%q' "$arg")"
        done
    fi

    if ! _deploy_exec_remote "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "$label" "$cmd"; then
        log_error "Remote ${subcmd} failed"
        return 1
    fi
}

backup_etcd_remote() {
    log_info "Remote etcd backup from ${ETCD_CONTROL_PLANE}..."

    _setup_etcd_remote || return 1

    log_info "Step 2: Generating and transferring bundle..."
    _transfer_etcd_bundle || return 1

    log_info "Step 3: Executing backup on remote node..."
    local remote_snapshot="${_ETCD_REMOTE_DIR}/etcd-snapshot.db"
    _exec_etcd_remote "backup" "etcd backup" --snapshot-path "$remote_snapshot" || return 1

    # Download snapshot
    log_info "Step 4: Downloading snapshot to $ETCD_SNAPSHOT_PATH..."
    if [ "$_ETCD_REMOTE_USER" != "root" ]; then
        local sudo_pfx="sudo -n "
        _deploy_ssh "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "${sudo_pfx}chmod 644 '${remote_snapshot}'" >/dev/null 2>&1 || true
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

    _teardown_etcd_remote
    log_info "Remote etcd backup complete!"
    return 0
}

# --- Remote restore ---

restore_etcd_remote() {
    log_info "Remote etcd restore to ${ETCD_CONTROL_PLANE}..."

    _setup_etcd_remote || return 1

    # Upload snapshot to remote
    log_info "Step 2: Uploading snapshot to remote node..."
    local remote_snapshot="${_ETCD_REMOTE_DIR}/etcd-snapshot.db"
    if ! _deploy_scp "$ETCD_SNAPSHOT_PATH" "$_ETCD_REMOTE_USER" "$_ETCD_REMOTE_HOST" "$remote_snapshot"; then
        log_error "Failed to upload snapshot"
        return 1
    fi

    log_info "Step 3: Generating and transferring bundle..."
    _transfer_etcd_bundle || return 1

    log_info "Step 4: Executing restore on remote node..."
    _exec_etcd_remote "restore" "etcd restore" --snapshot-path "$remote_snapshot" || return 1

    _teardown_etcd_remote
    log_info "Remote etcd restore complete!"
    return 0
}
