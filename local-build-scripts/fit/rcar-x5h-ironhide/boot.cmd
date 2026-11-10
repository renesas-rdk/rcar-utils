# U-Boot boot script for the R-Car X5H Ironhide fitImage.
#
# U-Boot script syntax: "if test ...; then", no "[" test, no subshells.
#
# ${fitconf}   FIT configuration: default, uio, uio-ca, or coresight.
#              Unset means default.
#                default    CA core only, UIO disabled
#                uio        CA + CR cores, UIO enabled
#                uio-ca     CA core only, UIO enabled
#                coresight  CoreSight debug/trace
# ${fitaddr}   Where to load the fitImage. Unset means 0xA2600000.
#              Stock U-Boot sets loadaddr to 0x9E600000. bootm then copies
#              the dtb to 0x9E600000 and the kernel to 0x9E680000, which
#              overwrites a FIT loaded at loadaddr. 0xA2600000 sits in the
#              Linux CMA region, unused while U-Boot runs, and clear of the
#              kernel, cr52_ca720_share, and relocated U-Boot.
#              Not tried on real Ironhide hardware yet.
# ${fitsrc}    mmc (default) or tftp.
# ${fitfile}   File name. Unset means fitImage.
# ${mmcdev}    eMMC device for fitsrc=mmc. Unset means 0.
# ${mmcpart}   Partition holding fitfile. Unset means 1.
#
# BL31, OP-TEE, and U-Boot are flashed separately. They are not in this image.
# Offsets: README.md, Boot contract.

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

# bootm selects that configuration's kernel and fdt from the FIT.
bootm ${fitaddr}#${fitconf}
