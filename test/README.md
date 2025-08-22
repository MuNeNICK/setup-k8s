# K8s Multi-Distribution Test Suite

複数のLinuxディストリビューションで`setup-k8s.sh`スクリプトの動作を自動テストするためのDocker + QEMU テストフレームワーク。

## 特徴

- **シンプル**: 1コマンドでテスト実行完了
- **環境汚染なし**: ホストにQEMU/cloud-utilsインストール不要
- **完全自動化**: VM起動からK8sセットアップ、結果収集まで無人実行
- **8ディストリビューション対応**: Ubuntu、Debian、CentOS、Fedora、openSUSE、Rocky、AlmaLinux
- **確実な結果判定**: setup-k8s.sh実行、kubelet起動、API応答まで確認

## 対応ディストリビューション

| Distribution | Version | Login User |
|-------------|---------|------------|
| ubuntu-2404 | 24.04 LTS | ubuntu |
| ubuntu-2204 | 22.04 LTS | ubuntu |
| debian-12 | 12 (Bookworm) | debian |
| centos-stream-9 | Stream 9 | centos |
| fedora-41 | 41 | fedora |
| opensuse-leap-155 | Leap 15.5 | opensuse |
| rocky-linux-9 | 9 | rocky |
| almalinux-9 | 9 | almalinux |

## システム要件

- Linux ホスト（Ubuntu 20.04+推奨）
- Docker Engine 20.10+
- `/dev/kvm` アクセス権限（KVM仮想化用）
- 最低 8GB RAM、10GB ディスク空き容量

## クイックスタート

### 1. 前提条件確認

```bash
# Dockerインストール確認
docker --version

# KVM利用可能性確認
kvm-ok

# /dev/kvm権限確認
ls -la /dev/kvm

# 必要に応じてkvmグループに追加
sudo usermod -aG kvm $USER
# （再ログイン必要）
```

### 2. テスト実行

```bash
# プロジェクトディレクトリに移動
cd setup-k8s/test

# 特定ディストリビューションでテスト
./run-test.sh ubuntu-2404

# 他のディストリビューション例
./run-test.sh debian-12
./run-test.sh centos-stream-9
```

### 3. 結果確認

テスト完了後、以下の形式で結果が表示されます：

```
✅ Test PASSED for ubuntu-2404
Status: success
Setup Exit Code: 0
Kubelet Status: active
API Responsive: true
```

## 使用方法詳細

### 基本コマンド

```bash
# ヘルプ表示
./run-test.sh --help

# サポート対象ディストリビューション一覧
./run-test.sh --help

# 特定ディストリビューションテスト
./run-test.sh <distro-name>
```

### ログの確認

```bash
# 実行ログ確認
ls -la results/logs/
tail -f results/logs/ubuntu-2404-20250101-120000.log

# JSON結果確認
cat results/test-result.json
```

### トラブルシューティング

```bash
# コンテナ状態確認
docker-compose ps

# コンテナ内確認
docker-compose exec qemu-tools bash

# 手動コンテナ再起動
docker-compose down
docker-compose up -d qemu-tools
```

## 内部動作フロー

1. **設定読み込み**: `distro-urls.conf`から対象ディストリビューション設定取得
2. **コンテナ起動**: QEMUツールコンテナを自動起動（必要時のみ）
3. **イメージ取得**: クラウドイメージをダウンロード・キャッシュ
4. **cloud-init準備**: 汎用テンプレートにsetup-k8s.shを埋め込み
5. **QEMU起動**: VM起動、シリアルコンソール出力監視開始
6. **テスト実行**: VM内でsetup-k8s.sh自動実行
7. **結果収集**: kubelet状態、API応答確認
8. **結果保存**: JSON形式で結果保存、ログファイル出力

## ファイル構成

```
test/
├── run-test.sh              # メイン実行スクリプト
├── distro-urls.conf         # ディストリビューション設定
├── cloud-init-template.yaml # 汎用cloud-initテンプレート
├── docker-compose.yml       # QEMUコンテナ定義
├── Dockerfile              # QEMU環境イメージ
├── images/                 # クラウドイメージキャッシュ
└── results/                # テスト結果・ログ
    ├── logs/              # 実行ログ
    └── test-result.json   # 最新テスト結果
```

## カスタマイズ

### New distribution追加

`distro-urls.conf`に以下形式で追加：

```bash
# New distribution
newdistro-1.0=https://example.com/newdistro-1.0-cloud.qcow2
newdistro-1.0_user=newuser
```

### タイムアウト調整

`run-test.sh`内の定数を変更：

```bash
TIMEOUT_TOTAL=1800    # 30分に延長
TIMEOUT_DOWNLOAD=900  # 15分に延長
```

### QEMU設定調整

`run-test.sh`内のQEMUコマンドを変更：

```bash
# メモリ増量例
-m 8192 \  # 8GB RAM
```

## よくある問題

### KVMアクセスエラー
```bash
# /dev/kvm権限設定
sudo chmod 666 /dev/kvm
```

### ダウンロード失敗
```bash
# キャッシュクリア
rm -f images/*.qcow2
```

### VM起動失敗
```bash
# コンテナ再起動
docker-compose restart qemu-tools
```

### テストタイムアウト
- ネットワーク速度の確認
- タイムアウト値の調整
- システムリソース（RAM/CPU）の確認

## 開発・拡張

### デバッグモード

```bash
# 詳細ログ出力
BASH_DEBUG=1 ./run-test.sh ubuntu-2404

# 手動VM起動
docker-compose exec qemu-tools bash
qemu-system-x86_64 -machine pc,accel=kvm ...
```

### 結果形式

テスト結果は以下のJSON形式で出力されます：

```json
{
  "status": "success|failed",
  "setup_exit_code": 0,
  "kubelet_status": "active|inactive", 
  "kubeconfig_exists": "true|false",
  "api_responsive": "true|false",
  "timestamp": "2025-01-01T12:00:00Z"
}
```

## ライセンス

このプロジェクトは元の`setup-k8s`プロジェクトと同じライセンスに従います。