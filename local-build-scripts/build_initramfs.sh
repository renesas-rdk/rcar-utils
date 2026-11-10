#!/bin/bash
#
# Initramfs is not supported for R-Car X5H Ironhide.
# The usual rootfs is on eMMC/UFS. The fitImage has no ramdisk unless
# INITRAMFS_CPIO points at an image built elsewhere.
#
set -uo pipefail

source ./config.ini
source ./common.sh

echo "Error: the initramfs target is not supported for PLATFORM=${PLATFORM}."
echo "       The usual rootfs is on eMMC/UFS."
echo "       To add a ramdisk to the fitImage, set INITRAMFS_CPIO to an existing cpio archive."
exit 1
