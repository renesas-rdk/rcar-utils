# Board Flashing Configuration on RZ devices

All the scripts uses a `boards_flash_config.toml` file to define flash layout and bootloader addresses for supported boards. The configuration is structured per board and boot type (e.g., xspi, emmc), and includes information such as:

- BL2, FIP, BID (Board Identification) flash offsets
- Ethernet addresses
- Common load_address per board

## Example Structure

```toml
[rzg2l-evk]
ethernet = ["11c20000", "11c30000"]
ethernet_udp_index = 0
bl2_base = "0x12000"
fconf_dtb_base = "0x2A000"

# Uload bootloader
flash_address = ["00000", "1D200", "1C700"]
load_address = "0x48000000"

# Bootloader flash SPI
[rzg2l-evk.xspi]
BL2 = ["11E00", "00000"]
FIP = ["00000", "1D200"]
BID = ["00810", "1C700"]

# Bootloader flash eMMC
[rzg2l-evk.emmc]
BL2 = ["1", "1", "11E00"]
FIP = ["1", "100", "00000", "2", "8"]
BID = ["1", "FA", "810"]

# Bootloader flash eSD
[rzg2l-evk.esd]
BL2_BP_ESD = ["1", "1"]
BL2 = ["8"]
BID = ["250"]
FIP = ["256"]
```

## How to support new board to script

Edit the `boards_flash_config.toml` file to include the new board information:

```toml
[<board_name>]
bl2_base = "<bl2_base_address>"
fconf_dtb_base = "<fconf_dtb_base_address>"
ethernet = ["<eth0_address>", "eth1_address"]
ethernet_udp_index = <port_index_or_list>

# Uload bootloader
flash_address = ["<bl2>", "<fip>", "<board_information>"]
load_address = "<working_ram>"

[<board_name>.xspi]
"BL2" = ["<srec_top_address>", "<flash_address>"]
"FIP" = ["<srec_top_address>", "<flash_address>"]
"BID" = ["<binary_size (.bin) / srec_top_address (.srec)>", "<flash_address>"]

[<board_name>.emmc]
"BL2": ["<area>", "<sector_start>", "<program_start_address>"]
"FIP": ["<area>", "<sector_start>", "<program_start_address>", "<ext_csd_b1>", "<ext_csd_b3>"]
"BID": ["<area>", "<sector_start>", "<binary_size>"]

[<board_name>.esd]
BL2_BP_ESD = ["<sector_start">, <sector_count>]
BL2        = ["<sector_start">]
BID        = ["<sector_start">]
FIP        = ["<sector_start">]
```

Each board has a dedicated section for its specific configuration. The available setting types are as follows:
- **General**:
  - bl2_base: Base address of the BL2 image in memory. This defines where the BL2 binary is loaded or linked before execution or flashing. The address must align with the memory map of the target board and match the BL2 linker configuration.
  - fconf_dtb_base: Base address (in-memory) where the FCONF DTB is loaded.
  - ethernet: Specifies the addresses of `ether0` and `ether1` in sequential order.
  - ethernet_udp_index: Specifies which Ethernet port(s) to use for UDP fastboot flashing. Can be a single integer (e.g., `0` or `1`) or a list of integers (e.g., `["0", "1"]`) if multiple ports are available. The universal flash script will automatically use this value without prompting the user.
  - flash_address: The SPI flash address where BL2, FIP, and board information are sequentially stored.
  - load_address: The working RAM address used to load the binary file before writing it to SPI flash.

- **xspi**:
  - BL2: Provide the `srec_top_address` and `flash_address` sequentially for the BL2 image.
  - FIP: Provide the `srec_top_address` and `flash_address` sequentially for the FIP image.
  - BID: Supports two image formats: `.bin` and `.srec`.
    - If using `.bin`: Specify `binary_size` and `flash_address` sequentially.
    - If using `.srec`: Specify `srec_top_address` and `flash_address` sequentially.

