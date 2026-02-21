#!/bin/bash

set -euo pipefail

# Ensure SUDO_USER is defined even when script runs as root without sudo
SUDO_USER="${SUDO_USER:-}"

# Get the directory where the script is located
# When piped via stdin (curl | bash), BASH_SOURCE[0] is unset under set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Detect stdin execution mode (curl | bash) — BASH_SOURCE[0] is empty or unset
_STDIN_MODE=false
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]:-}" = "bash" ] || [ "${BASH_SOURCE[0]:-}" = "/dev/stdin" ] || [ "${BASH_SOURCE[0]:-}" = "/proc/self/fd/0" ]; then
    _STDIN_MODE=true
fi

# Default GitHub base URL (can be overridden)
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/MuNeNICK/setup-k8s/main}"

# Check if running in bundled mode (all modules embedded in this script)
BUNDLED_MODE="${BUNDLED_MODE:-false}"

# Single-pass argument parsing: extract subcommand, global flags, and build cli_args
# before bootstrap to avoid unnecessary network fetch for --help.
# Subcommand is detected strictly from the first positional argument only,
# to avoid misinterpreting option values (e.g. --ha-interface deploy) as subcommands.
original_args=("$@")
ACTION=""
cli_args=()
_action_detected=false
i=0
while [ $i -lt ${#original_args[@]} ]; do
    arg="${original_args[$i]}"
    # shellcheck disable=SC2034 # LOG_LEVEL used by logging module
    case "$arg" in
        --help|-h)
            # Deploy/upgrade --help is deferred to their parsers
            if [ "$_action_detected" = true ] && { [ "$ACTION" = "deploy" ] || [ "$ACTION" = "upgrade" ]; }; then
                cli_args+=("$arg")
            else
                cat <<'HELPEOF'
Usage: setup-k8s.sh <init|join|deploy|upgrade> [options]

Subcommands:
  init                    Initialize a new Kubernetes cluster
  join                    Join an existing cluster as a worker or control-plane node
  deploy                  Deploy a cluster across remote nodes via SSH
  upgrade                 Upgrade cluster Kubernetes version

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
  --ssh-key PATH          Path to SSH private key
  --ssh-password PASS     SSH password (requires sshpass)
  --ssh-known-hosts FILE  known_hosts file for host key verification (recommended)
  --ssh-host-key-check MODE  SSH host key policy: yes, no, or accept-new (default: yes)
  --ha-vip ADDRESS        VIP for HA (required when >1 control-plane)

  Run 'setup-k8s.sh deploy --help' for deploy-specific details.

Options (upgrade):
  --kubernetes-version VER  Target version in MAJOR.MINOR.PATCH format (e.g., 1.33.2)
  --first-control-plane     Run 'kubeadm upgrade apply' (first CP only)
  --skip-drain              Skip drain/uncordon (for single-node clusters)
  --control-planes IPs      Remote mode: comma-separated control-plane nodes
  --workers IPs             Remote mode: comma-separated worker nodes

  Run 'setup-k8s.sh upgrade --help' for upgrade-specific details.
HELPEOF
                exit 0
            fi
            ((i += 1))
            ;;
        --verbose)
            LOG_LEVEL=2
            ((i += 1))
            ;;
        --quiet)
            LOG_LEVEL=0
            ((i += 1))
            ;;
        --dry-run)
            DRY_RUN=true
            ((i += 1))
            ;;
        --ha|--control-plane|--swap-enabled|--first-control-plane|--skip-drain)
            cli_args+=("$arg")
            ((i += 1))
            ;;
        -*)
            # All other flags take a value: skip next token so it is never
            # interpreted as a subcommand. Pass both through to cli_args.
            if [ $((i+1)) -ge ${#original_args[@]} ]; then
                echo "Error: $arg requires a value" >&2
                exit 1
            fi
            cli_args+=("$arg" "${original_args[$((i+1))]}")
            ((i += 2))
            ;;
        *)
            # First non-flag positional argument is the subcommand (strip it from cli_args)
            if [ "$_action_detected" = false ]; then
                case "$arg" in
                    init|join|deploy|upgrade)
                        ACTION="$arg"
                        _action_detected=true
                        ((i += 1))
                        continue
                        ;;
                esac
            fi
            cli_args+=("$arg")
            ((i += 1))
            ;;
    esac
done
unset _action_detected

