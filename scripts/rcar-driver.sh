#!/bin/bash
#
# rcar-driver.sh - build and verify the Sparrow Hawk kernel / fitImage without a board.
#
# The product of this repo is a boot artifact for an aarch64 target, so there is
# nothing to "launch" on the build host. The closest thing to running it is:
# build, then prove the artifacts are internally consistent and would actually
# boot - the fitImage carries the kernel that was just built, every device tree
# overlay still applies to the base DTB, the module tree has a modules.dep, and
# the initramfs holds the files the boot path reaches for.
#
# Each of those checks exists because the corresponding failure is silent:
# a stale fitImage, a depmod-less modules_install and a broken overlay all
# leave the build exiting 0.
#
# Usage:
#   ./rcar-driver.sh preflight              host tools, report what is missing
#   ./rcar-driver.sh build <target> <sub>   run main_build.sh from the right cwd
#   ./rcar-driver.sh verify                 assert every artifact invariant
#   ./rcar-driver.sh smoke                  preflight + full build + verify
#   ./rcar-driver.sh info                   summarise what is currently built
#
set -uo pipefail

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ -> repo root
RCAR_UTILS_DIR="$(cd "${DRIVER_DIR}/.." && pwd)"
SCRIPTS_DIR="${RCAR_UTILS_DIR}/local-build-scripts"

# Honour the same overrides the build scripts take, so a driver run follows a
# build that was pointed somewhere else.
KERNEL_DIR="${KERNEL_DIR:-${RCAR_UTILS_DIR}/linux-sh}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${RCAR_UTILS_DIR}/workspace}"
FIT_OUTPUT_DIR="${FIT_OUTPUT_DIR:-${WORKSPACE_DIR}/fitimage}"
KERNEL_MODULES_OUTPUT_DIR="${KERNEL_MODULES_OUTPUT_DIR:-${WORKSPACE_DIR}/kernel-modules}"
TFA_SRC_DIR="${TFA_SRC_DIR:-${WORKSPACE_DIR}/arm-trusted-firmware}"
TFA_OUTPUT_DIR="${TFA_OUTPUT_DIR:-${TFA_SRC_DIR}/release}"

BOARD_DTB="r8a779g3-sparrow-hawk"

PASS=0
FAIL=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '        %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

#-----------------------------------------------------------------------------
# preflight
#-----------------------------------------------------------------------------
# depmod is the one that matters: "make modules_install" only *warns* when it
# is missing and still exits 0, so the module tree ships with no modules.dep
# and nothing modprobes on the board. It lives in /usr/sbin, which is not on a
# non-root PATH on some images.
do_preflight() {
	head_ "Host tools"
	local t
	for t in aarch64-linux-gnu-gcc make bc bison flex cpio git curl mkimage dtc fdtoverlay; do
		if command -v "$t" >/dev/null 2>&1; then
			ok "$t"
		else
			bad "$t not found"
		fi
	done

	if command -v depmod >/dev/null 2>&1 || [ -x /usr/sbin/depmod ]; then
		ok "depmod"
	else
		bad "depmod not found - 'make modules_install' will WARN and still exit 0,"
		note "leaving no modules.dep. Fix: sudo apt-get install -y kmod"
	fi

	head_ "Sources"
	if [ -f "${KERNEL_DIR}/Makefile" ] && [ -d "${KERNEL_DIR}/arch/arm64" ]; then
		ok "kernel source at ${KERNEL_DIR}"
	else
		bad "no kernel source at ${KERNEL_DIR}"
		note "The build only offers to clone it when stdin is a TTY. Non-interactively:"
		note "  git clone --single-branch --branch ubuntu/rcar-v4h-sh \\"
		note "      https://github.com/renesas-rdk/linux-sh.git ${KERNEL_DIR}"
	fi
}