- **emmc**:
  - BL2: Specify `area`, `sector_start`, and `program_start_address` sequentially for the BL2 image.
  - FIP: Specify `area`, `sector_start`, `program_start_address`, `ext_csd_b1`, and `ext_csd_b3` sequentially for the FIP image.
  - BID: Specify `area`, `sector_start`, `binary_size` for the board identification image.

- **esd**:
  - BL2_BP_ESD: Specify `sector_start`, and `sector_count` sequentially for the BL2 bootparam eSD image.
  - BL2: Specify `sector_start` for the BL2 image.
  - BID: Specify `sector_start` for the FIP image.
  - FIP: Specify `sector_start` for the board identification image.

> [!NOTE]
> Entries in `boards_flash_config.toml` are configuration definitions used by the scripts and may also serve as templates for future development.
> The presence of a board section or a boot media subsection does **not** necessarily mean that flashing for that board/method is currently supported, implemented, or validated.
> For the list of officially supported boards and IPL flashing methods, refer to [the supported IPL flashing table](../README.md)

## R-Car V4H (Sparrow-Hawk) configuration

Sparrow-Hawk uses the same per-board/per-method table structure as the other boards, but its `xspi` table uses an `SPL` key instead of `BL2` (the bootloader flash scripts pick `SPL` vs `BL2` based on whether the board is V4H), and adds a `PCIE` key with no matching entry on other boards:

```toml
[sparrow-hawk]
ethernet = ["e6800000", "e6810000"]
ethernet_udp_index = "0"
# V4H uses SA0 (renesas-rcar4-sa0 binman etype), not bpgen — spl_dest here is the
# SPL_TEXT_BASE the SA0 header points the CR52/ROM loader to, per u-boot-sst .config.
spl_dest  = "0xEB210000"
fconf_dtb_base = "0x08130000"
uboot_load_address = "0x44100000"

# ULoad bootloader from a normal U-Boot console.
load_address = "0x48000000"

[sparrow-hawk.uload]
verify_address = "0x49000000"
SPL = "00000"
UBOOT_FIT = "80000"
BID = "2C0000"
PCIE = "300000"
erase_size = "310000"
spl_max_size = "80000"
uboot_fit_max_size = "240000"
bid_size = "810"
pcie_max_size = "10000"

# Bootloader flash SPI
# UBOOT_FIT is generated from U-Boot nodtb and this board's U-Boot DTB.
[sparrow-hawk.xspi]
SPL = ["EB210000", "00000"]
UBOOT_FIT = ["00000", "80000"]
PCIE = ["300000"]
BID = ["00810", "2C0000"]
```

Key differences from the `[<board_name>.xspi]` template above:
- **`SPL`** replaces `BL2` — same `[srec_top_address/VMA, flash_address]` shape, but the value at index 0 (`EB210000`) is `spl_dest` (the SPL's link-time text base, i.e. where the CR52/ROM loader expects it in RAM), not a QSPI offset.
- **`UBOOT_FIT`** replaces `FIP` because V4H flashes a board-specific U-Boot
  FIT, not a TF-A Firmware Image Package.
- **`PCIE`** — a single flash offset (no VMA) for the required Sparrow-Hawk PCIe PHY firmware blob (`rcar_gen4_pcie.bin`).
- **`BID` offset (`0x2C0000`)** is different from the `0x5F300` used by the V2H boards.
- **`[sparrow-hawk.uload]`** is the independent U-Boot-console layout. It
  targets the SD card's FAT32 partition 1, resolved at runtime via U-Boot's
  `${mmcdev}:${mmcpart}` (not a fixed MMC device number). `load_address` and
  `verify_address` are non-overlapping RAM buffers; the four offsets match the
  xSPI table; and the size limits prevent an aligned write from crossing into
  the next region.

> [!WARNING]
> Sparrow-Hawk has no eMMC or eSD boot path. Only `[sparrow-hawk.xspi]` and
> `[sparrow-hawk.uload]` are defined and have been validated on real hardware.

See [R-Car V4H (Sparrow-Hawk) flashing flow](../README.md#r-car-v4h-sparrow-hawk-flashing-flow) in the main README for how these offsets are used during flashing, and for a full comparison with the RZ board BL2/FIP flow.
