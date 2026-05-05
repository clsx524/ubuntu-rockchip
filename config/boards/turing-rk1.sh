# shellcheck shell=bash

export BOARD_NAME="Turing RK1"
export BOARD_MAKER="Turing Machines"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot-turing-rk3588"
export UBOOT_RULES_TARGET="turing-rk1-rk3588"
export COMPATIBLE_SUITES=("jammy" "noble" "oracular" "plucky" "questing" "resolute")
export COMPATIBLE_FLAVORS=("server" "desktop")

function config_image_hook__turing-rk1() {
    local rootfs="$1"
    local suite="$3"

    if [ "${suite}" == "jammy" ] || [ "${suite}" == "noble" ]; then
        # Install panfork
        chroot "${rootfs}" add-apt-repository -y ppa:jjriek/panfork-mesa
        chroot "${rootfs}" apt-get update
        chroot "${rootfs}" apt-get -y install mali-g610-firmware
        chroot "${rootfs}" apt-get -y dist-upgrade

        # Install libmali blobs alongside panfork
        chroot "${rootfs}" apt-get -y install libmali-g610-x11

        # Install the rockchip camera engine
        chroot "${rootfs}" apt-get -y install camera-engine-rkaiq-rk3588

        # The RK1 uses UART9 for console output
        sed -i 's/console=ttyS2,1500000/console=ttyS9,115200/g' "${rootfs}/etc/kernel/cmdline"
    elif [ "${suite}" == "oracular" ] || [ "${suite}" == "plucky" ] || [ "${suite}" == "questing" ] || [ "${suite}" == "resolute" ]; then
        # Turing RK1 wires UART9 (febc0000) to the BMC serial proxy.
        # Device tree (rk3588-turing-rk1.dts) sets stdout-path = "serial9";
        # alias serial9 -> &uart9, so Linux exposes it as /dev/ttyS9.
        # earlycon address must match uart9 in rk3588s.dtsi (febc0000).
        mkdir -p "${rootfs}/etc/kernel"
        cat > "${rootfs}/etc/kernel/cmdline" <<'EOF'
console=ttyS9,115200 earlycon=uart8250,mmio32,0xfebc0000 console=tty1 rootwait rw cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory
EOF

        # Desktop image needs Mali G610 GPU userspace + firmware so GDM can
        # render the desktop and oem-config-gtk shows up on HDMI. The Armbian
        # BSP 6.1 kernel uses the rockchip mali_kbase driver, which requires
        # the matching ARM proprietary userspace blob (libmali) and CSF
        # firmware. ARM does NOT publish libmali source -- it is closed-source.
        #
        # libmali deb: tsukumijima/libmali-rockchip releases (newer DDK than
        #              jjriek's PPA, actively maintained for 6.1 kernel).
        # firmware:    raw mali_csffw.bin from JeffyCN/mirrors (rockchip's
        #              canonical mirror; tsukumijima does not ship a fw deb).
        if [ "${FLAVOR}" == "desktop" ]; then
            local libmali_rel="v1.9-1-20260312-bd33ee2"
            local libmali_deb="libmali-valhall-g610-g13p0-x11-wayland-gbm_1.9-1_arm64.deb"
            local libmali_url="https://github.com/tsukumijima/libmali-rockchip/releases/download/${libmali_rel}/${libmali_deb}"
            local fw_url="https://github.com/JeffyCN/mirrors/raw/refs/heads/libmali/firmware/g610/mali_csffw.bin"

            curl -fL --retry 3 -o "${rootfs}/tmp/${libmali_deb}" "${libmali_url}"
            chroot "${rootfs}" apt-get install -y --no-install-recommends \
                "/tmp/${libmali_deb}"
            rm -f "${rootfs}/tmp/${libmali_deb}"

            mkdir -p "${rootfs}/lib/firmware"
            curl -fL --retry 3 -o "${rootfs}/lib/firmware/mali_csffw.bin" "${fw_url}"
        fi
    fi

    return 0
}
