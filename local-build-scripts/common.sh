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
            Build the pinned out-of-tree modules cmemdrv, qos and pvrsrvkm.
            Requires a built kernel.
            <sub_command>:
                - all     (fetch if needed, then build)
                - fetch   (re-clone at the pinned revision and re-apply patches)
                - install (build and install to KERNEL_MODULES_OUTPUT_DIR)
                - clean

        3. bl31
            Build the ARM Trusted Firmware BL31 blob. Flashed separately as
            a raw .srec on X5H (not loaded via the fitImage - see
            Flash_Yocto_Binaries_X5H.md in the rcar-x5h workspace).
            <sub_command>:
                - all   (fetch if needed, then build)
                - fetch (re-clone at the pinned revision)
                - clean

        4. optee
            Build OP-TEE OS (BL32). Also flashed separately as a raw .srec,
            not loaded via the fitImage. Not present in the upstream V4H
            repo this was ported from - added because X5H's real boot chain
            needs it.
            <sub_command>:
                - all   (fetch if needed, then build)
                - fetch (re-clone at the pinned revision)
                - clean

        5. uboot
            Build U-Boot (BL33). Also flashed separately as a raw .srec. Not
            present in the upstream V4H repo (that board keeps a stock,
            pre-flashed U-Boot); added for X5H because this project already
            has a verified from-source build.
            <sub_command>:
                - all   (fetch if needed, then build)
                - fetch (re-clone at the pinned revision)
                - clean

        6. initramfs
            NOT YET IMPLEMENTED for X5H - see build_initramfs.sh. Needed to
            boot a rootfs that is not on eMMC/SD, if X5H's PCIe driver turns
            out to need firmware loaded before root is reachable (unconfirmed).

        7. ext-modules
            NOT YET IMPLEMENTED for X5H - see build_ext_modules.sh. X5H's
            out-of-tree GPU/cmem/qos driver situation has not been researched.

        8. fitimage
            Build a U-Boot FIT image (fitImage) containing the kernel + dtb
            (+ optional ramdisk) only - unlike V4H, it does NOT contain BL31:
            on X5H, BL31/OP-TEE/U-Boot each run from separately-flashed raw
            .srec before U-Boot is even alive, so U-Boot never "loads" BL31
            the way V4H's stock U-Boot does via FIT.
            <sub_command>:
                - all   (build/install kernel, then assemble the fitImage)
                - image (assemble the fitImage from an existing kernel build)
                - clean

For example:
    Build all images (Kernel image and device tree) for the Linux Kernel:
        \$ ./main_build.sh kernel all

    Clean the Linux Kernel (Kernel image and device tree) output:
        \$ ./main_build.sh kernel clean

    Build and install kernel modules to KERNEL_MODULES_OUTPUT_DIR:
        \$ ./main_build.sh kernel modules-install

    Build the rest of the boot chain (each flashed separately, see above):
        \$ ./main_build.sh bl31 all
        \$ ./main_build.sh optee all
        \$ ./main_build.sh uboot all

    Build a fitImage (kernel + dtb) for the R-Car X5H Ironhide:
        \$ ./main_build.sh fitimage all

Note: No configuration is needed to build. The kernel source is expected in
      <rcar-utils>/linux-sh - when it is missing, the build offers to clone it -
      and every output is written under <rcar-utils>/workspace/:

        workspace/kernel-modules  installed kernel modules and their firmware
        workspace/ext-modules     out-of-tree module sources (not implemented)
        workspace/arm-trusted-firmware
        workspace/optee           OP-TEE OS source and output
        workspace/u-boot          U-Boot source and output
        workspace/initramfs       busybox tree and uInitramfs.cpio.gz (not implemented)
        workspace/fitimage        FIT inputs and fitImage
        workspace/downloads       checksum-verified download cache

      Uncomment a path in config.ini to build somewhere else, or set it for a
      single run, e.g. KERNEL_DIR=~/linux-sh ./main_build.sh kernel all

