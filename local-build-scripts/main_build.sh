#!/bin/bash

source ./config.ini
source ./common.sh

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# Allow PLATFORM override via positional arg
if [ -n "${PLAT:-}" ]; then
	PLATFORM="$PLAT"
	export PLATFORM
fi

# Main process
echo "Starting the build script at $(pwd)"
echo "Target platform ${PLATFORM}"
echo "Using cross toolchain prefix: ${CROSS_COMPILE}"
if [ -z "${1}" ] ; then
	show_help
else
	if [ -z "${2-}" ]; then
		show_help
	else
		case ${1} in
			"kernel")
				./build_kernel.sh "${2}"
				;;
			"ext-modules")
				./build_ext_modules.sh "${2}"
				;;
			"initramfs")
				./build_initramfs.sh "${2}"
				;;
			"fitimage")
				./build_fitimage.sh "${2}"
				;;
			"bl31")
				./build_bl31.sh "${2}"
				;;
			*)
				show_help
				;;
		esac
		# Propagate the sub-script's status: exiting 0 unconditionally makes a
		# failed build look successful to whatever called this.
		exit $?
	fi
fi

exit 0
