#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/flavors/${FLAVOR}.sh"

if [[ -f ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz ]]; then
    exit 0
fi

pushd .

tmp_dir=$(mktemp -d)
cd "${tmp_dir}" || exit 1

# Clone the livecd rootfs fork
git clone https://github.com/Joshua-Riek/livecd-rootfs
cd livecd-rootfs || exit 1

# Install build deps
apt-get update
apt-get build-dep . -y

# Build the package
dpkg-buildpackage -us -uc

# Install the custom livecd rootfs package
apt-get install ../livecd-rootfs_*.deb --assume-yes --allow-downgrades --allow-change-held-packages
dpkg -i ../livecd-rootfs_*.deb
apt-mark hold livecd-rootfs

rm -rf "${tmp_dir}"

popd

mkdir -p live-build && cd live-build

# Query the system to locate livecd-rootfs auto script installation path
cp -r "$(dpkg -L livecd-rootfs | grep "auto$")" auto

# For questing: germinate seed server (ubuntu-archive-team.ubuntu.com) is
# unreliable for development releases. Patch auto/config to make the germinate
# call non-fatal, and pre-seed the output directory with stubs so add_task
# doesn't abort on missing files. Our packages come from package-lists, not seeds.
if [ "${SUITE}" == "questing" ] || [ "${SUITE}" == "resolute" ]; then
    python3 -c "
import re
with open('auto/config', 'r') as f:
    s = f.read()
s = re.sub(
    r'(\(cd config/germinate-output && germinate\b.*?\))',
    r'(\1 || true)',
    s, flags=re.DOTALL)
with open('auto/config', 'w') as f:
    f.write(s)
"

    # Patch auto/build: when PROJECT=ubuntu-cpc, it writes chroot/etc/cloud/build.info
    # but cloud-init is not installed so the directory doesn't exist. Add mkdir -p.
    python3 -c "
with open('auto/build', 'r') as f:
    s = f.read()
s = s.replace(
    'cat > chroot/etc/cloud/build.info',
    'mkdir -p chroot/etc/cloud; cat > chroot/etc/cloud/build.info'
)
with open('auto/build', 'w') as f:
    f.write(s)
"
    mkdir -p config/germinate-output
    cat > config/germinate-output/structure <<'EOF'
required:
minimal: required
standard: minimal required
server: minimal standard required
server-minimal: minimal required
server-live: server minimal standard required
server-ship: server minimal standard required
EOF
    for seed in required minimal standard server server-minimal server-live server-ship \
                cloud-image ubuntu-desktop ubuntu-desktop-minimal \
                ubuntu-desktop-minimal-default-languages ubuntu-desktop-default-languages \
                ubuntu-live desktop desktop-minimal; do
        : > "config/germinate-output/${seed}"
        : > "config/germinate-output/${seed}.snaps"
        printf "Task-Description: %s\nTask-Key: %s\n" "${seed}" "${seed}" \
            > "config/germinate-output/${seed}.seedtext"
    done
fi

trap - ERR
set +e

export ARCH=arm64
export IMAGEFORMAT=none
export IMAGE_TARGETS=none

# Populate the configuration directory for live build
lb config \
    --architecture arm64 \
    --bootstrap-qemu-arch arm64 \
    --bootstrap-qemu-static /usr/bin/qemu-aarch64-static \
    --archive-areas "main restricted universe multiverse" \
    --parent-archive-areas "main restricted universe multiverse" \
    --mirror-bootstrap "http://ports.ubuntu.com" \
    --parent-mirror-bootstrap "http://ports.ubuntu.com" \
    --mirror-chroot-security "http://ports.ubuntu.com" \
    --parent-mirror-chroot-security "http://ports.ubuntu.com" \
    --mirror-binary-security "http://ports.ubuntu.com" \
    --parent-mirror-binary-security "http://ports.ubuntu.com" \
    --mirror-binary "http://ports.ubuntu.com" \
    --parent-mirror-binary "http://ports.ubuntu.com" \
    --keyring-packages ubuntu-keyring \
    --linux-flavours "${KERNEL_FLAVOR}"