Platform Override:
    By default, PLATFORM is read from config.ini, but you can override it at runtime, for example:
        \$ PLAT=RCAR-X5H-IRONHIDE ./main_build.sh kernel all
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
KERNEL_URL="${KERNEL_URL:-https://github.com/renesas-rcar/linux-bsp.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-v6.12.80/rcar-6.1.0}"
# The branch moves; this is the exact commit this project has verified
# end-to-end (02_Kernel_Build_GCC_X5H.md). Leave empty to track branch tip.
KERNEL_SRCREV="${KERNEL_SRCREV:-e1e83b5711610d83941c51dcf48418eda209f339}"

# Build outputs and the sources the scripts clone themselves. Ignored by git.
WORKSPACE_DIR="${WORKSPACE_DIR:-${RCAR_UTILS_DIR}/workspace}"
KERNEL_MODULES_OUTPUT_DIR="${KERNEL_MODULES_OUTPUT_DIR:-${WORKSPACE_DIR}/kernel-modules}"
EXT_MODULES_SRC_DIR="${EXT_MODULES_SRC_DIR:-${WORKSPACE_DIR}/ext-modules}"
TFA_SRC_DIR="${TFA_SRC_DIR:-${WORKSPACE_DIR}/arm-trusted-firmware}"
TFA_OUTPUT_DIR="${TFA_OUTPUT_DIR:-${TFA_SRC_DIR}/release}"
OPTEE_SRC_DIR="${OPTEE_SRC_DIR:-${WORKSPACE_DIR}/optee}"
OPTEE_OUTPUT_DIR="${OPTEE_OUTPUT_DIR:-${OPTEE_SRC_DIR}/release}"
UBOOT_SRC_DIR="${UBOOT_SRC_DIR:-${WORKSPACE_DIR}/u-boot}"
UBOOT_OUTPUT_DIR="${UBOOT_OUTPUT_DIR:-${UBOOT_SRC_DIR}/release}"
INITRAMFS_SRC_DIR="${INITRAMFS_SRC_DIR:-${WORKSPACE_DIR}/initramfs}"
INITRAMFS_OUTPUT_DIR="${INITRAMFS_OUTPUT_DIR:-${INITRAMFS_SRC_DIR}}"
FIT_OUTPUT_DIR="${FIT_OUTPUT_DIR:-${WORKSPACE_DIR}/fitimage}"

# Make sure KERNEL_DIR holds a kernel source tree, offering to clone it when it
# does not. Only the branch the build needs is fetched, then pinned to
# KERNEL_SRCREV (when set) so the build is reproducible even as the branch
# moves.
kernel_dir_is_valid() {
	[ -f "${KERNEL_DIR}/Makefile" ] && [ -d "${KERNEL_DIR}/arch/arm64" ]
}

kernel_dir_is_at_srcrev() {
	[ -z "${KERNEL_SRCREV}" ] && return 0
	[ "$(git -C "${KERNEL_DIR}" rev-parse HEAD 2>/dev/null)" = "${KERNEL_SRCREV}" ]
}

