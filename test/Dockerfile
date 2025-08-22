FROM ubuntu:22.04

# 非対話モードでapt実行
ENV DEBIAN_FRONTEND=noninteractive

# QEMUとcloud-utilsのみインストール
RUN apt-get update && apt-get install -y \
    qemu-kvm \
    qemu-utils \
    genisoimage \
    wget \
    curl \
    telnet \
    netcat \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# 共有ディレクトリ作成
RUN mkdir -p /shared/images /shared/results

# 作業ディレクトリ設定
WORKDIR /shared

# コンテナを待機状態で維持
CMD ["tail", "-f", "/dev/null"]