#!/bin/sh

set -eu

# Ensure /usr/local/bin is in PATH (generic distro installs binaries there)
case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) export PATH="/usr/local/bin:$PATH" ;;
esac

# Ensure SUDO_USER is defined even when script runs as root without sudo
SUDO_USER="${SUDO_USER:-}"

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect stdin execution mode (curl | sh)
_STDIN_MODE=false
case "$0" in
    sh|dash|ash|bash|*/sh|*/dash|*/ash|*/bash|/dev/stdin|/proc/self/fd/0) _STDIN_MODE=true ;;
esac

# Default GitHub base URL (can be overridden)
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main}"

# Defaults for global flags parsed before modules are loaded
LOG_DIR="${LOG_DIR:-}"
_AUDIT_SYSLOG="${_AUDIT_SYSLOG:-false}"
COLLECT_DIAGNOSTICS="${COLLECT_DIAGNOSTICS:-false}"
RESUME_ENABLED="${RESUME_ENABLED:-false}"

# Check if running in bundled mode (all modules embedded in this script)
BUNDLED_MODE="${BUNDLED_MODE:-false}"

# Single-pass argument parsing: extract subcommand, global flags, and build cli_args
# before bootstrap to avoid unnecessary network fetch for --help.
# Subcommand is detected strictly from the first positional argument only,
# to avoid misinterpreting option values (e.g. --ha-interface deploy) as subcommands.
ACTION=""
_cli_argc=0
_action_detected=false
while [ $# -gt 0 ]; do
    arg="$1"
    # shellcheck disable=SC2034 # LOG_LEVEL used by logging module
    case "$arg" in
        --help|-h)
            # Deploy/upgrade/backup/restore/status --help is deferred to their parsers
            if [ "$_action_detected" = true ] && { [ "$ACTION" = "deploy" ] || [ "$ACTION" = "upgrade" ] || [ "$ACTION" = "remove" ] || [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore" ] || [ "$ACTION" = "cleanup" ] || [ "$ACTION" = "status" ] || [ "$ACTION" = "preflight" ] || [ "$ACTION" = "renew" ]; }; then
                _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            else
                cat <<'HELPEOF'
Usage: setup-k8s.sh <init|join|deploy|upgrade|remove|backup|restore|cleanup|status|preflight|renew> [options]

Subcommands:
  init                    Initialize a new Kubernetes cluster
  join                    Join an existing cluster as a worker or control-plane node
  deploy                  Deploy a cluster across remote nodes via SSH
  upgrade                 Upgrade cluster Kubernetes version
  remove                  Remove nodes from the cluster (drain, delete, reset)
  backup                  Create an etcd snapshot backup
  restore                 Restore an etcd snapshot
  cleanup                 Clean up Kubernetes installation from this node
  status                  Show cluster and node status
  preflight               Run preflight checks before init/join
  renew                   Renew or check Kubernetes certificates

Options (init/join):
  --cri RUNTIME           Container runtime (containerd or crio). Default: containerd
  --proxy-mode MODE       Kube-proxy mode (iptables, ipvs, or nftables). Default: iptables
  --pod-network-cidr CIDR Pod network CIDR (e.g., 192.168.0.0/16)
  --apiserver-advertise-address ADDR  API server advertise address
  --control-plane-endpoint ENDPOINT   Control plane endpoint
  --service-cidr CIDR     Service CIDR (e.g., 10.96.0.0/12)
  --kubernetes-version VER Kubernetes version (e.g., 1.29, 1.28)
  --join-token TOKEN      Join token (join only)
  --join-address ADDR     Control plane address (join only)
  --discovery-token-hash HASH  Discovery token hash (join only)
  --control-plane         Join as control-plane node (join only, HA cluster)
  --certificate-key KEY   Certificate key for control-plane join
  --ha                    Enable HA mode with kube-vip (init only)
  --ha-vip ADDRESS        VIP address (required when --ha; also for join --control-plane)
  --ha-interface IFACE    Network interface for VIP (auto-detected if omitted)
  --swap-enabled          Keep swap enabled (K8s 1.28+, NodeSwap LimitedSwap)
  --distro FAMILY         Override distro family detection (debian, rhel, suse, arch, alpine, generic)
  --enable-completion BOOL  Enable shell completion setup (default: true)
  --completion-shells LIST  Shells to configure (auto, bash, zsh, fish, or comma-separated)
  --install-helm BOOL     Install Helm package manager (default: false)
  --dry-run               Show configuration summary and exit without making changes
  --verbose               Enable debug logging
  --quiet                 Suppress informational messages (errors only)
  --help, -h              Display this help message

Options (deploy):
  --control-planes IPs    Comma-separated control-plane nodes (user@ip or ip)
  --workers IPs           Comma-separated worker nodes (user@ip or ip)
  --ssh-user USER         Default SSH user (default: root)
  --ssh-port PORT         SSH port (default: 22)
  --ssh-key PATH          Path to SSH private key (auto-discovered from ~/.ssh/ when omitted)
  --ssh-password PASS     SSH password (requires sshpass)
  --ssh-known-hosts FILE  known_hosts file for host key verification (recommended)
  --ssh-host-key-check MODE  SSH host key policy: yes, no, or accept-new (default: accept-new)
  --ha-vip ADDRESS        VIP for HA (required when >1 control-plane)

  Run 'setup-k8s.sh deploy --help' for deploy-specific details.

Options (upgrade):
  --kubernetes-version VER  Target version in MAJOR.MINOR.PATCH format (e.g., 1.33.2)
  --first-control-plane     Run 'kubeadm upgrade apply' (first CP only)
  --skip-drain              Skip drain/uncordon (for single-node clusters)
  --control-planes IPs      Remote mode: comma-separated control-plane nodes
  --workers IPs             Remote mode: comma-separated worker nodes

  Run 'setup-k8s.sh upgrade --help' for upgrade-specific details.

Options (remove):
  --control-plane IP        Control-plane node (user@ip or ip)
  --nodes IPs               Comma-separated nodes to remove (user@ip or ip)
  --force                   Skip confirmation prompt

  Run 'setup-k8s.sh remove --help' for details.

Options (cleanup):
  --force                 Skip confirmation prompt
  --preserve-cni          Preserve CNI configurations
  --remove-helm           Remove Helm binary and configuration

  Run 'setup-k8s.sh cleanup --help' for details.

Options (backup):
  --snapshot-path PATH    Output snapshot path (default: auto-generated)
  --control-plane IP      Remote mode: target control-plane node (user@ip or ip)

  Run 'setup-k8s.sh backup --help' for details.

Options (restore):
  --snapshot-path PATH    Snapshot file to restore (required)
  --control-plane IP      Remote mode: target control-plane node (user@ip or ip)

  Run 'setup-k8s.sh restore --help' for details.

Options (status):
  --output FORMAT         Output format: text (default) or wide

  Run 'setup-k8s.sh status --help' for details.

Options (preflight):
  --mode MODE             Check mode: init or join (default: init)
  --cri RUNTIME           Container runtime to check (default: containerd)
  --proxy-mode MODE       Proxy mode to check (default: iptables)

  Run 'setup-k8s.sh preflight --help' for details.

Options (renew):
  --certs CERTS           Certificates to renew: 'all' or comma-separated list (default: all)
  --check-only            Only check certificate expiration (no renewal)
  --control-planes IPs    Remote mode: comma-separated control-plane nodes

  Run 'setup-k8s.sh renew --help' for details.
HELPEOF
                exit 0
            fi
            shift
            ;;
        --verbose)
            LOG_LEVEL=2
            shift
            ;;
        --quiet)
            LOG_LEVEL=0
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --log-dir)
            if [ $# -lt 2 ]; then
                echo "Error: --log-dir requires a value" >&2
                exit 1
            fi
            LOG_DIR="$2"
            shift 2
            ;;
        --audit-syslog)
            _AUDIT_SYSLOG=true
            shift
            ;;
        --collect-diagnostics)
            COLLECT_DIAGNOSTICS=true
            shift
            ;;
        --distro)
            if [ $# -lt 2 ]; then
                echo "Error: --distro requires a value" >&2
                exit 1
            fi
            DISTRO_OVERRIDE="$2"
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$2"
            shift 2
            ;;
        --resume)
            RESUME_ENABLED=true
            shift
            ;;
        --ha|--control-plane|--swap-enabled|--first-control-plane|--skip-drain|--no-rollback|--auto-step-upgrade|--force|--preserve-cni|--remove-helm|--check-only|--preflight-strict)
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            shift
            ;;
        -*)
            # All other flags take a value: skip next token so it is never
            # interpreted as a subcommand. Pass both through to cli_args.
            if [ $# -lt 2 ]; then
                echo "Error: $arg requires a value" >&2
                exit 1
            fi
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$2"
            shift 2
            ;;
        *)
            # First non-flag positional argument is the subcommand (strip it from cli_args)
            if [ "$_action_detected" = false ]; then
                case "$arg" in
                    init|join|deploy|upgrade|remove|backup|restore|cleanup|status|preflight|renew)
                        ACTION="$arg"
                        _action_detected=true
                        shift
                        continue
                        ;;
                    *)
                        echo "Error: Unknown subcommand '$arg'. Valid subcommands: init, join, deploy, upgrade, remove, backup, restore, cleanup, status, preflight, renew" >&2
                        exit 1
                        ;;
                esac
            fi
            _cli_argc=$((_cli_argc + 1)); eval "_cli_${_cli_argc}=\$arg"
            shift
            ;;
    esac