ensure_kernel_dir() {
	local answer

	if kernel_dir_is_valid && kernel_dir_is_at_srcrev; then
		return 0
	fi

	if kernel_dir_is_valid && ! kernel_dir_is_at_srcrev; then
		echo "Checking out linux-bsp at ${KERNEL_SRCREV}"
		if ! git -C "${KERNEL_DIR}" cat-file -e "${KERNEL_SRCREV}^{commit}" 2>/dev/null; then
			git -C "${KERNEL_DIR}" fetch -q --all --tags || return 1
		fi
		git -C "${KERNEL_DIR}" checkout -q -f "${KERNEL_SRCREV}" || return 1
		return 0
	fi

	if [ -d "${KERNEL_DIR}" ] && [ -n "$(ls -A "${KERNEL_DIR}" 2>/dev/null)" ]; then
		echo "Error: ${KERNEL_DIR} exists but is not a kernel source tree"
		echo "       (no Makefile, or no arch/arm64 directory)."
		echo "       Point KERNEL_DIR in config.ini at your linux-bsp tree, or remove"
		echo "       the directory and let this script clone it."
		return 1
	fi

	echo "No kernel source found at ${KERNEL_DIR}."
	echo "  repository: ${KERNEL_URL}"
	echo "  branch:     ${KERNEL_BRANCH}"
	echo "  commit:     ${KERNEL_SRCREV:-<branch tip>}"

	# A prompt that nobody can answer would hang a CI job or a build started
	# from a script, so only ask when there is a terminal to ask on.
	if [ ! -t 0 ]; then
		echo "Error: not running interactively, so the source cannot be cloned here."
		echo "       Run this once:"
		echo "         git clone --single-branch --branch ${KERNEL_BRANCH} \\"
		echo "             ${KERNEL_URL} ${KERNEL_DIR}"
		[ -n "${KERNEL_SRCREV}" ] && echo "         git -C ${KERNEL_DIR} checkout ${KERNEL_SRCREV}"
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

	if [ -n "${KERNEL_SRCREV}" ]; then
		git -C "${KERNEL_DIR}" checkout -q -f "${KERNEL_SRCREV}" || return 1
	fi

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

# Required firmware blobs. Both the kernel (CONFIG_EXTRA_FIRMWARE) and U-Boot
# (CONFIG_PHY_R8A78000_MP_PHY_FW) hard-fail to build without these - confirmed
# by deliberately removing them and re-building (02_/03_Build_GCC_X5H.md).
# Unlike V4H's single rcar_gen4_pcie.bin (downloadable from linux-firmware),
# these 3 files are NOT publicly downloadable: they ship only inside the
# Renesas SDK v4.39.0 package (My Renesas account required):
#   https://www.renesas.com/en/document/mas/sdk-documentation-sdk-v4390
#   -> <SDK v4.39.0>/user_manual/current/linux_bsp/_attachments/
FW_DIR="${FW_DIR:-}"
FW_BLOBS=(rcar_gen5_mp_phy.bin rcar_gen5_pcie6_iccm.bin rcar_gen5_pcie6_dccm.bin)

# Install the required firmware blobs into <dir>/usr/lib/firmware. Used by
# both the kernel module output tree and (via /lib/firmware on the build
# host, see build_uboot.sh) the U-Boot build. Fails loudly, with the SDK
# download instructions, rather than silently skipping a missing blob.
install_firmware_blobs() {
	local dir="$1" blob missing=()

	if [ -z "${FW_DIR}" ]; then
		missing=("${FW_BLOBS[@]}")
	else
		for blob in "${FW_BLOBS[@]}"; do
			[ -f "${FW_DIR}/${blob}" ] || missing+=("${blob}")
		done
	fi
	if [ "${#missing[@]}" -gt 0 ]; then
		echo "Error: required firmware blobs not found in FW_DIR=${FW_DIR:-<unset>}" >&2
		echo "       Missing: ${missing[*]}" >&2
		echo "       These are not downloadable - get them from the Renesas SDK v4.39.0" >&2
		echo "       package (My Renesas account required):" >&2
		echo "         https://www.renesas.com/en/document/mas/sdk-documentation-sdk-v4390" >&2
		echo "         -> <SDK v4.39.0>/user_manual/current/linux_bsp/_attachments/" >&2
		echo "       Then set FW_DIR in config.ini to the directory containing them." >&2
		return 1
	fi

	install -d "${dir}/usr/lib/firmware"
	for blob in "${FW_BLOBS[@]}"; do
		install -m 644 "${FW_DIR}/${blob}" "${dir}/usr/lib/firmware/${blob}"
		echo "  usr/lib/firmware/${blob}"
	done
}
