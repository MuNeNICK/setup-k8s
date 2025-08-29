#!/bin/bash
#
# K8s Multi-Distribution Test Runner
# Usage: ./run-test.sh <distro-name>
#

set -e

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/distro-urls.conf"
CLOUD_INIT_TEMPLATE="$SCRIPT_DIR/cloud-init-template.yaml"
SETUP_K8S_SCRIPT="$SCRIPT_DIR/../setup-k8s.sh"
CLEANUP_K8S_SCRIPT="$SCRIPT_DIR/../cleanup-k8s.sh"

# K8s version (can be overridden by command line option)
K8S_VERSION=""
# Extra args to pass to setup-k8s.sh
SETUP_EXTRA_ARGS=()
# Test mode (offline or online)
TEST_MODE="offline"

# Timeout settings (seconds)
TIMEOUT_TOTAL=1200    # 20 minutes
TIMEOUT_DOWNLOAD=600  # 10 minutes
TIMEOUT_QEMU_START=60 # 1 minute

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# Help message
show_help() {
    cat <<EOF
K8s Multi-Distribution Test Runner

Usage: $0 [OPTIONS] <distro-name>

Options:
  --all, -a                Test all distributions sequentially
  --k8s-version <version>   Kubernetes version to test (e.g., 1.32, 1.31, 1.30)
  --setup-args ARGS         Extra args for setup-k8s.sh (use quotes)
  --online                  Run test in online mode (fetch script from GitHub)
  --offline                 Run test in offline mode with bundled scripts (default)
  --                        Treat the rest as setup-args
  --help, -h                Show this help message

Supported distributions:
EOF
    grep -E '^[^#].*=.*' "$CONFIG_FILE" | grep -v '_user=' | sed 's/=.*//' | sort | while read distro; do
        echo "  - $distro"
    done
    echo
    echo "Examples:"
    echo "  $0 ubuntu-2404                        # Test single distribution offline (bundled)"
    echo "  $0 --online ubuntu-2404               # Test single distribution online (GitHub)"
    echo "  $0 --k8s-version 1.31 ubuntu-2404     # Test with specific k8s version"
    echo "  $0 --all                              # Test all distributions offline"
    echo "  $0 --all --online                     # Test all distributions online"
    echo "  $0 --all --k8s-version 1.30           # Test all distributions with k8s v1.30"
    echo "  $0 archlinux"
    echo "  $0 --k8s-version 1.32 rocky-linux-8"
    echo
    echo "Test Modes:"
    echo "  Online:  Downloads setup-k8s.sh from GitHub during test execution"
    echo "  Offline: Uses pre-bundled script with all modules included"
}

