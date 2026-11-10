#!/bin/bash
#
# Out-of-tree kernel modules are not supported for R-Car X5H Ironhide.
# This target does not build a GPU, cmem, or qos module.
#
set -uo pipefail

source ./config.ini
source ./common.sh

echo "Error: the ext-modules target is not supported for PLATFORM=${PLATFORM}."
echo "       It does not build a GPU, cmem, or qos module."
exit 1
