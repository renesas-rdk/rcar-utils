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
| `--atf-fdts`        | auto from JSON   | ATF FDT(s) to append to BL2.                                                          |
| `--uboot-dtbs`      | auto from JSON   | U-Boot DTB(s) to append to U-Boot nodtb.                                              |
| `--bl31`            | auto from images | Path to BL31 binary (override default).                                               |
| `--u-boot-nodtb`    | auto from images | Path to U-Boot (nodtb) binary (override default).                                     |
| `--sa0-bin`         | —                | *(V4H only)* Path to the pre-built SA0 header + SPL blob (`sa0.bin`).                 |
| `--fit-itb`         | —                | *(V4H only)* Path to the pre-built FIT image (`u-boot.itb`).                          |
| `--out-dir`         | `out`            | Output directory for generated files.                                                 |
| `--bootparameter`   | auto search      | Path to `bpgen` tool (override search path).                                          |
| `--fiptool`         | auto search      | Path to `fiptool` tool (override search path).                                        |
| `--objcopy`         | auto search      | Path to `objcopy` tool (override search path).                                        |
| `--fip-align`       | `16`             | FIP alignment.                                                                        |
| `--fip-vma`         | from TOML        | Override VMA for FIP `.srec`.                                                         |
| `--bl2-bp-vma`      | from TOML        | Override VMA for BL2+BP `.srec`.                                                      |
| `--spl-bp-vma`      | from TOML        | *(V4H only)* Override VMA for SPL BP `.srec`.                                         |
| `--fip-tb-kind`     | `soc`            | FIP firmware kind: `soc` or `tb`.                                                     |
| `--skip-bl2-output` | *(flag)*         | Skip BL2 + DTB step.                                                                  |

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

## RZ/V4H (Sparrow-Hawk) build pipeline

For `--soc v4h`, the script takes a different path (`run_all_v4h()`) instead of the BL2/bpgen/fiptool pipeline above, because Sparrow-Hawk's SPL and FIT artifacts come from the standalone U-Boot (`binman`) build rather than `bpgen`/`fiptool`:

1. `step_sa0_and_srec()` — copies the pre-built `sa0.bin` (SA0 header + SPL) to `spl_bp_<board>.bin`/`spl_bp_esd_<board>.bin`, then emits `spl_bp_<board>.srec` with the VMA from TOML (`spl_dest`) or `--spl-bp-vma`.
2. `step_fit_and_srec()` — copies the pre-built `u-boot.itb` (FIT image) to `fip_<board>.bin`, then emits `fip_<board>.srec` with the VMA from TOML or `--fip-vma`.

No `bpgen`/`fiptool` invocation happens for V4H — `--bl2`, `--atf-fdts`, `--uboot-dtbs`, `--bl31`, `--u-boot-nodtb` are unused in this path. Instead, `--sa0-bin`/`--fit-itb` (or the equivalent auto-discovered paths from `flash_images.json`'s `spl`/`fip` fields) must point to already-built artifacts.

> [!IMPORTANT]
> Unlike the legacy pipeline, **`run_all_v4h()` never reads the `tee` field** and has no `--tos-fw`-equivalent step — it only copies whatever `sa0.bin`/`u-boot.itb` were already built by `u-boot-sst`. Embedding BL31/OP-TEE directly into `u-boot.itb` (via extra `atf-1`/`tee-1` binman FIT nodes) was tried and **does not work**: SPL's FIT loader only copies loadables' raw bytes to their `load` address, it does not invoke the `U_BOOT_FIT_LOADABLE_HANDLER` handlers in `board/renesas/common/gen4-common.c` that perform the actual BL31/OP-TEE handoff — those only run when U-Boot proper's `bootm` processes a FIT (e.g. the SD-card `fitImage` used by ticket AMECSSTSWA-400), never when SPL loads `u-boot.itb`. On real hardware this caused SPL to overwrite the just-loaded U-Boot with OP-TEE (both targeted address `0x44100000`) and hang right after `EVTB1 board detected`. Setting `"tee": "..."` on the `sparrow-hawk` entry in `flash_images.json` remains unread by this script; see the main [README's OP-TEE section](../README.md#where-op-tee-lives-for-sparrow-hawk) for the full analysis. OP-TEE for this board is out of scope for `rz-utils` — it requires a `fitImage` built and flashed outside this tool.

| File Name                | Description                                              |
| ------------------------ | ---------------------------------------------------------|
| `spl_bp_<board>.bin`     | Copy of the pre-built SA0 header + SPL blob (`sa0.bin`)   |
| `spl_bp_esd_<board>.bin` | eSD copy of the same SA0+SPL blob                         |
| `spl_bp_<board>.srec`    | SPL BP in Motorola S-record format (with correct VMA)     |
| `fip_<board>.bin`        | Copy of the pre-built FIT image (`u-boot.itb`)            |
| `fip_<board>.srec`       | FIP(FIT) in Motorola S-record format (with correct VMA)   |

## Notes

- VMAs are pulled from boards_flash_config.toml per board and flash method.
- ATF DTB and U-Boot DTB names are taken from flash_images.json.
- All tools are prebuilt in tools/bin/<os> or host/tools/bin/<os> unless overridden.
- For `--soc v4h`, see [RZ/V4H (Sparrow-Hawk) build pipeline](#rzv4h-sparrow-hawk-build-pipeline) above — the BL2/bpgen/fiptool notes elsewhere in this document do not apply.
