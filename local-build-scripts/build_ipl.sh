#!/bin/bash
#
# Build the IPL burning package for the Sparrow Hawk: flash.bin (U-Boot SPL and
# U-Boot proper) plus everything needed to write it to the board's QSPI flash
# over the serial console, on Linux or Windows.
#
# The package is independent of the kernel. flash.bin does not contain BL31:
# that is loaded from the fitImage.
#
set -uo pipefail

source ./config.ini
source ./common.sh

# if PLATFORM is already exported from main_build.sh, keep it
if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

if [ "${PLATFORM}" != "RCAR-V4H-SH" ]; then
	echo "Error: the ipl target is only supported for PLATFORM=RCAR-V4H-SH"
	echo "       (current PLATFORM=${PLATFORM})."
	exit 1
fi

IPL_DIR="$(pwd)/ipl"
PATCH_DIR="$(pwd)/patches/u-boot"
# UBOOT_SRC_DIR and IPL_OUTPUT_DIR come from common.sh.
UBOOT_BUILD_DIR="${UBOOT_SRC_DIR}/build"
UBOOT_DEFCONFIG="r8a779g3_sparrowhawk_defconfig"
UBOOT_STAMP="${UBOOT_SRC_DIR}/.rcar-patched"

# ipl_burning.json writes rcar_gen4_pcie.bin at this QSPI offset, and U-Boot
# reads it back from there. A larger flash.bin would overwrite the firmware.
PCIE_FW_FLASH_OFFSET=$((0x300000))

export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

# U-Boot derives ARCH from its own configuration; main_build.sh exports the
# kernel's. Inheriting host flags would break the build, as for TF-A.
unset ARCH CFLAGS CPPFLAGS CXXFLAGS LDFLAGS AS LD

# binman and pylibfdt fail late in the build, so check for them up front.
check_host_tools() {
	local t missing=0

	for t in swig srec_cat unzip patch python3; do
		if ! command -v "${t}" >/dev/null 2>&1; then
			echo "Error: '${t}' not found."
			missing=1
		fi
	done
	if ! python3 -c 'import elftools, setuptools, sysconfig, os, sys
sys.exit(not os.path.exists(os.path.join(sysconfig.get_path("include"), "Python.h")))' 2>/dev/null; then
		echo "Error: python3 cannot find pyelftools, setuptools or Python.h."
		missing=1
	fi
	if [ "${missing}" -ne 0 ]; then
		echo "       Run: sudo apt-get install -y swig srecord unzip patch \\"
		echo "                python3-dev python3-pyelftools python3-setuptools"
		exit 1
	fi
}