# Source shared bootstrap logic (exit traps, module validation, _dispatch)
if ! type -t _validate_shell_module &>/dev/null; then
    if [ "$_STDIN_MODE" = false ] && [ -f "$SCRIPT_DIR/common/bootstrap.sh" ]; then
        source "$SCRIPT_DIR/common/bootstrap.sh"
    elif [ "$BUNDLED_MODE" = "true" ]; then
        echo "Error: Bundled mode via stdin requires a script with embedded modules." >&2
        exit 1
    else
        # Running standalone (e.g. curl | bash): download bootstrap.sh from GitHub
        _BOOTSTRAP_TMP=$(mktemp -t bootstrap-XXXXXX.sh)
        if curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/bootstrap.sh" > "$_BOOTSTRAP_TMP" && [ -s "$_BOOTSTRAP_TMP" ]; then
            # shellcheck disable=SC1090
            source "$_BOOTSTRAP_TMP"
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
        # Deploy uses associative arrays (declare -A) which require Bash 4.3+
        if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
            echo "Error: Deploy mode requires Bash 4.3+ (current: $BASH_VERSION)" >&2
            exit 1
        fi

        local deploy_src_modules=(variables logging validation deploy)
        if [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; then
            # Local checkout: source modules directly
            for module in "${deploy_src_modules[@]}"; do
                if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                    source "$SCRIPT_DIR/common/${module}.sh"
                else
                    echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                    exit 1
                fi
            done
        else
            # Standalone or curl | bash: download all modules for deploy bundle
            load_deploy_modules
            for module in "${deploy_src_modules[@]}"; do
                source "$DEPLOY_MODULES_DIR/common/${module}.sh"
            done
            # Override SCRIPT_DIR so bundle generation finds the downloaded files
            SCRIPT_DIR="$DEPLOY_MODULES_DIR"
        fi

        parse_deploy_args "${cli_args[@]}"
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
        for _uarg in "${cli_args[@]}"; do
            if [ "$_uarg" = "--control-planes" ]; then
                _upgrade_remote=true
                break
            fi
        done

        if [ "$_upgrade_remote" = true ]; then
            # Remote mode: orchestrate upgrade via SSH (no root required locally)
            if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
                echo "Error: Upgrade remote mode requires Bash 4.3+ (current: $BASH_VERSION)" >&2
                exit 1
            fi

            local upgrade_deploy_modules=(variables logging validation deploy upgrade)
            if [ "$_STDIN_MODE" = false ] && [ -d "$SCRIPT_DIR/common" ]; then
                for module in "${upgrade_deploy_modules[@]}"; do
                    if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
                        source "$SCRIPT_DIR/common/${module}.sh"
                    else
                        echo "Error: Required module common/${module}.sh not found in $SCRIPT_DIR" >&2
                        exit 1
                    fi
                done
            else
                load_deploy_modules
                for module in "${upgrade_deploy_modules[@]}"; do
                    source "$DEPLOY_MODULES_DIR/common/${module}.sh"
                done
                SCRIPT_DIR="$DEPLOY_MODULES_DIR"
            fi

            parse_upgrade_deploy_args "${cli_args[@]}"
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
            for _uarg in "${cli_args[@]}"; do
                if [ "$_uarg" = "--help" ] || [ "$_uarg" = "-h" ]; then
                    source "$SCRIPT_DIR/common/variables.sh" 2>/dev/null || true
                    source "$SCRIPT_DIR/common/logging.sh" 2>/dev/null || true
                    source "$SCRIPT_DIR/common/validation.sh" 2>/dev/null || true
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
                    source "$SCRIPT_DIR/common/upgrade.sh"
                fi
            else
                load_modules "setup-k8s" dependencies containerd crio kubernetes
                # Download and source upgrade module
                local _upgrade_tmp
                _upgrade_tmp=$(mktemp -t upgrade-XXXXXX.sh)
                if curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/upgrade.sh" > "$_upgrade_tmp" && [ -s "$_upgrade_tmp" ]; then
                    source "$_upgrade_tmp"
                    rm -f "$_upgrade_tmp"
                else
                    echo "Error: Failed to download upgrade.sh" >&2
                    rm -f "$_upgrade_tmp"
                    exit 1
                fi
            fi

            parse_upgrade_local_args "${cli_args[@]}"

            # Detect distribution (if not already detected)
            if [ -z "${DISTRO_FAMILY:-}" ]; then
                detect_distribution
            fi

            upgrade_node_local
            exit $?
        fi
    fi

    # Check root privileges early (before loading modules)
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root" >&2
        exit 1
    fi

    # Validate action early to avoid unnecessary module loading
    if [[ "$ACTION" != "init" && "$ACTION" != "join" ]]; then
        echo "Error: First argument must be 'init' or 'join' subcommand" >&2
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
    parse_setup_args "${cli_args[@]}"

    # Validate inputs
    validate_join_args
    validate_cri
    validate_completion_options

    # Detect distribution (if not already detected)
    if [ -z "${DISTRO_FAMILY:-}" ]; then
        detect_distribution
    fi

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

    # Install dependencies
    log_info "Installing dependencies..."
    _dispatch "install_dependencies_${DISTRO_FAMILY}"

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
    if [[ "$ACTION" == "init" ]]; then
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
