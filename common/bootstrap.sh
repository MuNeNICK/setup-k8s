#!/bin/bash

# Shared bootstrap logic for setup-k8s.sh and cleanup-k8s.sh
# Provides: exit trap management, module validation, _dispatch

# Canonical list of common modules (single source of truth).
# Used by load_modules, run_local, and bundle generation.
# bootstrap is listed for bundling but excluded from runtime loading (already sourced).
_COMMON_MODULES=(variables logging detection validation helpers networking swap completion helm upgrade)
_DISTRO_FAMILIES=(arch debian generic rhel suse)
_DISTRO_MODULES=(cleanup containerd crio dependencies kubernetes)

# EXIT trap: collect cleanup paths and run cleanup handlers on exit
_EXIT_CLEANUP_DIRS=()

_append_exit_trap() {
    _EXIT_CLEANUP_DIRS+=("$1")
}

# Composable cleanup handler stack (avoids brittle trap string parsing)
# Usage:
#   _push_cleanup "cleanup_function_name"  # registers handler and sets EXIT trap
#   ... do work ...
#   cleanup_function_name                   # run cleanup explicitly
#   _pop_cleanup                            # remove handler from stack
_EXIT_CLEANUP_HANDLERS=()
_run_cleanup_handlers() {
    # Run handlers in reverse order (LIFO)
    local i
    for (( i=${#_EXIT_CLEANUP_HANDLERS[@]}-1; i>=0; i-- )); do
        ${_EXIT_CLEANUP_HANDLERS[$i]} || echo "Warning: cleanup handler '${_EXIT_CLEANUP_HANDLERS[$i]}' failed" >&2
    done
    # Clean up temporary directories
    for dir in "${_EXIT_CLEANUP_DIRS[@]}"; do
        rm -rf "$dir"
    done
}
trap _run_cleanup_handlers EXIT

_push_cleanup() {
    _EXIT_CLEANUP_HANDLERS+=("$1")
}
_pop_cleanup() {
    if [ ${#_EXIT_CLEANUP_HANDLERS[@]} -gt 0 ]; then
        unset '_EXIT_CLEANUP_HANDLERS[-1]'
    fi
}

# Validate that a downloaded module looks like a shell script
# Usage: _validate_shell_module <file>
_validate_shell_module() {
    local file="$1"
    if [ ! -s "$file" ]; then
        echo "Error: Module file '$file' is empty or missing" >&2
        return 1
    fi
    local first_char
    first_char=$(head -c1 "$file")
    if [ "$first_char" != "#" ]; then
        echo "Error: Module file '$file' does not appear to be a valid shell script" >&2
        return 1
    fi
    local _syntax_err
    if ! _syntax_err=$(bash -n "$file" 2>&1); then
        echo "Error: Module file '$file' contains syntax errors:" >&2
        echo "$_syntax_err" >&2
        return 1
    fi
    return 0
}

# Helper to call dynamically-named functions with safety check
_dispatch() {
    local func_name="$1"; shift
    if type -t "$func_name" &>/dev/null; then
        "$func_name" "$@"
    else
        echo "Error: Required function '$func_name' not found." >&2
        exit 1
    fi
}

# Parameterized module loader for online mode (curl | bash).
# Usage: load_modules <temp_prefix> <distro_module> [<distro_module> ...]
#   temp_prefix:     prefix for the temp directory name (e.g. "setup-k8s" or "cleanup-k8s")
#   distro_modules:  list of distro-specific module names to download (e.g. "dependencies containerd crio kubernetes cleanup")
load_modules() {
    local temp_prefix="$1"; shift
    local -a distro_modules=("$@")

    echo "Loading modules from GitHub..." >&2

    local temp_dir
    temp_dir=$(mktemp -d -t "${temp_prefix}-XXXXXX")
    _append_exit_trap "$temp_dir"

    echo "Downloading common modules..." >&2
    local common_modules=("${_COMMON_MODULES[@]}")
    for module in "${common_modules[@]}"; do
        echo "  - Downloading common/${module}.sh" >&2
        if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/${module}.sh" > "$temp_dir/${module}.sh"; then
            echo "Error: Failed to download common/${module}.sh" >&2
            return 1
        fi
    done

    for module in "${common_modules[@]}"; do
        _validate_shell_module "$temp_dir/${module}.sh" || return 1
    done

    for module in variables logging detection; do
        source "$temp_dir/${module}.sh"
    done

    detect_distribution
    local distro_family_local="$DISTRO_FAMILY"

    log_info "Downloading modules for $distro_family_local..."
    for module in "${distro_modules[@]}"; do
        log_info "  - Downloading distros/$distro_family_local/${module}.sh"
        if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/distros/$distro_family_local/${module}.sh" > "$temp_dir/${distro_family_local}_${module}.sh"; then
            log_error "Failed to download distros/$distro_family_local/${module}.sh"
            return 1
        fi
    done

    for module in "${distro_modules[@]}"; do
        _validate_shell_module "$temp_dir/${distro_family_local}_${module}.sh" || return 1
    done

    log_info "Loading all modules..."
    # Skip modules already sourced for distro detection (variables, logging, detection)
    local _already_sourced=" variables logging detection "
    for module in "${common_modules[@]}"; do
        if [[ "$_already_sourced" == *" $module "* ]]; then
            continue
        fi
        source "$temp_dir/${module}.sh"
    done
    for module in "${distro_modules[@]}"; do
        source "$temp_dir/${distro_family_local}_${module}.sh"
    done

    log_info "All modules loaded successfully"
    return 0
}

# Parameterized local runner. Verifies key function exists; if not, sources from SCRIPT_DIR.
# Usage: run_local <key_function> <distro_module> [<distro_module> ...]
#   key_function:   function name to check (e.g. "parse_setup_args" or "parse_cleanup_args")
#   distro_modules: specific distro modules to load (e.g. "dependencies containerd crio kubernetes")
run_local() {
    local key_function="$1"; shift
    local -a distro_modules=("$@")

    if type -t "$key_function" &>/dev/null; then
        return 0
    fi

    if [ "$_STDIN_MODE" = true ]; then
        echo "Error: Bundled mode via stdin requires embedded modules. Cannot safely source local files." >&2
        return 1
    fi
    echo "Local mode: functions not bundled, loading from $SCRIPT_DIR..." >&2
    local common_modules=("${_COMMON_MODULES[@]}")
    for module in "${common_modules[@]}"; do
        if [ -f "$SCRIPT_DIR/common/${module}.sh" ]; then
            source "$SCRIPT_DIR/common/${module}.sh"
        else
            echo "Error: Required module not found: common/${module}.sh" >&2
            return 1
        fi
    done
    detect_distribution
    for module in "${distro_modules[@]}"; do
        if [ -f "$SCRIPT_DIR/distros/$DISTRO_FAMILY/${module}.sh" ]; then
            source "$SCRIPT_DIR/distros/$DISTRO_FAMILY/${module}.sh"
        else
            echo "Error: Required module not found: distros/$DISTRO_FAMILY/${module}.sh" >&2
            return 1
        fi
    done
    return 0
}

# Download all project modules to a temporary directory (for deploy in curl|bash mode).
# Creates the same directory structure as a local checkout so _generate_bundle_core works.
# Sets DEPLOY_MODULES_DIR to the temp directory path.
# Usage: load_deploy_modules
load_deploy_modules() {
    echo "Downloading all modules for deploy bundle..." >&2

    DEPLOY_MODULES_DIR=$(mktemp -d -t setup-k8s-deploy-modules-XXXXXX)
    _append_exit_trap "$DEPLOY_MODULES_DIR"

    mkdir -p "$DEPLOY_MODULES_DIR/common"

    # Download common modules (bootstrap + all runtime modules)
    local all_common=("bootstrap" "${_COMMON_MODULES[@]}")
    for module in "${all_common[@]}"; do
        echo "  - common/${module}.sh" >&2
        if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/${module}.sh" > "$DEPLOY_MODULES_DIR/common/${module}.sh"; then
            echo "Error: Failed to download common/${module}.sh" >&2
            return 1
        fi
    done

    # Download deploy and upgrade modules separately (not in _COMMON_MODULES)
    for extra_module in deploy upgrade; do
        echo "  - common/${extra_module}.sh" >&2
        if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/common/${extra_module}.sh" > "$DEPLOY_MODULES_DIR/common/${extra_module}.sh"; then
            echo "Error: Failed to download common/${extra_module}.sh" >&2
            return 1
        fi
    done

    # Download distro modules (cleanup excluded — not needed for deploy bundle)
    for family in "${_DISTRO_FAMILIES[@]}"; do
        mkdir -p "$DEPLOY_MODULES_DIR/distros/$family"
        for module in "${_DISTRO_MODULES[@]}"; do
            [ "$module" = "cleanup" ] && continue
            echo "  - distros/${family}/${module}.sh" >&2
            if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/distros/${family}/${module}.sh" > "$DEPLOY_MODULES_DIR/distros/${family}/${module}.sh"; then
                echo "Error: Failed to download distros/${family}/${module}.sh" >&2
                return 1
            fi
        done
    done

    # Download entry script (only setup-k8s.sh needed for deploy bundle)
    echo "  - setup-k8s.sh" >&2
    if ! curl -fsSL --retry 3 --retry-delay 2 "${GITHUB_BASE_URL}/setup-k8s.sh" > "$DEPLOY_MODULES_DIR/setup-k8s.sh"; then
        echo "Error: Failed to download setup-k8s.sh" >&2
        return 1
    fi

    # Validate all downloaded shell modules
    for module in "${all_common[@]}"; do
        _validate_shell_module "$DEPLOY_MODULES_DIR/common/${module}.sh" || return 1
    done
    _validate_shell_module "$DEPLOY_MODULES_DIR/common/deploy.sh" || return 1
    _validate_shell_module "$DEPLOY_MODULES_DIR/common/upgrade.sh" || return 1
    for family in "${_DISTRO_FAMILIES[@]}"; do
        for module in "${_DISTRO_MODULES[@]}"; do
            [ "$module" = "cleanup" ] && continue
            _validate_shell_module "$DEPLOY_MODULES_DIR/distros/${family}/${module}.sh" || return 1
        done
    done
    _validate_shell_module "$DEPLOY_MODULES_DIR/setup-k8s.sh" || return 1

    echo "All modules downloaded and validated" >&2
}

# Generate a self-contained bundle script for standalone execution.
# Usage: _generate_bundle_core <bundle_path> <entry_script> [include_mode] [script_dir]
#   bundle_path:   output file path
#   entry_script:  path to the entry script (setup-k8s.sh or cleanup-k8s.sh)
#   include_mode:  "all" (default), "cleanup" (cleanup modules only)
#   script_dir:    project root (default: derived from entry_script location)
_generate_bundle_core() {
    local bundle_path="$1"
    local entry_script="$2"
    local include_mode="${3:-all}"
    local script_dir="${4:-$(cd "$(dirname "$entry_script")" && pwd)}"

    {
        echo "#!/bin/bash"
        echo "set -euo pipefail"
        echo "BUNDLED_MODE=true"
        echo ""

        # Include all common modules
        # shellcheck disable=SC2086  # intentional word splitting on space-separated list
        for module in $BUNDLE_COMMON_MODULES; do
            if [ -f "$script_dir/common/${module}.sh" ]; then
                echo "# === common/${module}.sh ==="
                cat "$script_dir/common/${module}.sh"
                echo ""
            fi
        done

        # Include distro modules
        for distro_dir in "$script_dir/distros/"*/; do
            [ -d "$distro_dir" ] || continue
            local distro_name
            distro_name=$(basename "$distro_dir")
            if [ "$include_mode" = "cleanup" ]; then
                if [ -f "$distro_dir/cleanup.sh" ]; then
                    echo "# === distros/${distro_name}/cleanup.sh ==="
                    awk '!/^source.*SCRIPT_DIR/ && !/^SCRIPT_DIR=/' "$distro_dir/cleanup.sh"
                    echo ""
                fi
            else
                echo "# === distros/${distro_name} modules ==="
                for module_file in "$distro_dir"*.sh; do
                    if [ -f "$module_file" ]; then
                        echo "# === $(basename "$module_file") ==="
                        awk '!/^source.*SCRIPT_DIR/ && !/^SCRIPT_DIR=/' "$module_file"
                        echo ""
                    fi
                done
            fi
        done

        # Include entry script (without shebang)
        echo "# === Main $(basename "$entry_script") ==="
        tail -n +2 "$entry_script"
    } > "$bundle_path"

    chmod +x "$bundle_path"
}
