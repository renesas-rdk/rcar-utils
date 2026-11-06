#!/bin/bash
#
# rcar-driver.sh - build and verify the X5H Ironhide kernel / fitImage without a board.
#
# The product of this repo is a boot artifact for an aarch64 target, so there is
# nothing to "launch" on the build host. The closest thing to running it is:
# build, then prove the artifacts are internally consistent and would actually
# boot - the fitImage carries the kernel that was just built, every device tree
# variant it advertises is a readable FDT, the module tree has a modules.dep,
# and the rest of the boot chain (BL31, OP-TEE, U-Boot) has been built.
#
# Each of those checks exists because the corresponding failure is silent:
# a stale fitImage, a depmod-less modules_install and a truncated dtb all
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
OPTEE_SRC_DIR="${OPTEE_SRC_DIR:-${WORKSPACE_DIR}/optee}"
OPTEE_OUTPUT_DIR="${OPTEE_OUTPUT_DIR:-${OPTEE_SRC_DIR}/release}"
UBOOT_SRC_DIR="${UBOOT_SRC_DIR:-${WORKSPACE_DIR}/u-boot}"
UBOOT_OUTPUT_DIR="${UBOOT_OUTPUT_DIR:-${UBOOT_SRC_DIR}/release}"
FW_INSTALL_DIR="${FW_INSTALL_DIR:-/lib/firmware}"

BOARD_DTB="r8a78000-ironhide"

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
	for t in aarch64-linux-gnu-gcc make bc bison flex git curl mkimage dtc; do
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
		note "  git clone --single-branch --branch v6.12.80/rcar-6.1.0 \\"
		note "      https://github.com/renesas-rcar/linux-bsp.git ${KERNEL_DIR}"
		note "  git -C ${KERNEL_DIR} checkout e1e83b5711610d83941c51dcf48418eda209f339"
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
		echo "  targets: kernel bl31 optee uboot fitimage" >&2
		echo "  (ext-modules and initramfs are not implemented for X5H yet)" >&2
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

	# No atf-1 node here: unlike V4H, BL31 is not carried in this image (it is
	# flashed separately and already running by the time U-Boot starts). ramdisk-1
	# is optional too - the initramfs target is not implemented for X5H.
	local n
	for n in kernel-1 fdt-1 script; do
		if grep -q "($n)" <<<"$listing"; then
			ok "image node ${n}"
		else
			bad "image node ${n} missing from the fitImage"
		fi
	done

	local cfgs
	cfgs=$(grep -cE '^ Configuration ' <<<"$listing")
	# One configuration per device tree variant: default, uio, uio-ca, coresight.
	if [ "$cfgs" -ge 4 ]; then
		ok "${cfgs} FIT configurations"
	else
		bad "only ${cfgs} FIT configuration(s); the dtb variants are not exposed"
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

