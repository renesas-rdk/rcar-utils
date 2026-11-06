#!/bin/bash
#
# Initramfs - NOT YET PORTED to R-Car X5H Ironhide.
#
# The V4H Sparrow Hawk version of this script built a minimal static-busybox
# initramfs whose only job was to insmod pcie-rcar-gen4.ko (plus its
# rcar_gen4_pcie.bin PHY firmware) and switch_root to an NVMe rootfs - needed
# there because CONFIG_PCIE_RCAR_GEN4_HOST=m, so the PCIe driver is not in the
# kernel image and NVMe root is unreachable without it.
#
# Whether X5H needs any of that is unverified:
#   - X5H's normal root is eMMC/UFS, not PCIe NVMe (see
#     Flash_Yocto_Binaries_X5H.md), so the early-boot PCIe problem may not
#     arise at all for the usual boot path.
#   - It is not confirmed whether X5H's PCIe controller driver is built in or
#     a module in this kernel, nor what it is called (pcie-rcar-gen4 is the
#     Gen4 driver; a Gen5 equivalent has not been identified).
#   - X5H's PCIe firmware blobs (rcar_gen5_pcie6_iccm.bin /
#     rcar_gen5_pcie6_dccm.bin) are embedded into the kernel image at build
#     time via CONFIG_EXTRA_FIRMWARE, not loaded at run time, so the V4H
#     reason for staging firmware inside the cpio does not carry over as-is.
#
# Test cases PCI-01/PCI-02 in this project's Test_spec_x5h.xlsx cover PCIe
# NVMe root, so this is a real future use case - it just has not been
# researched or tried on hardware yet.
#
# To implement: confirm the above on a real board, then restore the busybox
# staging machinery from the ubuntu/rcar-v4h-sh branch
# (git show ubuntu/rcar-v4h-sh:local-build-scripts/build_initramfs.sh) and
# adapt the module/firmware names.
#
set -uo pipefail

source ./config.ini
source ./common.sh

echo "Error: the initramfs target is not implemented for PLATFORM=${PLATFORM}."
echo ""
echo "       X5H boots its rootfs from eMMC/UFS, and whether a PCIe-NVMe-root"
echo "       initramfs is needed (and what the Gen5 PCIe module is called) has"
echo "       not been confirmed - see the comment at the top of this script."
echo ""
echo "       The original V4H implementation is still in git history:"
echo "         git show ubuntu/rcar-v4h-sh:local-build-scripts/build_initramfs.sh"
exit 1
