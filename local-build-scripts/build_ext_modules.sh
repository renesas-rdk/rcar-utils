#!/bin/bash
#
# Out-of-tree kernel modules - NOT YET PORTED to R-Car X5H Ironhide.
#
# The V4H Sparrow Hawk version of this script built three pinned out-of-tree
# modules: cmemdrv (contiguous memory), qos (bus QoS), and pvrsrvkm (the
# PowerVR Rogue GPU kernel module, from a "GSX_KM_V4H_SparrowHawk" DDK
# tarball whose internal build target is literally the SoC part number
# r8a779g).
#
# None of that is known to apply to X5H:
#   - X5H's GPU IP and its kernel-module/DDK situation has not been
#     researched by this project at all. There is no evidence yet that the
#     V4H PowerVR tarball is the right one, or that an equivalent exists.
#   - cmem/qos may or may not be relevant to this SoC; their pinned
#     revisions and local patches were validated against the V4H kernel.
#
# Rather than ship something that looks like it works, this target fails.
# The V4H values are preserved as commented-out reference in config.ini for
# whoever picks this up.
#
# To implement: research X5H's GPU/DDK and cmem/qos equivalents, restore the
# EXT_MODULES table and fetch/patch/build machinery from the
# ubuntu/rcar-v4h-sh branch (git show ubuntu/rcar-v4h-sh:local-build-scripts/
# build_ext_modules.sh), and re-pin every revision against this kernel.
#
set -uo pipefail

source ./config.ini
source ./common.sh

echo "Error: the ext-modules target is not implemented for PLATFORM=${PLATFORM}."
echo ""
echo "       X5H's out-of-tree module set (GPU/pvrsrvkm, cmem, qos) has not"
echo "       been researched yet - see the comment at the top of this script"
echo "       and the commented-out V4H reference values in config.ini."
echo ""
echo "       The original V4H implementation is still in git history:"
echo "         git show ubuntu/rcar-v4h-sh:local-build-scripts/build_ext_modules.sh"
exit 1
