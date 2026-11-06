#!/bin/bash
#
# Build the Linux kernel, device trees, and modules directly from the board
# defconfig and configuration fragments.
#
set -uo pipefail

source ./config.ini
source ./common.sh

# if PLATFORM is already exported from main_build.sh, keep it
if [ -n "${PLATFORM:-}" ] && [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
fi

# Per-platform mapping
declare -A KERN_DEFCONFIG=(
	["RCAR-V4H-SH"]="sparrow_hawk_defconfig"
)

# Kconfig fragment merged on top of the defconfig, mirroring the ".cfg" files a
declare -A KERN_CONFIG_FRAGMENT=(
	["RCAR-V4H-SH"]="sparrow_hawk.config"
)

# Extra flags exported to dtc while building the device trees. "-@" keeps the
# __symbols__ node so that U-Boot can apply the .dtbo overlays at run time.
declare -A KERN_DTC_FLAGS=(
	["RCAR-V4H-SH"]="-@"
)

# Resolve DEFCONFIG
if [[ -z "${KERN_DEFCONFIG[$PLATFORM]+x}" ]]; then
	echo "Error: Platform '${PLATFORM}' is not supported."
	echo "Supported platforms are:"
	printf '  %s\n' "${!KERN_DEFCONFIG[@]}"
	exit 1
fi
DEFCONFIG="${KERN_DEFCONFIG[$PLATFORM]}"
CONFIG_FRAGMENT="${KERN_CONFIG_FRAGMENT[$PLATFORM]:-}"

# Optional kernel variant. KERNEL_VARIANT=<name> merges
# kernel-config/<name>.config on top of the board defconfig and fragment,
# producing a second kernel from the same source tree. The variant fragment is
# the last input to the merge, so it can override anything the board
# configuration set - including CONFIG_LOCALVERSION, which is what gives the
# variant its own "uname -r" and its own /usr/lib/modules/<release>.
VARIANT_FRAGMENT=""
if [ -n "${KERNEL_VARIANT:-}" ]; then
	VARIANT_FRAGMENT="${COMMON_SH_DIR}/kernel-config/${KERNEL_VARIANT}.config"
	if [ ! -f "${VARIANT_FRAGMENT}" ]; then
		echo "Error: unknown KERNEL_VARIANT '${KERNEL_VARIANT}'."
		echo "       No such fragment: ${VARIANT_FRAGMENT}"
		echo "Available variants:"
		for f in "${COMMON_SH_DIR}"/kernel-config/*.config; do
			[ -e "$f" ] || { echo "  (none)"; break; }
			echo "  $(basename "$f" .config)"
		done
		exit 1
	fi
fi

# Copy of the .config this script generated last, kept next to it inside the
# kernel tree (the kernel's .gitignore covers dot files, and mk_distclean
# removes it along with the .config it describes). It is what lets
# config_is_customized() tell a generated .config, which is safe to regenerate,
# from one that menuconfig or an editor has changed since - regenerating that
# one would throw the customization away without saying so.
CONFIG_STAMP=".rcar-config.stamp"

echo "Using DEFCONFIG=${DEFCONFIG}"
if [ -n "${CONFIG_FRAGMENT}" ]; then
	echo "Using CONFIG_FRAGMENT=${CONFIG_FRAGMENT}"
fi
if [ -n "${VARIANT_FRAGMENT}" ]; then
	echo "Using KERNEL_VARIANT=${KERNEL_VARIANT} (${VARIANT_FRAGMENT})"
fi

if [ -n "${KERN_DTC_FLAGS[$PLATFORM]:-}" ]; then
	# DTC_FLAGS is picked up from the environment and appended to by
	# scripts/Makefile.dtbs, so the in-tree warning suppressions are kept.
	export DTC_FLAGS="${KERN_DTC_FLAGS[$PLATFORM]}"
	echo "Using DTC_FLAGS=${DTC_FLAGS}"
fi

# Setup the build
kernel_setup() {
	# Remove '+' at the end of kernel version. scripts/setlocalversion only
	# appends it when LOCALVERSION is unset in the environment, so an empty
	# value is enough - no .scmversion needed.
	export LOCALVERSION=""
}

# Concatenate the defconfig and the platform fragment and let kconfig fill in
# the defaults for everything else.
mk_config_merged() {
	local defconfig_file="arch/arm64/configs/${DEFCONFIG}"
	local fragment_file="arch/arm64/configs/${CONFIG_FRAGMENT}"
	local merged

	for f in "${defconfig_file}" "${fragment_file}"; do
		if [ ! -f "$f" ]; then
			echo "Error: missing kernel config input: ${KERNEL_DIR}/$f"
			exit 1
		fi
	done

	merged="$(mktemp -t rcar-merged-config.XXXXXX)"
	cat "${defconfig_file}" "${fragment_file}" > "${merged}"
	# Last assignment wins, so pin the local version here.
	{
		echo "CONFIG_LOCALVERSION_AUTO=n"
		echo "CONFIG_LOCALVERSION=\"${KERNEL_LOCALVERSION:--arm64-renesas}\""
	} >> "${merged}"
	# The variant fragment goes last of all: it is meant to override the board
	# configuration, and its CONFIG_LOCALVERSION has to beat the one just
	# written above.
	if [ -n "${VARIANT_FRAGMENT}" ]; then
		cat "${VARIANT_FRAGMENT}" >> "${merged}"
	fi

	echo '|============================================|'
	echo '|      Configure kernel (alldefconfig)       |'
	echo '|============================================|'
	make KCONFIG_ALLCONFIG="${merged}" alldefconfig
	local rc=$?
	rm -f "${merged}"
	if [ ${rc} -ne 0 ]; then
		echo "Error: kernel configuration failed"
		exit ${rc}
	fi
}

mk_image() {
	echo '|============================================|'
	echo '|          Build IMAGE ARM64 RENESAS         |'
	echo '|============================================|'
	make -j"$(nproc)" Image || exit 1
}

mk_dtbs() {
	echo '|============================================|'
	echo '|             Build device tree              |'
	echo '|============================================|'
	make -j"$(nproc)" dtbs || exit 1
}

mk_full_image() {
	mk_defconfig
	mk_image
	mk_dtbs
}

mk_clean() {
	make clean || exit 1
}

mk_distclean() {
	make distclean || exit 1
	# distclean removes .config, so the copy it was compared against describes
	# nothing any more.
	rm -f "${CONFIG_STAMP}"
}

# Regenerate .config from the tracked defconfig plus the platform fragment,
# overwriting whatever is there now, and record what was generated.
config_generate() {
	kernel_setup
	if [ -n "${CONFIG_FRAGMENT}" ]; then
		mk_config_merged
	else
		make "${DEFCONFIG}" || exit 1
	fi
	cp .config "${CONFIG_STAMP}" || exit 1
}

# True when .config holds something other than what this script generated - a
# .config with no stamp beside it counts as customized, because there is no way
# to tell where it came from and discarding it is the one outcome that cannot
# be undone.
config_is_customized() {
	[ -f .config ] || return 1
	[ -f "${CONFIG_STAMP}" ] || return 0
	! cmp -s .config "${CONFIG_STAMP}"
}

# Run by every build target. A .config this script generated is regenerated, so
# an edit to the tracked defconfig or fragment is picked up. A .config that has
# been changed since is kept and only brought up to date with "olddefconfig":
# "kernel menuconfig" would be pointless if the next build silently replaced
# what it saved.
mk_defconfig() {
	kernel_setup

	if ! config_is_customized; then
		config_generate
		return
	fi

	echo '|============================================|'
	echo '|       Keeping the customized .config       |'
	echo '|============================================|'
	if [ -f "${CONFIG_STAMP}" ]; then
		echo "${KERNEL_DIR}/.config has changed since it was generated from"
		echo "${DEFCONFIG}, so it is kept and only updated with olddefconfig."
	else
		echo "${KERNEL_DIR}/.config was not generated by this script, so it is"
		echo "kept and only updated with olddefconfig."
	fi
	echo "Run './main_build.sh kernel defconfig' to discard it and start again"
	echo "from ${DEFCONFIG}."
	make olddefconfig || exit 1
}

# Asking for "defconfig" explicitly means starting again from the tracked
# defconfig, so this is the one path that does overwrite a customized .config.
mk_defconfig_force() {
	if config_is_customized; then
		echo "Note: replacing the customized ${KERNEL_DIR}/.config."
	fi
	config_generate
}

mk_menuconfig() {
	kernel_setup
	# menuconfig edits the .config that is already there, so without one it
	# would start from the arm64 defaults instead of the board configuration.
	if [ ! -f .config ]; then
		echo "No .config yet, generating one from ${DEFCONFIG} first."
		config_generate
	fi
	make menuconfig || exit 1
	if config_is_customized; then
		echo "Kernel configuration changed; the following builds keep it."
	fi
}

mk_modules() {
	mk_full_image
	echo '|============================================|'
	echo '|               Build modules                |'
	echo '|============================================|'
	make -j"$(nproc)" modules || exit 1
	echo "Build completed successfully"
}

mk_modules_install() {
	if [ -z "${KERNEL_MODULES_OUTPUT_DIR:-}" ]; then
		echo "KERNEL_MODULES_OUTPUT_DIR is not set in config.ini."
		echo "Please recheck your setup"
		exit 1
	fi

	mk_modules
	echo '|============================================|'
	echo '|              Install modules               |'
	echo '|============================================|'
	mkdir -p "${KERNEL_MODULES_OUTPUT_DIR}/usr" || exit 1

	# The target rootfs is usrmerged and keeps its modules in /usr/lib/modules,
	# so stage them under usr/ and let this directory mirror the rootfs.
	# The usr/ component has to go into INSTALL_MOD_PATH rather than into a
	# MODLIB override: scripts/depmod.sh passes INSTALL_MOD_PATH to "depmod -b",
	# and depmod appends its own /lib/modules/<release> to that base. Overriding
	# only MODLIB would move the modules but leave depmod looking in the old
	# location, so no modules.dep would be written.
	make INSTALL_MOD_PATH="${KERNEL_MODULES_OUTPUT_DIR}/usr" modules_install || exit 1
	rm -f "${KERNEL_MODULES_OUTPUT_DIR}"/usr/lib/modules/*/build

	# An output directory from before this layout change still has the modules
	# in lib/modules, which nothing installs into any more.
	if [ -d "${KERNEL_MODULES_OUTPUT_DIR}/lib/modules" ]; then
		echo "Note: ${KERNEL_MODULES_OUTPUT_DIR}/lib/modules is left over from an"
		echo "      earlier build; the modules are now in usr/lib/modules. Remove"
		echo "      the old directory to avoid deploying a stale copy."
	fi

	# uio_pdrv_genirq needs its of_id parameter: the driver's OF match table
	# has a single entry that is only filled in from that module parameter, so
	# without it no "generic-uio" node binds.
	install -d "${KERNEL_MODULES_OUTPUT_DIR}/usr/lib/modules-load.d" \
	           "${KERNEL_MODULES_OUTPUT_DIR}/usr/lib/modprobe.d"
	echo "uio_pdrv_genirq" > "${KERNEL_MODULES_OUTPUT_DIR}/usr/lib/modules-load.d/uio_pdrv_genirq.conf"
	echo 'options uio_pdrv_genirq of_id="generic-uio"' > "${KERNEL_MODULES_OUTPUT_DIR}/usr/lib/modprobe.d/uio_pdrv_genirq.conf"

	# CONFIG_PCIE_RCAR_GEN4=m, so pcie-rcar-gen4.ko was just installed above,
	# and it calls request_firmware() from
	# rcar_gen4_pcie_download_phy_firmware() on every probe. The blob is not in
	# the distro's linux-firmware package - on the board it comes from a
	# separate .deb - so ship it with the modules, the same way the initramfs
	# does.
	install_pcie_firmware "${KERNEL_MODULES_OUTPUT_DIR}" || exit 1

	echo "Installed kernel modules to ${KERNEL_MODULES_OUTPUT_DIR}"
}

# Main Linux Kernel build
cmd="${1:-}"
ensure_kernel_dir || exit 1
echo "Starting the kernel build at ${KERNEL_DIR}"
cd "${KERNEL_DIR}" || exit 1

case ${cmd} in
	'clean')
		mk_clean
		;;
	'distclean')
		mk_distclean
		;;
	'defconfig')
		mk_defconfig_force
		;;
	'menuconfig')
		mk_menuconfig
		;;
	'image')
		mk_defconfig
		mk_image
		;;
	'dtbs')
		mk_defconfig
		mk_dtbs
		;;
	'all')
		mk_full_image
		;;
	'modules')
		mk_modules
		;;
	'modules-install')
		mk_modules_install
		;;
	*)
		show_help
		;;
esac

# Every step above exits non-zero on failure, so getting here means the build
# succeeded. main_build.sh and build_fitimage.sh both act on this status.
exit 0
