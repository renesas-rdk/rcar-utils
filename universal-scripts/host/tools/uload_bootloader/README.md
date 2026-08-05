# RZ uload-bootloader - Bootloader Programming/Flashing on U-Boot console

This section describes the ULoad-bootloader flow for programming the bootloader from the U-Boot console. It supports xSPI flashing and is intended for cases where the device can boot to U-Boot and program flash using images stored on the removable media.

> **IMPORTANT:** All steps in this README must be followed in order. The script performs pre-checks to verify files exist on the SD card before erasing the SPI flash. If any required files are missing, the script will abort safely without erasing the flash.

## Outline of the folder

```
uload-bootloader
├── uload_bootloader_flash.py
└── README.md
```

## Prerequisites

The release does not automatically stage ULoad images on the SD card. The
legacy ULoad flow requires BL2 and FIP artifacts rebuilt for the selected
board with the correct DTB/FCONF and configuration. Sparrow-Hawk uses SA0+SPL
and a U-Boot FIT generated from U-Boot nodtb plus its selected DTB.

Run the `firmware_compile.py` script in the `firmware_compile` folder to generate these artifacts, then copy them to partition 1 (FAT32) under `/uload-bootloader/` before running the ULoad flasher. This ensures the programmed bootloader matches the exact board and release configuration, minimizing the risk of mismatch.

To compile ULoad images, refer to
[`firmware_compile/Readme.md`](../firmware_compile/Readme.md).

## R-Car V4H Sparrow-Hawk ULoad path

Sparrow-Hawk is supported through a dedicated ULoad path. It is a recovery or
field-update path that requires a currently bootable Sparrow-Hawk U-Boot; it
does not use the SCIF Flash Writer or XLS3 protocol.

Stage these files on the SD card's FAT32 partition 1 (`${mmcdev}:${mmcpart}`
in U-Boot), under `/uload-bootloader/`:

| File | xSPI offset |
|---|---:|
| `spl_bp_sparrow-hawk.bin` | `0x000000` |
| `u-boot_sparrow-hawk.itb` | `0x080000` |
| `sparrow-hawk-platform-settings.bin` | `0x2c0000` |
| `rcar_gen4_pcie.bin` | `0x300000` |

Run ULoad at the normal U-Boot console baud rate, `115200`:

```shell
python3 uload_bootloader_flash.py \
  --board_name sparrow-hawk \
  --serial_port /dev/ttyUSB1 \
  --serial_port_baud 115200
```

The tool accepts an existing U-Boot prompt as a recovery session; a power
cycle is required only when the board is not already at `=>`.

SD path overrides are `--spl_path`, `--uboot_fit_path`, `--image_bid`, and
`--pcie_fw_path`. All four images are required. A filename without a directory
is resolved below `/uload-bootloader/`.

Before erasing xSPI, the script loads all four files and checks their sizes:
SPL must fit before `0x080000`, FIT before `0x2c0000`, BID must be exactly
`0x810` bytes, and PCIe firmware must fit before `0x310000`. It then erases
`0x000000` through `0x30ffff` and writes the four regions with U-Boot `sf`
commands. V4H U-Boot requires `sf write` lengths divisible by four, so the
tool rounds each write up to four bytes after verifying the padded length
still fits its reserved region and fills only the padding bytes with `0xff`.
After each write it reads the raw payload back from xSPI and requires its
CRC32 to match the file loaded from FAT. This path programs only the SPI
loader layout. Direct OP-TEE payloads are loaded from rootfs partition 2
with the explicit `ext4load`, `tfa_prepare`, and `mmc_do_boot` sequence in
the host tools README.

> **RECOVERY SAFETY:** All four payloads are preloaded and size-checked before
> `sf erase`. If an error occurs after `Erasing V4H xSPI region...`, do not
> reset or power off the board: SPL/FIT may be erased or only partly written.
> Keep the current U-Boot prompt alive, correct the SD-card artifacts, and run
> the command again. The V4H path accepts an existing `=>` prompt specifically
> for this recovery case.

## Getting help

Run the following command to know how to use the script

- Windows:

```
py uload_bootloader_flash.py -h
```

- Linux:

```
python3 uload_bootloader_flash.py -h
```

## Flashing procedure

Please follow the steps below:

**1. Prepare necessary images (required)**

This step packages the artifacts built by `firmware_compile.py` and places them on the removable media so the ULoad-bootloader script (U-Boot console flow) can program xSPI.

From `target/images`, gather the per-board files:
- `bl2`: bl2_bp_&lt;board-name&gt;.bin
- `fip`: fip_&lt;board&gt;.bin
- `Board identification`: &lt;board&gt;-platform-settings.bin, or the explicit
  revisioned filename selected for that board

Place all files on partition 1 (FAT32) of the SD card under this directory.

```
/uload-bootloader
```
**2. Connect debug serial port to Host PC, then change switches to enter normal boot mode**

**3. Run the script**

*Basic Usage*

