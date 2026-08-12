#!/bin/bash
#
# Build the out-of-tree kernel modules that meta-sparrow-hawk ships as
# separate recipes (kernel-module-cmemdrv, kernel-module-qos)
#
# Sources are cloned from the upstream repositories at the revisions pinned
# by the recipes and patched with the same patches, kept under patches/.
#
set -uo pipefail

source ./config.ini
source ./common.sh

# if PLATFORM is already exported from main_build.sh, keep it
if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

if [ "${PLATFORM}" != "RCAR-V4H-SH" ]; then
	echo "Error: the ext-modules target is only supported for PLATFORM=RCAR-V4H-SH"
	echo "       (current PLATFORM=${PLATFORM})."
	exit 1
fi

ensure_kernel_dir || exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/patches"
# EXT_MODULES_SRC_DIR comes from common.sh.

CMEM_URL="${CMEM_URL:-https://github.com/renesas-rcar/cmem.git}"
CMEM_SRCREV="${CMEM_SRCREV:-e67f473cddb089f71abead8bf18f618d42f515da}"
CMEM_BSIZE="${CMEM_BSIZE:-0x20000000}"
QOS_URL="${QOS_URL:-https://github.com/renesas-rcar/qos_drv.git}"
QOS_SRCREV="${QOS_SRCREV:-72a861aab57e0529b0f24ea2febdaa7afce52fda}"
GLES_URL="${GLES_URL:-https://github.com/rcar-community/rcar-gfx/raw/daf8608d920fbf1d179abab8a52cbc0f022c98a1/gfxdrv/GSX_KM_V4H_SparrowHawk.tar.bz2}"
GLES_SHA256="${GLES_SHA256:-f7a4dee2ed239970425728a48f9c4ed1918e1385e23547635811983a95f9306d}"
GLES_FW_URL="${GLES_FW_URL:-https://github.com/rcar-community/rcar-gfx/raw/daf8608d920fbf1d179abab8a52cbc0f022c98a1/opengl/r8a779g3_linux_gsx_binaries_gles.tar.bz2}"
GLES_FW_SHA256="${GLES_FW_SHA256:-6da8b5ca8d09ea7690f61340a5c5fbe8a13fb810e99be926969a0d5602591293}"

# "<name>|<git|tar>|<url>|<srcrev or sha256>|<build subdir>|<.ko glob>|<install subdir>"
# The build subdir and the .ko glob are relative to the module source
# directory. The install subdir mirrors where the recipes install the module.
EXT_MODULES=(
	"cmem|git|${CMEM_URL}|${CMEM_SRCREV}|.|*.ko|updates"
	"qos|git|${QOS_URL}|${QOS_SRCREV}|qos-module/files/qos/drv|qos-module/files/qos/drv/*.ko|extra"
	"gles|tar|${GLES_URL}|${GLES_SHA256}|rogue_km/build/linux/r8a779g_linux|rogue_km/pvrsrvkm.ko|extra"
)

# The environment the recipes set through include/rcar-bsp-modules-common.inc.
# cmem's Makefile uses KERNEL_SRC, qos' Makefile uses KERNELSRC.
export KERNELSRC="${KERNEL_DIR}"
export KERNELDIR="${KERNEL_DIR}"
export KERNEL_SRC="${KERNEL_DIR}"
export LDFLAGS=""
export CP="cp"

# Must match build_kernel.sh: without it scripts/setlocalversion appends a '+'
# and the modules would land in a different /lib/modules/<release> directory
# than the in-tree ones.
export LOCALVERSION=""

kernel_is_built() {
	if [ ! -f "${KERNEL_DIR}/Module.symvers" ]; then
		echo "Error: ${KERNEL_DIR}/Module.symvers not found."
		echo "       External modules link against the kernel build, so build it"
		echo "       first: ./main_build.sh kernel modules"
		exit 1
	fi
}

kernel_release() {
	make -s -C "${KERNEL_DIR}" kernelrelease 2>/dev/null | tail -1
}

# Apply the patches listed in patches/<name>/series, in that order. The order
# matters and is not alphabetical, it mirrors the recipe's SRC_URI.
apply_patches() {
	local name="$1" dir="$2"
	local series="${PATCH_DIR}/${name}/series"

	if [ ! -f "${series}" ]; then
		return 0
	fi

	local p
	while read -r p; do
		[ -z "${p}" ] && continue
		case "${p}" in \#*) continue;; esac
		if ! patch -p1 -d "${dir}" --no-backup-if-mismatch -i "${PATCH_DIR}/${name}/${p}" >/dev/null; then
			echo "Error: failed to apply ${name}/${p}"
			exit 1
		fi
		echo "  applied ${p}"
	done < "${series}"
}