#-----------------------------------------------------------------------------
# build
#-----------------------------------------------------------------------------
# main_build.sh does "source ./config.ini" and "source ./common.sh", so it only
# works with cwd = local-build-scripts. Called from anywhere else it prints
# "No such file or directory", runs on with an empty PLATFORM, and the failure
# reads like a missing file rather than a wrong directory.
do_build() {
	if [ $# -lt 2 ]; then
		echo "usage: rcar-driver.sh build <target> <sub_command>" >&2
		echo "  targets: kernel ext-modules bl31 initramfs fitimage" >&2
		return 2
	fi
	head_ "Build: $1 $2"
	( cd "${SCRIPTS_DIR}" && ./main_build.sh "$1" "$2" )
	local rc=$?
	if [ $rc -eq 0 ]; then
		ok "main_build.sh $1 $2 exited 0"
	else
		bad "main_build.sh $1 $2 exited ${rc}"
	fi
	return $rc
}

#-----------------------------------------------------------------------------
# verify
#-----------------------------------------------------------------------------
verify_kernel() {
	head_ "Kernel image"
	local img="${KERNEL_DIR}/arch/arm64/boot/Image"
	if [ ! -f "$img" ]; then
		bad "no kernel Image at ${img} (run: rcar-driver.sh build kernel all)"
		return
	fi
	# arm64 boot images carry the ASCII magic "ARM\x64" at byte offset 56.
	local magic
	magic=$(dd if="$img" bs=1 skip=56 count=4 2>/dev/null)
	if [ "$magic" = "ARMd" ]; then
		ok "Image is an arm64 kernel ($(stat -c%s "$img") bytes)"
	else
		bad "Image lacks the arm64 magic at offset 56 (got '${magic}')"
	fi

	local rel="${KERNEL_DIR}/include/config/kernel.release"
	[ -f "$rel" ] && note "release: $(cat "$rel")"
}

verify_fitimage() {
	head_ "fitImage"
	local fit="${FIT_OUTPUT_DIR}/fitImage"
	if [ ! -f "$fit" ]; then
		bad "no fitImage at ${fit} (run: rcar-driver.sh build fitimage all)"
		return
	fi

	local listing
	if ! listing=$(mkimage -l "$fit" 2>&1); then
		bad "mkimage cannot parse ${fit}"
		note "$listing"
		return
	fi
	ok "fitImage parses ($(stat -c%s "$fit") bytes)"

	# Every FIT configuration loads BL31, and boot.cmd selects the initramfs
	# configuration when the rootfs is not on eMMC/SD, so all four have to be
	# present for both boot paths to work.
	local n
	for n in kernel-1 fdt-1 atf-1 ramdisk-1 script; do
		if grep -q "($n)" <<<"$listing"; then
			ok "image node ${n}"
		else
			bad "image node ${n} missing from the fitImage"
		fi
	done

	local cfgs
	cfgs=$(grep -cE '^ Configuration ' <<<"$listing")
	if [ "$cfgs" -ge 2 ]; then
		ok "${cfgs} FIT configurations"
	else
		bad "only ${cfgs} FIT configuration(s); overlays are not exposed"
	fi

	# The trap this exists for: the kernel target and the fitimage target are
	# separate, so rebuilding the kernel leaves a fitImage carrying the
	# previous one. Nothing warns; the board just boots the old kernel.
	local tree_img="${KERNEL_DIR}/arch/arm64/boot/Image"
	if [ -f "$tree_img" ]; then
		local tree_sz fit_sz
		tree_sz=$(stat -c%s "$tree_img")
		fit_sz=$(awk '/\(kernel-1\)/{f=1} f&&/Data Size:/{print $3; exit}' <<<"$listing")
		if [ "$tree_sz" = "$fit_sz" ]; then
			ok "fitImage carries the current kernel (${tree_sz} bytes)"
		else
			bad "fitImage kernel is STALE: tree=${tree_sz} vs fit=${fit_sz}"
			note "Re-assemble it: rcar-driver.sh build fitimage image"
		fi
	fi
}

verify_overlays() {
	head_ "Device tree overlays"
	local base="${FIT_OUTPUT_DIR}/${BOARD_DTB}.dtb"
	if [ ! -f "$base" ]; then
		bad "no base DTB at ${base}"
		return
	fi
	if ! command -v fdtoverlay >/dev/null 2>&1; then
		bad "fdtoverlay not installed (device-tree-compiler); cannot check overlays"
		return
	fi

	local tmp o err n=0
	tmp=$(mktemp -d)
	# A .dtbo that no longer applies to the base DTB is only discovered when
	# the board fails to boot with that overlay selected - it builds fine.
	for o in "${FIT_OUTPUT_DIR}"/${BOARD_DTB}-*.dtbo; do
		[ -e "$o" ] || continue
		n=$((n + 1))
		if err=$(fdtoverlay -i "$base" -o "${tmp}/out.dtb" "$o" 2>&1); then
			ok "applies: $(basename "$o")"
		else
			bad "does NOT apply: $(basename "$o")"
			note "$err"
		fi
	done
	rm -rf "$tmp"
	[ "$n" -eq 0 ] && bad "no overlays found in ${FIT_OUTPUT_DIR}"
}

verify_modules() {
	head_ "Kernel modules"
	local modroot="${KERNEL_MODULES_OUTPUT_DIR}/usr/lib/modules"
	local relfile="${KERNEL_DIR}/include/config/kernel.release"
	local release=""
	[ -f "$relfile" ] && release=$(cat "$relfile")

	if [ ! -d "$modroot" ]; then
		bad "no installed module tree (run: rcar-driver.sh build kernel modules-install)"
		return
	fi

	# modules_install never removes the tree of a previous kernel version, so
	# a release bump leaves both behind. Deploying kernel-modules/ wholesale
	# ships the stale one too - check the tree for the kernel that is actually
	# built, and call out the leftovers.
	local moddir
	if [ -n "$release" ] && [ -d "${modroot}/${release}" ]; then
		moddir="${modroot}/${release}"
	else
		moddir=$(find "$modroot" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
		if [ -z "$moddir" ]; then
			bad "no installed module tree (run: rcar-driver.sh build kernel modules-install)"
			return
		fi
		if [ -n "$release" ]; then
			bad "no module tree for the built kernel ${release}"
			note "found only: $(basename "$moddir")"
			note "run: rcar-driver.sh build kernel modules-install"
		fi
	fi

	local other
	while read -r other; do
		[ -z "$other" ] && continue
		[ "$other" = "$moddir" ] && continue
		bad "stale module tree: $(basename "$other")"
		note "modules_install does not remove it; deploying kernel-modules/ would"
		note "ship both. Remove it: rm -rf ${other}"
	done < <(find "$modroot" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

	local ko
	ko=$(find "$moddir" -name '*.ko' | wc -l)
	ok "${ko} modules installed in $(basename "$moddir")"

	# The silent one: without depmod, modules_install prints a warning, exits
	# 0, and writes no modules.dep - so nothing resolves dependencies on the
	# board even though the build "succeeded".
	if [ -s "${moddir}/modules.dep" ]; then
		ok "modules.dep present ($(wc -l < "${moddir}/modules.dep") entries)"
	else
		bad "modules.dep missing or empty - depmod did not run"
		note "Install it (sudo apt-get install -y kmod) and re-run:"
		note "  rcar-driver.sh build kernel modules-install"
	fi

	local extmod
	for extmod in updates/cmemdrv.ko extra/qos.ko extra/pvrsrvkm.ko; do
		if [ -f "${moddir}/${extmod}" ]; then
			ok "external module ${extmod}"
		else
			bad "external module ${extmod} missing"
			note "run: rcar-driver.sh build ext-modules install"
		fi
	done

	# pcie-rcar-gen4 calls request_firmware() on every probe and the blob is
	# not in the distro linux-firmware package.
	if [ -f "${KERNEL_MODULES_OUTPUT_DIR}/usr/lib/firmware/rcar_gen4_pcie.bin" ]; then
		ok "PCIe PHY firmware staged with the modules"
	else
		bad "usr/lib/firmware/rcar_gen4_pcie.bin missing from the module tree"
	fi
}

verify_initramfs() {
	head_ "Initramfs"
	local cpio="${FIT_OUTPUT_DIR}/uInitramfs.cpio.gz"
	[ -f "$cpio" ] || cpio="${WORKSPACE_DIR}/initramfs/uInitramfs.cpio.gz"
	if [ ! -f "$cpio" ]; then
		note "no initramfs built (only needed to boot from NVMe/USB)"
		return
	fi

	local listing
	if ! listing=$(zcat "$cpio" 2>/dev/null | cpio -t 2>/dev/null); then
		bad "cannot read ${cpio}"
		return
	fi
	ok "initramfs readable ($(wc -l <<<"$listing") entries)"

	# init is what the kernel execs; the module and its firmware are the whole
	# reason this initramfs exists (bring PCIe up, then switch to the real root).
	local f
	for f in init linuxrc pcie-rcar-gen4.ko usr/lib/firmware/rcar_gen4_pcie.bin; do
		if grep -qx "$f" <<<"$listing"; then
			ok "contains ${f}"
		else
			bad "missing ${f}"
		fi
	done
}

verify_bl31() {
	head_ "ARM Trusted Firmware"
	local bl31="${FIT_OUTPUT_DIR}/bl31-sparrow-hawk.bin"
	[ -f "$bl31" ] || bl31="${TFA_OUTPUT_DIR}/bl31-sparrow-hawk.bin"
	if [ -f "$bl31" ]; then
		ok "BL31 blob present ($(stat -c%s "$bl31") bytes)"
	else
		bad "no bl31-sparrow-hawk.bin (run: rcar-driver.sh build bl31 all)"
	fi
}

do_verify() {
	verify_kernel
	verify_fitimage
	verify_overlays
	verify_modules
	verify_initramfs
	verify_bl31

	head_ "Result"
	printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ]
}

#-----------------------------------------------------------------------------
# info
#-----------------------------------------------------------------------------
do_info() {
	head_ "Layout"
	printf '  repo       %s\n' "${RCAR_UTILS_DIR}"
	printf '  kernel     %s\n' "${KERNEL_DIR}"
	printf '  workspace  %s\n' "${WORKSPACE_DIR}"

	head_ "Artifacts"
	local f
	for f in "${KERNEL_DIR}/arch/arm64/boot/Image" \
	         "${FIT_OUTPUT_DIR}/fitImage" \
	         "${FIT_OUTPUT_DIR}/${BOARD_DTB}.dtb" \
	         "${FIT_OUTPUT_DIR}/uInitramfs.cpio.gz" \
	         "${TFA_OUTPUT_DIR}/bl31-sparrow-hawk.bin"; do
		if [ -f "$f" ]; then
			printf '  %-12s %10s  %s\n' "$(stat -c%y "$f" | cut -d. -f1 | cut -d' ' -f2)" \
				"$(stat -c%s "$f")" "${f#"${RCAR_UTILS_DIR}"/}"
		else
			printf '  %-12s %10s  %s\n' "-" "-" "${f#"${RCAR_UTILS_DIR}"/} (absent)"
		fi
	done
	echo
}

#-----------------------------------------------------------------------------
case "${1:-}" in
	preflight) do_preflight; [ "$FAIL" -eq 0 ] ;;
	build)     shift; do_build "$@" ;;
	verify)    do_verify ;;
	info)      do_info ;;
	smoke)
		do_preflight
		if [ "$FAIL" -ne 0 ]; then
			head_ "Result"
			echo "  preflight failed; not building."
			exit 1
		fi
		do_build fitimage all || exit 1
		PASS=0; FAIL=0
		do_verify
		;;
	*)
		sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 2
		;;
esac
