#!/bin/bash

# Logging module with log level control
# LOG_LEVEL: 0=quiet (errors only), 1=normal (default), 2=verbose (debug)

log_error() {
    echo "ERROR: $*" >&2
}

log_warn() {
    if [ "${LOG_LEVEL:-1}" -ge 1 ]; then
        echo "WARNING: $*" >&2
    fi
}

log_info() {
    if [ "${LOG_LEVEL:-1}" -ge 1 ]; then
        echo "$*" >&2
    fi
}

log_debug() {
    if [ "${LOG_LEVEL:-1}" -ge 2 ]; then
        echo "DEBUG: $*" >&2
    fi
}
