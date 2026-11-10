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

        2. bl31
            Build TF-A BL31 (apu-bl31-ironhide). Flash the .srec separately.
            It is not part of the fitImage. Flash offsets: README.md, Boot contract.
            <sub_command>:
                - all   (fetch if needed, then build)
                - fetch (check out the pinned revision; stops if the tree is dirty)
                - clean

        3. optee
            Build OP-TEE (BL32, apu-tee-ironhide). Flash the .srec separately.
            Default is the development image (CFG_INSECURE=y).
            <sub_command>:
                - all   (fetch if needed, then build)
                - fetch (check out the pinned revision; stops if the tree is dirty)
                - clean

        4. uboot
            Build U-Boot (BL33, u-boot-elf-ironhide.srec). Flash it separately.
            <sub_command>:
                - all   (fetch if needed, then build)
                - fetch (check out the pinned revision; stops if the tree is dirty)
                - clean

        5. initramfs
            Not supported. Exits 1. See build_initramfs.sh.

        6. ext-modules
            Not supported. Exits 1. See build_ext_modules.sh.

        7. fitimage
            Build a U-Boot fitImage: kernel, device tree, optional ramdisk,
            and the boot script. BL31 is not in this image.
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
# Pinned commit. Leave empty to build the tip of KERNEL_BRANCH.
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

# A pinned checkout discards uncommitted work. Stop when the tree is dirty
# and let the caller switch revision by hand. release/ is skipped: it is the
# default *_OUTPUT_DIR inside the bl31/optee/uboot trees, so it is always
# there after the first build.
refuse_dirty_tree() {
	local dir="$1" name="$2" rev="$3" dirty
	dirty="$(git -C "${dir}" status --porcelain -- . ':(exclude)release' 2>/dev/null)" || true
	if [ -n "${dirty}" ]; then
		echo "Error: ${name} at ${dir} has local changes." >&2
		echo "       Checking out ${rev} would discard them." >&2
		echo "       Commit or stash those changes, then re-run." >&2
		echo "       To switch revision yourself:" >&2
		echo "         git -C ${dir} checkout ${rev}" >&2
		return 1
	fi
}

ensure_kernel_dir() {
	local answer

	if kernel_dir_is_valid && kernel_dir_is_at_srcrev; then
		return 0
	fi

	if kernel_dir_is_valid && ! kernel_dir_is_at_srcrev; then
		refuse_dirty_tree "${KERNEL_DIR}" "linux-bsp" "${KERNEL_SRCREV}" || return 1
		echo "Checking out linux-bsp at ${KERNEL_SRCREV}"
		if ! git -C "${KERNEL_DIR}" cat-file -e "${KERNEL_SRCREV}^{commit}" 2>/dev/null; then
			git -C "${KERNEL_DIR}" fetch -q --all --tags || return 1
		fi
		git -C "${KERNEL_DIR}" checkout -q "${KERNEL_SRCREV}" || return 1
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


#-----------------------------------------------------------------------------
# Required firmware blobs
#-----------------------------------------------------------------------------
# These are embedded into the binaries at BUILD time, not loaded at run time:
#
#   kernel  CONFIG_EXTRA_FIRMWARE="rcar_gen5_mp_phy.bin rcar_gen5_pcie6_iccm.bin
#                                  rcar_gen5_pcie6_dccm.bin"
#           CONFIG_EXTRA_FIRMWARE_DIR="/lib/firmware"
#   U-Boot  CONFIG_PHY_R8A78000_MP_PHY_FW="/lib/firmware/rcar_gen5_mp_phy.bin"
#           (via configs/r8a78000_ironhide_defconfig's
#            "#include <configs/renesas_rcar5.config>")
#
# Both Kconfigs use the absolute path /lib/firmware on the build host.
# The blobs are linked into the image. Nothing installs them on the target.
# A missing blob fails the build. There is no public URL: they ship in the
# Renesas SDK v4.39.0 package (My Renesas login):
#   https://www.renesas.com/en/document/mas/sdk-documentation-sdk-v4390
#   -> <SDK v4.39.0>/user_manual/current/linux_bsp/_attachments/
FW_BLOBS=(rcar_gen5_mp_phy.bin rcar_gen5_pcie6_iccm.bin rcar_gen5_pcie6_dccm.bin)
# Where the Kconfigs above look for them. Only change this if the kernel's
# CONFIG_EXTRA_FIRMWARE_DIR is changed to match.
FW_INSTALL_DIR="${FW_INSTALL_DIR:-/lib/firmware}"
# Optional source directory holding the three blobs, copied to FW_INSTALL_DIR
# when they are not already there. Set in config.ini.
FW_DIR="${FW_DIR:-}"

fw_blobs_installed() {
	local blob
	for blob in "${FW_BLOBS[@]}"; do
		[ -f "${FW_INSTALL_DIR}/${blob}" ] || return 1
	done
}

fw_missing_msg() {
	echo "Error: required firmware blobs are missing from ${FW_INSTALL_DIR}." >&2
	echo "       Needed: ${FW_BLOBS[*]}" >&2
	echo "" >&2
	echo "       They are embedded into the kernel and U-Boot at build time, so" >&2
	echo "       the build fails outright without them. They are not downloadable:" >&2
	echo "       get them from the Renesas SDK v4.39.0 package (My Renesas login):" >&2
	echo "         https://www.renesas.com/en/document/mas/sdk-documentation-sdk-v4390" >&2
	echo "         -> <SDK v4.39.0>/user_manual/current/linux_bsp/_attachments/" >&2
	echo "" >&2
	echo "       Then either copy them to ${FW_INSTALL_DIR} yourself, or set FW_DIR" >&2
	echo "       in config.ini to the directory holding them and re-run this build." >&2
}

# Make sure the three blobs are in FW_INSTALL_DIR before the kernel or U-Boot
# build starts. Already-present blobs are left alone, so a build host (or
# container image) that ships them needs no FW_DIR at all.
ensure_firmware_blobs() {
	local blob

	if fw_blobs_installed; then
		return 0
	fi

	if [ -z "${FW_DIR}" ]; then
		fw_missing_msg
		return 1
	fi

	for blob in "${FW_BLOBS[@]}"; do
		if [ ! -f "${FW_DIR}/${blob}" ]; then
			echo "Error: ${FW_DIR}/${blob} not found." >&2
			fw_missing_msg
			return 1
		fi
	done

	echo "Installing firmware blobs from ${FW_DIR} to ${FW_INSTALL_DIR}"
	# Writing to /lib/firmware needs root; use sudo only when not already root
	# so this still works unprivileged in a root container.
	local sudo_cmd=()
	[ "$(id -u)" -ne 0 ] && sudo_cmd=(sudo)
	"${sudo_cmd[@]}" install -d "${FW_INSTALL_DIR}" || return 1
	for blob in "${FW_BLOBS[@]}"; do
		"${sudo_cmd[@]}" install -m 644 "${FW_DIR}/${blob}" "${FW_INSTALL_DIR}/${blob}" || return 1
		echo "  ${FW_INSTALL_DIR}/${blob}"
	done
}