done
unset _action_detected

# Inline helper: reconstruct cli_args into positional parameters.
# In POSIX sh, `set --` inside a function only affects function-local params.
# This macro must be used inline (not in a function) to modify the caller's $@.
# Usage: eval "$_RESTORE_CLI_ARGS"
_RESTORE_CLI_ARGS='set -- ; _i=1; while [ "$_i" -le "$_cli_argc" ]; do eval "set -- \"\$@\" \"\$_cli_${_i}\""; _i=$((_i + 1)); done'

# Source shared bootstrap logic (exit traps, module validation, _dispatch)
if ! type _validate_shell_module >/dev/null 2>&1; then
    if [ "$_STDIN_MODE" = false ] && [ -f "$SCRIPT_DIR/common/bootstrap.sh" ]; then
        . "$SCRIPT_DIR/common/bootstrap.sh"
    elif [ "$BUNDLED_MODE" = "true" ]; then
        echo "Error: Bundled mode via stdin requires a script with embedded modules." >&2
        exit 1
    else
        # Running standalone (e.g. curl | sh): download bootstrap.sh from GitHub
        _BOOTSTRAP_TMP=$(mktemp /tmp/bootstrap-XXXXXX)
        if curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/bootstrap.sh" > "$_BOOTSTRAP_TMP" && [ -s "$_BOOTSTRAP_TMP" ]; then
            # shellcheck disable=SC1090
            . "$_BOOTSTRAP_TMP"
            rm -f "$_BOOTSTRAP_TMP"
        else
            echo "Error: Failed to download bootstrap.sh from ${GITHUB_BASE_URL}" >&2
            rm -f "$_BOOTSTRAP_TMP"
            exit 1
        fi
    fi
