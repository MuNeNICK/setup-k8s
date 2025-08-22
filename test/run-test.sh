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
SETUP_K8S_SCRIPT="$SCRIPT_DIR/../hack/setup-k8s.sh"

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

Usage: $0 <distro-name>

Supported distributions:
EOF
    grep -E '^[^#].*=.*' "$CONFIG_FILE" | grep -v '_user=' | sed 's/=.*//' | sort | while read distro; do
        echo "  - $distro"
    done
    echo
    echo "Examples:"
    echo "  $0 ubuntu-2404"
    echo "  $0 debian-12" 
    echo "  $0 centos-stream-9"
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
    if [ $? -eq 0 ]; then
        log_success "Image downloaded successfully: $image_file"
        
        # Check file size
        local downloaded_size=$(stat -c%s "$image_file" 2>/dev/null || echo "0")
        log_info "Downloaded size: $((downloaded_size/1024/1024))MB"
        
        return 0
    else
        log_error "Failed to download image"
        rm -f "$image_file"
        return 1
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
    
    # Base64 encode setup-k8s.sh content
    if [ ! -f "$SETUP_K8S_SCRIPT" ]; then
        log_error "setup-k8s.sh not found: $SETUP_K8S_SCRIPT"
        return 1
    fi
    
    local setup_k8s_b64=$(base64 -w 0 < "$SETUP_K8S_SCRIPT")
    
    # Process cloud-init template
    sed -e "s/{{LOGIN_USER}}/$login_user/g" \
        -e "s/{{SETUP_K8S_CONTENT}}/$setup_k8s_b64/g" \
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
            TEST_START_TIME=$(echo "$line" | grep -o '[0-9T:-]*')
            log_info "Test started at: $TEST_START_TIME"
            ;;
        *"K8S_TEST_COMPLETED:"*)
            TEST_COMPLETED=true
            TEST_END_TIME=$(echo "$line" | grep -o '[0-9T:-]*')
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
    local qemu_cmd="qemu-system-x86_64 \
        -machine pc,accel=kvm:tcg \
        -m 4096 \
        -smp 2 \
        -nographic \
        -serial mon:stdio \
        -drive file=/shared/$test_image,if=virtio \
        -drive file=/shared/seed.iso,if=virtio,media=cdrom \
        -netdev user,id=net0 \
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
    
    # Read and display JSON content
    local status=$(grep -o '"status": *"[^"]*"' results/test-result.json | cut -d'"' -f4)
    local exit_code=$(grep -o '"setup_exit_code": *[0-9]*' results/test-result.json | grep -o '[0-9]*')
    local kubelet_status=$(grep -o '"kubelet_status": *"[^"]*"' results/test-result.json | cut -d'"' -f4)
    local api_responsive=$(grep -o '"api_responsive": *"[^"]*"' results/test-result.json | cut -d'"' -f4)
    
    echo "Status: $status"
    echo "Setup Exit Code: $exit_code"
    echo "Kubelet Status: $kubelet_status"
    echo "API Responsive: $api_responsive"
    echo "=================="
    
    # Determine results
    if [ "$status" = "success" ] && [ "$exit_code" = "0" ]; then
        log_success "✅ Test PASSED for $distro"
        return 0
    else
        log_error "❌ Test FAILED for $distro"
        return 1
    fi
}

# Main process
main() {
    local distro=$1
    
    # Check arguments
    if [ -z "$distro" ]; then
        log_error "Distribution name required"
        show_help
        exit 1
    fi
    
    if [ "$distro" = "--help" ] || [ "$distro" = "-h" ]; then
        show_help
        exit 0
    fi
    
    log_info "Starting K8s test for: $distro"
    log_info "Working directory: $SCRIPT_DIR"
    
    # Execute each step
    load_config "$distro" || exit 1
    ensure_container_running || exit 1
    download_image "$distro" "$IMAGE_URL" || exit 1
    generate_cloud_init "$distro" "$LOGIN_USER" || exit 1
    run_qemu_test "$distro" || exit 1
    
    # Display results and set exit code
    if show_test_results "$distro"; then
        exit 0
    else
        exit 1
    fi
}

# Execute script
main "$@"