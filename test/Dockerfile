FROM ubuntu:22.04

# Run apt in non-interactive mode
ENV DEBIAN_FRONTEND=noninteractive

# Install only QEMU and cloud-utils
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

# Create shared directories
RUN mkdir -p /shared/images /shared/results

# Set working directory
WORKDIR /shared

# Keep container running in wait state
CMD ["tail", "-f", "/dev/null"]