fi

# Show dry-run configuration summary for init/join
_setup_dry_run() {
    log_info "=== Dry-run Configuration Summary ==="
    log_info "Action: ${ACTION}"
    log_info "Container Runtime: ${CRI}"
    log_info "Proxy mode: ${PROXY_MODE}"
    log_info "Kubernetes Version (minor): ${K8S_VERSION}"
    log_info "Distribution: ${DISTRO_NAME:-unknown} (family: ${DISTRO_FAMILY:-unknown})"
    log_info "Swap enabled: ${SWAP_ENABLED}"
    log_info "Install Helm: ${INSTALL_HELM}"
    log_info "Shell Completion: ${ENABLE_COMPLETION} (shells: ${COMPLETION_SHELLS})"
    [ -n "$KUBEADM_POD_CIDR" ] && log_info "Pod network CIDR: $KUBEADM_POD_CIDR"
    [ -n "$KUBEADM_SERVICE_CIDR" ] && log_info "Service CIDR: $KUBEADM_SERVICE_CIDR"
    [ -n "$KUBEADM_API_ADDR" ] && log_info "API server address: $KUBEADM_API_ADDR"
    [ -n "$KUBEADM_CP_ENDPOINT" ] && log_info "Control plane endpoint: $KUBEADM_CP_ENDPOINT"
    if [ "$JOIN_AS_CONTROL_PLANE" = true ]; then
        log_info "HA Mode: joining as control-plane"
    fi
    if [ "$HA_ENABLED" = true ]; then
        log_info "HA Mode: kube-vip enabled"
        log_info "HA VIP: ${HA_VIP_ADDRESS}"
        log_info "HA Interface: ${HA_VIP_INTERFACE}"
    fi
    log_info "=== End of dry-run (no changes made) ==="
}

