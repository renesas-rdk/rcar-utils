#!/bin/bash
#
# Assemble a U-Boot fitImage for the R-Car X5H Ironhide.
# Contents: kernel, four device trees, optional ramdisk, boot script.
# Each device tree is its own FIT configuration. BL31 is not in this image.
#
set -uo pipefail

source ./config.ini
source ./common.sh

# if PLATFORM is already exported from main_build.sh, keep it
if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

if [ "${PLATFORM}" != "RCAR-X5H-IRONHIDE" ]; then
	echo "Error: the fitimage target is only supported for PLATFORM=RCAR-X5H-IRONHIDE"
	echo "       (current PLATFORM=${PLATFORM})."
	echo "       Set it in config.ini or override it: PLAT=RCAR-X5H-IRONHIDE ./main_build.sh fitimage all"
	exit 1
fi

MKIMAGE="${MKIMAGE:-mkimage}"
# Where bootm copies the kernel and the dtb. boot.cmd loads the FIT clear of them.
FIT_KERNEL_LOADADDR="${FIT_KERNEL_LOADADDR:-0x9E680000}"
FIT_DTB_LOADADDR="${FIT_DTB_LOADADDR:-0x9E600000}"
WITH_INITRAMFS=0

if ! command -v "${MKIMAGE}" >/dev/null 2>&1; then
	echo "Error: '${MKIMAGE}' not found."
	echo "       Install it with 'sudo apt install u-boot-tools', or point MKIMAGE"
	echo "       at a mkimage binary from a U-Boot build."
	exit 1
fi

# ---- Board description ----
BOARD_DTB="r8a78000-ironhide"
INITRAMFS_NAME="uInitramfs.cpio.gz"

DTS_DIR="arch/arm64/boot/dts/renesas"
KERNEL_IMAGE="arch/arm64/boot/Image"

# Device tree variants, as built by the kernel for this board.
# "<config name>|<fdt node label>|<dtb file name>|<description>"
# The first entry is the default configuration.
#
# r8a78000-ironhide-npu.dtb is not built by the kernel. It ships in the SDK
# Linux BSP tarball. Copy it into the kernel dts directory and add it here
# when an NPU configuration is required.
FIT_DTBS=(
	"default|fdt-1|${BOARD_DTB}.dtb|CA core only, UIO disabled (native drivers)"
	"uio|fdt-uio|${BOARD_DTB}-uio.dtb|CA + CR cores, UIO enabled"
	"uio-ca|fdt-uio-ca|${BOARD_DTB}-uio-ca.dtb|CA core only, UIO enabled"
	"coresight|fdt-coresight|${BOARD_DTB}-coresight.dtb|CoreSight debug/trace build"
)

# ---- Resolve paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIT_TEMPLATE_DIR="${SCRIPT_DIR}/fit/rcar-x5h-ironhide"

ensure_kernel_dir || exit 1

# KERNEL_DIR, FIT_OUTPUT_DIR and INITRAMFS_OUTPUT_DIR come from common.sh.
# The initramfs is optional here (its target is not implemented for X5H yet);
# a path set in config.ini comes from another build and is never rebuilt.
INITRAMFS_FROM_BUILD=1
if [ -z "${INITRAMFS_CPIO:-}" ]; then
	INITRAMFS_CPIO="${INITRAMFS_OUTPUT_DIR}/${INITRAMFS_NAME}"
else
	INITRAMFS_FROM_BUILD=0
fi

# ---- Steps ----

# Build and install the kernel Image, the board device trees, and the in-tree
# modules. The installed module tree is part of the deployable output.
mk_kernel() {
	echo '|============================================|'
	echo '| Build/install kernel + device trees + mods |'
	echo '|============================================|'
	./build_kernel.sh "modules-install" || exit 1
}

# Copy everything the .its refers to next to the .its before assembly.
stage_inputs() {
	echo '|============================================|'
	echo '|            Stage FIT image inputs          |'
	echo '|============================================|'
	mkdir -p "${FIT_OUTPUT_DIR}" || exit 1

	# This directory is reused by incremental builds. Remove previously staged
	# device trees so a renamed or dropped variant cannot be mistaken for a
	# member of the newly assembled FIT by host-side verification.
	find "${FIT_OUTPUT_DIR}" -maxdepth 1 -type f \
		-name "${BOARD_DTB}*.dtb" -delete || exit 1

	if [ ! -f "${KERNEL_DIR}/${KERNEL_IMAGE}" ]; then
		echo "Error: kernel image not found: ${KERNEL_DIR}/${KERNEL_IMAGE}"
		echo "       Run './main_build.sh fitimage all' to build it first."
		exit 1
	fi
	install -m 644 "${KERNEL_DIR}/${KERNEL_IMAGE}" "${FIT_OUTPUT_DIR}/Image"

	local entry name label dtb desc missing=0
	for entry in "${FIT_DTBS[@]}"; do
		IFS='|' read -r name label dtb desc <<<"${entry}"
		if [ ! -f "${KERNEL_DIR}/${DTS_DIR}/${dtb}" ]; then
			echo "Error: device tree not built: ${KERNEL_DIR}/${DTS_DIR}/${dtb} (FIT node ${label})"
			missing=1
			continue
		fi
		install -m 644 "${KERNEL_DIR}/${DTS_DIR}/${dtb}" "${FIT_OUTPUT_DIR}/"
	done
	if [ ${missing} -ne 0 ]; then
		echo "       Check that ${DTS_DIR}/Makefile still lists these variants."
		exit 1
	fi

	WITH_INITRAMFS=0
	if [ -n "${INITRAMFS_CPIO:-}" ] && [ -f "${INITRAMFS_CPIO}" ]; then
		install -m 644 "${INITRAMFS_CPIO}" "${FIT_OUTPUT_DIR}/${INITRAMFS_NAME}"
		WITH_INITRAMFS=1
	else
		# The usual rootfs is on eMMC/UFS, so a ramdisk is optional.
		echo "No initramfs staged (INITRAMFS_CPIO=${INITRAMFS_CPIO:-unset})."
		echo "  The fitImage is generated without a ramdisk."
	fi

	if [ ! -f "${FIT_TEMPLATE_DIR}/boot.cmd" ]; then
		echo "Error: boot script template not found: ${FIT_TEMPLATE_DIR}/boot.cmd"
		exit 1
	fi
	install -m 644 "${FIT_TEMPLATE_DIR}/boot.cmd" "${FIT_OUTPUT_DIR}/boot.cmd"
}