# V4H verified that each .dtbo still applies to the base DTB with fdtoverlay.
# Ironhide has no overlays - it has four full device tree variants - so what
# matters here is that every variant the fitImage advertises was actually
# built and staged, and that each is a readable FDT.
verify_dtbs() {
	head_ "Device trees"
	local v n=0 bad_n=0
	for v in "" "-uio" "-uio-ca" "-coresight"; do
		local dtb="${FIT_OUTPUT_DIR}/${BOARD_DTB}${v}.dtb"
		if [ ! -f "$dtb" ]; then
			bad "not staged: $(basename "$dtb")"
			bad_n=$((bad_n + 1))
			continue
		fi
		# A truncated or non-FDT file still "exists"; dtc reading it back is
		# what proves the staged blob is usable.
		if dtc -I dtb -O dts -o /dev/null "$dtb" >/dev/null 2>&1; then
			ok "$(basename "$dtb") ($(stat -c%s "$dtb") bytes)"
			n=$((n + 1))
		else
			bad "not a readable FDT: $(basename "$dtb")"
			bad_n=$((bad_n + 1))
		fi
	done
	[ "$n" -eq 0 ] && bad "no device trees staged in ${FIT_OUTPUT_DIR}"

	# r8a78000-ironhide-npu.dtb is required for NPU inference but is NOT
	# produced by the kernel build - it only ships prebuilt in the SDK's
	# Linux BSP tarball. Absence is expected, so this is a note, not a FAIL.
	if [ -f "${FIT_OUTPUT_DIR}/${BOARD_DTB}-npu.dtb" ]; then
		ok "${BOARD_DTB}-npu.dtb staged (supplied by hand from the SDK)"
	else
		note "${BOARD_DTB}-npu.dtb absent - expected: the kernel does not build it."
		note "Copy it from the SDK Linux BSP tarball if you need NPU inference."
	fi
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

	# No out-of-tree modules are checked: the ext-modules target is not
	# implemented for X5H (V4H's cmemdrv/qos/pvrsrvkm set has not been
	# researched for this SoC - see local-build-scripts/build_ext_modules.sh).
	note "out-of-tree modules not checked - ext-modules is not implemented yet"

	# Nothing firmware-related is staged with the modules on X5H: the three
	# blobs are linked into the kernel image at build time by
	# CONFIG_EXTRA_FIRMWARE, so the board needs no copy. What matters instead
	# is that they were present on the BUILD HOST - without them the kernel
	# would not have linked at all, so this is really a "was it built the way
	# we think" check.
	local blob miss=0
	for blob in rcar_gen5_mp_phy.bin rcar_gen5_pcie6_iccm.bin rcar_gen5_pcie6_dccm.bin; do
		[ -f "${FW_INSTALL_DIR}/${blob}" ] || miss=$((miss + 1))
	done
	if [ "$miss" -eq 0 ]; then
		ok "firmware blobs present in ${FW_INSTALL_DIR} (embedded at build time)"
	else
		note "${miss} of 3 firmware blobs missing from ${FW_INSTALL_DIR}"
		note "a kernel built here would fail; an Image built elsewhere is unaffected"
	fi
}

# BL31, OP-TEE and U-Boot are not part of the fitImage on X5H (see
# build_fitimage.sh): each is flashed separately as a raw .srec at a fixed
# offset, per Table 4-1-2 of the startup guide. They are checked here so a
# "verify" run still tells you whether the full boot chain has been built,
# but a missing one does not mean the fitImage is wrong.
verify_bootchain() {
	head_ "Boot chain (flashed separately, not in the fitImage)"

	local bl31="${TFA_OUTPUT_DIR}/apu-bl31-ironhide.bin"
	if [ -f "$bl31" ]; then
		ok "BL31 $(basename "$bl31") ($(stat -c%s "$bl31") bytes)"
	else
		bad "no apu-bl31-ironhide.bin (run: rcar-driver.sh build bl31 all)"
	fi

	local tee="${OPTEE_OUTPUT_DIR}/apu-tee-ironhide.bin"
	if [ -f "$tee" ]; then
		ok "OP-TEE $(basename "$tee") ($(stat -c%s "$tee") bytes)"
	else
		bad "no apu-tee-ironhide.bin (run: rcar-driver.sh build optee all)"
	fi

	# u-boot-elf.srec, not u-boot.bin: the S-record is what the flash
	# programmer takes (UFS, flash_address 0x06F00000).
	local ub="${UBOOT_OUTPUT_DIR}/u-boot-elf-ironhide.srec"
	if [ -f "$ub" ]; then
		ok "U-Boot $(basename "$ub") ($(stat -c%s "$ub") bytes)"
	else
		bad "no u-boot-elf-ironhide.srec (run: rcar-driver.sh build uboot all)"
	fi

	head_ "Initramfs"
	note "not implemented for X5H - the normal rootfs is on eMMC/UFS, and the"
	note "PCIe-NVMe-root case has not been researched (build_initramfs.sh)"
}

do_verify() {
	verify_kernel
	verify_fitimage
	verify_dtbs
	verify_modules
	verify_bootchain

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
	         "${TFA_OUTPUT_DIR}/apu-bl31-ironhide.bin" \
	         "${OPTEE_OUTPUT_DIR}/apu-tee-ironhide.bin" \
	         "${UBOOT_OUTPUT_DIR}/u-boot-elf-ironhide.srec"; do
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
		# The whole deployable set: kernel+fitImage, then the three boot-chain
		# stages that are flashed separately (BL31, OP-TEE, U-Boot).
		do_build fitimage all || exit 1
		do_build bl31 all || exit 1
		do_build optee all || exit 1
		do_build uboot all || exit 1
		PASS=0; FAIL=0
		do_verify
		;;
	*)
		sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 2
		;;
esac