To run the script, use the following command

- Windows:

```
py uload_bootloader_flash.py
```

- Linux:

```
python3 uload_bootloader_flash.py
```

When no arguments are provided, the script will use the following default info:
- Serial port: most recently connected port (E.g: COM8 in Windows or /dev/ttyUSB0 in Linux)
- Serial port baudrate: 115200
- `bl2`: bl2_bp_&lt;board-name&gt;.bin
- `fip`: fip_&lt;board&gt;.bin
- `Board identification`: &lt;board&gt;-platform-settings.bin

**Note:** default `board-name` is `rzg2l-sbc`

*Custom Usage*

To specify custom file paths or override the defaults, the following arguments can be passed:

- **--board_name**: Board name used to select defaults and the flash layout.
- **--serial_port**: Serial port to use for communication with the board.
- **--serial_port_by_id**: Stable Linux by-id serial path used after reconnect.
- **--serial_port_baud**: Baud rate for the serial port (must be `115200`).
- **--bl2_path**: Path or filename of the BL2 image for legacy boards.
- **--spl_path**: Path or filename of the SA0+SPL image for Sparrow-Hawk.
- **--fip_path**: Path or filename of the FIP for legacy boards. It remains a
  compatibility alias for V4H.
- **--uboot_fit_path**: Path or filename of the Sparrow-Hawk U-Boot FIT.
- **--image_bid**: Path or filename of the board-identification file.
- **--pcie_fw_path**: Path or filename of the V4H PCIe firmware.

Example Custom Command

- Windows:

```powershell
py uload_bootloader_flash.py `
  --serial_port COM8 `
  --serial_port_baud 115200 `
  --bl2_path uload-bootloader/bl2_bp_rzg2l-sbc.bin `
  --fip_path uload-bootloader/fip_rzg2l-sbc.bin `
  --image_bid uload-bootloader/rzg2l-sbc-platform-settings.bin
```

- Linux:

```shell
python3 uload_bootloader_flash.py \
  --serial_port /dev/ttyUSB0 \
  --serial_port_baud 115200 \
  --bl2_path uload-bootloader/bl2_bp_rzg2l-sbc.bin \
  --fip_path uload-bootloader/fip_rzg2l-sbc.bin \
  --image_bid uload-bootloader/rzg2l-sbc-platform-settings.bin
```

**Notes:**
- If only a filename is provided (no path), the script searches the default directory (e.g., /uload-bootloader on partition 1, FAT32).
- If a path is provided, the script searches only partition 1 (FAT32), not the ext4 partition.
- Ensure the filenames match the board that was built with firmware_compile.py.
- Boards whose BID filename contains a hardware revision must pass the exact
  filename with `--image_bid`; the generic default is
  `<board-name>-platform-settings.bin`.

**4. Power on the board. It will start to load bootloader images from uboot into xSPI flash**

The script will:
1. First perform a **pre-check** to verify all required files exist on the SD card
2. If pre-check passes, proceed to erase and write the SPI flash
3. If pre-check fails, abort safely without erasing the flash

Wait for the script to run automatically. No input or operation is required during this period. After completing the process, you can set RZ board to boot from xSPI as your needs.

## Troubleshooting

### Pre-check Failed: Missing Files

If you see an error message stating:
```
** Pre-check FAILED: Missing or inaccessible files on SD card **
```

This means one or more required files are not found on the SD card partition 1 (FAT32).

**Solution:**
1. Verify that you completed **Step 1** (Prepare necessary images) in the "Flashing procedure" section above
2. Run `firmware_compile.py` to generate the required legacy BL2/FIP or V4H
   SPL/FIT files
3. Copy all generated files to `/uload-bootloader/` directory on SD card partition 1 (FAT32)
4. Ensure filenames match your board name (e.g., `bl2_bp_rzg2l-sbc.bin` for rzg2l-sbc)
5. Re-run the script

**Note:** The SPI flash is NOT erased if pre-check fails, so your board remains in a bootable state.

### Failure After xSPI Erase

If the script reports a write, readback, or CRC error after
`Erasing V4H xSPI region...`, leave the board powered on at the current U-Boot
prompt. Do not reset it. Correct or replace the files on the SD card's FAT32
partition 1, then rerun the same Sparrow-Hawk command. Power-cycle only after all four
`Verified ... CRC32` messages and
`V4H ULoad bootloader flashing completed successfully` are printed.

### Serial Communication Issues

If the serial port fails to open or communicate:
- Verify the serial cable is properly connected to the debug port
- Check that no other application is using the serial port
- Confirm the correct port is selected (default: most recent port)
- Try specifying the port manually with `--serial_port` argument

### Board Does Not Boot to U-Boot Prompt

If the board doesn't reach U-Boot prompt:
- Verify DIP switches are set to **normal boot mode** (not SCIF download mode)
- Check that power is properly connected
- Ensure the board has a valid bootloader already programmed (required for ULoad method)
- Try power cycling the board
