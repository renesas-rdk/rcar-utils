# Bootloader Flashing on RZ and R-Car Boards

This document introduces the Python script `bootloader_flash.py` that simplifies the process by automating the flashing of bootloader images onto RZ and R-Car boards in a multiple-OS environment.

## Outline of the folder

```
bootloader-flasher
├── bootloader_flash.py
└── README.md
```

## Getting help

Run the following command to know how to use the script

- Windows:

```
py bootloader_flash.py -h
```

- Linux:

```
python3 bootloader_flash.py -h
```

## Flashing procedure

**1. Prepare necessary bootloader files under `target/images` folder (optional)**

Place all bootloader images (e.g., for RZG2L-SBC board) in the /path/to/universal-scripts/target/images/ folder on the Host PC.

```bash
mkdir -p /path/to/universal-scripts/target/images/
cp /path/to/your/bootloader/file/Flash_Writer_SCIF_rzg2l-sbc.mot /path/to/universal-scripts/target/images/
cp /path/to/your/bootloader/file/bl2_bp_rzg2l-sbc.srec /path/to/universal-scripts/target/images/
cp /path/to/your/bootloader/file/fip-rzg2l-sbc.srec /path/to/universal-scripts/target/images/
cp /path/to/your/bootloader/file/rzg2l-sbc-platform-settings.bin /path/to/universal-scripts/target/images/
```

**2. Hardware connection:**

Depending on the type of IPL flashing, set up the corresponding hardware connection:

- xSPI/eMMC: Connect the debug serial port to the host PC, then change the switches to enter SCIF download mode.
- eSD: Connect the USB SD card reader to the host PC.

**3. Run the script**

*Basic Usage*

To run the script without passing any arguments, simply execute the following command:

- Windows:

```
py bootloader_flash.py
```

- Linux:

```
python3 bootloader_flash.py
```

When no arguments are provided, the script will use the following default info:

- Board name: rzg2l-sbc
- Flash method: xspi
- Serial port: most recently connected port (E.g: COM8 in Windows or /dev/ttyUSB0 in Linux)
- Serial port baud: 115200
- Flash Writer Image: /path/to/universal-scripts/target/images/Flash_Writer_SCIF_rzg2l-sbc.mot
- BL2 Image: /path/to/universal-scripts/target/images/bl2_bp_rzg2l-sbc.srec
- FIP Image: /path/to/universal-scripts/target/images/fip-rzg2l-sbc.srec
- Board identification Image: /path/to/universal-scripts/target/images/rzg2l-sbc-platform-settings.bin

Ensure these files are present in the current directory before executing the script.

*Custom Usage*

If you want to specify different file paths or change the serial port settings or images file, you can pass the arguments as shown below:

