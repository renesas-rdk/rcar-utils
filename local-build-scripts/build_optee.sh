#!/bin/bash
#
# Build OP-TEE OS (BL32) for the X5H Ironhide boot chain (apu-tee-ironhide.bin).
#
# NOT present in the upstream V4H Sparrow Hawk repo this was ported from -
# that board's boot chain does not use OP-TEE. X5H's real chain does
# (BL31 -> BL32/OP-TEE -> BL33/U-Boot), and like bl31, it is flashed as a
# separate raw .srec, not loaded via the fitImage.
#
# Fully open source (BSD-2/3-Clause) - verified end-to-end in
# 06_Optee_Build_GCC_X5H.md in the rcar-x5h workspace.
#
set -uo pipefail

source ./config.ini
source ./common.sh

if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

if [ "${PLATFORM}" != "RCAR-X5H-IRONHIDE" ]; then
	echo "Error: the optee target is only supported for PLATFORM=RCAR-X5H-IRONHIDE"
	echo "       (current PLATFORM=${PLATFORM})."
	exit 1
fi

OPTEE_URL="${OPTEE_URL:-https://github.com/renesas-rcar/optee_os.git}"
OPTEE_SRCREV="${OPTEE_SRCREV:-134a538a93f8bdf4d6b068430f7cb38036fa7d33}"
# OPTEE_SRC_DIR and OPTEE_OUTPUT_DIR come from common.sh.
OPTEE_NAME="apu-tee-ironhide"
OPTEE_PLATFORM="rcar_gen5"

# Requires python3-pycryptodome, python3-pyelftools, python3-cryptography
# (apt packages - pip was broken on the real build server due to a mirror
# issue missing libexpat1-dev; the apt packages work and are what preflight
# checks for). The Debian pycryptodome package provides the "Cryptodome"
# module name, not "Crypto" - this build does not hit that distinction.
export CROSS_COMPILE64="${CROSS_COMPILE64:-aarch64-linux-gnu-}"
export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1

fetch_src() {
	if [ ! -d "${OPTEE_SRC_DIR}/.git" ]; then
		echo "Cloning ${OPTEE_URL} -> ${OPTEE_SRC_DIR}"
		mkdir -p "$(dirname "${OPTEE_SRC_DIR}")"
		git clone -q "${OPTEE_URL}" "${OPTEE_SRC_DIR}" || exit 1
	fi

	if ! git -C "${OPTEE_SRC_DIR}" cat-file -e "${OPTEE_SRCREV}^{commit}" 2>/dev/null; then
		git -C "${OPTEE_SRC_DIR}" fetch -q --all --tags || exit 1
	fi

	echo "Checking out optee_os at ${OPTEE_SRCREV}"
	git -C "${OPTEE_SRC_DIR}" checkout -q -f "${OPTEE_SRCREV}" || exit 1
	git -C "${OPTEE_SRC_DIR}" clean -qxfd || exit 1
}

# Only re-fetch when the tree is missing or on another revision, so that a
# rebuild does not throw away an existing checkout.
ensure_src() {
	local have
	have="$(git -C "${OPTEE_SRC_DIR}" rev-parse HEAD 2>/dev/null)"
	if [ "${have}" = "${OPTEE_SRCREV}" ]; then
		echo "optee_os: already at ${OPTEE_SRCREV}"
		return 0
	fi
	fetch_src
}

mk_build() {
	ensure_src

	echo '|============================================|'
	echo '|               Build OP-TEE OS               |'
	echo '|============================================|'
	# CFG_INSECURE=y builds the development/insecure-boot variant (no
	# production key signing) - matches what this project's real Yocto
	# build uses.
	# cd, not make -C: "-e MAKEFLAGS=" wipes the -C directory context
	# that sub-makes inherit, so the build fails outside the source tree.
	# Unset ARCH/CROSS_COMPILE (exported for the kernel by main_build.sh):
	# with "make -e" ARCH=arm64 overrides OP-TEE's own ARCH=arm.
	(cd "${OPTEE_SRC_DIR}" && unset ARCH CROSS_COMPILE && make -e MAKEFLAGS= \
		PLATFORM="${OPTEE_PLATFORM}" CFG_ARM64_core=y CFG_INSECURE=y \
		RCAR_DEBUG_LOG=0 CFG_SCIF=n -j"$(nproc)") || exit 1

	local rel="${OPTEE_SRC_DIR}/out/arm-plat-${OPTEE_PLATFORM}/core"
	if [ ! -f "${rel}/tee.bin" ]; then
		echo "Error: ${rel}/tee.bin was not produced."
		exit 1
	fi

	echo '|============================================|'
	echo '|           Install OP-TEE artifacts          |'
	echo '|============================================|'
	install -d "${OPTEE_OUTPUT_DIR}"
	install -m 644 "${rel}/tee.elf"  "${OPTEE_OUTPUT_DIR}/${OPTEE_NAME}.elf"
	install -m 644 "${rel}/tee.bin"  "${OPTEE_OUTPUT_DIR}/${OPTEE_NAME}.bin"
	install -m 644 "${rel}/tee.srec" "${OPTEE_OUTPUT_DIR}/${OPTEE_NAME}.srec"
	echo "  ${OPTEE_NAME}.elf"
	echo "  ${OPTEE_NAME}.bin"
	echo "  ${OPTEE_NAME}.srec"
	echo ""
	ls -l "${OPTEE_OUTPUT_DIR}/${OPTEE_NAME}.bin"
}

mk_clean() {
	if [ -d "${OPTEE_SRC_DIR}" ]; then
		echo "Cleaning ${OPTEE_SRC_DIR}"
		make -C "${OPTEE_SRC_DIR}" PLATFORM="${OPTEE_PLATFORM}" clean >/dev/null 2>&1 || true
	fi
	if [ -d "${OPTEE_OUTPUT_DIR}" ]; then
		echo "Removing ${OPTEE_OUTPUT_DIR}"
		rm -rf "${OPTEE_OUTPUT_DIR}"
	fi
}

# ---- Main ----
cmd="${1:-all}"
echo "Starting the OP-TEE build '${cmd}' (PLATFORM=${PLATFORM})"
echo "Source directory: ${OPTEE_SRC_DIR}"
echo "Output directory: ${OPTEE_OUTPUT_DIR}"

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
