#!/bin/bash
#
# Assemble a U-Boot FIT image (fitImage) for the R-Car V4H Sparrow Hawk that
# is equivalent to the one produced by the meta-sparrow-hawk linux-fitimage
# recipe: kernel + base DTB + TF-A BL31 + optional initramfs + boot script +
# every device tree overlay, each overlay exposed as its own FIT
# configuration so that boot.cmd can select them at run time.
#
set -uo pipefail

source ./config.ini
source ./common.sh

# if PLATFORM is already exported from main_build.sh, keep it
if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

if [ "${PLATFORM}" != "RCAR-V4H-SH" ]; then
	echo "Error: the fitimage target is only supported for PLATFORM=RCAR-V4H-SH"
	echo "       (current PLATFORM=${PLATFORM})."
	echo "       Set it in config.ini or override it: PLAT=RCAR-V4H-SH ./main_build.sh fitimage all"
	exit 1
fi

MKIMAGE="${MKIMAGE:-mkimage}"
FIT_KERNEL_LOADADDR="${FIT_KERNEL_LOADADDR:-0x50200000}"
FIT_ATF_LOADADDR="${FIT_ATF_LOADADDR:-0x46400000}"
WITH_INITRAMFS=0

if ! command -v "${MKIMAGE}" >/dev/null 2>&1; then
	echo "Error: '${MKIMAGE}' not found."
	echo "       Install it with 'sudo apt install u-boot-tools', or point MKIMAGE"
	echo "       at a mkimage binary from a U-Boot build."
	exit 1
fi

# ---- Board description ----
BOARD_DTB="r8a779g3-sparrow-hawk"
BL31_NAME="bl31-sparrow-hawk.bin"
INITRAMFS_NAME="uInitramfs.cpio.gz"

DTS_DIR="arch/arm64/boot/dts/renesas"
KERNEL_IMAGE="arch/arm64/boot/Image"

# FIT image nodes: "<node label>|<dtbo file name without directory>"
# Order matches the linux-fitimage recipe's fit-image.its.
FIT_OVERLAY_IMAGES=(
	"fdt-uio|${BOARD_DTB}-uio.dtbo"
	"fdt-j1-imx219|${BOARD_DTB}-camera-j1-imx219.dtbo"
	"fdt-j2-imx219|${BOARD_DTB}-camera-j2-imx219.dtbo"
	"fdt-j1-imx462|${BOARD_DTB}-camera-j1-imx462.dtbo"
	"fdt-j2-imx462|${BOARD_DTB}-camera-j2-imx462.dtbo"
	"fdt-j1-imx708|${BOARD_DTB}-camera-j1-imx708.dtbo"
	"fdt-j2-imx708|${BOARD_DTB}-camera-j2-imx708.dtbo"
	"fdt-fan-argon40|${BOARD_DTB}-fan-argon40.dtbo"
	"fdt-fan-pwm|${BOARD_DTB}-fan-pwm.dtbo"
	"fdt-rpi-display-2-5in|${BOARD_DTB}-rpi-display-2-5in.dtbo"
	"fdt-rpi-display-2-7in|${BOARD_DTB}-rpi-display-2-7in.dtbo"
	"fdt-ws-display-13in|${BOARD_DTB}-ws-display-13in.dtbo"
	"fdt-olimex-dsi-hdmi|${BOARD_DTB}-olimex-dsi-hdmi.dtbo"
)

# Overlay configurations: "<config name>|<fdt node label>|<comment>"
# boot.cmd appends these names to the bootm address as "#<name>".
FIT_OVERLAY_CONFIGS=(
	"uio|fdt-uio|"
	"j1-imx219|fdt-j1-imx219|"
	"j2-imx219|fdt-j2-imx219|"
	"j1-imx462|fdt-j1-imx462|"
	"j2-imx462|fdt-j2-imx462|"
	"j1-imx708|fdt-j1-imx708|"
	"j2-imx708|fdt-j2-imx708|"
	"fan-argon40|fdt-fan-argon40|"
	"fan-pwm|fdt-fan-pwm|"
	"rpi-display-2|fdt-rpi-display-2-7in| // For backward compatibility"
	"rpi-display-2-7in|fdt-rpi-display-2-7in|"
	"rpi-display-2-5in|fdt-rpi-display-2-5in|"
	"waveshare-panel|fdt-ws-display-13in| // For backward compatibility"
	"ws-display-13in|fdt-ws-display-13in|"
	"olimex-dsi-hdmi|fdt-olimex-dsi-hdmi|"
)

