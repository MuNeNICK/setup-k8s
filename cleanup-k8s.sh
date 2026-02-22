#!/bin/bash

set -euo pipefail

# Ensure /usr/local/bin is in PATH (generic distro installs binaries there)
case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) export PATH="/usr/local/bin:$PATH" ;;
esac

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

# Single-pass argument parsing: detect global flags and build cli_args
# before bootstrap to avoid unnecessary network fetch for --help.
cli_args=()
for _arg in "$@"; do
    # shellcheck disable=SC2034 # LOG_LEVEL used by logging module
    case "$_arg" in
        --help|-h)
            cat <<'HELPEOF'
Usage: cleanup-k8s.sh [options]

Options:
  --force                 Skip confirmation prompt
  --preserve-cni          Preserve CNI configurations
  --remove-helm           Remove Helm binary and configuration
  --verbose               Enable debug logging
  --quiet                 Suppress informational messages (errors only)
  --help, -h              Display this help message
HELPEOF
            exit 0
            ;;
        --verbose) LOG_LEVEL=2 ;;
        --quiet) LOG_LEVEL=0 ;;
        *) cli_args+=("$_arg") ;;
    esac
done
unset _arg

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

# Main execution starts here
main() {
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
        run_local "parse_cleanup_args" cleanup
    else
        load_modules "cleanup-k8s" cleanup
    fi

    parse_cleanup_args "${cli_args[@]}"

    # Confirmation prompt
    confirm_cleanup

    CLEANUP_ERRORS=0
    log_info "Starting Kubernetes cleanup..."

    # Detect distribution (if not already detected)
    if [ -z "${DISTRO_FAMILY:-}" ]; then
        detect_distribution
    fi

    # Check Docker warning
    check_docker_warning

    # Stop Kubernetes and CRI services
    stop_kubernetes_services || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    stop_cri_services || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Reset cluster state
    reset_kubernetes_cluster || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Remove Kubernetes configurations
    remove_kubernetes_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Restore swap settings that were modified during setup
    restore_fstab_swap || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    restore_zram_swap || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Clean up CNI configurations conditionally
    cleanup_cni_conditionally || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Remove kernel modules and sysctl configurations
    cleanup_network_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Clean up .kube directories
    cleanup_kube_configs || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Remove crictl configuration
    cleanup_crictl_config || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Reset iptables rules
    reset_iptables || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Reset containerd configuration (but don't remove containerd)
    reset_containerd_config || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Reload init system
    _service_reload || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Perform distribution-specific cleanup
    _dispatch "cleanup_${DISTRO_FAMILY}" || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Cleanup shell completions
    cleanup_kubernetes_completions || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))

    # Cleanup Helm only when explicitly requested
    if [ "${REMOVE_HELM:-false}" = true ]; then
        cleanup_helm || CLEANUP_ERRORS=$((CLEANUP_ERRORS + 1))
    fi

    if [ "$CLEANUP_ERRORS" -gt 0 ]; then
        log_error "Cleanup finished with $CLEANUP_ERRORS error(s). Check the output above for details."
        exit 1
    fi

    log_info "Cleanup complete! Please reboot the system for all changes to take effect."
}

main "$@"
