#!/bin/bash
#
# Build the Sparrow Hawk early-boot initramfs (uInitramfs.cpio.gz). Busybox is
# static because the image only needs to load one kernel module and switch to
# the real root filesystem.
#
# The kernel module is taken from the local kernel build rather than shipped
# as a binary, so it always matches the kernel the fitImage is built from.
# That is the failure a prebuilt initramfs cannot avoid: the module's vermagic
# has to match, and a mismatch only shows up at switch_root time.
#
set -uo pipefail

source ./config.ini
source ./common.sh

# if PLATFORM is already exported from main_build.sh, keep it
if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

if [ "${PLATFORM}" != "RCAR-V4H-SH" ]; then
	echo "Error: the initramfs target is only supported for PLATFORM=RCAR-V4H-SH"
	echo "       (current PLATFORM=${PLATFORM})."
	exit 1
fi

ensure_kernel_dir || exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INITRAMFS_TEMPLATE_DIR="${SCRIPT_DIR}/initramfs"

# INITRAMFS_SRC_DIR and INITRAMFS_OUTPUT_DIR come from common.sh.
INITRAMFS_NAME="uInitramfs.cpio.gz"

BUSYBOX_URL="${BUSYBOX_URL:-https://busybox.net/downloads/busybox-1.36.1.tar.bz2}"
BUSYBOX_SHA256="${BUSYBOX_SHA256:-b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314}"

# PCIE_FW_*, DOWNLOAD_DIR, fetch_file and install_pcie_firmware come from
# common.sh: the kernel modules need the same firmware and the same cache.
BUSYBOX_DIR="${INITRAMFS_SRC_DIR}/busybox"
STAGE_DIR="${INITRAMFS_SRC_DIR}/rootfs"

# The single module the initramfs needs. CONFIG_PCIE_DW_HOST is builtin, so
# this is the only .ko involved and "depends=" is empty - hence insmod rather
# than modprobe in the init script.
PCIE_MODULE="drivers/pci/controller/dwc/pcie-rcar-gen4.ko"

# Must match build_kernel.sh: without it scripts/setlocalversion appends a '+'
# to the release string, and the module would be built with a vermagic that
# does not match the kernel in the fitImage.
export LOCALVERSION=""

# Normally exported by main_build.sh; default them so the script also works
# when it is called directly. Without CROSS_COMPILE busybox would silently
# build for the host.
export ARCH="${ARCH:-arm64}"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

# Build busybox for arm64, statically, without a dynamic loader or libc files.
mk_busybox() {
	local tarball

	if [ -x "${BUSYBOX_DIR}/busybox" ]; then
		echo "busybox: already built"
		return 0
	fi

	tarball="$(fetch_file "${BUSYBOX_URL}" "${BUSYBOX_SHA256}" "$(basename "${BUSYBOX_URL}")")" || exit 1

	echo '|============================================|'
	echo '|              Build busybox                 |'
	echo '|============================================|'
	rm -rf "${BUSYBOX_DIR}"
	mkdir -p "${BUSYBOX_DIR}"
	tar xf "${tarball}" -C "${BUSYBOX_DIR}" --strip-components=1 || exit 1

	make -C "${BUSYBOX_DIR}" defconfig >/dev/null || exit 1
	# CONFIG_STATIC is the point of the exercise. The applets below pull in
	# kernel headers that changed after 1.36.1 was released and do not build
	# against a current linux-libc-dev; none of them are of any use in an
	# initramfs.
	sed -i \
		-e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
		-e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
		"${BUSYBOX_DIR}/.config" || exit 1
	# busybox' kconfig predates olddefconfig. silentoldconfig recomputes the
	# dependencies without prompting, which is all that is needed here: the
	# sed above only flips symbols that the defconfig already knows about.
	make -C "${BUSYBOX_DIR}" silentoldconfig </dev/null >/dev/null || exit 1

	if ! grep -q '^CONFIG_STATIC=y' "${BUSYBOX_DIR}/.config"; then
		echo "Error: could not enable CONFIG_STATIC in the busybox config."
		exit 1
	fi

	make -C "${BUSYBOX_DIR}" -j"$(nproc)" || exit 1

	local desc
	desc="$(file -b "${BUSYBOX_DIR}/busybox")"
	if ! grep -q "statically linked" <<<"${desc}"; then
		echo "Error: ${BUSYBOX_DIR}/busybox is not statically linked."
		echo "       Install libc6-dev-arm64-cross, which provides"
		echo "       /usr/aarch64-linux-gnu/lib/libc.a."
		exit 1
	fi
	# A missing CROSS_COMPILE builds a host binary that links and passes the
	# check above, and only fails once the board tries to run /init.
	if ! grep -q "ARM aarch64" <<<"${desc}"; then
		echo "Error: ${BUSYBOX_DIR}/busybox was not built for arm64:"
		echo "       ${desc}"
		echo "       CROSS_COMPILE=${CROSS_COMPILE}"
		exit 1
	fi
}

