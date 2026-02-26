#!/bin/sh
# Unit tests for lib/diagnostics.sh

# File-local module loader
_load_diagnostics_test_modules() {
    source "$PROJECT_ROOT/lib/bootstrap.sh"
    source "$PROJECT_ROOT/lib/variables.sh"
    source "$PROJECT_ROOT/lib/logging.sh"
    source "$PROJECT_ROOT/lib/diagnostics.sh"
}

# ============================================================
# Test: diagnostics functions exist
# ============================================================
test_diagnostics_functions() {
    echo "=== Test: diagnostics functions exist ==="
    (
        _load_diagnostics_test_modules

        local has_remote="false"
        type _collect_diagnostics >/dev/null 2>&1 && has_remote="true"
        _assert_eq "_collect_diagnostics defined" "true" "$has_remote"

        local has_local="false"
        type _collect_local_diagnostics >/dev/null 2>&1 && has_local="true"
        _assert_eq "_collect_local_diagnostics defined" "true" "$has_local"
    )
}
