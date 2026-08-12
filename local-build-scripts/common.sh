#!/bin/bash

_usage="
Usage:

$ ./main_build.sh <target_build> <sub_command>

Option:
    <target_build>:
        1. kernel
            Build for Linux Kernel
            <sub_command>:
                - clean
                - distclean
                - defconfig    (regenerate .config from the board defconfig,
                                discarding any local change)
                - menuconfig   (edit .config; the builds that follow keep it)
                - image
                - dtbs
                - all
                - modules
                - modules-install

        2. ext-modules
            Build the out-of-tree kernel modules that meta-sparrow-hawk ships
            as separate recipes (cmemdrv, qos). Requires a built kernel.
            <sub_command>:
                - all     (fetch if needed, then build)
                - fetch   (re-clone at the pinned revision and re-apply patches)
                - install (build and install to KERNEL_MODULES_OUTPUT_DIR)
                - clean

        3. bl31
            Build the ARM Trusted Firmware BL31 blob that meta-sparrow-hawk
            deploys with the arm-trusted-firmware recipe. Every FIT
            configuration loads it, so the fitimage target needs it.
            <sub_command>:
                - all   (fetch if needed, then build)
                - fetch (re-clone at the pinned revision)
                - clean

        4. initramfs
            Build the initramfs that meta-sparrow-hawk produces with the
            initramfs-image recipe (uInitramfs.cpio.gz). Needed to boot a
            rootfs that is not on eMMC/SD. Requires built kernel modules.
            <sub_command>:
                - all     (build busybox if needed, then the cpio)
                - image   (same as all)
                - busybox (build the static busybox only)
                - clean

        5. fitimage
            Build a U-Boot FIT image (fitImage)
            <sub_command>:
                - all   (build the kernel first, then the fitImage)
                - image (assemble the fitImage from an existing kernel build)
                - clean

For example:
    Build all images (Kernel image and device tree) for the Linux Kernel:
        \$ ./main_build.sh kernel all

    Clean the Linux Kernel (Kernel image and device tree) output:
        \$ ./main_build.sh kernel clean

    Build and install kernel modules to KERNEL_MODULES_OUTPUT_DIR:
        \$ ./main_build.sh kernel modules-install

    Build BL31 and the initramfs, the two other fitImage inputs:
        \$ ./main_build.sh bl31 all
        \$ ./main_build.sh initramfs all

    Build a fitImage for the R-Car V4H Sparrow Hawk:
        \$ ./main_build.sh fitimage all

Note: No configuration is needed to build. The kernel source is expected in
      <rcar-utils>/linux-sh - when it is missing, the build offers to clone it -
      and every output is written under <rcar-utils>/workspace/:

        workspace/kernel-modules  installed kernel modules and their firmware
        workspace/ext-modules     out-of-tree module sources
        workspace/arm-trusted-firmware
        workspace/initramfs       busybox tree and uInitramfs.cpio.gz
        workspace/fitimage        FIT inputs and fitImage
        workspace/downloads       checksum-verified download cache

      Uncomment a path in config.ini to build somewhere else, or set it for a
      single run, e.g. KERNEL_DIR=~/linux-sh ./main_build.sh kernel all

Platform Override:
    By default, PLATFORM is read from config.ini, but you can override it at runtime, for example:
        \$ PLAT=RCAR-V4H-SH ./main_build.sh kernel all
"
# Help message
show_help() {
        echo 'Error: Invalid Syntax!'
        echo "${_usage}"
        exit 1
}

#-----------------------------------------------------------------------------
# Paths
#-----------------------------------------------------------------------------
# Everything the build produces or clones lives inside the rcar-utils checkout,
# so the scripts work straight after a "git clone" with no configuration at
# all. config.ini is sourced before this file, so any value set there (or
# exported in the environment while config.ini leaves it empty) still wins.
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RCAR_UTILS_DIR="$(cd "${COMMON_SH_DIR}/.." && pwd)"

# Kernel source tree. Cloned on demand by ensure_kernel_dir().
KERNEL_DIR="${KERNEL_DIR:-${RCAR_UTILS_DIR}/linux-sh}"
KERNEL_URL="${KERNEL_URL:-https://github.com/renesas-rdk/linux-sh.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-ubuntu/rcar-v4h-sh}"

# Build outputs and the sources the scripts clone themselves. Ignored by git.
WORKSPACE_DIR="${WORKSPACE_DIR:-${RCAR_UTILS_DIR}/workspace}"
KERNEL_MODULES_OUTPUT_DIR="${KERNEL_MODULES_OUTPUT_DIR:-${WORKSPACE_DIR}/kernel-modules}"
EXT_MODULES_SRC_DIR="${EXT_MODULES_SRC_DIR:-${WORKSPACE_DIR}/ext-modules}"
TFA_SRC_DIR="${TFA_SRC_DIR:-${WORKSPACE_DIR}/arm-trusted-firmware}"
TFA_OUTPUT_DIR="${TFA_OUTPUT_DIR:-${TFA_SRC_DIR}/release}"
INITRAMFS_SRC_DIR="${INITRAMFS_SRC_DIR:-${WORKSPACE_DIR}/initramfs}"
INITRAMFS_OUTPUT_DIR="${INITRAMFS_OUTPUT_DIR:-${INITRAMFS_SRC_DIR}}"
FIT_OUTPUT_DIR="${FIT_OUTPUT_DIR:-${WORKSPACE_DIR}/fitimage}"

