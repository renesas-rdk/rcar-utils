# local-build-scripts

This directory contains the build scripts for the R-Car X5H Ironhide kernel,
FIT image and boot chain (`PLATFORM=RCAR-X5H-IRONHIDE`, SoC `r8a78000`).

Prefer `../scripts/rcar-driver.sh build <target> <sub_command>` over calling
`main_build.sh` yourself: these scripts `source ./config.ini` and
`./common.sh` with relative paths, so they only work with cwd set to this
directory.

## Hierarchy

```
.
├── build_bl31.sh
├── build_ext_modules.sh      stub - not implemented for X5H, exits 1
├── build_fitimage.sh
├── build_initramfs.sh        stub - not implemented for X5H, exits 1
├── build_kernel.sh
├── build_optee.sh
├── build_uboot.sh
├── common.sh
├── config.ini
├── fit/
│   └── rcar-x5h-ironhide/
│       └── boot.cmd
├── initramfs/
│   └── init                  V4H leftover, unused while initramfs is a stub
├── kernel-config/
│   └── preempt-rt.config     PREEMPT_RT variant (configure stage verified on X5H)
├── main_build.sh
├── patches/                  V4H ext-modules patches, unused while it is a stub
│   ├── cmem/
│   ├── gles/
│   └── qos/
└── README.md
```

## Prerequisites

Ubuntu 24.04 host machine or Docker container with Ubuntu 24.04 image.

```bash
sudo apt update
sudo apt install \
    build-essential \
    gcc-aarch64-linux-gnu \
    libc6-dev-arm64-cross \
    bc \
    bison \
    flex \
    libssl-dev \
    u-boot-tools \
    kmod \
    curl \
    git \
    device-tree-compiler \
    python3-pycryptodome \
    python3-pyelftools \
    python3-cryptography
```

The last three are OP-TEE's build dependencies. Install them with **apt, not
pip** — pip failed on the reference build host, the Debian packages work.

