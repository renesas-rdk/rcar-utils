# U-Boot boot script for the R-Car X5H Ironhide fitImage.
#
# NOTE: this is U-Boot script syntax, not POSIX shell. "if test ...; then" has
# no "[" form, there are no subshells, and every variable is a string.
#
# Deliberately much shorter than the V4H Sparrow Hawk boot.cmd it was ported
# from. That board probes I2C buses to detect which camera/display/fan module
# is plugged in and composes an overlay string from what it finds. Ironhide has
# no equivalent pluggable peripheral set: it has four fixed device tree
# variants, so the configuration is chosen by an environment variable rather
# than guessed from hardware.
#
# Entry contract:
#   ${fitconf}   FIT configuration to boot. One of:
#                  default    CA core only, UIO disabled (native drivers)
#                  uio        CA + CR cores, UIO enabled
#                  uio-ca     CA core only, UIO enabled
#                  coresight  CoreSight debug/trace build
#                Unset means "default".
#   ${fitaddr}   where to load the fitImage. Unset means 0xA2600000. Not
#                ${loadaddr}: stock U-Boot sets it to 0x9E600000, where bootm
#                then copies the dtb (0x9E600000) and kernel (0x9E680000) on
#                top of the FIT it is reading. 0xA2600000 is the start of the
#                Linux CMA region - unused while U-Boot runs, clear of the
#                kernel, of cr52_ca720_share and of relocated U-Boot at the top
#                of DRAM bank 0. Not yet tried on real Ironhide hardware.
#   ${fitsrc}    where to load it from: "mmc" (default) or "tftp".
#   ${fitfile}   file name. Unset means "fitImage".
#   ${mmcdev}    eMMC device number for fitsrc=mmc. Unset means 0.
#   ${mmcpart}   partition holding ${fitfile}. Unset means 1.
#
# Flash the bootloader chain itself (BL31, OP-TEE, U-Boot) separately with the
# Flash Programmer - it is not part of this image. See
# Flash_Yocto_Binaries_X5H.md / Table 4-1-2.

if test -z "${fitconf}"; then
	setenv fitconf default
fi
if test -z "${fitfile}"; then
	setenv fitfile fitImage
fi
if test -z "${fitsrc}"; then
	setenv fitsrc mmc
fi
if test -z "${fitaddr}"; then
	setenv fitaddr 0xA2600000
fi
if test -z "${mmcdev}"; then
	setenv mmcdev 0
fi
if test -z "${mmcpart}"; then
	setenv mmcpart 1
fi

echo "Loading ${fitfile} from ${fitsrc} to ${fitaddr}, configuration #${fitconf}"

if test "${fitsrc}" = "tftp"; then
	tftp ${fitaddr} ${fitfile}
else
	load mmc ${mmcdev}:${mmcpart} ${fitaddr} ${fitfile}
fi

# bootm applies the named configuration: it picks that config's kernel and
# fdt out of the FIT. BL31 and OP-TEE are already running by this point - they
# are not in this image and are not loaded here.
bootm ${fitaddr}#${fitconf}
