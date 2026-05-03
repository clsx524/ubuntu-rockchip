FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install all required build dependencies
RUN apt-get update && \
    apt-get purge needrestart -y && \
    apt-get upgrade -y && \
    apt-get install -y \
    build-essential gcc-aarch64-linux-gnu bison \
    qemu-user-binfmt qemu-system-arm qemu-efi-aarch64 u-boot-tools binfmt-support \
    debootstrap flex libssl-dev bc rsync kmod cpio xz-utils fakeroot parted \
    udev dosfstools uuid-runtime git-lfs device-tree-compiler python3 \
    python-is-python3 fdisk debhelper python3-pyelftools python3-setuptools \
    python3-pkg-resources swig libfdt-dev libpython3-dev \
    dctrl-tools sudo wget curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Keep the container running or allow passing a command
CMD ["/bin/bash"]