if [ "${SUITE}" == "noble" ] || [ "${SUITE}" == "jammy" ]; then
    # Pin rockchip package archives
    (
        echo "Package: *"
        echo "Pin: release o=LP-PPA-jjriek-rockchip"
        echo "Pin-Priority: 1001"
        echo ""
        echo "Package: *"
        echo "Pin: release o=LP-PPA-jjriek-rockchip-multimedia"
        echo "Pin-Priority: 1001"
    ) > config/archives/extra-ppas.pref.chroot
fi

if [ "${SUITE}" == "noble" ]; then
    # Ignore custom ubiquity package (mistake i made, uploaded to wrong ppa)
    (
        echo "Package: oem-*"
        echo "Pin: release o=LP-PPA-jjriek-rockchip-multimedia"
        echo "Pin-Priority: -1"
        echo ""
        echo "Package: ubiquity*"
        echo "Pin: release o=LP-PPA-jjriek-rockchip-multimedia"
        echo "Pin-Priority: -1"

    ) > config/archives/extra-ppas-ignore.pref.chroot
fi

if [ "${SUITE}" == "questing" ] || [ "${SUITE}" == "resolute" ]; then
    # Add our custom rockchip apt repo
    # Use [trusted=yes] during rootfs build — live-build doesn't install
    # .gpg.chroot keys before apt-get update runs, so signed-by verification
    # would fail. Keys are verified in config-image.sh for the final image.
    echo "deb [trusted=yes] ${REPO_URL} ${REPO_SUITE} main" \
        > config/archives/ubuntu-rockchip.list.chroot

    # Pin our packages above Ubuntu main
    (
        echo "Package: *"
        echo "Pin: origin clsx524.github.io"
        echo "Pin-Priority: 1001"
    ) > config/archives/ubuntu-rockchip.pref.chroot

    # Add armbian apt repo for armbian-firmware
    echo "deb [trusted=yes] ${ARMBIAN_REPO_URL} ${ARMBIAN_REPO_SUITE} main" \
        > config/archives/armbian.list.chroot
fi

# Snap packages to install
(
    echo "snapd/classic=stable"
    echo "core22/classic=stable"
    echo "lxd/classic=stable"
) > config/seeded-snaps

# Generic packages to install
echo "software-properties-common" > config/package-lists/my.list.chroot

if [ "${SUITE}" == "questing" ] || [ "${SUITE}" == "resolute" ]; then
    echo "armbian-firmware" >> config/package-lists/my.list.chroot
fi

if [ "${PROJECT}" == "ubuntu" ]; then
    # Specific packages to install for ubuntu desktop
    (
        echo "ubuntu-desktop-rockchip"
        echo "oem-config-gtk"
        echo "ubiquity-frontend-gtk"
        echo "ubiquity-slideshow-ubuntu"
        echo "localechooser-data"
    ) >> config/package-lists/my.list.chroot
else
    # Specific packages to install for ubuntu server
    echo "ubuntu-server-rockchip" >> config/package-lists/my.list.chroot
fi

# Remove cloud-image-specific hooks that fail on non-cloud Rockchip builds:
# - *ssh_authentication*: writes to /etc/ssh/sshd_config.d/60-cloudimg-settings.conf (absent)
# - *cpc-fixes*: runs dpkg-reconfigure cloud-init (not installed)
# - *ec2-version*: writes EC2 cloud branding marker (irrelevant)
rm -f config/hooks/*ssh_authentication*.chroot
rm -f config/hooks/*cpc*.chroot
rm -f config/hooks/*ec2*.chroot

# Build the rootfs
lb build

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

# Verify the chroot was actually built with our meta-package installed
if [ ! -d chroot/dev ]; then
    echo "Error: lb build produced incomplete chroot (missing /dev)"
    exit 1
fi
if [ ! -f chroot/var/lib/dpkg/info/ubuntu-server-rockchip.list ] && \
   [ ! -f chroot/var/lib/dpkg/info/ubuntu-desktop-rockchip.list ]; then
    echo "Error: ubuntu-*-rockchip meta-package was not installed in chroot"
    exit 1
fi

# Tar the entire rootfs
(cd chroot/ &&  tar -p -c --sort=name --xattrs ./*) | xz -3 -T0 > "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"
mv "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz" ../