# Load configuration function
load_config() {
    local distro=$1
    
    # Get image URL
    IMAGE_URL=$(grep "^${distro}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
    if [ -z "$IMAGE_URL" ]; then
        log_error "Unknown distribution: $distro"
        echo "Available distributions:"
        grep -E '^[^#].*=.*' "$CONFIG_FILE" | grep -v '_user=' | sed 's/=.*//' | sort
        return 1
    fi
    
    # Get login user
    LOGIN_USER=$(grep "^${distro}_user=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
    if [ -z "$LOGIN_USER" ]; then
        log_error "Login user not found for: $distro"
        return 1
    fi
    
    log_info "Configuration loaded:"
    log_info "  Distribution: $distro"
    log_info "  Login user: $LOGIN_USER"
    log_info "  Image URL: $IMAGE_URL"
    
    return 0
}

# Check and start container
ensure_container_running() {
    log_info "Checking QEMU container status..."
    
    # Check if container is running
    if docker ps --format "{{.Names}}" | grep -q "k8s-qemu-tools"; then
        log_info "QEMU container is already running"
    else
        log_info "Starting QEMU container..."
        cd "$SCRIPT_DIR"
        docker-compose up -d qemu-tools
        
        # Wait for startup completion
        log_info "Waiting for container to be ready..."
        for i in {1..10}; do
            if docker-compose exec -T qemu-tools echo "Container ready" >/dev/null 2>&1; then
                log_success "QEMU container is ready"
                break
            fi
            sleep 2
        done
        
        if [ $i -eq 10 ]; then
            log_error "Container failed to start properly"
            return 1
        fi
    fi
    
    return 0
}

# Download image
download_image() {
    local distro=$1
    local image_url=$2
    local image_file="images/${distro}.qcow2"
    
    log_info "Checking cloud image: $image_file"
    
    # Check existing image
    if [ -f "$image_file" ]; then
        local file_size=$(stat -c%s "$image_file" 2>/dev/null || echo "0")
        if [ "$file_size" -gt 104857600 ]; then  # More than 100MB
            log_info "Using cached image: $image_file ($((file_size/1024/1024))MB)"
            return 0
        else
            log_warn "Cached image too small, re-downloading..."
            rm -f "$image_file"
        fi
    fi
    
    # Create directory
    mkdir -p "$(dirname "$image_file")"
    
    # Execute download
    log_info "Downloading cloud image: $image_url"
    log_info "This may take several minutes..."
    
    cd "$SCRIPT_DIR"
    
    # Start download in background and monitor progress
    docker-compose exec -T qemu-tools bash -c "
        wget --progress=bar:force:noscroll -O '/shared/$image_file' '$image_url' 2>&1 | \
        stdbuf -o0 -e0 sed 's/^/[DOWNLOAD] /'
    " &
    local download_pid=$!
    
    # Monitor download progress
    local monitor_count=0
    while kill -0 $download_pid 2>/dev/null; do
        if [ -f "$image_file" ]; then
            local current_size=$(stat -c%s "$image_file" 2>/dev/null || echo "0")
            if [ $((monitor_count % 5)) -eq 0 ] && [ "$current_size" -gt 0 ]; then
                log_info "Downloaded: $((current_size/1024/1024))MB"
            fi
        fi
        monitor_count=$((monitor_count + 1))
        sleep 1
    done
    
    # Check if download succeeded
    wait $download_pid
    local download_status=$?
    
    # Check file size
    local downloaded_size=$(stat -c%s "$image_file" 2>/dev/null || echo "0")
    
    if [ $download_status -eq 0 ] && [ "$downloaded_size" -gt 104857600 ]; then  # More than 100MB
        log_success "Image downloaded successfully: $image_file"
        log_info "Downloaded size: $((downloaded_size/1024/1024))MB"
        return 0
    else
        if [ $download_status -ne 0 ]; then
            log_error "wget failed with exit code: $download_status"
        elif [ "$downloaded_size" -eq 0 ]; then
            log_error "Downloaded file is empty (0 bytes). URL may be invalid."
        else
            log_error "Downloaded file too small: $((downloaded_size/1024/1024))MB"
        fi
        log_error "Failed to download image from: $image_url"
        rm -f "$image_file"
        return 1
    fi
}

# Generate bundled scripts for offline mode
generate_bundled_scripts() {
    local setup_bundle="/tmp/setup-k8s-bundle.sh"
    local cleanup_bundle="/tmp/cleanup-k8s-bundle.sh"
    
    log_info "Generating bundled scripts for cloud-init (mode: $TEST_MODE)..."
    
    # Only generate bundled scripts in offline mode
    if [ "$TEST_MODE" = "offline" ]; then
        # Generate setup bundle
        {
            echo "#!/bin/bash"
            echo "# Bundled setup-k8s.sh with all modules"
            echo "set -e"
            echo ""
            echo "# Force offline mode"
            echo "OFFLINE_MODE=true"
            echo ""
        
        # Include all common modules
        for module in variables detection validation helpers networking swap; do
            echo "# === common/${module}.sh ==="
            cat "${SCRIPT_DIR}/../common/${module}.sh"
            echo ""
        done
        
        # Include all distro modules (removing source lines that reference other modules)
        for distro_dir in "${SCRIPT_DIR}/../distros/"*/; do
            if [ -d "$distro_dir" ]; then
                distro_name=$(basename "$distro_dir")
                echo "# === distros/${distro_name} modules ==="
                for module_file in "$distro_dir"*.sh; do
                    if [ -f "$module_file" ]; then
                        echo "# === $(basename "$module_file") ==="
                        # Remove source lines and SCRIPT_DIR declarations since everything is bundled
                        grep -v '^source.*SCRIPT_DIR' "$module_file" | grep -v '^SCRIPT_DIR='
                        echo ""
                    fi
                done
            fi
        done
        
            # Include main setup script (without shebang)
            echo "# === Main setup-k8s.sh ==="
            tail -n +2 "$SETUP_K8S_SCRIPT"
        } > "$setup_bundle"
        
        # Generate cleanup bundle
        {
            echo "#!/bin/bash"
            echo "# Bundled cleanup-k8s.sh with all modules"
            echo "set -e"
            echo ""
            echo "# Force offline mode"
            echo "OFFLINE_MODE=true"
            echo ""
            
            # Include all common modules
            for module in variables detection validation helpers networking swap; do
                echo "# === common/${module}.sh ==="
                cat "${SCRIPT_DIR}/../common/${module}.sh"
                echo ""
            done
            
            # Include all distro cleanup modules (removing source lines that reference other modules)
            for distro_dir in "${SCRIPT_DIR}/../distros/"*/; do
                if [ -d "$distro_dir" ]; then
                    distro_name=$(basename "$distro_dir")
                    if [ -f "$distro_dir/cleanup.sh" ]; then
                        echo "# === distros/${distro_name}/cleanup.sh ==="
                        # Remove source lines and SCRIPT_DIR declarations since everything is bundled
                        grep -v '^source.*SCRIPT_DIR' "$distro_dir/cleanup.sh" | grep -v '^SCRIPT_DIR='
                        echo ""
                    fi
                fi
            done
            
            # Include main cleanup script (without shebang)
            echo "# === Main cleanup-k8s.sh ==="
            tail -n +2 "$CLEANUP_K8S_SCRIPT"
        } > "$cleanup_bundle"
        
        log_info "Bundled scripts generated successfully for offline mode"
    else
        # For online mode, create empty files or minimal scripts
        echo "#!/bin/bash" > "$setup_bundle"
        echo "echo 'Online mode - should use curl'" >> "$setup_bundle"
        echo "#!/bin/bash" > "$cleanup_bundle"
        echo "echo 'Online mode - should use curl'" >> "$cleanup_bundle"
        log_info "Placeholder scripts created for online mode"
    fi
}

# Generate cloud-init configuration
generate_cloud_init() {
    local distro=$1
    local login_user=$2
    local temp_dir="cloud-init-temp"
    
    log_info "Generating cloud-init configuration..."
    
    # Create temporary directory in shared directory
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    
    # Generate bundled scripts (for offline mode) or placeholders (for online mode)
    log_info "Generating scripts for $TEST_MODE mode..."
    generate_bundled_scripts
    local setup_bundle="/tmp/setup-k8s-bundle.sh"
    local cleanup_bundle="/tmp/cleanup-k8s-bundle.sh"
    
    if [ ! -f "$setup_bundle" ] || [ ! -f "$cleanup_bundle" ]; then
        log_error "Failed to generate bundled scripts"
        log_error "Setup bundle exists: $([ -f "$setup_bundle" ] && echo "yes" || echo "no")"
        log_error "Cleanup bundle exists: $([ -f "$cleanup_bundle" ] && echo "yes" || echo "no")"
        return 1
    fi
    
    # Base64 encode bundled scripts
    local setup_k8s_b64=$(base64 -w 0 < "$setup_bundle")
    local cleanup_k8s_b64=$(base64 -w 0 < "$cleanup_bundle")
    
    # Clean up bundle files
    rm -f "$setup_bundle" "$cleanup_bundle"
    
    # Prepare K8s version argument (resolve on host if not provided)
    local k8s_version_arg=""
    local setup_extra_args_str=""
    if [ -z "$K8S_VERSION" ]; then
        log_info "Resolving latest stable Kubernetes minor on host..."
        local stable_txt
        stable_txt=$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || true)
        if echo "$stable_txt" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
            K8S_VERSION=$(echo "$stable_txt" | sed -E 's/^v([0-9]+\.[0-9]+)\..*/\1/')
            log_success "Detected stable minor: $K8S_VERSION"
        else
            K8S_VERSION="1.32"
            log_warn "Failed to detect stable version; falling back to $K8S_VERSION"
        fi
    fi
    if [ -n "$K8S_VERSION" ]; then
        k8s_version_arg="--kubernetes-version $K8S_VERSION"
        log_info "Using Kubernetes version: $K8S_VERSION"
    else
        log_info "Using default Kubernetes version from setup-k8s.sh"
    fi

    # Join extra args with spaces, escape sed-sensitive chars minimally
    if [ ${#SETUP_EXTRA_ARGS[@]} -gt 0 ]; then
        setup_extra_args_str="${SETUP_EXTRA_ARGS[*]}"
        log_info "Passing extra setup args: $setup_extra_args_str"
    fi
    
    # Process cloud-init template (use a safe delimiter to avoid '/' conflicts)
    sed -e "s|{{LOGIN_USER}}|$login_user|g" \
        -e "s|{{SETUP_K8S_CONTENT}}|$setup_k8s_b64|g" \
        -e "s|{{CLEANUP_K8S_CONTENT}}|$cleanup_k8s_b64|g" \
        -e "s|{{K8S_VERSION_ARG}}|$k8s_version_arg|g" \
        -e "s|{{SETUP_EXTRA_ARGS}}|$setup_extra_args_str|g" \
        -e "s|{{TEST_MODE}}|$TEST_MODE|g" \
        "$CLOUD_INIT_TEMPLATE" > "$temp_dir/user-data"
    
    # Generate meta-data
    cat > "$temp_dir/meta-data" <<EOF
instance-id: k8s-test-${distro}-$(date +%s)
local-hostname: k8s-test-${distro}
EOF
    
    # Generate seed.iso (execute in container, access via /shared)
    log_info "Creating seed.iso..."
    cd "$SCRIPT_DIR"
    docker-compose exec -T qemu-tools genisoimage \
        -output "/shared/seed.iso" \
        -volid cidata \
        -joliet \
        -rock \
        "/shared/$temp_dir/user-data" \
        "/shared/$temp_dir/meta-data" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_success "cloud-init configuration generated: seed.iso"
        rm -rf "$temp_dir"
        return 0
    else
        log_error "Failed to generate seed.iso"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Parse test results
parse_test_output() {
    local line="$1"
    
    # Detect JSON test results
    if [[ "$line" == *"=== K8S_TEST_RESULT_JSON_START ==="* ]]; then
        JSON_CAPTURE=true
        JSON_CONTENT=""
        return
    fi
    
    if [[ "$line" == *"=== K8S_TEST_RESULT_JSON_END ==="* ]]; then
        JSON_CAPTURE=false
        
        # Parse JSON and save results
        if [ -n "$JSON_CONTENT" ]; then
            echo "$JSON_CONTENT" > results/test-result.json
            log_info "Test result captured"
        fi
        return
    fi
    
    # Accumulate JSON content
    if [ "$JSON_CAPTURE" = true ]; then
        JSON_CONTENT="${JSON_CONTENT}${line}\n"
        return
    fi
    
    # Detect other markers
    case "$line" in
        *"K8S_TEST_START:"*)
            TEST_STARTED=true
            TEST_START_TIME=$(echo "$line" | sed -n 's/.*K8S_TEST_START:\([0-9T:-]*\).*/\1/p')
            log_info "Test started at: $TEST_START_TIME"
            ;;
        *"K8S_TEST_COMPLETED:"*)
            TEST_COMPLETED=true
            TEST_END_TIME=$(echo "$line" | sed -n 's/.*K8S_TEST_COMPLETED:\([0-9T:-]*\).*/\1/p')
            log_info "Test completed at: $TEST_END_TIME"
            ;;
    esac
}

# Execute and monitor QEMU
run_qemu_test() {
    local distro=$1
    local image_file="images/${distro}.qcow2"
    local log_file="results/logs/${distro}-$(date +%Y%m%d-%H%M%S).log"
    
    log_info "Starting QEMU VM test for: $distro"
    
    # Clean up existing QEMU processes
    log_info "Cleaning up existing QEMU processes..."
    docker-compose exec -T qemu-tools pkill -9 qemu-system-x86_64 2>/dev/null || true
    sleep 2
    
    # Create results and log directories
    mkdir -p results/logs
    rm -f results/test-result.json
    
    # Create test image (expand and copy original)
    local test_image="images/${distro}-test.qcow2"
    log_info "Creating test image with expanded size..."
    docker-compose exec -T qemu-tools bash -c "
        cp /shared/$image_file /shared/$test_image
        qemu-img resize /shared/$test_image 10G
    " || {
        log_error "Failed to create test image"
        return 1
    }
    
    # Build QEMU command
    # Use Haswell CPU model (2013) for good compatibility and performance
    # Can be overridden with QEMU_CPU_MODEL environment variable
    local cpu_model="${QEMU_CPU_MODEL:-Haswell}"
    log_info "Using CPU model: $cpu_model"
    
    # Configure network with DNS
    local netdev_opts="user,id=net0,dns=8.8.8.8"
    
    local qemu_cmd="qemu-system-x86_64 \
        -machine pc,accel=kvm:tcg \
        -cpu $cpu_model \
        -m 4096 \
        -smp 2 \
        -nographic \
        -serial mon:stdio \
        -drive file=/shared/$test_image,if=virtio \
        -drive file=/shared/seed.iso,if=virtio,media=cdrom \
        -netdev $netdev_opts \
        -device virtio-net,netdev=net0"
    
    log_info "QEMU command: $qemu_cmd"
    log_info "Monitor output in: $log_file"
    
    # Initialize monitoring variables
    TEST_STARTED=false
    TEST_COMPLETED=false
    JSON_CAPTURE=false
    JSON_CONTENT=""
    
    # Set trap for cleanup
    cleanup_qemu() {
        log_info "Cleaning up QEMU process..."
        docker-compose exec -T qemu-tools pkill -9 qemu-system-x86_64 2>/dev/null || true
    }
    trap cleanup_qemu EXIT INT TERM
    
    # Start QEMU and monitor output
    local start_time=$(date +%s)
    cd "$SCRIPT_DIR"
    
    # Start QEMU in background and save PID
    docker-compose exec -T qemu-tools bash -c "$qemu_cmd" 2>&1 | \
    while IFS= read -r line; do
        # Record to log file
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line" | tee -a "$log_file"
        
        # Parse test results
        parse_test_output "$line"
        
        # Check timeout
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $TIMEOUT_TOTAL ]; then
            log_error "Test timeout after ${TIMEOUT_TOTAL}s"
            break
        fi
        
        # Check test completion
        if [ "$TEST_COMPLETED" = true ] && [ -f "results/test-result.json" ]; then
            log_success "Test execution completed"
            break
        fi
    done
    
    # Ensure QEMU process termination
    log_info "Terminating QEMU process..."
    docker-compose exec -T qemu-tools pkill -9 qemu-system-x86_64 2>/dev/null || true
    
    # Delete test image
    log_info "Cleaning up test image..."
    rm -f "images/${distro}-test.qcow2"
    
    # Remove trap
    trap - EXIT INT TERM
    
    return 0
}

