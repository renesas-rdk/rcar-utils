#!/bin/bash
#
# Build U-Boot for the R-Car V4H Sparrow Hawk: pinned revision, the patches,
# the defconfig plus the config fragments, an empty .scmversion (version
# "2026.10") and prefix maps in CC that hide the build paths.
#
# flash.bin (SPL + U-Boot proper, assembled by binman) and the other outputs
# are copied to UBOOT_OUTPUT_DIR. Build only: nothing is written to the board
# flash.
#
# UBOOT_SRC_DIR is owned by this script: it only uses a directory that is new,
# empty, or a clone it made itself (mark in its local git config), and
# resets that clone (checkout -f, clean -xfd) on every build.
#
set -uo pipefail

source ./config.ini
source ./common.sh

# PLAT overrides PLATFORM, as in main_build.sh
if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

UBOOT_URL="${UBOOT_URL:-https://git.u-boot-project.org/u-boot/u-boot.git}"
UBOOT_SRCREV="${UBOOT_SRCREV:-5508406582f6f7120dce0c4b3059819a41788db2}"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-r8a779g3_sparrowhawk_defconfig}"
# UBOOT_SRC_DIR, UBOOT_BUILD_DIR and UBOOT_OUTPUT_DIR come from common.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Patches, fragments and env.
PATCH_DIR="${SCRIPT_DIR}/patches/u-boot"
# The env file is copied here, where CONFIG_ENV_SOURCE_FILE finds it.
ENV_FILE="board/renesas/sparrowhawk/sparrowhawk.env"
# Fragments in merge order.
FRAGMENTS=(nfs_cmd.cfg mmc_boot.cfg preboot.cfg env_source_file.cfg)
# Right-hand side of the prefix maps.
# Update it together with UBOOT_SRCREV.
DEBUG_PREFIX="/usr/src/debug/u-boot/v2026.10+git"
# Files copied from the build directory to UBOOT_OUTPUT_DIR (plus u-boot.config).
ARTIFACTS=(flash.bin u-boot.bin u-boot-elf.srec u-boot-initial-env)
# Marks the clone and the build directory as created by this script.
MANAGED_KEY="rcar-utils.managed"
BUILD_MARK=".rcar-utils-uboot-build"

export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

# U-Boot sets up its own flags; inheriting host flags would change the build.
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS GIT_DIR GIT_WORK_TREE

die() {
	echo "Error: $*"
	exit 1
}

# U-Boot on ARM64 is built with ARCH=arm, out of tree in UBOOT_BUILD_DIR.
uboot_make() {
	make -C "${UBOOT_SRC_DIR}" O="${UBOOT_BUILD_DIR}" ARCH=arm \
		CROSS_COMPILE="${CROSS_COMPILE}" "$@"
}

#-----------------------------------------------------------------------------
# Checks
#-----------------------------------------------------------------------------
# Only the Sparrow Hawk is supported.
check_platform() {
	if [ "${PLATFORM}" != "RCAR-V4H-SH" ]; then
		echo "Error: the uboot target is only supported for PLATFORM=RCAR-V4H-SH"
		die "(current PLATFORM=${PLATFORM})."
	fi
}

# True when directory $1 is $2 or lies inside it.
is_inside() {
	case "$1/" in
		"$2/"*) return 0 ;;
	esac
	return 1
}

# Die when $1 (named $2) is a directory that must never be used or removed.
refuse_protected_dir() {
	local dir="$1" name="$2" bad

	for bad in / "$(realpath -m "${HOME:-/}")" "$(realpath -m "${WORKSPACE_DIR}")" \
		"$(realpath -m "${RCAR_UTILS_DIR}")"; do
		if [ "${dir}" = "${bad}" ]; then
			die "${name}=${dir} is not allowed (/, \$HOME, WORKSPACE_DIR, rcar-utils)."
		fi
	done
}

# Die when directories $1 and $2 are the same or one is inside the other.
refuse_overlap() {
	if is_inside "$1" "$2" || is_inside "$2" "$1"; then
		die "$3 must be separate directories ($1, $2)."
	fi
}

