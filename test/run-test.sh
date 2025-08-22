#!/bin/bash
#
# K8s Multi-Distribution Test Runner
# Usage: ./run-test.sh <distro-name>
#

set -e

# 定数定義
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/distro-urls.conf"
CLOUD_INIT_TEMPLATE="$SCRIPT_DIR/cloud-init-template.yaml"
SETUP_K8S_SCRIPT="$SCRIPT_DIR/../hack/setup-k8s.sh"

# タイムアウト設定（秒）
TIMEOUT_TOTAL=1200    # 20分
TIMEOUT_DOWNLOAD=600  # 10分
TIMEOUT_QEMU_START=60 # 1分

# 色付きログ用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ログ関数
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# ヘルプメッセージ
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

# 設定読み込み関数
load_config() {
    local distro=$1
    
    # イメージURL取得
    IMAGE_URL=$(grep "^${distro}=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
    if [ -z "$IMAGE_URL" ]; then
        log_error "Unknown distribution: $distro"
        echo "Available distributions:"
        grep -E '^[^#].*=.*' "$CONFIG_FILE" | grep -v '_user=' | sed 's/=.*//' | sort
        return 1
    fi
    
    # ログインユーザー取得
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

# コンテナ起動確認・起動
ensure_container_running() {
    log_info "Checking QEMU container status..."
    
    # コンテナが起動しているかチェック
    if docker ps --format "{{.Names}}" | grep -q "k8s-qemu-tools"; then
        log_info "QEMU container is already running"
    else
        log_info "Starting QEMU container..."
        cd "$SCRIPT_DIR"
        docker-compose up -d qemu-tools
        
        # 起動完了待機
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

# イメージダウンロード
download_image() {
    local distro=$1
    local image_url=$2
    local image_file="images/${distro}.qcow2"
    
    log_info "Checking cloud image: $image_file"
    
    # 既存イメージの確認
    if [ -f "$image_file" ]; then
        local file_size=$(stat -c%s "$image_file" 2>/dev/null || echo "0")
        if [ "$file_size" -gt 104857600 ]; then  # 100MB以上
            log_info "Using cached image: $image_file ($((file_size/1024/1024))MB)"
            return 0
        else
            log_warn "Cached image too small, re-downloading..."
            rm -f "$image_file"
        fi
    fi
    
    # ディレクトリ作成
    mkdir -p "$(dirname "$image_file")"
    
    # ダウンロード実行
    log_info "Downloading cloud image: $image_url"
    log_info "This may take several minutes..."
    
    cd "$SCRIPT_DIR"
    if timeout "$TIMEOUT_DOWNLOAD" docker-compose exec -T qemu-tools \
        wget --progress=dot:giga -O "/shared/$image_file" "$image_url" 2>&1; then
        log_success "Image downloaded successfully: $image_file"
        
        # ファイルサイズ確認
        local downloaded_size=$(stat -c%s "$image_file" 2>/dev/null || echo "0")
        log_info "Downloaded size: $((downloaded_size/1024/1024))MB"
        
        return 0
    else
        log_error "Failed to download image"
        rm -f "$image_file"
        return 1
    fi
}

# cloud-init設定生成
generate_cloud_init() {
    local distro=$1
    local login_user=$2
    local temp_dir="cloud-init-temp"
    
    log_info "Generating cloud-init configuration..."
    
    # 共有ディレクトリ内に一時ディレクトリ作成
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    
    # setup-k8s.sh内容をBase64エンコード
    if [ ! -f "$SETUP_K8S_SCRIPT" ]; then
        log_error "setup-k8s.sh not found: $SETUP_K8S_SCRIPT"
        return 1
    fi
    
    local setup_k8s_b64=$(base64 -w 0 < "$SETUP_K8S_SCRIPT")
    
    # cloud-initテンプレート処理
    sed -e "s/{{LOGIN_USER}}/$login_user/g" \
        -e "s/{{SETUP_K8S_CONTENT}}/$setup_k8s_b64/g" \
        "$CLOUD_INIT_TEMPLATE" > "$temp_dir/user-data"
    
    # meta-data生成
    cat > "$temp_dir/meta-data" <<EOF
instance-id: k8s-test-${distro}-$(date +%s)
local-hostname: k8s-test-${distro}
EOF
    
    # seed.iso生成（コンテナ内で実行、/shared経由でアクセス）
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

# テスト結果解析
parse_test_output() {
    local line="$1"
    
    # JSONテスト結果検出
    if [[ "$line" == *"=== K8S_TEST_RESULT_JSON_START ==="* ]]; then
        JSON_CAPTURE=true
        JSON_CONTENT=""
        return
    fi
    
    if [[ "$line" == *"=== K8S_TEST_RESULT_JSON_END ==="* ]]; then
        JSON_CAPTURE=false
        
        # JSON解析・結果保存
        if [ -n "$JSON_CONTENT" ]; then
            echo "$JSON_CONTENT" > results/test-result.json
            log_info "Test result captured"
        fi
        return
    fi
    
    # JSON内容蓄積
    if [ "$JSON_CAPTURE" = true ]; then
        JSON_CONTENT="${JSON_CONTENT}${line}\n"
        return
    fi
    
    # その他のマーカー検出
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

# QEMU実行・監視
run_qemu_test() {
    local distro=$1
    local image_file="images/${distro}.qcow2"
    local log_file="results/logs/${distro}-$(date +%Y%m%d-%H%M%S).log"
    
    log_info "Starting QEMU VM test for: $distro"
    
    # 既存のQEMUプロセスをクリーンアップ
    log_info "Cleaning up existing QEMU processes..."
    docker-compose exec -T qemu-tools pkill -9 qemu-system-x86_64 2>/dev/null || true
    sleep 2
    
    # 結果・ログディレクトリ作成
    mkdir -p results/logs
    rm -f results/test-result.json
    
    # テスト用イメージの作成（オリジナルを拡張してコピー）
    local test_image="images/${distro}-test.qcow2"
    log_info "Creating test image with expanded size..."
    docker-compose exec -T qemu-tools bash -c "
        cp /shared/$image_file /shared/$test_image
        qemu-img resize /shared/$test_image 10G
    " || {
        log_error "Failed to create test image"
        return 1
    }
    
    # QEMUコマンド構築
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
    
    # 監視変数初期化
    TEST_STARTED=false
    TEST_COMPLETED=false
    JSON_CAPTURE=false
    JSON_CONTENT=""
    
    # クリーンアップ用のtrap設定
    cleanup_qemu() {
        log_info "Cleaning up QEMU process..."
        docker-compose exec -T qemu-tools pkill -9 qemu-system-x86_64 2>/dev/null || true
    }
    trap cleanup_qemu EXIT INT TERM
    
    # QEMU起動・出力監視
    local start_time=$(date +%s)
    cd "$SCRIPT_DIR"
    
    # QEMUをバックグラウンドで起動し、PIDを保存
    docker-compose exec -T qemu-tools bash -c "$qemu_cmd" 2>&1 | \
    while IFS= read -r line; do
        # ログファイルに記録
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line" | tee -a "$log_file"
        
        # テスト結果解析
        parse_test_output "$line"
        
        # タイムアウトチェック
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $TIMEOUT_TOTAL ]; then
            log_error "Test timeout after ${TIMEOUT_TOTAL}s"
            break
        fi
        
        # テスト完了チェック
        if [ "$TEST_COMPLETED" = true ] && [ -f "results/test-result.json" ]; then
            log_success "Test execution completed"
            break
        fi
    done
    
    # QEMUプロセスを確実に終了
    log_info "Terminating QEMU process..."
    docker-compose exec -T qemu-tools pkill -9 qemu-system-x86_64 2>/dev/null || true
    
    # テスト用イメージを削除
    log_info "Cleaning up test image..."
    rm -f "images/${distro}-test.qcow2"
    
    # trapを解除
    trap - EXIT INT TERM
    
    return 0
}

# テスト結果表示
show_test_results() {
    local distro=$1
    
    if [ ! -f "results/test-result.json" ]; then
        log_error "Test result not found"
        return 1
    fi
    
    log_info "Test Results for $distro:"
    echo "=================="
    
    # JSON内容を読み取り・表示
    local status=$(grep -o '"status": *"[^"]*"' results/test-result.json | cut -d'"' -f4)
    local exit_code=$(grep -o '"setup_exit_code": *[0-9]*' results/test-result.json | grep -o '[0-9]*')
    local kubelet_status=$(grep -o '"kubelet_status": *"[^"]*"' results/test-result.json | cut -d'"' -f4)
    local api_responsive=$(grep -o '"api_responsive": *"[^"]*"' results/test-result.json | cut -d'"' -f4)
    
    echo "Status: $status"
    echo "Setup Exit Code: $exit_code"
    echo "Kubelet Status: $kubelet_status"
    echo "API Responsive: $api_responsive"
    echo "=================="
    
    # 結果判定
    if [ "$status" = "success" ] && [ "$exit_code" = "0" ]; then
        log_success "✅ Test PASSED for $distro"
        return 0
    else
        log_error "❌ Test FAILED for $distro"
        return 1
    fi
}

# メイン処理
main() {
    local distro=$1
    
    # 引数チェック
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
    
    # 各ステップ実行
    load_config "$distro" || exit 1
    ensure_container_running || exit 1
    download_image "$distro" "$IMAGE_URL" || exit 1
    generate_cloud_init "$distro" "$LOGIN_USER" || exit 1
    run_qemu_test "$distro" || exit 1
    
    # 結果表示・終了コード設定
    if show_test_results "$distro"; then
        exit 0
    else
        exit 1
    fi
}

# スクリプト実行
main "$@"