# Show test results
show_test_results() {
    local distro=$1
    
    if [ ! -f "results/test-result.json" ]; then
        log_error "Test result not found"
        return 1
    fi
    
    log_info "Test Results for $distro:"
    echo "=================="
    
    # Read JSON content into variable for better parsing
    local json_content=$(cat results/test-result.json)
    
    # Parse overall status
    local overall_status=$(echo "$json_content" | grep -o '"status": *"[^"]*"' | head -1 | cut -d'"' -f4)
    
    # Setup test results - parse from the setup_test block
    echo "Setup Test:"
    local setup_block=$(echo "$json_content" | sed -n '/"setup_test":/,/^  }/p')
    local setup_status=$(echo "$setup_block" | grep '"status"' | head -1 | cut -d'"' -f4)
    local setup_exit_code=$(echo "$setup_block" | grep '"exit_code"' | grep -o '[0-9]*' | head -1)
    local kubelet_status=$(echo "$setup_block" | grep '"kubelet_status"' | cut -d'"' -f4)
    local api_responsive=$(echo "$setup_block" | grep '"api_responsive"' | sed 's/.*: *"\?\([^",]*\)"\?.*/\1/')
    
    echo "  Status: ${setup_status:-unknown}"
    echo "  Exit Code: ${setup_exit_code:-unknown}"
    echo "  Kubelet Status: ${kubelet_status:-unknown}"
    echo "  API Responsive: ${api_responsive:-unknown}"
    
    # Cleanup test results - parse from the cleanup_test block
    echo "Cleanup Test:"
    local cleanup_block=$(echo "$json_content" | sed -n '/"cleanup_test":/,/^  }/p')
    local cleanup_status=$(echo "$cleanup_block" | grep '"status"' | head -1 | cut -d'"' -f4)
    local cleanup_exit_code=$(echo "$cleanup_block" | grep '"exit_code"' | grep -o '[0-9]*' | head -1)
    local services_stopped=$(echo "$cleanup_block" | grep '"services_stopped"' | cut -d'"' -f4)
    local config_cleaned=$(echo "$cleanup_block" | grep '"config_cleaned"' | cut -d'"' -f4)
    local packages_removed=$(echo "$cleanup_block" | grep '"packages_removed"' | cut -d'"' -f4)
    
    echo "  Status: ${cleanup_status:-unknown}"
    echo "  Exit Code: ${cleanup_exit_code:-unknown}"
    echo "  Services Stopped: ${services_stopped:-unknown}"
    echo "  Config Cleaned: ${config_cleaned:-unknown}"
    echo "  Packages Removed: ${packages_removed:-unknown}"
    echo "=================="
    
    # Determine results
    if [ "$overall_status" = "success" ]; then
        log_success "✅ Test PASSED for $distro (both setup and cleanup succeeded)"
        return 0
    else
        if [ "$setup_status" != "success" ]; then
            log_error "❌ Setup test FAILED for $distro"
        fi
        if [ "$cleanup_status" != "success" ] && [ "$cleanup_status" != "skipped" ]; then
            log_error "❌ Cleanup test FAILED for $distro"
        fi
        log_error "❌ Test FAILED for $distro"
        return 1
    fi
}

