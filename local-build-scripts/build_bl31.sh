#!/bin/bash
#
# Build the ARM Trusted Firmware BL31 blob that meta-sparrow-hawk deploys with
# the arm-trusted-firmware recipe (bl31-sparrow-hawk.bin).
#
# Every FIT configuration loads BL31 through "loadables", so the fitImage
# cannot be assembled without it.
#
set -uo pipefail

source ./config.ini
source ./common.sh

# if PLATFORM is already exported from main_build.sh, keep it
if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

if [ "${PLATFORM}" != "RCAR-V4H-SH" ]; then
	echo "Error: the bl31 target is only supported for PLATFORM=RCAR-V4H-SH"
	echo "       (current PLATFORM=${PLATFORM})."
	exit 1
fi

TFA_URL="${TFA_URL:-https://github.com/ARM-software/arm-trusted-firmware.git}"
TFA_SRCREV="${TFA_SRCREV:-1d5aa939bc8d3d892e2ed9945fa50e36a1a924cc}"
# TFA_SRC_DIR and TFA_OUTPUT_DIR come from common.sh.
BL31_NAME="bl31-sparrow-hawk"

# From the recipe: PLATFORM:rcar-gen4, BUILD_OPT:rcar-gen4 and the
# "sparrow_hawk_r8a779g3[default]" varflag. Kept verbatim so the blob matches
# the one the recipe produces, apart from the compiler version.
TFA_PLAT="rcar_gen4"
TFA_BUILD_OPT=(bl31 rcar_srecord)
TFA_CLEAN_OPT=(clean_srecord)
TFA_OPT=(
	LSI=V4H
	CTX_INCLUDE_AARCH32_REGS=0
	MBEDTLS_COMMON_MK=1
	PTP_NONSECURE_ACCESS=1
	LOG_LEVEL=20
	DEBUG=0
	ENABLE_ASSERTIONS=0
	E=0
)

export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

# TF-A is a standalone application whose makefiles set up their own flags; the
# recipe unexports these for the same reason, and inheriting the host's would
# break the build.
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS AS LD

fetch_src() {
	if [ ! -d "${TFA_SRC_DIR}/.git" ]; then
		echo "Cloning ${TFA_URL} -> ${TFA_SRC_DIR}"
		mkdir -p "$(dirname "${TFA_SRC_DIR}")"
		git clone -q "${TFA_URL}" "${TFA_SRC_DIR}" || exit 1
	fi

	if ! git -C "${TFA_SRC_DIR}" cat-file -e "${TFA_SRCREV}^{commit}" 2>/dev/null; then
		git -C "${TFA_SRC_DIR}" fetch -q --all --tags || exit 1
	fi

	echo "Checking out arm-trusted-firmware at ${TFA_SRCREV}"
	git -C "${TFA_SRC_DIR}" checkout -q -f "${TFA_SRCREV}" || exit 1
	git -C "${TFA_SRC_DIR}" clean -qxfd || exit 1
}

# Only re-fetch when the tree is missing or on another revision, so that a
# rebuild does not throw away an existing checkout.
ensure_src() {
	local have
	have="$(git -C "${TFA_SRC_DIR}" rev-parse HEAD 2>/dev/null)"
	if [ "${have}" = "${TFA_SRCREV}" ]; then
		echo "arm-trusted-firmware: already at ${TFA_SRCREV}"
		return 0
	fi
	fetch_src
}

mk_build() {
	ensure_src

	echo '|============================================|'
	echo '|          Build ARM Trusted Firmware        |'
	echo '|============================================|'
	# Same three invocations as the recipe's do_ipl_compile().
	make -C "${TFA_SRC_DIR}" distclean >/dev/null || exit 1
	make -C "${TFA_SRC_DIR}" "${TFA_CLEAN_OPT[@]}" \
		PLAT="${TFA_PLAT}" SPD=none MBEDTLS_COMMON_MK=1 "${TFA_OPT[@]}" >/dev/null || exit 1
	make -C "${TFA_SRC_DIR}" -j"$(nproc)" "${TFA_BUILD_OPT[@]}" \
		PLAT="${TFA_PLAT}" SPD=none MBEDTLS_COMMON_MK=1 "${TFA_OPT[@]}" || exit 1

	local rel="${TFA_SRC_DIR}/build/${TFA_PLAT}/release"
	if [ ! -f "${rel}/bl31.bin" ]; then
		echo "Error: ${rel}/bl31.bin was not produced."
		exit 1
	fi

	echo '|============================================|'
	echo '|            Install BL31 artifacts          |'
	echo '|============================================|'
	install -d "${TFA_OUTPUT_DIR}"
	install -m 644 "${rel}/bl31/bl31.elf" "${TFA_OUTPUT_DIR}/${BL31_NAME}.elf"
	install -m 644 "${rel}/bl31.bin"      "${TFA_OUTPUT_DIR}/${BL31_NAME}.bin"
	install -m 644 "${rel}/bl31.srec"     "${TFA_OUTPUT_DIR}/${BL31_NAME}.srec"
	echo "  ${BL31_NAME}.elf"
	echo "  ${BL31_NAME}.bin"
	echo "  ${BL31_NAME}.srec"
	echo ""
	ls -l "${TFA_OUTPUT_DIR}/${BL31_NAME}.bin"
}

mk_clean() {
	if [ -d "${TFA_SRC_DIR}" ]; then
		echo "Cleaning ${TFA_SRC_DIR}"
		make -C "${TFA_SRC_DIR}" distclean >/dev/null 2>&1 || true
	fi
	if [ -d "${TFA_OUTPUT_DIR}" ]; then
		echo "Removing ${TFA_OUTPUT_DIR}"
		rm -rf "${TFA_OUTPUT_DIR}"
	fi
}

# ---- Main ----
cmd="${1:-all}"
echo "Starting the BL31 build '${cmd}' (PLATFORM=${PLATFORM})"
echo "Source directory: ${TFA_SRC_DIR}"
echo "Output directory: ${TFA_OUTPUT_DIR}"

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