# ---- Resolve paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIT_TEMPLATE_DIR="${SCRIPT_DIR}/fit/rcar-v4h-sh"

ensure_kernel_dir || exit 1

# KERNEL_DIR, FIT_OUTPUT_DIR, TFA_OUTPUT_DIR and INITRAMFS_OUTPUT_DIR come
# from common.sh. Default the two blobs that other targets produce, so that
# "fitimage all" after "bl31 all" and "initramfs all" needs no further
# configuration.
if [ -z "${BL31_BIN:-}" ]; then
	BL31_BIN="${TFA_OUTPUT_DIR}/${BL31_NAME}"
fi
if [ -z "${INITRAMFS_CPIO:-}" ]; then
	INITRAMFS_CPIO="${INITRAMFS_OUTPUT_DIR}/${INITRAMFS_NAME}"
fi

# ---- Steps ----

# Build the kernel Image and every device tree, including the .dtbo overlays.
mk_kernel() {
	echo '|============================================|'
	echo '|      Build kernel Image + device trees     |'
	echo '|============================================|'
	./build_kernel.sh "all" || exit 1
}

# Copy everything the .its refers to next to the .its itself, the same way the
# recipe assembles it inside its deploy directory.
stage_inputs() {
	echo '|============================================|'
	echo '|            Stage FIT image inputs          |'
	echo '|============================================|'
	mkdir -p "${FIT_OUTPUT_DIR}" || exit 1

	if [ ! -f "${KERNEL_DIR}/${KERNEL_IMAGE}" ]; then
		echo "Error: kernel image not found: ${KERNEL_DIR}/${KERNEL_IMAGE}"
		echo "       Run './main_build.sh fitimage all' to build it first."
		exit 1
	fi
	install -m 644 "${KERNEL_DIR}/${KERNEL_IMAGE}" "${FIT_OUTPUT_DIR}/Image"

	if [ ! -f "${KERNEL_DIR}/${DTS_DIR}/${BOARD_DTB}.dtb" ]; then
		echo "Error: base device tree not found: ${KERNEL_DIR}/${DTS_DIR}/${BOARD_DTB}.dtb"
		exit 1
	fi
	install -m 644 "${KERNEL_DIR}/${DTS_DIR}/${BOARD_DTB}.dtb" "${FIT_OUTPUT_DIR}/"

	local entry label dtbo missing=0
	for entry in "${FIT_OVERLAY_IMAGES[@]}"; do
		label="${entry%%|*}"
		dtbo="${entry##*|}"
		if [ ! -f "${KERNEL_DIR}/${DTS_DIR}/${dtbo}" ]; then
			echo "Error: overlay not built: ${KERNEL_DIR}/${DTS_DIR}/${dtbo} (FIT node ${label})"
			missing=1
			continue
		fi
		install -m 644 "${KERNEL_DIR}/${DTS_DIR}/${dtbo}" "${FIT_OUTPUT_DIR}/"
	done
	if [ ${missing} -ne 0 ]; then
		echo "       Make sure the kernel tree lists the overlays in ${DTS_DIR}/Makefile."
		exit 1
	fi

	if [ ! -f "${BL31_BIN}" ]; then
		echo "Error: BL31 blob not found: ${BL31_BIN}"
		echo "       Every FIT configuration loads BL31, so it is mandatory."
		echo "       Build it with './main_build.sh bl31 all', or point BL31_BIN"
		echo "       at a blob from another build in config.ini."
		exit 1
	fi
	install -m 644 "${BL31_BIN}" "${FIT_OUTPUT_DIR}/${BL31_NAME}"

	WITH_INITRAMFS=0
	if [ -n "${INITRAMFS_CPIO:-}" ] && [ -f "${INITRAMFS_CPIO}" ]; then
		install -m 644 "${INITRAMFS_CPIO}" "${FIT_OUTPUT_DIR}/${INITRAMFS_NAME}"
		WITH_INITRAMFS=1
	else
		echo "Warning: no initramfs available (INITRAMFS_CPIO=${INITRAMFS_CPIO:-unset})."
		echo "         The fitImage is generated without the 'initramfs'"
		echo "         configuration, so booting a rootfs that is not on"
		echo "         eMMC/SD will fail. Build it with"
		echo "         './main_build.sh initramfs all'."
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
		echo "	description = \"Linux kernel and FDT blob for ${BOARD_DTB}\";"
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
		echo '		fdt-1 {'
		echo '			description = "Flattened Device Tree blob";'
		echo "			data = /incbin/(\"./${BOARD_DTB}.dtb\");"
		echo '			type = "flat_dt";'
		echo '			arch = "arm64";'
		echo '			compression = "none";'
		echo '			hash-1 {'
		echo '				algo = "crc32";'
		echo '			};'
		echo '		};'
		echo '		atf-1 {'
		echo '			description = "ARM Trusted Firmware";'
		echo "			data = /incbin/(\"./${BL31_NAME}\");"
		echo '			type = "tfa-bl31";'
		echo '			arch = "arm64";'
		echo '			os = "arm-trusted-firmware";'
		echo '			compression = "none";'
		echo "			load = <${FIT_ATF_LOADADDR}>;"
		echo "			entry = <${FIT_ATF_LOADADDR}>;"
		echo '			hash-1 {'
		echo '				algo = "crc32";'
		echo '			};'
		echo '		};'
		if [ "${WITH_INITRAMFS}" = "1" ]; then
			echo '		ramdisk-1 {'
			echo '			description = "Initramfs for driver loading";'
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
		echo '			description = "Boot script for automatic applying dt-overlay ";'
		echo '			data = /incbin/("./boot.cmd");'
		echo '			type = "script";'
		echo '			arch = "arm64";'
		echo '			os = "u-boot";'
		echo '			compression = "none";'
		echo '			hash-1 {'
		echo '				algo = "crc32";'
		echo '			};'
		echo '		};'

		local entry label dtbo name comment
		for entry in "${FIT_OVERLAY_IMAGES[@]}"; do
			label="${entry%%|*}"
			dtbo="${entry##*|}"
			echo "		${label} {"
			echo '			description = "Flattened Device Tree Overlay";'
			echo "			data = /incbin/(\"./${dtbo}\");"
			echo '			type = "flat_dt";'
			echo '			arch = "arm64";'
			echo '			compression = "none";'
			echo '			hash-1 {'
			echo '				algo = "crc32";'
			echo '			};'
			echo '		};'
		done

		echo '	};'
		echo ''
		echo '	configurations {'
		echo '		default = "default";'
		echo '		default {'
		echo '			description = "Boot Linux kernel with FDT blob";'
		echo '			kernel = "kernel-1";'
		echo '			fdt = "fdt-1";'
		echo '			loadables = "atf-1";'
		echo '			hash-1 {'
		echo '				algo = "crc32";'
		echo '			};'
		echo '		};'
		if [ "${WITH_INITRAMFS}" = "1" ]; then
			echo '		initramfs {'
			echo '			description = "Boot Linux kernel with FDT blob/Initramfs";'
			echo '			kernel = "kernel-1";'
			echo '			fdt = "fdt-1";'
			echo '			loadables = "atf-1";'
			echo '			ramdisk = "ramdisk-1";'
			echo '			hash-1 {'
			echo '				algo = "crc32";'
			echo '			};'
			echo '		};'
		fi
		for entry in "${FIT_OVERLAY_CONFIGS[@]}"; do
			IFS='|' read -r name label comment <<<"${entry}"
			echo "		${name} {${comment}"
			echo "			fdt = \"${label}\";"
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
		# Reuse whatever is already built in KERNEL_DIR.
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