# Identifies the revision and the patch set a source tree was prepared with.
src_stamp() {
	echo "${UBOOT_SRCREV}"
	cat "${PATCH_DIR}/series" "${PATCH_DIR}"/*.patch | sha256sum
}

# Apply the patches listed in patches/u-boot/series, in that order.
apply_patches() {
	local p
	while read -r p; do
		[ -z "${p}" ] && continue
		case "${p}" in \#*) continue;; esac
		if ! patch -p1 -d "${UBOOT_SRC_DIR}" --no-backup-if-mismatch -i "${PATCH_DIR}/${p}" >/dev/null; then
			echo "Error: failed to apply u-boot/${p}"
			exit 1
		fi
		echo "  applied ${p}"
	done < "${PATCH_DIR}/series"
}

# Only the pinned commit is fetched: the full U-Boot history is large and the
# build does not use it.
fetch_src() {
	if [ ! -d "${UBOOT_SRC_DIR}/.git" ]; then
		echo "Fetching ${UBOOT_URL} -> ${UBOOT_SRC_DIR}"
		mkdir -p "${UBOOT_SRC_DIR}"
		git -C "${UBOOT_SRC_DIR}" init -q || exit 1
		git -C "${UBOOT_SRC_DIR}" remote add origin "${UBOOT_URL}" || exit 1
	fi

	if ! git -C "${UBOOT_SRC_DIR}" cat-file -e "${UBOOT_SRCREV}^{commit}" 2>/dev/null; then
		git -C "${UBOOT_SRC_DIR}" fetch -q --depth 1 origin "${UBOOT_SRCREV}" || exit 1
	fi

	echo "Checking out u-boot at ${UBOOT_SRCREV}"
	git -C "${UBOOT_SRC_DIR}" checkout -q -f "${UBOOT_SRCREV}" || exit 1
	git -C "${UBOOT_SRC_DIR}" clean -qxfd || exit 1
	apply_patches
	# An empty .scmversion stops the version banner gaining a git suffix.
	: > "${UBOOT_SRC_DIR}/.scmversion"
	src_stamp > "${UBOOT_STAMP}"
}

# The patches leave HEAD on the pinned revision, so HEAD alone cannot tell a
# prepared tree from one whose fetch was interrupted. The stamp is written last.
ensure_src() {
	if [ -f "${UBOOT_STAMP}" ] && [ "$(cat "${UBOOT_STAMP}")" = "$(src_stamp)" ]; then
		echo "u-boot: already at ${UBOOT_SRCREV}"
		return 0
	fi
	fetch_src
}

# merge_config.sh only warns about a value that does not take effect, and a
# flash.bin without the boot environment still builds. Check each one.
check_config() {
	local cfg line
	for cfg in "${IPL_DIR}"/u-boot/*.cfg; do
		while read -r line; do
			[ -z "${line}" ] && continue
			if ! grep -qxF -- "${line}" "${UBOOT_BUILD_DIR}/.config"; then
				echo "Error: '${line}' from $(basename "${cfg}") did not take effect."
				exit 1
			fi
		done < "${cfg}"
	done
}

mk_uboot() {
	check_host_tools
	ensure_src

	echo '|============================================|'
	echo '|               Build U-Boot                 |'
	echo '|============================================|'
	install -m 644 "${IPL_DIR}/u-boot/sparrowhawk.env" "${UBOOT_SRC_DIR}/board/renesas/sparrowhawk/"

	# no_mkeficapsule.cfg drops a host tool that is not part of flash.bin and
	# would otherwise add a build dependency on the gnutls headers.
	make -C "${UBOOT_SRC_DIR}" O="${UBOOT_BUILD_DIR}" "${UBOOT_DEFCONFIG}" >/dev/null || exit 1
	( cd "${UBOOT_SRC_DIR}" && scripts/kconfig/merge_config.sh -m -O "${UBOOT_BUILD_DIR}" \
		"${UBOOT_BUILD_DIR}/.config" "${IPL_DIR}"/u-boot/*.cfg ) >/dev/null || exit 1
	make -C "${UBOOT_SRC_DIR}" O="${UBOOT_BUILD_DIR}" olddefconfig >/dev/null || exit 1
	check_config

	make -C "${UBOOT_SRC_DIR}" O="${UBOOT_BUILD_DIR}" -j"$(nproc)" || exit 1

	local size
	if [ ! -f "${UBOOT_BUILD_DIR}/flash.bin" ]; then
		echo "Error: ${UBOOT_BUILD_DIR}/flash.bin was not produced."
		exit 1
	fi
	size="$(stat -c%s "${UBOOT_BUILD_DIR}/flash.bin")"
	if [ "${size}" -gt "${PCIE_FW_FLASH_OFFSET}" ]; then
		echo "Error: flash.bin is ${size} bytes and would overwrite the PCIe firmware"
		echo "       at QSPI offset $(printf '0x%x' "${PCIE_FW_FLASH_OFFSET}")."
		exit 1
	fi
}

mk_package() {
	local f fw lic py pip
	local out="${IPL_OUTPUT_DIR}"

	echo '|============================================|'
	echo '|          Install the IPL package           |'
	echo '|============================================|'
	fw="$(fetch_file "${PCIE_FW_URL}" "${PCIE_FW_SHA256}" "rcar_gen4_pcie.bin")" || exit 1
	lic="$(fetch_file "${PCIE_FW_LIC_URL}" "${PCIE_FW_LIC_SHA256}" "LICENCE.r8a779g_pcie_phy")" || exit 1
	py="$(fetch_file "${PYTHON_EMBED_URL}" "${PYTHON_EMBED_SHA256}" "$(basename "${PYTHON_EMBED_URL}")")" || exit 1
	pip="$(fetch_file "${GET_PIP_URL}" "${GET_PIP_SHA256}" "get-pip.py")" || exit 1

	install -d "${out}/License/u-boot_licenses" "${out}/python-embed-amd64"

	for f in "${IPL_DIR}"/burning/*; do
		install -m 644 "${f}" "${out}/"
	done
	chmod 755 "${out}/run.sh"
	install -m 644 "${UBOOT_BUILD_DIR}/flash.bin" "${out}/"
	install -m 644 "${fw}" "${out}/rcar_gen4_pcie.bin"

	install -m 644 "${IPL_DIR}/License/LICENSE.MIT" "${IPL_DIR}/License/LICENSE.BSD-3-Clause" "${out}/License/"
	install -m 644 "${lic}" "${out}/License/LICENCE.r8a779g_pcie_phy"
	install -m 644 "${UBOOT_SRC_DIR}/Licenses/README" "${out}/License/u-boot_licenses/"
	install -m 644 "${IPL_DIR}/License/generic_GPL-2.0-or-later" "${out}/License/u-boot_licenses/"
	printf 'LICENSE: GPL-2.0-or-later\nPR: r0\nPV: %s\n' "${UBOOT_PV}" > "${out}/License/u-boot_licenses/recipeinfo"

	# run.bat needs the embedded Python on Windows, and pip to install pyserial
	# into it, which is what "import site" enables.
	unzip -qo "${py}" -d "${out}/python-embed-amd64" || exit 1
	sed -i -e 's/.*import site/import site/' "${out}"/python-embed-amd64/*._pth
	install -m 644 "${pip}" "${out}/python-embed-amd64/get-pip.py"

	echo ""
	ls -l "${out}/flash.bin" "${out}/rcar_gen4_pcie.bin"
	echo "IPL package: ${out}"
}

mk_clean() {
	if [ -d "${UBOOT_BUILD_DIR}" ]; then
		echo "Removing ${UBOOT_BUILD_DIR}"
		rm -rf "${UBOOT_BUILD_DIR}"
	fi
	if [ -d "${IPL_OUTPUT_DIR}" ]; then
		echo "Removing ${IPL_OUTPUT_DIR}"
		rm -rf "${IPL_OUTPUT_DIR}"
	fi
}

# ---- Main ----
cmd="${1:-all}"
echo "Starting the IPL build '${cmd}' (PLATFORM=${PLATFORM})"
echo "Source directory: ${UBOOT_SRC_DIR}"
echo "Output directory: ${IPL_OUTPUT_DIR}"

case "${cmd}" in
	'fetch')
		fetch_src
		;;
	'all'|'image')
		mk_uboot
		mk_package
		;;
	'clean')
		mk_clean
		;;
	*)
		show_help
		;;
esac

exit 0