- **--board_name**: Board name to flash bootloader.
- **--flash_method**: Flash method to use (`xspi`, `emmc`, or `esd`). When `esd` is selected the script writes directly to an SD card reader using `dd` and no serial connection is required.
- **--serial_port**: Serial port to use for communication with the board.
- **--serial_port_by_id**: Stable Linux by-id serial path used after reconnect.
- **--serial_port_baud**: Baud rate for the serial port (`115200` for most boards; Sparrow-Hawk's Flash Writer runs at `921600` from power-on).
- **--image_writer**: Path to the Flash Writer image.
- **--image_bl2**: Path to the BL2 image (V2L/V2H/G2L boards).
- **--image_bl2_esd**: Path to the BL2 eSD image (V2L/V2H/G2L boards).
- **--image_spl**: *(V4H only)* Path to the SPL image — SA0 header + SPL binary. Required instead of `--image_bl2` when `--board_name sparrow-hawk`.
- **--image_fip**: Path to the TF-A FIP image for RZ boards.
- **--image_uboot_fit**: *(V4H only)* Path to the board-specific U-Boot FIT.
- **--image_bid**: Path to the board identification image.
- **--image_pcie_fw**: *(V4H only)* Path to the PCIe PHY firmware (`rcar_gen4_pcie.bin`). It is flashed after SPL and the U-Boot FIT.
- **--esd_device**: Raw device path of the SD card (`esd` method only).

**Sparrow-Hawk (R-Car V4H) notes:**
- Use `--image_spl` instead of `--image_bl2`; the board's `__is_v4h()` check looks up the `SPL` key in `boards_flash_config.toml`.
- Sparrow-Hawk supports only `--flash_method xspi` in this tool. xSPI writes use the `XLS3` chunked binary protocol instead of `XLS2` (SREC), and the `XCS` full-chip erase / `SUP` baud-switch steps are skipped — the Flash Writer already talks at 921600 baud and erases per-chunk internally.
- Sparrow-Hawk has no eMMC/eSD bootloader-flash configuration. Use the separate ULoad tool for updates from an existing U-Boot console.
- See the main [`universal-scripts/host/tools/README.md`](../README.md#r-car-v4h-sparrow-hawk-flashing-flow) for the full flow diagram and comparison with the RZ boards.

### Why Sparrow-Hawk prints many `XLS3` commands

One `XLS3` command programs one raw binary chunk, not one complete artifact.
The V4H implementation uses a fixed 128 KiB (`0x20000`) chunk size:

```text
chunks = ceil(file_size / 0x20000)
```

The SPL chunks start at `0x000000`, FIT chunks start at `0x080000`, BID is at
`0x2c0000`, and PCIe firmware is at `0x300000`. Sequential `XLS3` entries are
therefore expected and are not duplicate full-image writes. Each entry must
end with the Flash Writer's `complete!` response.

The Flash Writer XLS3 path validates command completion and reported save
addresses, but it does not read xSPI back and compare a CRC. A successful
cold boot provides functional evidence. For bit-for-bit SPI verification,
use the Sparrow-Hawk ULoad path, which performs source/readback CRC32 checks
for all four raw payloads.

**eSD flashing**

In eSD flashing, the script writes directly to an SD card reader using `dd` and no serial connection is required.

When the eSD method is selected the script will:

- Use the `--esd_device` argument to determine which SD card to write and run
  `dd` four times to program the IPL boot-parameter image, IPL image, BID, and
  FIP at the sector offsets defined in `boards_flash_config.toml`.
- Require the `--image_bl2`/`--image_bl2_esd` pair for RZ boards, plus `--image_bid`
  and `--image_fip`, to be `.bin` files. Sparrow-Hawk does not support eSD.
- Attempt to flush cached data (via `conv=fsync` and `sync`) and eject the media on Linux hosts once flashing completes.

Ensure the SD card is not mounted before starting the process. On Linux the default device name is typically `/dev/sdX`; on Windows you can provide a raw device path such as `E:` when prompted.

Example Custom Command

- Windows:

```
py bootloader_flash.py --board_name rzg2l-evk --flash_method emmc --serial_port COM11 --serial_port_baud 115200 --image_writer D:\custom_images\Flash_Writer_SCIF_rzg2l-sbc.mot --image_bl2 D:\custom_images\bl2_bp_rzg2l-sbc.srec --image_fip D:\custom_images\fip-rzg2l-sbc.srec --image_bid D:\custom_images\rzg2l-evk-platform-settings.bin
```

- Linux:

```
python3 bootloader_flash.py --board_name rzg2l-evk --flash_method emmc --serial_port /dev/ttyUSB0 --serial_port_baud 115200 --image_writer /home/renesas/custom_images/Flash_Writer_SCIF_rzg2l-sbc.mot --image_bl2 /home/renesas/custom_images/bl2_bp_rzg2l-sbc.srec --image_fip /home/renesas/custom_images/fip-rzg2l-sbc.srec --image_bid /home/renesas/custom_images/rzg2l-evk-platform-settings.bin
```

**3. Power on the board. It will start to flash bootloader images**

Wait for the script to run automatically; no input or operation is required during this period. After the process completes, configure the RZ or R-Car board to boot from xSPI/eMMC as needed.