fetch_git() {
	local name="$1" url="$2" rev="$3"
	local dir="${EXT_MODULES_SRC_DIR}/${name}"

	if [ ! -d "${dir}/.git" ]; then
		echo "Cloning ${url} -> ${dir}"
		mkdir -p "${EXT_MODULES_SRC_DIR}"
		git clone -q "${url}" "${dir}" || exit 1
	fi

	if ! git -C "${dir}" cat-file -e "${rev}^{commit}" 2>/dev/null; then
		git -C "${dir}" fetch -q --all --tags || exit 1
	fi

	echo "Checking out ${name} at ${rev}"
	git -C "${dir}" checkout -q -f "${rev}" || exit 1
	git -C "${dir}" clean -qxfd || exit 1
	apply_patches "${name}" "${dir}"
}

# Fetch a tarball, verify its checksum, and extract it into the source directory.
fetch_tar() {
	local name="$1" url="$2" sha="$3"
	local dir="${EXT_MODULES_SRC_DIR}/${name}"
	local tarball

	tarball="$(fetch_tarball "${url}" "${sha}")" || exit 1

	echo "Extracting ${name}"
	rm -rf "${dir}"
	mkdir -p "${dir}"
	tar xf "${tarball}" -C "${dir}" || exit 1
	echo "${sha}" > "${dir}/.srcrev"
	apply_patches "${name}" "${dir}"
}

# Download and verify a tarball into the downloads cache, echoing its path.
fetch_tarball() {
	local url="$1" sha="$2"
	local dl="${EXT_MODULES_SRC_DIR}/downloads"
	local tarball="${dl}/$(basename "${url%%;*}")"

	mkdir -p "${dl}"
	if [ ! -f "${tarball}" ] || [ "$(sha256sum "${tarball}" | cut -d' ' -f1)" != "${sha}" ]; then
		echo "Downloading ${url}" >&2
		curl -fsSL -o "${tarball}" "${url}" || return 1
	fi

	local got
	got="$(sha256sum "${tarball}" | cut -d' ' -f1)"
	if [ "${got}" != "${sha}" ]; then
		echo "Error: checksum mismatch for ${tarball}" >&2
		echo "       expected ${sha}" >&2
		echo "       got      ${got}" >&2
		return 1
	fi
	echo "${tarball}"
}

fetch_one() {
	local name="$1" type="$2" url="$3" rev="$4"
	case "${type}" in
		git) fetch_git "${name}" "${url}" "${rev}" ;;
		tar) fetch_tar "${name}" "${url}" "${rev}" ;;
		*)   echo "Error: unknown source type '${type}' for ${name}"; exit 1 ;;
	esac
}

# Only re-fetch when the source is missing or sits on a different revision, so
# that "all" can be re-run without throwing away an already patched tree.
ensure_src() {
	local name="$1" type="$2" url="$3" rev="$4"
	local dir="${EXT_MODULES_SRC_DIR}/${name}"
	local have=""

	case "${type}" in
		git) have="$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" ;;
		tar) have="$(cat "${dir}/.srcrev" 2>/dev/null)" ;;
	esac

	if [ -n "${have}" ] && [ "${have}" = "${rev}" ]; then
		echo "${name}: already at ${rev}"
		return 0
	fi
	fetch_one "${name}" "${type}" "${url}" "${rev}"
}

mk_fetch() {
	local entry name type url rev
	for entry in "${EXT_MODULES[@]}"; do
		IFS='|' read -r name type url rev _ _ _ <<<"${entry}"
		fetch_one "${name}" "${type}" "${url}" "${rev}"
	done
}

mk_build() {
	kernel_is_built
	local entry name type url rev sub
	echo '|============================================|'
	echo '|        Build out-of-tree modules           |'
	echo '|============================================|'
	for entry in "${EXT_MODULES[@]}"; do
		IFS='|' read -r name type url rev sub _ _ <<<"${entry}"
		ensure_src "${name}" "${type}" "${url}" "${rev}"
		echo "--- building ${name}"
		# The GPU driver's makefiles pick up host CFLAGS and choke on them,
		# which is why the recipe unsets them before it runs make.
		( unset CFLAGS CPPFLAGS CXXFLAGS
		  make -C "${EXT_MODULES_SRC_DIR}/${name}/${sub}" -j"$(nproc)" ) || exit 1
	done
}

