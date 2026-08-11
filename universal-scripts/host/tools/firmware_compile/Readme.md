# firmware_compile.py

## Overview

`firmware_compile.py` is a helper script for building Renesas RZ family firmware artifacts, including **BL2**, **Boot Parameter (BP)** files, **U-Boot** binaries, and **FIP** packages.

It automatically pulls board and flash-method–specific configuration (such as VMA addresses) from:

- [`boards_flash_config.toml`](../config/boards_flash_config.toml)
- [`flash_images.json`](../flash_images.json)

The script supports multiple boards and flash methods without hardcoding addresses.

---

## Features

- Generates **BL2 + DTB** combined binary.
- Creates **Boot Parameter + BL2** binary and `.srec` with correct VMA offset.
- Builds **U-Boot (nodtb) + DTB** combined binary.
- Generates **FIP** binary and `.srec` with correct VMA offset (optionally includes **OP-TEE BL32** if configured).
- Supports both **Windows** and **Linux** build hosts.

---

## Prerequisites
The following tools are required and **already bundled** in `tools/bin/<os>` or `host/tools/bin/<os>`:
- `bpgen` (unified boot parameter generator)
- `fiptool` (TF-A utility, includes bundled OpenSSL libraries)
- `objcopy` (part of GNU binutils, includes bundled MinGW runtime for Windows)
- Python 3.8+ (Python 3.11+ recommended for built-in TOML parsing)

**No additional installation or PATH configuration required.** All dependencies are included.

Firmware binaries and DTBs must be available in (already included in release package):

```
target/images/
```

## Usage

Basic example:

### On Windows:

```bash
py firmware_compile.py --soc g2l --board rzg2l-sbc --method xspi
```

### On Linux:

```bash
python3 firmware_compile.py --soc g2l --board rzg2l-sbc --method xspi
```

This will:

1. Build bl2_&lt;board&gt;.bin (BL2 + board DTB)
2. Build bl2_bp_&lt;board&gt;.bin and .srec
3. Build u-boot_&lt;board&gt;.bin (U-Boot + board DTB)
4. Build fip_&lt;board&gt;.bin and .srec (includes OP-TEE BL32 if `tee` field is set in `flash_images.json` and the binary is present)

## CLI Options

| Option              | Default          | Description                                                                           |
| ------------------- | ---------------- | ------------------------------------------------------------------------------------- |
| `--board`           | `rzg2l-sbc`      | Target board name (must exist in `boards_flash_config.toml` and `flash_images.json`). |
| `--soc`             | `g2l`            | Target SoC family (`g2l`, `v2l`, `v2h`, `v4h`).                                       |
| `--method`          | `xspi`           | Flash method (`xspi`, `emmc`, or `esd`).                                              |
| `--bl2`             | auto from images | Path to BL2 binary (override default). Not used when `--soc v4h`.                     |
| `--atf-fdts`        | auto from JSON   | *(RZ boards only)* ATF FDT(s) to append to BL2; rejected for V4H.                     |
| `--uboot-dtbs`      | auto from JSON   | U-Boot DTB(s) to append to U-Boot nodtb.                                              |
| `--bl31`            | auto from images | Path to BL31 binary (override default).                                               |
| `--u-boot-nodtb`    | auto from images | Path to U-Boot (nodtb) binary (override default).                                     |
| `--spl`             | auto from images | *(V4H only)* Path to `target/images/u-boot/sa0.bin` (SA0 header + SPL). `--sa0-bin` is kept as a compatibility alias. |
| `--out-dir`         | `target/images`  | Output directory for generated files.                                                 |
| `--bootparameter`   | auto search      | Path to `bpgen` tool (override search path).                                          |
| `--fiptool`         | auto search      | Path to `fiptool` tool (override search path).                                        |
| `--mkimage`         | auto search      | *(V4H only)* Path to U-Boot `mkimage`.                                                |
| `--objcopy`         | auto search      | Path to `objcopy` tool (override search path).                                        |
| `--fip-align`       | `16`             | FIP alignment.                                                                        |
| `--fip-vma`         | from TOML        | Override VMA for FIP `.srec`.                                                         |
| `--uboot-fit-vma`   | from TOML        | *(V4H only)* Override VMA for U-Boot FIT `.srec`.                                     |
| `--bl2-bp-vma`      | from TOML        | Override VMA for BL2+BP `.srec`.                                                      |
| `--spl-bp-vma`      | from TOML        | *(V4H only)* Override VMA for SPL BP `.srec`.                                         |
| `--fip-tb-kind`     | `soc`            | FIP firmware kind: `soc` or `tb`.                                                     |

