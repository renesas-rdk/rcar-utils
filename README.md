# R-Car Utility - R-Car X5H Ironhide

Standalone scripts to build and deploy the Linux kernel, modules, device trees,
a U-Boot FIT image (`fitImage`), and the separately-flashed boot-chain stages
(TF-A BL31, OP-TEE, U-Boot) for the R-Car X5H Ironhide board - directly from
source, with no Yocto or bitbake anywhere.

This branch (`ubuntu/rcar-x5h-ironhide`) is a port of `ubuntu/rcar-v4h-sh`, which
targets the R-Car V4H Sparrow Hawk. The structure is the same; the board facts,
the boot architecture and two of the targets are not - see
[Boot contract](#boot-contract) below.

## Hierarchy

```
.
├── linux-sh/               kernel source, cloned on demand (gitignored)
├── local-build-scripts/
├── scripts/                rcar-driver.sh and helpers
├── workspace/              everything the build produces (gitignored)
├── LICENSE
└── README.md
```

### local-build-scripts

Build scripts for the kernel, fitImage, BL31, OP-TEE and U-Boot. See
[local-build-scripts/README.md](local-build-scripts/README.md) for the
configuration and usage details.

## Quick start

```bash
./scripts/rcar-driver.sh preflight
./scripts/rcar-driver.sh smoke
```

`smoke` builds the complete deployable set - installed kernel and modules, the
fitImage, BL31, OP-TEE and U-Boot - then verifies the artifacts.

Two things are needed before the first build:

1. **The kernel source**, cloned on demand when stdin is a TTY, or by hand:
   ```bash
   git clone --single-branch --branch v6.12.80/rcar-6.1.0 \
       https://github.com/renesas-rcar/linux-bsp.git linux-sh
   git -C linux-sh checkout e1e83b5711610d83941c51dcf48418eda209f339
   ```

2. **Three firmware blobs** in `/lib/firmware` on the build host. The kernel
   and U-Boot embed them at build time, so a missing blob is a hard build
   failure. They are not downloadable - they ship only inside the Renesas SDK
   v4.39.0 package (My Renesas login):
   <https://www.renesas.com/en/document/mas/sdk-documentation-sdk-v4390>
   -> `<SDK v4.39.0>/user_manual/current/linux_bsp/_attachments/` ->
   `rcar_gen5_mp_phy.bin`, `rcar_gen5_pcie6_iccm.bin`,
   `rcar_gen5_pcie6_dccm.bin`. Point `FW_DIR` in `config.ini` at them, or copy
   them to `/lib/firmware` yourself.

Everything else is produced under `workspace/`, next to these scripts.
Uncomment a path in `config.ini` only to build somewhere else.

## What this does NOT build

Two targets from the V4H original are present but deliberately stubbed - they
exit 1 with an explanation rather than appearing to work:

- `ext-modules` (cmem / qos / PowerVR GPU module) - X5H's out-of-tree module
  set has not been researched.
- `initramfs` - X5H boots its rootfs from eMMC/UFS; the PCIe-NVMe-root case
  that makes this mandatory on V4H has not been confirmed here.

## Flashing

`scripts/rcar-deploy.sh` deploys the **kernel side** (fitImage, modules, dtbs)
to a running board over ssh. BL31, OP-TEE and U-Boot are not deployed this way:
they are flashed as raw `.srec` at fixed offsets with the Flash Programmer,
which needs USB/serial and physical DIP switch access. The addresses are in
[Boot contract](#boot-contract).

## Boot contract

X5H boots a standard ARM TF-A chain. Every stage before Linux is flashed
separately as a raw S-record at a fixed offset:

```
IPL (RSIP-M BL2 -> SI-BL2 -> 2nd IPL) -> BL31/TF-A -> BL32/OP-TEE -> BL33/U-Boot -> Linux
```

| Artifact | Flash module | Flash address | Load address |
|---|---|---|---|
| `apu-bl31-ironhide.srec` | UFS | `0x06C00000` | `0x104C200000` |
| `apu-tee-ironhide.srec` | UFS | `0x06D00000` | `0x104C400000` |
| `u-boot-elf-ironhide.srec` | UFS | `0x06F00000` | `0x104E300000` |

Source: SDK startup guide, "Table 4-1-2: Information list of X5H image".
Flashing uses the Flash Programmer over USB/serial with the DIP switches in
SCIF download mode.

Unlike V4H, where U-Boot loads BL31 from the fitImage (`loadables = "atf-1"`),
BL31 and OP-TEE have already run by the time U-Boot starts. The fitImage holds
only the kernel, the device trees and an optional ramdisk. Do not add an
`atf-1` node to it.

U-Boot then loads the fitImage and boots one configuration:

```
load mmc 0:1 ${loadaddr} fitImage && source ${loadaddr}:script
bootm ${fitaddr}#${fitconf}      # fitconf: default | uio | uio-ca | coresight
```

The first line only runs the embedded `boot.cmd`. That script loads the
fitImage again at `${fitaddr}`, `0xA2600000` by default, not at `${loadaddr}`.
Stock X5H U-Boot sets `loadaddr=0x9E600000`, which is the FIT dtb load address
and just below the kernel (`0x9E680000`), so `bootm` would copy both on top of
the FIT it is reading. `0xA2600000` is the start of the Linux CMA region: unused
while U-Boot runs, and clear of the kernel, `cr52_ca720_share` and relocated
U-Boot. This address has not been tried on real Ironhide hardware yet.