# Normalize the three U-Boot directories and refuse unsafe or overlapping ones.
check_dirs() {
	if [ -z "${UBOOT_SRC_DIR}" ] || [ -z "${UBOOT_BUILD_DIR}" ] ||
	   [ -z "${UBOOT_OUTPUT_DIR}" ]; then
		die "UBOOT_SRC_DIR, UBOOT_BUILD_DIR and UBOOT_OUTPUT_DIR must not be empty."
	fi
	UBOOT_SRC_DIR="$(realpath -m "${UBOOT_SRC_DIR}")"
	UBOOT_BUILD_DIR="$(realpath -m "${UBOOT_BUILD_DIR}")"
	UBOOT_OUTPUT_DIR="$(realpath -m "${UBOOT_OUTPUT_DIR}")"

	refuse_protected_dir "${UBOOT_SRC_DIR}" UBOOT_SRC_DIR
	refuse_protected_dir "${UBOOT_BUILD_DIR}" UBOOT_BUILD_DIR
	refuse_protected_dir "${UBOOT_OUTPUT_DIR}" UBOOT_OUTPUT_DIR

	refuse_overlap "${UBOOT_SRC_DIR}" "${UBOOT_BUILD_DIR}" "UBOOT_SRC_DIR and UBOOT_BUILD_DIR"
	refuse_overlap "${UBOOT_SRC_DIR}" "${UBOOT_OUTPUT_DIR}" "UBOOT_SRC_DIR and UBOOT_OUTPUT_DIR"
	refuse_overlap "${UBOOT_BUILD_DIR}" "${UBOOT_OUTPUT_DIR}" \
		"UBOOT_BUILD_DIR and UBOOT_OUTPUT_DIR"
}

# Report every missing build dependency at once, with the package to install.
check_tools() {
	local missing=()
	local cmd

	for cmd in git make bison flex bc swig python3 "${CROSS_COMPILE}gcc"; do
		command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
	done
	# The prefix maps need -fcanon-prefix-map (gcc >= 13).
	if ! "${CROSS_COMPILE}gcc" -fcanon-prefix-map -E -x c /dev/null >/dev/null 2>&1; then
		missing+=("${CROSS_COMPILE}gcc>=13")
	fi
	# binman builds the libfdt Python module (swig + Python headers) and reads ELF.
	command -v python3-config >/dev/null 2>&1 || missing+=("python3-dev")
	python3 -c 'import elftools' 2>/dev/null || missing+=("python3-pyelftools")
	python3 -c 'import setuptools' 2>/dev/null || missing+=("python3-setuptools")
	[ -f /usr/include/gnutls/gnutls.h ] || missing+=("libgnutls28-dev")
	[ -f /usr/include/openssl/ssl.h ] || missing+=("libssl-dev")

	if [ "${#missing[@]}" -ne 0 ]; then
		echo "Error: missing build dependencies: ${missing[*]}"
		echo "       On Ubuntu 24.04 install them with:"
		echo "         sudo apt install bison flex bc swig python3-dev \\"
		echo "             python3-pyelftools python3-setuptools libgnutls28-dev \\"
		echo "             libssl-dev gcc-aarch64-linux-gnu"
		exit 1
	fi
}

#-----------------------------------------------------------------------------
# Source tree
#-----------------------------------------------------------------------------
# Echo new (missing or empty), managed (our clone) or foreign (anything else).
src_state() {
	if [ ! -e "${UBOOT_SRC_DIR}" ]; then
		echo new
	elif [ -d "${UBOOT_SRC_DIR}" ] && [ -z "$(ls -A "${UBOOT_SRC_DIR}")" ]; then
		echo new
	elif [ -d "${UBOOT_SRC_DIR}/.git" ] &&
	     [ "$(git -C "${UBOOT_SRC_DIR}" config --local --get "${MANAGED_KEY}")" = "true" ]; then
		echo managed
	else
		echo foreign
	fi
}

# Stop unless UBOOT_SRC_DIR is a clone made by this script.
require_managed_src() {
	if [ "$(src_state)" != "managed" ]; then
		echo "Error: ${UBOOT_SRC_DIR} is not a u-boot clone made by build_uboot.sh."
		echo "       The script resets its clone with 'git checkout -f' and"
		echo "       'git clean -xfd' on every build, so it does not touch other"
		echo "       directories. Point UBOOT_SRC_DIR to a new or empty directory."
		exit 1
	fi
}

