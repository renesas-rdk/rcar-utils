#!/bin/bash
#
# Build U-Boot (BL33) for the X5H Ironhide boot chain
# (u-boot-elf-ironhide.srec).
#
# NOT present in the upstream V4H Sparrow Hawk repo this was ported from -
# that board keeps a stock, pre-flashed U-Boot and only ever replaces the
# fitImage it loads. X5H's U-Boot is flashed as a raw .srec of its own (see
# Flash_Yocto_Binaries_X5H.md / Table 4-1-2 in the rcar-x5h workspace), and
# this project has a verified from-source build for it, so it is a target
# here.
#
# Verified end-to-end in 03_Uboot_Build_GCC_X5H.md.
#
set -uo pipefail

source ./config.ini
source ./common.sh

if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

if [ "${PLATFORM}" != "RCAR-X5H-IRONHIDE" ]; then
	echo "Error: the uboot target is only supported for PLATFORM=RCAR-X5H-IRONHIDE"
	echo "       (current PLATFORM=${PLATFORM})."
	exit 1
fi

UBOOT_URL="${UBOOT_URL:-https://github.com/renesas-rcar/u-boot.git}"
UBOOT_BRANCH="${UBOOT_BRANCH:-v2026.01/rcar-8.0.0}"
UBOOT_SRCREV="${UBOOT_SRCREV:-1a33b2bc6981f2077bc4b0780fa3604c1e20d1a0}"
# Ironhide. The Perceptor board uses r8j78070_perceptor_defconfig; there is
# exactly one correct defconfig per board here, so unlike the kernel there is
# no wrong-defconfig trap to avoid.
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-r8a78000_ironhide_defconfig}"
# UBOOT_SRC_DIR and UBOOT_OUTPUT_DIR come from common.sh.
UBOOT_NAME="u-boot-elf-ironhide"

export ARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

# U-Boot sets up its own flags; inheriting host flags would break the build.
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS AS LD

fetch_src() {
	if [ ! -d "${UBOOT_SRC_DIR}/.git" ]; then
		echo "Cloning ${UBOOT_URL} -> ${UBOOT_SRC_DIR}"
		mkdir -p "$(dirname "${UBOOT_SRC_DIR}")"
		git clone -q --single-branch --branch "${UBOOT_BRANCH}" \
			"${UBOOT_URL}" "${UBOOT_SRC_DIR}" || exit 1
	fi

	if ! git -C "${UBOOT_SRC_DIR}" cat-file -e "${UBOOT_SRCREV}^{commit}" 2>/dev/null; then
		git -C "${UBOOT_SRC_DIR}" fetch -q --all --tags || exit 1
	fi

	echo "Checking out u-boot at ${UBOOT_SRCREV}"
	git -C "${UBOOT_SRC_DIR}" checkout -q -f "${UBOOT_SRCREV}" || exit 1
	git -C "${UBOOT_SRC_DIR}" clean -qxfd || exit 1
}

# Only re-fetch when the tree is missing or on another revision, so that a
# rebuild does not throw away an existing checkout.
ensure_src() {
	local have
	have="$(git -C "${UBOOT_SRC_DIR}" rev-parse HEAD 2>/dev/null)"
	if [ "${have}" = "${UBOOT_SRCREV}" ]; then
		echo "u-boot: already at ${UBOOT_SRCREV}"
		return 0
	fi
	fetch_src
}

mk_build() {
	ensure_src
	# r8a78000_ironhide_defconfig pulls in configs/renesas_rcar5.config via an
	# "#include" on its first line, and that fragment enables
	# CONFIG_PHY_R8A78000_MP_PHY with
	# CONFIG_PHY_R8A78000_MP_PHY_FW="/lib/firmware/rcar_gen5_mp_phy.bin".
	# Without that blob the build dies at drivers/phy/renesas with
	# "No rule to make target '/usr/lib/firmware/rcar_gen5_mp_phy.bin'".
	ensure_firmware_blobs || exit 1

	echo '|============================================|'
	echo '|                Build U-Boot                 |'
	echo '|============================================|'
	make -C "${UBOOT_SRC_DIR}" distclean || exit 1
	make -C "${UBOOT_SRC_DIR}" "${UBOOT_DEFCONFIG}" || exit 1
	make -C "${UBOOT_SRC_DIR}" -j"$(nproc)" || exit 1

	if [ ! -f "${UBOOT_SRC_DIR}/u-boot-elf.srec" ]; then
		echo "Error: ${UBOOT_SRC_DIR}/u-boot-elf.srec was not produced."
		exit 1
	fi

	echo '|============================================|'
	echo '|           Install U-Boot artifacts          |'
	echo '|============================================|'
	# u-boot-elf.srec is the one the flash programmer takes (Table 4-1-2,
	# module UFS, flash_address 0x06F00000). The others are kept for
	# debugging and for anyone booting U-Boot some other way.
	install -d "${UBOOT_OUTPUT_DIR}"
	install -m 644 "${UBOOT_SRC_DIR}/u-boot-elf.srec" "${UBOOT_OUTPUT_DIR}/${UBOOT_NAME}.srec"
	install -m 644 "${UBOOT_SRC_DIR}/u-boot.bin"      "${UBOOT_OUTPUT_DIR}/u-boot-ironhide.bin"
	install -m 644 "${UBOOT_SRC_DIR}/u-boot.srec"     "${UBOOT_OUTPUT_DIR}/u-boot-ironhide.srec"
	[ -f "${UBOOT_SRC_DIR}/u-boot.dtb" ] && \
		install -m 644 "${UBOOT_SRC_DIR}/u-boot.dtb" "${UBOOT_OUTPUT_DIR}/u-boot-ironhide.dtb"
	echo "  ${UBOOT_NAME}.srec"
	echo "  u-boot-ironhide.bin"
	echo "  u-boot-ironhide.srec"
	echo ""
	ls -l "${UBOOT_OUTPUT_DIR}/${UBOOT_NAME}.srec"
}

mk_clean() {
	if [ -d "${UBOOT_SRC_DIR}" ]; then
		echo "Cleaning ${UBOOT_SRC_DIR}"
		make -C "${UBOOT_SRC_DIR}" distclean >/dev/null 2>&1 || true
	fi
	if [ -d "${UBOOT_OUTPUT_DIR}" ]; then
		echo "Removing ${UBOOT_OUTPUT_DIR}"
		rm -rf "${UBOOT_OUTPUT_DIR}"
	fi
}

# ---- Main ----
cmd="${1:-all}"
echo "Starting the U-Boot build '${cmd}' (PLATFORM=${PLATFORM})"
echo "Source directory: ${UBOOT_SRC_DIR}"
echo "Output directory: ${UBOOT_OUTPUT_DIR}"

case "${cmd}" in
	'fetch')
		fetch_src
		;;
	'all'|'image')
		mk_build
		;;
	'clean')
		mk_clean
		;;
	*)
		show_help
		;;
esac

exit 0