# Make sure KERNEL_DIR holds a kernel source tree, offering to clone it when it
# does not. Only the branch the build needs is fetched.
kernel_dir_is_valid() {
	[ -f "${KERNEL_DIR}/Makefile" ] && [ -d "${KERNEL_DIR}/arch/arm64" ]
}

ensure_kernel_dir() {
	local answer

	if kernel_dir_is_valid; then
		return 0
	fi

	if [ -d "${KERNEL_DIR}" ] && [ -n "$(ls -A "${KERNEL_DIR}" 2>/dev/null)" ]; then
		echo "Error: ${KERNEL_DIR} exists but is not a kernel source tree"
		echo "       (no Makefile, or no arch/arm64 directory)."
		echo "       Point KERNEL_DIR in config.ini at your linux-sh tree, or remove"
		echo "       the directory and let this script clone it."
		return 1
	fi

	echo "No kernel source found at ${KERNEL_DIR}."
	echo "  repository: ${KERNEL_URL}"
	echo "  branch:     ${KERNEL_BRANCH}"

	# A prompt that nobody can answer would hang a CI job or a build started
	# from a script, so only ask when there is a terminal to ask on.
	if [ ! -t 0 ]; then
		echo "Error: not running interactively, so the source cannot be cloned here."
		echo "       Run this once:"
		echo "         git clone --single-branch --branch ${KERNEL_BRANCH} \\"
		echo "             ${KERNEL_URL} ${KERNEL_DIR}"
		echo "       or set KERNEL_DIR in config.ini to an existing tree."
		return 1
	fi

	read -r -p "Clone it now? [y/N] " answer
	case "${answer}" in
		[yY] | [yY][eE][sS]) ;;
		*)
			echo "Aborted. Set KERNEL_DIR in config.ini to your own kernel tree."
			return 1
			;;
	esac

	mkdir -p "$(dirname "${KERNEL_DIR}")" || return 1
	git clone --single-branch --branch "${KERNEL_BRANCH}" \
		"${KERNEL_URL}" "${KERNEL_DIR}" || return 1

	if ! kernel_dir_is_valid; then
		echo "Error: ${KERNEL_DIR} was cloned but does not look like a kernel tree."
		return 1
	fi
}

#-----------------------------------------------------------------------------
# Shared downloads
#-----------------------------------------------------------------------------
# Cache for the artifacts pinned by checksum, shared by every target.
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${WORKSPACE_DIR}/downloads}"

# PCIe PHY firmware. pcie-rcar-gen4 calls request_firmware() while bringing the
# link up, so the blob is needed both inside the initramfs and on the rootfs
# next to the module - it is not part of the distro's linux-firmware package.
# Same file and revision the sparrow-hawk-fw recipe fetches.
PCIE_FW_URL="${PCIE_FW_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rcar_gen4_pcie.bin?h=20260519}"
PCIE_FW_SHA256="${PCIE_FW_SHA256:-cad6315e51397e9e2dd401d79eaa873c7b67290bce381bb97728883cc243e5ff}"
PCIE_FW_LIC_URL="${PCIE_FW_LIC_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/LICENCE.r8a779g_pcie_phy?h=20260519}"
PCIE_FW_LIC_SHA256="${PCIE_FW_LIC_SHA256:-fa0df1c508be531a302823721ae14258ba0481c9b1d717b2d3f2344aa0f66894}"

# Download a file into the cache and verify it, echoing its path. Same
# contract as the fetcher in build_ext_modules.sh: the checksum is what pins
# the artifact, exactly like the recipes' SRC_URI does.
fetch_file() {
	local url="$1" sha="$2" name="$3"
	local out="${DOWNLOAD_DIR}/${name}"
	local got

	mkdir -p "${DOWNLOAD_DIR}"
	if [ ! -f "${out}" ] || [ "$(sha256sum "${out}" | cut -d' ' -f1)" != "${sha}" ]; then
		echo "Downloading ${name}" >&2
		curl -fsSL -o "${out}" "${url}" || return 1
	fi

	got="$(sha256sum "${out}" | cut -d' ' -f1)"
	if [ "${got}" != "${sha}" ]; then
		echo "Error: checksum mismatch for ${out}" >&2
		echo "       expected ${sha}" >&2
		echo "       got      ${got}" >&2
		return 1
	fi
	echo "${out}"
}

# Install the PCIe PHY firmware and its licence into <dir>/usr/lib/firmware.
# Used by both the initramfs staging tree and the kernel module output tree.
install_pcie_firmware() {
	local dir="$1" fw lic

	install -d "${dir}/usr/lib/firmware"

	fw="$(fetch_file "${PCIE_FW_URL}" "${PCIE_FW_SHA256}" "rcar_gen4_pcie.bin")" || return 1
	install -m 644 "${fw}" "${dir}/usr/lib/firmware/rcar_gen4_pcie.bin"
	echo "  usr/lib/firmware/rcar_gen4_pcie.bin"

	# The firmware is redistributable but its licence has to travel with it.
	lic="$(fetch_file "${PCIE_FW_LIC_URL}" "${PCIE_FW_LIC_SHA256}" "LICENCE.r8a779g_pcie_phy")" || return 1
	install -m 644 "${lic}" "${dir}/usr/lib/firmware/LICENCE.r8a779g_pcie_phy"
	echo "  usr/lib/firmware/LICENCE.r8a779g_pcie_phy"
}