---

## Output Files

| File Name                | Description                                           |
| ------------------------ | ----------------------------------------------------- |
| `bl2_<board>.bin`        | BL2 + ATF DTB binary                                  |
| `bl2_bp_<board>.bin`     | Boot Parameter + BL2 binary                           |
| `bl2_bp_esd_<board>.bin` | ESD copy of BL2 BP before BL2 append                  |
| `bl2_bp_<board>.srec`    | BL2 BP in Motorola S-record format (with correct VMA) |
| `u-boot_<board>.bin`     | U-Boot (nodtb) + U-Boot DTB binary                    |
| `fip_<board>.bin`        | Firmware Image Package binary                         |
| `fip_<board>.srec`       | FIP in Motorola S-record format (with correct VMA)    |

## R-Car V4H (Sparrow-Hawk) build pipeline

For `--soc v4h`, the script takes a different path (`run_all_v4h()`) instead
of the BL2/bpgen/fiptool pipeline:

1. `step_sa0_and_srec()` — copies the pre-built `sa0.bin` (SA0 header + SPL) to `spl_bp_<board>.bin`, then emits `spl_bp_<board>.srec` with the VMA from TOML (`spl_dest`) or `--spl-bp-vma`.
2. `step_uboot_fit_and_srec()` — runs `mkimage` with Yocto's
   `u-boot-nodtb-rz-cmn.bin` and the selected `uboot_dtb`, producing
   `u-boot_<board>.itb` and `u-boot_<board>.srec`.

No `bpgen`/`fiptool` invocation happens for V4H. `--spl` (or compatibility
alias `--sa0-bin`), `--u-boot-nodtb`, and `--uboot-dtbs` override the inputs.
Without overrides, the script reads the corresponding files under
`target/images/u-boot/`. `universal_flash.py` passes those inputs explicitly.

> [!IMPORTANT]
> Unlike the RZ board pipeline, **`run_all_v4h()` has no `--tos-fw` step**. It
> builds only the SPI loader inputs (SA0+SPL and the U-Boot-only FIT). Do not embed
> BL31/OP-TEE in that FIT: SPL only copies loadables and cannot construct the
> EL3 handoff. V4H OP-TEE is supplied by the Yocto WIC as separate `/boot`
> files and is loaded with the direct `ext4load`, `tfa_prepare`, and
> `mmc_do_boot` sequence documented in the host tools README.

| File Name                | Description                                              |
| ------------------------ | ---------------------------------------------------------|
| `spl_bp_<board>.bin`     | Copy of the pre-built SA0 header + SPL blob (`sa0.bin`)   |
| `spl_bp_<board>.srec`    | SPL BP in Motorola S-record format (with correct VMA)     |
| `u-boot_<board>.itb`     | U-Boot nodtb plus the selected board's U-Boot DTB          |
| `u-boot_<board>.srec`    | U-Boot FIT in Motorola S-record format                      |

## Notes

- VMAs are pulled from boards_flash_config.toml per board and flash method.
- ATF DTB and U-Boot DTB names are taken from flash_images.json.
- The tools used for RZ boards are prebuilt in the tools directories. V4H additionally needs
  U-Boot `mkimage` in `PATH` or supplied with `--mkimage`.
- For `--soc v4h`, see [R-Car V4H (Sparrow-Hawk) build pipeline](#r-car-v4h-sparrow-hawk-build-pipeline) above — the BL2/bpgen/fiptool notes elsewhere in this document do not apply.
