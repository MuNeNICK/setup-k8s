#!/bin/bash

# Source common helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../common/helpers.sh"

# Setup containerd for generic distributions
setup_containerd_generic() {
    echo "Warning: Using generic method to set up containerd."
    echo "This may not work correctly on your distribution."
    echo "Please install containerd manually if needed."
    
    # Try to configure containerd if it's installed
    if command -v containerd &> /dev/null; then
        configure_containerd_toml
        configure_crictl containerd
    else
        echo "containerd not found. Please install it manually."
    fi
}