# Main execution starts here
main() {
    # Deploy subcommand: orchestrator runs locally, no root / distro detection needed
    if [ "$ACTION" = "deploy" ]; then
        local deploy_src_modules="variables logging validation ssh health diagnostics state deploy"
        if [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; then
            # Local checkout: source modules directly
            for module in $deploy_src_modules; do
                if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                    . "$SCRIPT_DIR/common/${module}.sh"
                else
                    echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                    exit 1
                fi
            done
        else
            # Standalone or curl | sh: download all modules for deploy bundle
            load_deploy_modules
            for module in $deploy_src_modules; do
                . "$DEPLOY_MODULES_DIR/common/${module}.sh"
            done
            # Override SCRIPT_DIR so bundle generation finds the downloaded files
            SCRIPT_DIR="$DEPLOY_MODULES_DIR"
        fi

        eval "$_RESTORE_CLI_ARGS"
        parse_deploy_args "$@"
        validate_deploy_args

        if [ "$DRY_RUN" = true ]; then
            deploy_dry_run
            exit 0
        fi

        deploy_cluster
        exit $?
    fi

    # Upgrade subcommand: local or remote mode
    if [ "$ACTION" = "upgrade" ]; then
        # Detect mode: --control-planes present → remote mode, otherwise → local mode
        local _upgrade_remote=false
        eval "$_RESTORE_CLI_ARGS"
        for _uarg in "$@"; do
            if [ "$_uarg" = "--control-planes" ]; then
                _upgrade_remote=true
                break
            fi
        done

        if [ "$_upgrade_remote" = true ]; then
            # Remote mode: orchestrate upgrade via SSH (no root required locally)
            local upgrade_deploy_modules="variables logging validation ssh health diagnostics state deploy upgrade"
            if [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; then
                for module in $upgrade_deploy_modules; do
                    if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                        . "$SCRIPT_DIR/common/${module}.sh"
                    else
                        echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                        exit 1
                    fi
                done
            else
                load_deploy_modules
                for module in $upgrade_deploy_modules; do
                    . "$DEPLOY_MODULES_DIR/common/${module}.sh"
                done
                SCRIPT_DIR="$DEPLOY_MODULES_DIR"
            fi

            eval "$_RESTORE_CLI_ARGS"
            parse_upgrade_deploy_args "$@"
            validate_upgrade_deploy_args

            if [ "$DRY_RUN" = true ]; then
                upgrade_dry_run
                exit 0
            fi

            upgrade_cluster
            exit $?
        else
            # Local mode: upgrade this node (root required)
            # Handle --help before root check (allow non-root users to see help)
            eval "$_RESTORE_CLI_ARGS"
            for _uarg in "$@"; do
                if [ "$_uarg" = "--help" ] || [ "$_uarg" = "-h" ]; then
                    . "$SCRIPT_DIR/common/variables.sh" 2>/dev/null || true
                    . "$SCRIPT_DIR/common/logging.sh" 2>/dev/null || true
                    . "$SCRIPT_DIR/common/validation.sh" 2>/dev/null || true
                    show_upgrade_help
                fi
            done
            if [ "$(id -u)" -ne 0 ]; then
                echo "Error: Local upgrade must be run as root" >&2
                exit 1
            fi

            if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
                run_local "parse_upgrade_local_args" dependencies containerd crio kubernetes
                # Source upgrade module
                if [ "$BUNDLED_MODE" != "true" ] && [ -f "$SCRIPT_DIR/common/upgrade.sh" ]; then
                    . "$SCRIPT_DIR/common/upgrade.sh"
                fi
            else
                load_modules "setup-k8s" dependencies containerd crio kubernetes
                # Download and source upgrade module
                local _upgrade_tmp
                _upgrade_tmp=$(mktemp /tmp/upgrade-XXXXXX)
                if curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/upgrade.sh" > "$_upgrade_tmp" && [ -s "$_upgrade_tmp" ]; then
                    . "$_upgrade_tmp"
                    rm -f "$_upgrade_tmp"
                else
                    echo "Error: Failed to download upgrade.sh" >&2
                    rm -f "$_upgrade_tmp"
                    exit 1
                fi
            fi

            eval "$_RESTORE_CLI_ARGS"
            parse_upgrade_local_args "$@"

            # Detect distribution (if not already detected)
            if [ -z "${DISTRO_FAMILY:-}" ]; then
                detect_distribution
            fi

            upgrade_node_local
            exit $?
        fi
    fi

    # Remove subcommand: remote mode only (orchestrate node removal via SSH)
    if [ "$ACTION" = "remove" ]; then
        local remove_deploy_modules="variables logging validation ssh health diagnostics state deploy upgrade remove"
        if [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; then
            for module in $remove_deploy_modules; do
                if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                    . "$SCRIPT_DIR/common/${module}.sh"
                else
                    echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                    exit 1
                fi
            done
        else
            load_deploy_modules
            for module in $remove_deploy_modules; do
                . "$DEPLOY_MODULES_DIR/common/${module}.sh"
            done
            SCRIPT_DIR="$DEPLOY_MODULES_DIR"
        fi

        eval "$_RESTORE_CLI_ARGS"
        parse_remove_args "$@"
        validate_remove_args

        if [ "$DRY_RUN" = true ]; then
            remove_dry_run
            exit 0
        fi

        remove_cluster
        exit $?
    fi

    # Cleanup subcommand: local mode only (replaces cleanup-k8s.sh)
    if [ "$ACTION" = "cleanup" ]; then
        # Handle --help before root check
        eval "$_RESTORE_CLI_ARGS"
        for _carg in "$@"; do
            if [ "$_carg" = "--help" ] || [ "$_carg" = "-h" ]; then
                . "$SCRIPT_DIR/common/variables.sh" 2>/dev/null || true
                . "$SCRIPT_DIR/common/logging.sh" 2>/dev/null || true
                . "$SCRIPT_DIR/common/validation.sh" 2>/dev/null || true
                show_cleanup_help
            fi
        done
        if [ "$(id -u)" -ne 0 ]; then
            echo "Error: Cleanup must be run as root" >&2
            exit 1
        fi

        if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
            run_local "parse_cleanup_args" cleanup
        else
            load_modules "setup-k8s" cleanup
        fi

        eval "$_RESTORE_CLI_ARGS"
        parse_cleanup_args "$@"
        confirm_cleanup

        CLEANUP_ERRORS=0
        log_info "Starting Kubernetes cleanup..."

        if [ -z "${DISTRO_FAMILY:-}" ]; then
            detect_distribution
        fi

        check_docker_warning
        stop_kubernetes_services || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        stop_cri_services || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        reset_kubernetes_cluster || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        remove_kubernetes_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        restore_fstab_swap || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        restore_zram_swap || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        cleanup_cni_conditionally || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        cleanup_network_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        cleanup_kube_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        cleanup_crictl_config || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        reset_iptables || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        reset_containerd_config || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        _service_reload || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        _dispatch "cleanup_${DISTRO_FAMILY}" || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        cleanup_kubernetes_completions || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        if [ "${REMOVE_HELM:-false}" = true ]; then
            cleanup_helm || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
        fi

        if [ "$CLEANUP_ERRORS" -gt 0 ]; then
            log_error "Cleanup finished with $CLEANUP_ERRORS error(s). Check the output above for details."
            exit 1
        fi

        log_info "Cleanup complete! Please reboot the system for all changes to take effect."
        exit 0
    fi

    # Backup/Restore subcommand: local or remote mode
    if [ "$ACTION" = "backup" ] || [ "$ACTION" = "restore" ]; then
        # Detect mode: --control-plane present → remote mode, otherwise → local mode
        local _etcd_remote=false
        eval "$_RESTORE_CLI_ARGS"
        for _earg in "$@"; do
            if [ "$_earg" = "--control-plane" ]; then
                _etcd_remote=true; break
            fi
        done

        if [ "$_etcd_remote" = true ]; then
            # Remote mode: orchestrate via SSH (no root required locally)
            local etcd_deploy_modules="variables logging validation ssh deploy etcd"
            if [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; then
                for module in $etcd_deploy_modules; do
                    if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                        . "$SCRIPT_DIR/common/${module}.sh"
                    else
                        echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                        exit 1
                    fi
                done
            else
                load_deploy_modules
                for module in $etcd_deploy_modules; do
                    . "$DEPLOY_MODULES_DIR/common/${module}.sh"
                done
                SCRIPT_DIR="$DEPLOY_MODULES_DIR"
            fi

            eval "$_RESTORE_CLI_ARGS"
            if [ "$ACTION" = "backup" ]; then
                parse_backup_remote_args "$@"
                validate_backup_remote_args
                if [ "$DRY_RUN" = true ]; then
                    backup_dry_run
                    exit 0
                fi
                backup_etcd_remote
            else
                parse_restore_remote_args "$@"
                validate_restore_remote_args
                if [ "$DRY_RUN" = true ]; then
                    restore_dry_run
                    exit 0
                fi
                restore_etcd_remote
            fi
            exit $?
        else
            # Local mode: run on control-plane node (root required)
            # Handle --help before root check
            eval "$_RESTORE_CLI_ARGS"
            for _earg in "$@"; do
                if [ "$_earg" = "--help" ] || [ "$_earg" = "-h" ]; then
                    . "$SCRIPT_DIR/common/variables.sh" 2>/dev/null || true
                    . "$SCRIPT_DIR/common/logging.sh" 2>/dev/null || true
                    . "$SCRIPT_DIR/common/validation.sh" 2>/dev/null || true
                    if [ "$ACTION" = "backup" ]; then
                        show_backup_help
                    else
                        show_restore_help
                    fi
                fi
            done
            if [ "$(id -u)" -ne 0 ]; then
                echo "Error: Local backup/restore must be run as root" >&2
                exit 1
            fi

            if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
                run_local "parse_backup_local_args" dependencies containerd crio kubernetes
                # Source etcd module
                if [ "$BUNDLED_MODE" != "true" ] && [ -f "$SCRIPT_DIR/common/etcd.sh" ]; then
                    . "$SCRIPT_DIR/common/etcd.sh"
                fi
            else
                load_modules "setup-k8s" dependencies containerd crio kubernetes
                # Download and source etcd module
                local _etcd_tmp
                _etcd_tmp=$(mktemp /tmp/etcd-XXXXXX)
                if curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/etcd.sh" > "$_etcd_tmp" && [ -s "$_etcd_tmp" ]; then
                    . "$_etcd_tmp"
                    rm -f "$_etcd_tmp"
                else
                    echo "Error: Failed to download etcd.sh" >&2
                    rm -f "$_etcd_tmp"
                    exit 1
                fi
            fi

            eval "$_RESTORE_CLI_ARGS"
            if [ "$ACTION" = "backup" ]; then
                parse_backup_local_args "$@"
                if [ "$DRY_RUN" = true ]; then
                    backup_dry_run
                    exit 0
                fi
                backup_etcd_local
            else
                parse_restore_local_args "$@"
                if [ "$DRY_RUN" = true ]; then
                    restore_dry_run
                    exit 0
                fi
                restore_etcd_local
            fi
            exit $?
        fi
    fi

    # Preflight subcommand: local mode only, root required
    if [ "$ACTION" = "preflight" ]; then
        local preflight_modules="variables logging detection validation helpers preflight"
        if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
            if [ "$BUNDLED_MODE" != "true" ]; then
                for module in $preflight_modules; do
                    if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                        . "$SCRIPT_DIR/common/${module}.sh"
                    else
                        echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                        exit 1
                    fi
                done
            fi
        else
            # Standalone or curl | sh: download required modules
            local _preflight_tmp_dir
            _preflight_tmp_dir=$(mktemp -d /tmp/setup-k8s-preflight-XXXXXX)
            _append_exit_trap "$_preflight_tmp_dir"
            for module in $preflight_modules; do
                if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/${module}.sh" > "$_preflight_tmp_dir/${module}.sh"; then
                    echo "Error: Failed to download common/${module}.sh" >&2
                    exit 1
                fi
                . "$_preflight_tmp_dir/${module}.sh"
            done
        fi

        # Handle --help before root check
        eval "$_RESTORE_CLI_ARGS"
        for _parg in "$@"; do
            if [ "$_parg" = "--help" ] || [ "$_parg" = "-h" ]; then
                show_preflight_help
            fi
        done

        if [ "$(id -u)" -ne 0 ]; then
            echo "Error: Preflight checks must be run as root" >&2
            exit 1
        fi

        eval "$_RESTORE_CLI_ARGS"
        parse_preflight_args "$@"

        if [ "$DRY_RUN" = true ]; then
            preflight_dry_run
            exit 0
        fi

        preflight_local
        exit $?
    fi

    # Renew subcommand: local or remote mode
    if [ "$ACTION" = "renew" ]; then
        # Detect mode: --control-planes present → remote mode, otherwise → local mode
        local _renew_remote=false
        eval "$_RESTORE_CLI_ARGS"
        for _rarg in "$@"; do
            if [ "$_rarg" = "--control-planes" ]; then
                _renew_remote=true
                break
            fi
        done

        if [ "$_renew_remote" = true ]; then
            # Remote mode: orchestrate renewal via SSH (no root required locally)
            local renew_deploy_modules="variables logging validation ssh deploy renew"
            if [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; then
                for module in $renew_deploy_modules; do
                    if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                        . "$SCRIPT_DIR/common/${module}.sh"
                    else
                        echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                        exit 1
                    fi
                done
            else
                load_deploy_modules
                for module in $renew_deploy_modules; do
                    . "$DEPLOY_MODULES_DIR/common/${module}.sh"
                done
                SCRIPT_DIR="$DEPLOY_MODULES_DIR"
            fi

            eval "$_RESTORE_CLI_ARGS"
            parse_renew_deploy_args "$@"
            validate_renew_deploy_args

            if [ "$DRY_RUN" = true ]; then
                renew_dry_run
                exit 0
            fi

            renew_cluster
            exit $?
        else
            # Local mode: renew on this node (root required)
            # Handle --help before root check
            eval "$_RESTORE_CLI_ARGS"
            for _rarg in "$@"; do
                if [ "$_rarg" = "--help" ] || [ "$_rarg" = "-h" ]; then
                    . "$SCRIPT_DIR/common/variables.sh" 2>/dev/null || true
                    . "$SCRIPT_DIR/common/logging.sh" 2>/dev/null || true
                    . "$SCRIPT_DIR/common/validation.sh" 2>/dev/null || true
                    show_renew_help
                fi
            done
            if [ "$(id -u)" -ne 0 ]; then
                echo "Error: Local certificate renewal must be run as root" >&2
                exit 1
            fi

            local renew_local_modules="variables logging detection validation helpers renew"
            if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
                if [ "$BUNDLED_MODE" != "true" ]; then
                    for module in $renew_local_modules; do
                        if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                            . "$SCRIPT_DIR/common/${module}.sh"
                        else
                            echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                            exit 1
                        fi
                    done
                fi
            else
                # Standalone or curl | sh: download required modules
                local _renew_tmp_dir
                _renew_tmp_dir=$(mktemp -d /tmp/setup-k8s-renew-XXXXXX)
                _append_exit_trap "$_renew_tmp_dir"
                for module in $renew_local_modules; do
                    if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/${module}.sh" > "$_renew_tmp_dir/${module}.sh"; then
                        echo "Error: Failed to download common/${module}.sh" >&2
                        exit 1
                    fi
                    . "$_renew_tmp_dir/${module}.sh"
                done
            fi

            eval "$_RESTORE_CLI_ARGS"
            parse_renew_local_args "$@"

            if [ "$DRY_RUN" = true ]; then
                renew_dry_run
                exit 0
            fi

            renew_certs_local
            exit $?
        fi
    fi

    # Status subcommand: local mode only, no root required
    if [ "$ACTION" = "status" ]; then
        local status_modules="variables logging validation helpers status"
        if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
            if [ "$BUNDLED_MODE" != "true" ]; then
                for module in $status_modules; do
                    if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                        . "$SCRIPT_DIR/common/${module}.sh"
                    else
                        echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                        exit 1
                    fi
                done
            fi
        else
            # Standalone or curl | sh: download required modules
            local _status_tmp_dir
            _status_tmp_dir=$(mktemp -d /tmp/setup-k8s-status-XXXXXX)
            _append_exit_trap "$_status_tmp_dir"
            for module in $status_modules; do
                if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/${module}.sh" > "$_status_tmp_dir/${module}.sh"; then
                    echo "Error: Failed to download common/${module}.sh" >&2
                    exit 1
                fi
                . "$_status_tmp_dir/${module}.sh"
            done
        fi

        eval "$_RESTORE_CLI_ARGS"
        parse_status_args "$@"

        if [ "$DRY_RUN" = true ]; then
            status_dry_run
            exit 0
        fi

        status_local
        exit $?
    fi

    # Validate action early (deploy/upgrade/backup/restore/status already handled above)
    if [ -z "$ACTION" ]; then
        echo "Error: Missing subcommand. Valid subcommands: init, join, deploy, upgrade, remove, backup, restore, cleanup, status, preflight, renew" >&2
        echo "Run with --help for usage information" >&2
        exit 1
    fi

    # Check root privileges early (before loading modules)
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root" >&2
        exit 1
    fi

    # Load modules:
    #   - Local checkout (common/ exists): source from SCRIPT_DIR
    #   - Bundled: modules already defined as functions
    #   - stdin or single-file download: fetch from GitHub
    if { [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; } || [ "$BUNDLED_MODE" = "true" ]; then
        run_local "parse_setup_args" dependencies containerd crio kubernetes
    else
        load_modules "setup-k8s" dependencies containerd crio kubernetes
    fi

    # Parse command line arguments
    eval "$_RESTORE_CLI_ARGS"
    parse_setup_args "$@"

    # Validate inputs
    validate_join_args
    validate_cri
    validate_completion_options

    # Detect distribution (if not already detected)
    if [ -z "${DISTRO_FAMILY:-}" ]; then
        detect_distribution
    fi

    # Install dependencies early — generic distro needs curl before version detection
    log_info "Installing dependencies..."
    _dispatch "install_dependencies_${DISTRO_FAMILY}"

    # Determine Kubernetes version
    determine_k8s_version

    # Validate proxy mode after K8S_VERSION is determined
    validate_proxy_mode

    # Validate swap enabled option
    validate_swap_enabled

    # Validate HA arguments
    validate_ha_args

    # Dry-run: show configuration summary and exit
    if [ "$DRY_RUN" = true ]; then
        _setup_dry_run
        exit 0
    fi

    log_info "Starting Kubernetes initialization script..."
    log_info "Action: ${ACTION}"
    log_info "Container Runtime: ${CRI}"
    log_info "Proxy mode: ${PROXY_MODE}"
    log_info "Swap enabled: ${SWAP_ENABLED}"
    log_info "Kubernetes Version (minor): ${K8S_VERSION}"

    # Disable swap (unless --swap-enabled)
    if [ "$SWAP_ENABLED" != true ]; then
        disable_swap
        disable_zram_swap
    fi

    # Enable kernel modules and network settings
    enable_kernel_modules
    configure_network_settings

    # Check IPVS availability if IPVS mode is requested
    if [ "$PROXY_MODE" = "ipvs" ]; then
        check_ipvs_availability
    fi

    # Check nftables availability if nftables mode is requested
    if [ "$PROXY_MODE" = "nftables" ]; then
        check_nftables_availability
    fi

    # Setup container runtime
    log_info "Setting up container runtime: ${CRI}..."
    if [ "$CRI" = "containerd" ]; then
        _dispatch "setup_containerd_${DISTRO_FAMILY}"
    else
        _dispatch "setup_crio_${DISTRO_FAMILY}"
    fi

    # Setup Kubernetes
    log_info "Setting up Kubernetes..."
    _dispatch "setup_kubernetes_${DISTRO_FAMILY}"

    # Pre-cleanup for fresh installation
    log_info "Performing pre-installation cleanup..."
    cleanup_pre_common

    # Clean up existing kube configs
    cleanup_kube_configs

    # Reset iptables rules
    reset_iptables

    # Initialize or join cluster based on action
    if [ "$ACTION" = "init" ]; then
        initialize_cluster
    else
        join_cluster
    fi

    # Show installed versions
    show_versions

    # Setup Helm if requested
    setup_helm

    # Setup shell completions
    setup_k8s_shell_completion

    log_info "Setup completed successfully!"
}

main "$@"
