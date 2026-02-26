#!/bin/bash
#
# HA test dispatcher: routes to init or failover test based on --failover flag.
# Usage: ./test/run-ha-test.sh [--failover] [options...]
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILOVER=false
for arg in "$@"; do [ "$arg" = "--failover" ] && FAILOVER=true; done

if [ "$FAILOVER" = true ]; then
    exec bash "$SCRIPT_DIR/run-ha-failover-test.sh" "$@"
else
    exec bash "$SCRIPT_DIR/run-ha-init-test.sh" "$@"
fi