# Create an empty repository and mark it as ours.
create_repo() {
	echo "Creating ${UBOOT_SRC_DIR}"
	mkdir -p "${UBOOT_SRC_DIR}" || die "cannot create ${UBOOT_SRC_DIR}"
	git -C "${UBOOT_SRC_DIR}" init -q || die "git init failed"
	git -C "${UBOOT_SRC_DIR}" config --local "${MANAGED_KEY}" true || die "git config failed"
}

# Get UBOOT_SRCREV only (shallow); fall back to a full fetch if the server refuses.
fetch_rev() {
	local repo="${UBOOT_SRC_DIR}"

	if git -C "${repo}" cat-file -e "${UBOOT_SRCREV}^{commit}" 2>/dev/null; then
		return 0
	fi
	echo "Fetching ${UBOOT_SRCREV} from ${UBOOT_URL}"
	if ! git -C "${repo}" fetch -q --depth 1 "${UBOOT_URL}" "${UBOOT_SRCREV}"; then
		git -C "${repo}" fetch -q --tags "${UBOOT_URL}" ||
			die "fetch from ${UBOOT_URL} failed"
	fi
}

# Discard local changes in our clone: pinned revision, no untracked files.
reset_tree() {
	require_managed_src
	git -C "${UBOOT_SRC_DIR}" checkout -q -f "${UBOOT_SRCREV}" ||
		die "checkout ${UBOOT_SRCREV} failed"
	git -C "${UBOOT_SRC_DIR}" clean -qxfd || die "git clean failed"
}

# Make UBOOT_SRC_DIR a clean checkout of UBOOT_SRCREV (clone it if needed).
ensure_src() {
	case "$(src_state)" in
		new)
			create_repo
			;;
		managed)
			echo "u-boot: using ${UBOOT_SRC_DIR}, resetting it to ${UBOOT_SRCREV}"
			;;
		*)
			require_managed_src
			;;
	esac
	fetch_rev
	reset_tree
}

# Apply patches/u-boot/series in order, as working-tree changes (no commits).
apply_patches() {
	local p
	while read -r p || [ -n "${p}" ]; do
		[ -z "${p}" ] && continue
		case "${p}" in \#*) continue;; esac
		git -C "${UBOOT_SRC_DIR}" apply "${PATCH_DIR}/${p}" || die "failed to apply ${p}"
		echo "  applied ${p}"
	done < "${PATCH_DIR}/series"
}

# Install sparrowhawk.env where CONFIG_ENV_SOURCE_FILE="sparrowhawk" finds it.
add_env_file() {
	local env
	env="${PATCH_DIR}/sparrowhawk.env"
	install -m 644 "${env}" "${UBOOT_SRC_DIR}/${ENV_FILE}" || die "cannot install ${env}"
	echo "  env: ${env}"
}

#-----------------------------------------------------------------------------
# Build
#-----------------------------------------------------------------------------
# Start from an empty build dir; only a dir marked as ours is removed.
prepare_build_dir() {
	local dir="${UBOOT_BUILD_DIR}"

	if [ -d "${dir}" ] && [ -n "$(ls -A "${dir}")" ]; then
		if [ ! -f "${dir}/${BUILD_MARK}" ]; then
			die "${dir} is not empty and was not created by build_uboot.sh."
		fi
		rm -rf "${dir:?}"
	fi
	mkdir -p "${dir}" || die "cannot create ${dir}"
	touch "${dir}/${BUILD_MARK}" || die "cannot write ${dir}/${BUILD_MARK}"
}

# Fresh build dir: defconfig, merge the fragments, olddefconfig.
configure() {
	local merge_config="${UBOOT_SRC_DIR}/scripts/kconfig/merge_config.sh"
	local frags=()
	local f

	for f in "${FRAGMENTS[@]}"; do
		frags+=("${PATCH_DIR}/${f}")
	done

	prepare_build_dir
	uboot_make "${UBOOT_DEFCONFIG}" || die "${UBOOT_DEFCONFIG} failed"
	# merge_config.sh writes .config in the current directory.
	(cd "${UBOOT_BUILD_DIR}" && "${merge_config}" -m .config "${frags[@]}") ||
		die "merge_config.sh failed"
	uboot_make olddefconfig || die "olddefconfig failed"
}

# Compiler plus the prefix maps that hide the build paths.
uboot_cc() {
	local cc="${CROSS_COMPILE}gcc -fcanon-prefix-map"
	local dir

	for dir in "${UBOOT_SRC_DIR}" "${UBOOT_BUILD_DIR}"; do
		cc="${cc} -fmacro-prefix-map=${dir}=${DEBUG_PREFIX}"
		cc="${cc} -fdebug-prefix-map=${dir}=${DEBUG_PREFIX}"
	done
	echo "${cc}"
}

