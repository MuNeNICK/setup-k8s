#!/bin/sh
# Unit tests for lib/completion.sh

# File-local module loader
_load_completion_test_modules() {
    . "$PROJECT_ROOT/lib/variables.sh"
    log_error() { :; }; log_warn() { :; }; log_info() { :; }; log_debug() { :; }
    . "$PROJECT_ROOT/lib/completion.sh"
}

# ============================================================
# Test: completion.sh functions defined
# ============================================================
test_completion_functions_defined() {
    echo "=== Test: completion.sh functions defined ==="
    (
        _load_completion_test_modules

        local has_detect_shell="false"
        type detect_user_shell >/dev/null 2>&1 && has_detect_shell="true"
        _assert_eq "detect_user_shell defined" "true" "$has_detect_shell"

        local has_setup="false"
        type setup_kubernetes_completions >/dev/null 2>&1 && has_setup="true"
        _assert_eq "setup_kubernetes_completions defined" "true" "$has_setup"

        local has_cleanup="false"
        type cleanup_kubernetes_completions >/dev/null 2>&1 && has_cleanup="true"
        _assert_eq "cleanup_kubernetes_completions defined" "true" "$has_cleanup"

        local has_k8s_comps="false"
        type setup_k8s_shell_completion >/dev/null 2>&1 && has_k8s_comps="true"
        _assert_eq "setup_k8s_shell_completion defined" "true" "$has_k8s_comps"
    )
}
