#!/bin/bash
#
# Build OP-TEE (BL32) for the X5H Ironhide boot chain (apu-tee-ironhide).
# Flash the .srec separately. It is not part of the fitImage.
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

# Needs python3-pycryptodome, python3-pyelftools, and python3-cryptography
# from apt. rcar-driver.sh preflight does not check them, so a missing one
# fails here. The Debian pycryptodome package provides Cryptodome.
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

	refuse_dirty_tree "${OPTEE_SRC_DIR}" "optee_os" "${OPTEE_SRCREV}" || exit 1
	echo "Checking out optee_os at ${OPTEE_SRCREV}"
	git -C "${OPTEE_SRC_DIR}" checkout -q "${OPTEE_SRCREV}" || exit 1
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
	# CFG_INSECURE=y is the development image, which prints "This OP-TEE
	# configuration might be insecure" at boot. OPTEE_CFG_INSECURE=n drops
	# that development configuration. It does not sign with production keys.
	# cd, not make -C: "-e MAKEFLAGS=" clears the directory sub-makes inherit.
	# Unset ARCH and CROSS_COMPILE: main_build.sh exports them for the kernel,
	# and "make -e" would let ARCH=arm64 override OP-TEE's ARCH=arm.
	OPTEE_CFG_INSECURE="${OPTEE_CFG_INSECURE:-y}"
	case "${OPTEE_CFG_INSECURE}" in
		y|n) ;;
		*)
			echo "Error: OPTEE_CFG_INSECURE must be y or n (got '${OPTEE_CFG_INSECURE}')."
			exit 1
			;;
	esac
	echo "OP-TEE CFG_INSECURE=${OPTEE_CFG_INSECURE}"
	(cd "${OPTEE_SRC_DIR}" && unset ARCH CROSS_COMPILE && make -e MAKEFLAGS= \
		PLATFORM="${OPTEE_PLATFORM}" CFG_ARM64_core=y \
		CFG_INSECURE="${OPTEE_CFG_INSECURE}" \
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