# make all and the default env text, like do_compile.
build() {
	# An empty .scmversion keeps the version "2026.10".
	: > "${UBOOT_SRC_DIR}/.scmversion" || die "cannot write .scmversion"
	: > "${UBOOT_BUILD_DIR}/.scmversion" || die "cannot write .scmversion"

	echo '|============================================|'
	echo '|                Build U-Boot                |'
	echo '|============================================|'
	uboot_make CC="$(uboot_cc)" -j"$(nproc)" all || die "U-Boot build failed"
	uboot_make CC="$(uboot_cc)" u-boot-initial-env || die "u-boot-initial-env failed"
}

#-----------------------------------------------------------------------------
# Output
#-----------------------------------------------------------------------------
# Remove only the files this script installs from UBOOT_OUTPUT_DIR.
remove_artifacts() {
	local f
	for f in "${ARTIFACTS[@]}" u-boot.config; do
		rm -f "${UBOOT_OUTPUT_DIR:?}/${f}" || die "cannot remove ${UBOOT_OUTPUT_DIR}/${f}"
	done
}

# Copy the outputs and the final .config (as u-boot.config) to UBOOT_OUTPUT_DIR.
install_artifacts() {
	local f

	echo '|============================================|'
	echo '|           Install U-Boot artifacts         |'
	echo '|============================================|'
	install -d "${UBOOT_OUTPUT_DIR}" || die "cannot create ${UBOOT_OUTPUT_DIR}"
	remove_artifacts
	for f in "${ARTIFACTS[@]}"; do
		[ -f "${UBOOT_BUILD_DIR}/${f}" ] || die "${UBOOT_BUILD_DIR}/${f} was not produced."
		install -m 644 "${UBOOT_BUILD_DIR}/${f}" "${UBOOT_OUTPUT_DIR}/${f}" ||
			die "cannot install ${f}"
		echo "  ${f}"
	done
	install -m 644 "${UBOOT_BUILD_DIR}/.config" "${UBOOT_OUTPUT_DIR}/u-boot.config" ||
		die "cannot install u-boot.config"
	echo "  u-boot.config"
	echo ""
	ls -l "${UBOOT_OUTPUT_DIR}/flash.bin"
}

#-----------------------------------------------------------------------------
# Sub-commands
#-----------------------------------------------------------------------------
# Whole build: source, patches, env, configure, compile, install.
mk_build() {
	check_tools
	ensure_src
	apply_patches
	add_env_file
	configure
	build
	install_artifacts
}

# Reset our clone, remove our build dir and our files in the output dir.
mk_clean() {
	if [ "$(src_state)" = "managed" ]; then
		echo "Resetting ${UBOOT_SRC_DIR}"
		reset_tree
	elif [ -e "${UBOOT_SRC_DIR}" ]; then
		echo "Leaving ${UBOOT_SRC_DIR} untouched (not created by build_uboot.sh)"
	fi

	if [ -f "${UBOOT_BUILD_DIR}/${BUILD_MARK}" ]; then
		echo "Removing ${UBOOT_BUILD_DIR}"
		rm -rf "${UBOOT_BUILD_DIR:?}"
	elif [ -e "${UBOOT_BUILD_DIR}" ]; then
		echo "Leaving ${UBOOT_BUILD_DIR} untouched (not created by build_uboot.sh)"
	fi

	if [ -d "${UBOOT_OUTPUT_DIR}" ]; then
		echo "Removing the U-Boot artifacts from ${UBOOT_OUTPUT_DIR}"
		remove_artifacts
		rmdir --ignore-fail-on-non-empty "${UBOOT_OUTPUT_DIR}"
	fi
}

main() {
	local cmd="${1:-all}"

	check_platform
	check_dirs
	echo "Starting the U-Boot build '${cmd}' (PLATFORM=${PLATFORM})"
	echo "Source directory: ${UBOOT_SRC_DIR}"
	echo "Build directory:  ${UBOOT_BUILD_DIR}"
	echo "Output directory: ${UBOOT_OUTPUT_DIR}"

	case "${cmd}" in
		'fetch')
			ensure_src
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
}

main "$@"
exit 0