# Assemble the minimal cpio tree required by the early boot path.
mk_stage() {
	local ko

	ko="${KERNEL_DIR}/${PCIE_MODULE}"
	if [ ! -f "${ko}" ]; then
		echo "Error: ${ko} not found."
		echo "       The initramfs needs the PCIe driver from this kernel build."
		echo "       Build the modules first: ./main_build.sh kernel modules"
		exit 1
	fi

	echo '|============================================|'
	echo '|          Stage the initramfs tree          |'
	echo '|============================================|'
	rm -rf "${STAGE_DIR}"
	mkdir -p "${STAGE_DIR}"

	# busybox' install target reads the generated busybox.links and creates
	# the applet symlinks with the host shell, so it works when cross
	# building - it never runs the arm64 binary.
	make -C "${BUSYBOX_DIR}" CONFIG_PREFIX="${STAGE_DIR}" install >/dev/null || exit 1

	install -d "${STAGE_DIR}/proc" "${STAGE_DIR}/dev" "${STAGE_DIR}/sys" \
	           "${STAGE_DIR}/mnt" "${STAGE_DIR}/usr/lib/firmware"

	# The kernel firmware loader only ever searches /lib/firmware and
	# /lib/firmware/<release>
	ln -sfn usr/lib "${STAGE_DIR}/lib"
	echo "  lib -> usr/lib"

	install -m 644 "${ko}" "${STAGE_DIR}/$(basename "${PCIE_MODULE}")"
	echo "  $(basename "${PCIE_MODULE}")"

	# pcie-rcar-gen4 declares MODULE_FIRMWARE(rcar_gen4_pcie.bin) and calls
	# request_firmware() from its LTSSM setup, so the blob has to be in the
	# initramfs too - the module cannot probe without it.
	install_pcie_firmware "${STAGE_DIR}" || exit 1

	if [ ! -f "${INITRAMFS_TEMPLATE_DIR}/init" ]; then
		echo "Error: init script template not found: ${INITRAMFS_TEMPLATE_DIR}/init"
		exit 1
	fi
	install -m 755 "${INITRAMFS_TEMPLATE_DIR}/init" "${STAGE_DIR}/init"
	echo "  init"
}

mk_image() {
	local out="${INITRAMFS_OUTPUT_DIR}/${INITRAMFS_NAME}"

	echo '|============================================|'
	echo '|             Build the initramfs            |'
	echo '|============================================|'
	mkdir -p "${INITRAMFS_OUTPUT_DIR}" || exit 1
	# Owned by root inside the image: the build does not run as root, so hand
	# the ownership to cpio instead of relying on the staged files.
	( cd "${STAGE_DIR}" && find . | cpio -o -H newc --quiet \
		--owner=0:0 | gzip -9 ) > "${out}" || exit 1

	echo ""
	echo "initramfs: ${out}"
	ls -l "${out}"
}

mk_clean() {
	local d
	for d in "${BUSYBOX_DIR}" "${STAGE_DIR}"; do
		if [ -d "${d}" ]; then
			echo "Removing ${d}"
			rm -rf "${d}"
		fi
	done
	rm -f "${INITRAMFS_OUTPUT_DIR}/${INITRAMFS_NAME}"
}

# ---- Main ----
cmd="${1:-all}"
echo "Starting the initramfs build '${cmd}' (PLATFORM=${PLATFORM})"
echo "Source directory: ${INITRAMFS_SRC_DIR}"
echo "Output directory: ${INITRAMFS_OUTPUT_DIR}"

case "${cmd}" in
	'busybox')
		mk_busybox
		;;
	'all'|'image')
		mk_busybox
		mk_stage
		mk_image
		;;
	'clean')
		mk_clean
		;;
	*)
		show_help
		;;
esac

exit 0
