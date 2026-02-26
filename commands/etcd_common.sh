#!/bin/sh

# Shared CLI parsing, help, and validation for backup/restore subcommands.
# Separated from lib/etcd_helpers.sh to follow the lib/ = library, commands/ = CLI convention.

# Help message for backup/restore (shared).
# Usage: _show_etcd_help <backup|restore>
_show_etcd_help() {
    local mode="$1"
    if [ "$mode" = "backup" ]; then
        echo "Usage: $0 backup [options]"
        echo ""
        echo "Create an etcd snapshot backup from a kubeadm cluster."
        echo ""
        echo "Local mode (run on a control-plane node with sudo):"
        echo "  Optional:"
        echo "    --snapshot-path PATH    Output snapshot path (default: auto-generated)"
    else
        echo "Usage: $0 restore [options]"
        echo ""
        echo "Restore an etcd snapshot to a kubeadm cluster."
        echo ""
        echo "Local mode (run on a control-plane node with sudo):"
        echo "  Required:"
        echo "    --snapshot-path PATH    Snapshot file to restore"
        echo ""
        echo "  Optional:"
    fi
    echo "    --distro FAMILY         Override distro family detection"
    _show_help_footer "    " "Show ${mode} plan and exit"
    echo ""
    echo "Remote mode (from local machine via SSH):"
    echo "  Required:"
    echo "    --control-planes IP     Target control-plane node (user@ip or ip)"
    if [ "$mode" = "restore" ]; then
        echo "    --snapshot-path PATH    Snapshot file to restore (uploaded to remote)"
    fi
    echo ""
    echo "  Optional:"
    if [ "$mode" = "backup" ]; then
        echo "    --snapshot-path PATH    Local download path for snapshot"
    fi
    _show_common_ssh_help "    "
    _show_help_footer "    " "Show ${mode} plan and exit"
    echo ""
    echo "Examples:"
    if [ "$mode" = "backup" ]; then
        echo "  # Local: backup on this node"
        echo "  sudo $0 backup"
        echo "  sudo $0 backup --snapshot-path /tmp/etcd-snapshot.db"
        echo ""
        echo "  # Remote: backup from control-plane node"
        echo "  $0 backup --control-planes 10.0.0.1"
    else
        echo "  # Local: restore on this node"
        echo "  sudo $0 restore --snapshot-path /tmp/etcd-snapshot.db"
        echo ""
        echo "  # Remote: restore to control-plane node"
        echo "  $0 restore --control-planes 10.0.0.1 --snapshot-path /tmp/etcd-snapshot.db"
    fi
}

show_backup_help() { _show_etcd_help "backup"; exit "${1:-0}"; }
show_restore_help() { _show_etcd_help "restore"; exit "${1:-0}"; }

# Parse etcd command line arguments (shared for backup/restore).
# Usage: _parse_etcd_local_args <backup|restore> "$@"
_parse_etcd_local_args() {
    local mode="$1"; shift
    local help_func="show_${mode}_help"
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h)
                "$help_func"
                ;;
            --snapshot-path)
                _require_value $# "$1" "${2:-}"
                # shellcheck disable=SC2034 # used by backup/restore
                ETCD_SNAPSHOT_PATH="$2"
                shift 2
                ;;
            *)
                if _is_distro_flag "$1"; then
                    _parse_distro_flag $# "$1" "${2:-}"
                    shift "$_DISTRO_SHIFT"
                else
                    log_error "Unknown ${mode} option: $1"
                    "$help_func" 1
                fi
                ;;
        esac
    done
    if [ "$mode" = "backup" ] && [ -z "$ETCD_SNAPSHOT_PATH" ]; then
        ETCD_SNAPSHOT_PATH="/var/lib/etcd-backup/snapshot-$(date +%Y%m%d-%H%M%S).db"
    elif [ "$mode" = "restore" ] && [ -z "$ETCD_SNAPSHOT_PATH" ]; then
        log_error "--snapshot-path is required for restore"
        exit 1
    fi
}

# Usage: _parse_etcd_remote_args <backup|restore> "$@"
_parse_etcd_remote_args() {
    local mode="$1"; shift
    local help_func="show_${mode}_help"
    while [ $# -gt 0 ]; do
        case $1 in
            --help|-h)
                "$help_func"
                ;;
            --control-planes)
                _require_value $# "$1" "${2:-}"
                ETCD_CONTROL_PLANES="$2"
                shift 2
                ;;
            --snapshot-path)
                _require_value $# "$1" "${2:-}"
                ETCD_SNAPSHOT_PATH="$2"
                shift 2
                ;;
            --distro)
                _require_value $# "$1" "${2:-}"
                ETCD_PASSTHROUGH_ARGS=$(_passthrough_add_pair "$ETCD_PASSTHROUGH_ARGS" "$1" "$2")
                shift 2
                ;;
            *)
                if _is_common_ssh_flag "$1"; then
                    _parse_common_ssh_args $# "$1" "${2:-}"
                    shift "$_SSH_SHIFT"
                else
                    log_error "Unknown ${mode} option: $1"
                    "$help_func" 1
                fi
                ;;
        esac
    done
    if [ "$mode" = "backup" ] && [ -z "$ETCD_SNAPSHOT_PATH" ]; then
        ETCD_SNAPSHOT_PATH="./etcd-snapshot-$(date +%Y%m%d-%H%M%S).db"
    elif [ "$mode" = "restore" ] && [ -z "$ETCD_SNAPSHOT_PATH" ]; then
        log_error "--snapshot-path is required for restore"
        exit 1
    fi
}

# Validate etcd remote arguments (shared for backup/restore).
# Usage: _validate_etcd_remote_args <backup|restore>
_validate_etcd_remote_args() {
    local mode="$1"
    ETCD_CONTROL_PLANES=$(_normalize_node_list "$ETCD_CONTROL_PLANES")
    if [ -z "$ETCD_CONTROL_PLANES" ]; then
        log_error "--control-planes is required for remote ${mode}"
        exit 1
    fi
    if [ "$mode" = "restore" ] && [ ! -f "$ETCD_SNAPSHOT_PATH" ]; then
        log_error "Snapshot file not found: $ETCD_SNAPSHOT_PATH"
        exit 1
    fi
    _validate_common_ssh_args
    _validate_node_addresses "$ETCD_CONTROL_PLANES"
}

# Public wrappers (called by setup-k8s.sh)
parse_backup_local_args() { _parse_etcd_local_args "backup" "$@"; }
parse_restore_local_args() { _parse_etcd_local_args "restore" "$@"; }
parse_backup_remote_args() { _parse_etcd_remote_args "backup" "$@"; }
parse_restore_remote_args() { _parse_etcd_remote_args "restore" "$@"; }
validate_backup_remote_args() { _validate_etcd_remote_args "backup"; }
validate_restore_remote_args() { _validate_etcd_remote_args "restore"; }