# Emit the image tree source. A custom one can be used instead by setting
# FIT_ITS in config.ini.
gen_its() {
	local its="${FIT_OUTPUT_DIR}/fit-image.its"

	if [ -n "${FIT_ITS:-}" ]; then
		echo "Using custom image tree source: ${FIT_ITS}"
		install -m 644 "${FIT_ITS}" "${its}" || exit 1
		return 0
	fi

	echo "Generating ${its}"
	{
		echo '/dts-v1/;'
		echo ''
		echo '/ {'
		echo "	description = \"Linux kernel and FDT blobs for ${BOARD_DTB}\";"
		echo ''
		echo '	images {'
		echo '		kernel-1 {'
		echo '			description = "Linux kernel";'
		echo '			data = /incbin/("./Image");'
		echo '			type = "kernel";'
		echo '			arch = "arm64";'
		echo '			os = "linux";'
		echo '			compression = "none";'
		echo "			load = <${FIT_KERNEL_LOADADDR}>;"
		echo "			entry = <${FIT_KERNEL_LOADADDR}>;"
		echo '			hash-1 {'
		echo '				algo = "crc32";'
		echo '			};'
		echo '		};'

		local entry name label dtb desc
		for entry in "${FIT_DTBS[@]}"; do
			IFS='|' read -r name label dtb desc <<<"${entry}"
			echo "		${label} {"
			echo "			description = \"${desc}\";"
			echo "			data = /incbin/(\"./${dtb}\");"
			echo '			type = "flat_dt";'
			echo '			arch = "arm64";'
			echo '			compression = "none";'
			echo "			load = <${FIT_DTB_LOADADDR}>;"
			echo '			hash-1 {'
			echo '				algo = "crc32";'
			echo '			};'
			echo '		};'
		done

		if [ "${WITH_INITRAMFS}" = "1" ]; then
			echo '		ramdisk-1 {'
			echo '			description = "Initramfs";'
			echo "			data = /incbin/(\"./${INITRAMFS_NAME}\");"
			echo '			type = "ramdisk";'
			echo '			arch = "arm64";'
			echo '			os = "linux";'
			echo '			compression = "none";'
			echo '			hash-1 {'
			echo '				algo = "crc32";'
			echo '			};'
			echo '		};'
		fi
		echo '		script {'
		echo '			description = "Boot script";'
		echo '			data = /incbin/("./boot.cmd");'
		echo '			type = "script";'
		echo '			arch = "arm64";'
		echo '			os = "u-boot";'
		echo '			compression = "none";'
		echo '			hash-1 {'
		echo '				algo = "crc32";'
		echo '			};'
		echo '		};'
		echo '	};'
		echo ''
		echo '	configurations {'
		echo '		default = "default";'
		# One configuration per device tree. No loadables entry: BL31 is not
		# in this image.
		for entry in "${FIT_DTBS[@]}"; do
			IFS='|' read -r name label dtb desc <<<"${entry}"
			echo "		${name} {"
			echo "			description = \"Boot Linux - ${desc}\";"
			echo '			kernel = "kernel-1";'
			echo "			fdt = \"${label}\";"
			if [ "${WITH_INITRAMFS}" = "1" ]; then
				echo '			ramdisk = "ramdisk-1";'
			fi
			echo '			hash-1 {'
			echo '				algo = "crc32";'
			echo '			};'
			echo '		};'
		done
		echo '	};'
		echo '};'
	} > "${its}" || exit 1
}

mk_fitimage() {
	echo '|============================================|'
	echo '|              Build FIT image               |'
	echo '|============================================|'
	( cd "${FIT_OUTPUT_DIR}" && "${MKIMAGE}" -f ./fit-image.its ./fitImage ) || exit 1
	echo ""
	echo "fitImage: ${FIT_OUTPUT_DIR}/fitImage"
	ls -l "${FIT_OUTPUT_DIR}/fitImage"
}

mk_clean() {
	if [ -d "${FIT_OUTPUT_DIR}" ]; then
		echo "Removing ${FIT_OUTPUT_DIR}"
		rm -rf "${FIT_OUTPUT_DIR}"
	fi
}

# ---- Main ----
cmd="${1:-all}"
echo "Starting the FIT image build '${cmd}' (PLATFORM=${PLATFORM})"
echo "Output directory: ${FIT_OUTPUT_DIR}"

case "${cmd}" in
	'image')
		# Reuse what is already built in KERNEL_DIR.
		stage_inputs
		gen_its
		mk_fitimage
		;;
	'all')
		mk_kernel
		stage_inputs
		gen_its
		mk_fitimage
		;;
	'clean')
		mk_clean
		;;
	*)
		show_help
		;;
esac

exit 0