Three firmware blobs must also be present in `/lib/firmware` on the build
host — see [Firmware blobs](#firmware-blobs).

## Usage

```
Usage:

$ ./main_build.sh <target_build> <sub_command>

Option:
    <target_build>:
        1. kernel
            Build for Linux Kernel
            <sub_command>:
                - clean
                - distclean
                - defconfig    (regenerate .config from the board defconfig,
                                discarding any local change)
                - menuconfig   (edit .config; the builds that follow keep it)
                - image
                - dtbs
                - all
                - modules
                - modules-install

        2. bl31
            Build the ARM Trusted Firmware BL31 blob (apu-bl31-ironhide).
            Flashed separately as a raw .srec, not loaded via the fitImage.
            <sub_command>:
                - all   (fetch if needed, then build)
                - image (same as all)
                - fetch (check out the pinned revision; stops if the tree is dirty)
                - clean

        3. optee
            Build OP-TEE OS / BL32 (apu-tee-ironhide). Also flashed
            separately as a raw .srec.
            <sub_command>:
                - all   (fetch if needed, then build)
                - image (same as all)
                - fetch (check out the pinned revision; stops if the tree is dirty)
                - clean

        4. uboot
            Build U-Boot / BL33 (u-boot-elf-ironhide.srec). Also flashed
            separately as a raw .srec.
            <sub_command>:
                - all   (fetch if needed, then build)
                - image (same as all)
                - fetch (check out the pinned revision; stops if the tree is dirty)
                - clean

        5. initramfs
            NOT IMPLEMENTED for X5H - exits 1 with an explanation.

        6. ext-modules
            NOT IMPLEMENTED for X5H - exits 1 with an explanation.

        7. fitimage
            Build the deployable U-Boot FIT image (fitImage): kernel + the
            four device tree variants (+ optional ramdisk) + boot script.
            No BL31 inside.
            <sub_command>:
                - all   (build/install kernel and modules, then assemble
                         the fitImage)
                - image (assemble the fitImage from an existing kernel build)
                - clean

For example:
    Build all images (Kernel image and device tree) for the Linux Kernel:
        $ ./main_build.sh kernel all

    Build and install kernel modules to KERNEL_MODULES_OUTPUT_DIR:
        $ ./main_build.sh kernel modules-install

    Build the rest of the boot chain (each flashed separately):
        $ ./main_build.sh bl31 all
        $ ./main_build.sh optee all
        $ ./main_build.sh uboot all

    Build a fitImage (kernel + dtb) for the R-Car X5H Ironhide:
        $ ./main_build.sh fitimage all

Note: No configuration is needed to build. See config.ini for the layout.
```

## Boot chain and the fitImage

X5H boots a standard ARM TF-A chain:

```
IPL → BL31/TF-A → BL32/OP-TEE → BL33/U-Boot → Linux
```

BL31, OP-TEE and U-Boot are each flashed as a raw S-record at a fixed UFS
offset with the Flash Programmer; by the time U-Boot runs, BL31 and OP-TEE
have already started. So unlike the V4H scripts this was ported from, the
fitImage carries **only** what U-Boot hands to Linux — there is no `atf-1`
node and no `BL31_BIN` input. Flash offsets and load addresses are in
[`README.md`](../README.md#boot-contract) under "Boot contract".

Each device tree variant is a full DTB and its own FIT configuration, listed
in `FIT_DTBS` in `build_fitimage.sh`:

| FIT config | DTB |
|---|---|
| `default` | `r8a78000-ironhide.dtb` |
| `uio` | `r8a78000-ironhide-uio.dtb` |
| `uio-ca` | `r8a78000-ironhide-uio-ca.dtb` |
| `coresight` | `r8a78000-ironhide-coresight.dtb` |

`fit/rcar-x5h-ironhide/boot.cmd` loads the fitImage (`fitsrc` = `mmc` or
`tftp`) and runs `bootm ${fitaddr}#${fitconf}`; `fitconf` unset means
`default`. `fitaddr` unset means `0xA2600000`. It does not follow
`${loadaddr}`: stock U-Boot sets that to `0x9E600000`, where `bootm` copies
the dtb, and the kernel goes to `0x9E680000`, so a FIT loaded there would be
overwritten while it is being read. `0xA2600000` has not yet been tried on
real Ironhide hardware. `r8a78000-ironhide-npu.dtb` is not built by the kernel — it ships
prebuilt in the SDK and has to be added to `FIT_DTBS` by hand.

## Kernel configuration

Every kernel build configures the kernel first from the plain
`arch/arm64/configs/defconfig` — **not** `renesas_defconfig`, which is missing
`CONFIG_RENESAS_ETHER_SWITCH3` and fails at the vmlinux link with
`undefined reference to rswitch3_attach_tsnes`. X5H needs no board config
fragment. The result is passed through `make alldefconfig`, with
`CONFIG_LOCALVERSION` pinned from `KERNEL_LOCALVERSION`.

To change an option, edit `.config` through menuconfig and build as usual:

```sh
./main_build.sh kernel menuconfig
./main_build.sh kernel all
```

A `.config` that differs from the one the scripts generated is kept and only
brought up to date with `make olddefconfig`, so the build uses what menuconfig
saved. When `.config` is still the generated one it is regenerated on every
build instead, so an update to the defconfig is picked up. The scripts tell
the two apart with a copy of the last generated `.config` in
`<kernel>/.rcar-config.stamp`; a `.config` with no stamp beside it — one from an
older checkout, or written by hand — counts as customized and is kept.

To go back to the board configuration and discard local changes:

```sh
./main_build.sh kernel defconfig
```

`menuconfig` also generates a `.config` first when the kernel tree does not have
one yet, so it never starts from the plain arm64 defaults.

`KERNEL_VARIANT=<name>` merges `kernel-config/<name>.config` last. X5H has no
board fragment, so setting a variant is what switches `build_kernel.sh` from
plain `make defconfig` to the merge path (`defconfig` + variant →
`alldefconfig`). An empty `KERNEL_LOCALVERSION` stays empty. With
`KERNEL_VARIANT=preempt-rt` the configure stage gives `CONFIG_PREEMPT_RT=y`
and `CONFIG_LOCALVERSION="-arm64-renesas-rt"` (verified on the build server).
A full RT build and an RT boot have not been run. The fragment's pin-back list
was derived on V4H.

## Firmware blobs

The kernel (`CONFIG_EXTRA_FIRMWARE`) and U-Boot
(`CONFIG_PHY_R8A78000_MP_PHY_FW`) embed three blobs at **build time** from the
absolute path `/lib/firmware` on the build host:

```
rcar_gen5_mp_phy.bin       kernel + U-Boot
rcar_gen5_pcie6_iccm.bin   kernel
rcar_gen5_pcie6_dccm.bin   kernel
```

A missing blob is a hard build failure. They are **not downloadable**: they
ship only inside the Renesas SDK v4.39.0 package (My Renesas login):

```
https://www.renesas.com/en/document/mas/sdk-documentation-sdk-v4390
  -> <SDK v4.39.0>/user_manual/current/linux_bsp/_attachments/
```

Either copy them to `/lib/firmware` yourself, or set `FW_DIR` in `config.ini`
to the directory holding them; `ensure_firmware_blobs` in `common.sh` copies
them before the kernel or U-Boot build (with `sudo` when not root) and leaves
already-present blobs alone. Nothing installs them onto the target — they are
inside the images.

## Directory layout

Nothing has to be configured before a build. `common.sh` derives every path
from the location of these scripts, so a fresh `git clone` of `rcar-utils` is
ready to build:

```
<rcar-utils>/
├── linux-sh/                     kernel source, cloned on demand
├── local-build-scripts/
└── workspace/
    ├── kernel-modules/           installed modules and their .conf files
    ├── ext-modules/              (unused - ext-modules is a stub)
    ├── arm-trusted-firmware/     TF-A source and release/apu-bl31-ironhide.{bin,elf,srec}
    ├── optee/                    OP-TEE source and release/apu-tee-ironhide.{bin,elf,srec}
    ├── u-boot/                   U-Boot source and release/u-boot-elf-ironhide.srec
    ├── initramfs/                (unused - initramfs is a stub)
    ├── fitimage/                 FIT inputs and fitImage
    └── downloads/                checksum-verified download cache
```

`linux-sh/` and `workspace/` are in `.gitignore`.

When `linux-sh/` is missing, the build prints the repository and branch it is
about to use and asks before cloning — only when stdin is a TTY. It then
checks out the pinned `KERNEL_SRCREV`. Non-interactively, clone it by hand:

```bash
git clone --single-branch --branch v6.12.80/rcar-6.1.0 \
    https://github.com/renesas-rcar/linux-bsp.git linux-sh
git -C linux-sh checkout e1e83b5711610d83941c51dcf48418eda209f339
```

### config.ini

This configuration file contains the configurations for the build. Please make sure that you review all the settings carefully before performing a build.

- **PLATFORM**: Select the supported platform (`RCAR-X5H-IRONHIDE`).
- **KERNEL_LOCALVERSION**: Suffix appended to `uname -r`. Empty by default, and it stays empty. It is written into the config only on the merge path (a `KERNEL_VARIANT` build), where the variant's own `CONFIG_LOCALVERSION` comes after it and wins. A stock X5H build takes `defconfig`'s value.
- **KERNEL_VARIANT**: Optional kernel variant (see above). Commented out.

Paths, all optional. They are commented out in `config.ini` because the file is
sourced by the scripts, so even an empty assignment would overwrite the
environment. While a line stays commented out, the same variable can be set for
a single run: `KERNEL_MODULES_OUTPUT_DIR=/tmp/mods ./main_build.sh kernel modules-install`.

- **KERNEL_DIR**: Kernel source tree. Defaults to `<rcar-utils>/linux-sh`.
- **KERNEL_URL** / **KERNEL_BRANCH** / **KERNEL_SRCREV**: Repository and branch used when the kernel source has to be cloned, and the exact commit checked out afterwards (`renesas-rcar/linux-bsp`, `v6.12.80/rcar-6.1.0`, `e1e83b57…`).
- **WORKSPACE_DIR**: Parent of every output directory. Defaults to `<rcar-utils>/workspace`. Set it to move all of them at once.
- **KERNEL_MODULES_OUTPUT_DIR**, **EXT_MODULES_SRC_DIR**, **TFA_SRC_DIR**, **OPTEE_SRC_DIR**, **UBOOT_SRC_DIR**, **INITRAMFS_SRC_DIR**, **FIT_OUTPUT_DIR**, **DOWNLOAD_DIR**: One output directory each, all under `WORKSPACE_DIR` by default.

ARM Trusted Firmware settings, only used by the `bl31` target:

- **TFA_URL** / **TFA_SRCREV**: TF-A source and pinned revision. Renesas's fork (`renesas-rcar/arm-trusted-firmware`), not ARM upstream — `rcar_gen5` is not upstreamed.
- **TFA_OUTPUT_DIR**: Where `apu-bl31-ironhide.{bin,elf,srec}` are written. Defaults to `${TFA_SRC_DIR}/release`.

OP-TEE settings, only used by the `optee` target:

- **OPTEE_URL** / **OPTEE_BRANCH** / **OPTEE_SRCREV**: `renesas-rcar/optee_os`, `rcar-gen5_4.4.0`, pinned revision.
- **OPTEE_OUTPUT_DIR**: Where `apu-tee-ironhide.{bin,elf,srec}` are written. Defaults to `${OPTEE_SRC_DIR}/release`.

U-Boot settings, only used by the `uboot` target:

- **UBOOT_URL** / **UBOOT_BRANCH** / **UBOOT_SRCREV**: `renesas-rcar/u-boot`, `v2026.01/rcar-8.0.0`, pinned revision.
- **UBOOT_DEFCONFIG**: `r8a78000_ironhide_defconfig`.
- **UBOOT_OUTPUT_DIR**: Where `u-boot-elf-ironhide.srec` is written. Defaults to `${UBOOT_SRC_DIR}/release`.

Firmware, used by the `kernel` and `uboot` targets:

- **FW_DIR**: Local directory holding the three firmware blobs, copied to `/lib/firmware` when they are not already there. Optional if they are already installed.

FIT image settings, only used by the `fitimage` target:

- **INITRAMFS_CPIO**: Initramfs used by an `initramfs` FIT configuration. Optional; when it is missing the fitImage is generated without a ramdisk (the normal case on X5H).
- **FIT_KERNEL_LOADADDR** / **FIT_DTB_LOADADDR**: Kernel and device tree load addresses (`0x9E680000` / `0x9E600000`), must match the board's U-Boot environment.
- **FIT_ITS**: Optional path to a hand-written image tree source, used instead of the generated one.
- **BL31_BIN**: Not used on X5H — kept commented out for reference only.

`BUSYBOX_URL`/`BUSYBOX_SHA256` are kept for whoever implements the initramfs
target for X5H. They are not used today. The V4H `CMEM_*`/`QOS_*`/`GLES_*`
pins are only in git history:
`git show ubuntu/rcar-v4h-sh:local-build-scripts/config.ini`.