mk_install() {
	if [ -z "${KERNEL_MODULES_OUTPUT_DIR:-}" ]; then
		echo "KERNEL_MODULES_OUTPUT_DIR is not set in config.ini."
		exit 1
	fi

	mk_build

	local kver dest
	kver="$(kernel_release)"
	if [ -z "${kver}" ]; then
		echo "Error: could not determine the kernel release from ${KERNEL_DIR}"
		exit 1
	fi
	dest="${KERNEL_MODULES_OUTPUT_DIR}"

	echo '|============================================|'
	echo '|       Install out-of-tree modules          |'
	echo '|============================================|'
	# Modules go under usr/lib/modules to match build_kernel.sh and the
	# usrmerge rootfs on the target, where /lib is a symlink to /usr/lib.
	local entry name koglob instdir ko
	for entry in "${EXT_MODULES[@]}"; do
		IFS='|' read -r name _ _ _ _ koglob instdir <<<"${entry}"
		for ko in "${EXT_MODULES_SRC_DIR}/${name}/"${koglob}; do
			[ -e "${ko}" ] || continue
			install -Dm 644 "${ko}" "${dest}/usr/lib/modules/${kver}/${instdir}/$(basename "${ko}")"
			echo "  ${instdir}/$(basename "${ko}")"
		done
	done

	# Module configuration
	install -d "${dest}/usr/lib/modules-load.d" "${dest}/usr/lib/modprobe.d"
	echo "cmemdrv" > "${dest}/usr/lib/modules-load.d/cmemdrv.conf"
	echo "options cmemdrv bsize=${CMEM_BSIZE}" > "${dest}/usr/lib/modprobe.d/cmemdrv.conf"
	echo "  usr/lib/modules-load.d/cmemdrv.conf"
	echo "  usr/lib/modprobe.d/cmemdrv.conf"

	# Auto load pvrsrvkm so that the GPU driver is available for GLES applications without
	# having to modprobe it manually.
	echo "pvrsrvkm" > "${dest}/usr/lib/modules-load.d/pvrsrvkm.conf"
	echo "  usr/lib/modules-load.d/pvrsrvkm.conf"

	# pvrsrvkm refuses to initialise unless the GPU firmware comes from the
	# same DDK release: it checks the firmware header and bails out with
	# "KM and FW version mismatch".
	local fwtar fwtmp
	if fwtar="$(fetch_tarball "${GLES_FW_URL}" "${GLES_FW_SHA256}")"; then
		fwtmp="$(mktemp -d)"
		if tar xf "${fwtar}" -C "${fwtmp}" rogue/lib/firmware 2>/dev/null; then
			local fw
			for fw in "${fwtmp}"/rogue/lib/firmware/*; do
				[ -f "${fw}" ] || continue
				install -Dm 644 "${fw}" "${dest}/usr/lib/firmware/$(basename "${fw}")"
				echo "  usr/lib/firmware/$(basename "${fw}")"
			done
		else
			echo "Warning: no rogue/lib/firmware in ${fwtar}, GPU firmware not installed"
		fi
		rm -rf "${fwtmp}"
	else
		echo "Warning: could not fetch the GPU firmware; pvrsrvkm will fail to"
		echo "         initialise unless a matching rgx.fw is already installed."
	fi

	# Headers shipped by the -dev packages of the two recipes.
	local hdr
	for hdr in \
		"qos/qos-module/files/qos/drv/qos_public_common.h|usr/include/qos_public_common.h" \
		"cmem/cmemdrv.h|usr/include/linux/cmemdrv.h"
	do
		if [ -f "${EXT_MODULES_SRC_DIR}/${hdr%%|*}" ]; then
			install -Dm 644 "${EXT_MODULES_SRC_DIR}/${hdr%%|*}" "${dest}/${hdr##*|}"
			echo "  ${hdr##*|}"
		fi
	done

	echo "Installed out-of-tree modules to ${dest}"
}

mk_clean() {
	local entry name sub
	for entry in "${EXT_MODULES[@]}"; do
		IFS='|' read -r name _ _ _ sub _ _ <<<"${entry}"
		if [ -d "${EXT_MODULES_SRC_DIR}/${name}/${sub}" ]; then
			echo "Cleaning ${name}"
			( unset CFLAGS CPPFLAGS CXXFLAGS
			  make -C "${EXT_MODULES_SRC_DIR}/${name}/${sub}" clean ) || true
		fi
	done
}

# ---- Main ----
cmd="${1:-all}"
echo "Starting the out-of-tree module build '${cmd}' (PLATFORM=${PLATFORM})"
echo "Source directory: ${EXT_MODULES_SRC_DIR}"

case "${cmd}" in
	'fetch')   mk_fetch   ;;
	'all')     mk_build   ;;
	'install') mk_install ;;
	'clean')   mk_clean   ;;
	*)         show_help  ;;
esac

exit 0