# Test all distributions
test_all() {
    log_info "Starting test for all distributions"
    log_info "Test mode: $TEST_MODE"
    if [ "$TEST_MODE" = "online" ]; then
        log_info "Script source: GitHub (https://raw.github.com/MuNeNICK/setup-k8s/main/)"
    else
        log_info "Script source: Bundled (all modules included)"
    fi
    
    # Get all distributions from config
    local distros=($(grep -E '^[^#].*=.*' "$CONFIG_FILE" | grep -v '_user=' | sed 's/=.*//' | sort))
    local total=${#distros[@]}
    local passed=0
    local failed=0
    local current=0
    
    # Create summary log file
    local summary_file="results/test-all-summary-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p results
    
    echo "Testing $total distributions in $TEST_MODE mode" | tee "$summary_file"
    echo "===================" | tee -a "$summary_file"
    echo "Start time: $(date)" | tee -a "$summary_file"
    echo "" | tee -a "$summary_file"
    
    for distro in "${distros[@]}"; do
        current=$((current + 1))
        echo "" | tee -a "$summary_file"
        echo -e "${BLUE}[$current/$total] Testing: $distro${NC}" | tee -a "$summary_file"
        echo "-----------------------------------" | tee -a "$summary_file"
        
        local start_time=$(date +%s)
        
        if run_single_test "$distro"; then
            passed=$((passed + 1))
            local status="PASSED"
        else
            failed=$((failed + 1))
            local status="FAILED"
        fi
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        echo "$distro: $status (${duration}s)" | tee -a "$summary_file"
        
        # Add individual test result details to summary
        if [ -f "results/test-result.json" ]; then
            echo "  Details from test-result.json:" >> "$summary_file"
            # Extract setup and cleanup status
            local setup_status=$(grep -A5 '"setup_test"' results/test-result.json | grep '"status"' | head -1 | cut -d'"' -f4)
            local cleanup_status=$(grep -A5 '"cleanup_test"' results/test-result.json | grep '"status"' | head -1 | cut -d'"' -f4)
            echo "    Setup: $setup_status, Cleanup: $cleanup_status" >> "$summary_file"
        fi
    done
    
    # Summary
    echo "" | tee -a "$summary_file"
    echo -e "${BLUE}===== Test Summary =====${NC}" | tee -a "$summary_file"
    echo "Total: $total, Passed: $passed, Failed: $failed" | tee -a "$summary_file"
    echo "End time: $(date)" | tee -a "$summary_file"
    echo "" | tee -a "$summary_file"
    
    # List all individual log files
    echo "Individual test logs:" | tee -a "$summary_file"
    ls -la results/logs/*.log 2>/dev/null | tail -n +2 | awk '{print "  " $9}' | tee -a "$summary_file"
    
    echo "" | tee -a "$summary_file"
    echo "Summary saved to: $summary_file"
    
    if [ $failed -gt 0 ]; then
        log_error "Some tests failed. Check $summary_file and results/logs/ for details"
        return 1
    else
        log_success "All tests passed!"
        return 0
    fi
}

# Run single test
run_single_test() {
    local distro=$1
    
    log_info "Starting K8s test for: $distro"
    log_info "Test mode: $TEST_MODE"
    if [ "$TEST_MODE" = "online" ]; then
        log_info "Script source: GitHub (https://raw.github.com/MuNeNICK/setup-k8s/main/)"
    else
        log_info "Script source: Bundled (all modules included)"
    fi
    if [ -n "$K8S_VERSION" ]; then
        log_info "Kubernetes version: $K8S_VERSION"
    else
        log_info "Kubernetes version: default (from setup-k8s.sh)"
    fi
    log_info "Working directory: $SCRIPT_DIR"
    
    # Execute each step
    load_config "$distro" || return 1
    ensure_container_running || return 1
    download_image "$distro" "$IMAGE_URL" || return 1
    generate_cloud_init "$distro" "$LOGIN_USER" || return 1
    run_qemu_test "$distro" || return 1
    
    # Display results and return status
    if show_test_results "$distro"; then
        return 0
    else
        return 1
    fi
}

# Main process
main() {
    local run_all=false
    local distro=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --all|-a)
                run_all=true
                shift
                ;;
            --k8s-version)
                K8S_VERSION="$2"
                shift 2
                ;;
            --online)
                TEST_MODE="online"
                shift
                ;;
            --offline)
                TEST_MODE="offline"
                shift
                ;;
            --setup-args)
                # Split quoted string into array
                IFS=' ' read -r -a SETUP_EXTRA_ARGS <<< "$2"
                shift 2
                ;;
            --)
                shift
                # Everything after -- goes into SETUP_EXTRA_ARGS as-is
                while [[ $# -gt 0 ]]; do
                    SETUP_EXTRA_ARGS+=("$1")
                    shift
                done
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # This should be the distribution name
                distro=$1
                shift
                ;;
        esac
    done
    
    # Check if we should run all tests
    if [ "$run_all" = true ]; then
        test_all
        exit $?
    fi
    
    # Check arguments for single test
    if [ -z "$distro" ]; then
        log_error "Distribution name required"
        show_help
        exit 1
    fi
    
    # Run single test
    if run_single_test "$distro"; then
        exit 0
    else
        exit 1
    fi
}

# Execute script
main "$@"