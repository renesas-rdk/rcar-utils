# local-build-scripts

This directory contains the build scripts for the R-Car V4H Sparrow Hawk kernel
and FIT image (`PLATFORM=RCAR-V4H-SH`).

## Hierarchy

```
.
├── build_bl31.sh
├── build_ext_modules.sh
├── build_fitimage.sh
├── build_initramfs.sh
├── build_kernel.sh
├── build_uboot.sh
├── common.sh
├── config.ini
├── fit/
│   └── rcar-v4h-sh/
│       └── boot.cmd
├── initramfs/
│   └── init
├── main_build.sh
├── patches/
│   ├── cmem/
│   ├── gles/
│   ├── qos/
│   └── u-boot/
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
    cpio \
    curl \
    git \
    device-tree-compiler \
    swig \
    python3-dev \
    python3-pyelftools \
    python3-setuptools \
    libgnutls28-dev \
    srecord
```

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

        2. ext-modules
            Build the pinned out-of-tree modules cmemdrv, qos and pvrsrvkm.
            Requires a built kernel.
            <sub_command>:
                - all     (fetch if needed, then build)
                - fetch   (re-clone at the pinned revision and re-apply patches)
                - install (build and install to KERNEL_MODULES_OUTPUT_DIR)
                - clean

        3. bl31
            Build the ARM Trusted Firmware BL31 blob. Every FIT configuration
            loads it, so the fitimage target needs it.
            <sub_command>:
                - all   (fetch if needed, then build)
                - fetch (re-clone at the pinned revision)
                - clean

        4. initramfs
            Build uInitramfs.cpio.gz. Needed to boot a rootfs that is not on
            eMMC/SD. Requires built kernel modules.
            <sub_command>:
                - all     (build busybox if needed, then the cpio)
                - image   (same as all)
                - busybox (build the static busybox only)
                - clean

        5. fitimage
            Build the deployable U-Boot FIT image (fitImage).
            <sub_command>:
                - all   (build/install kernel and external modules, build BL31
                         and initramfs, then assemble the fitImage)
                - image (assemble the fitImage from an existing kernel build)
                - clean

        6. uboot
            Build U-Boot (flash.bin with SPL and U-Boot proper) at the
            pinned revision.
            <sub_command>:
                - all   (fetch if needed, reset and patch the source,
                         configure, build, install)
                - fetch (fetch the pinned revision and reset the source)
                - clean (reset the source, remove the build directory and
                         the U-Boot files in UBOOT_OUTPUT_DIR)

For example:
    Build all images (Kernel image and device tree) for the Linux Kernel:
        $ ./main_build.sh kernel all

    Clean the Linux Kernel (Kernel image and device tree) output:
        $ ./main_build.sh kernel clean

    Build and install kernel modules to KERNEL_MODULES_OUTPUT_DIR:
        $ ./main_build.sh kernel modules-install
        $ ./main_build.sh ext-modules install

    Build BL31 and the initramfs, the two other fitImage inputs:
        $ ./main_build.sh bl31 all
        $ ./main_build.sh initramfs all

    Build the complete deployable output for the R-Car V4H Sparrow Hawk:
        $ ./main_build.sh fitimage all

Note: No configuration is needed to build. See config.ini for the layout.
```

## U-Boot

The `uboot` target builds U-Boot at the revision pinned by `UBOOT_SRCREV`,
with the patches, configuration fragments, and default environment in
`patches/u-boot/`. When `UBOOT_SRCREV` changes, update `DEBUG_PREFIX` in
`build_uboot.sh` to match.

To build U-Boot:

```sh
./main_build.sh uboot all
```

The build writes `flash.bin` and the other U-Boot outputs to
`UBOOT_OUTPUT_DIR` (`workspace/u-boot-release` by default).

The script owns `UBOOT_SRC_DIR` and `UBOOT_BUILD_DIR`. Every `all` and `fetch`
resets the source with `git checkout -f` and `git clean -xfd`, so local
changes are discarded. The script uses only a new or empty directory, or one
that it created itself, and refuses any other directory.

To reset the source and remove the build directory and the U-Boot outputs:

```sh
./main_build.sh uboot clean
```

## Kernel configuration

Every build target configures the kernel first: `sparrow_hawk_defconfig` and
the `sparrow_hawk.config` fragment are concatenated and passed through
`make alldefconfig`.

To change an option, edit `.config` through menuconfig and build as usual:

```sh
./main_build.sh kernel menuconfig
./main_build.sh kernel all
```

A `.config` that differs from the one the scripts generated is kept and only
brought up to date with `make olddefconfig`, so the build uses what menuconfig
saved. When `.config` is still the generated one it is regenerated on every
build instead, so an update to the defconfig or to the fragment is picked up.
The scripts tell the two apart with a copy of the last generated `.config` in
`<kernel>/.rcar-config.stamp`; a `.config` with no stamp beside it — one from an
older checkout, or written by hand — counts as customized and is kept.

To go back to the board configuration and discard local changes:

```sh
./main_build.sh kernel defconfig
```

`menuconfig` also generates a `.config` first when the kernel tree does not have
one yet, so it never starts from the plain arm64 defaults.

## Directory layout

Nothing has to be configured before a build. `common.sh` derives every path
from the location of these scripts, so a fresh `git clone` of `rcar-utils` is
ready to build:

```
<rcar-utils>/
├── linux-sh/                     kernel source, cloned on demand
├── local-build-scripts/
└── workspace/
    ├── kernel-modules/           installed modules, their .conf files and firmware
    ├── ext-modules/              cmem, qos and gles sources
    ├── arm-trusted-firmware/     TF-A source and release/bl31-sparrow-hawk.bin
    ├── u-boot/                   U-Boot source
    ├── u-boot-build/             U-Boot build directory
    ├── u-boot-release/           flash.bin and the other U-Boot outputs
    ├── initramfs/                busybox tree and uInitramfs.cpio.gz
    ├── fitimage/                 FIT inputs and fitImage
    └── downloads/                checksum-verified download cache
```

`linux-sh/` and `workspace/` are in `.gitignore`.

When `linux-sh/` is missing, the build prints the repository and branch it is
about to use and asks before cloning:

```
No kernel source found at <rcar-utils>/linux-sh.
  repository: https://github.com/renesas-rdk/linux-sh.git
  branch:     ubuntu/rcar-v4h-sh
Clone it now? [y/N]
```

#### Switching an existing linux-sh

An existing `linux-sh/` is used as it is, whatever branch it has checked out.
When that is not `KERNEL_BRANCH` the kernel build prints a warning (an older
branch builds an older kernel with the same `-rcarv4h-sh` suffix). A clone
made with `--single-branch` only knows its own branch, so add the new one
first:

```bash
cd linux-sh
BRANCH=ubuntu/rcar-v4h-sh
git remote set-branches --add origin "$BRANCH"
git fetch origin "$BRANCH"
git checkout -b "$BRANCH" "origin/$BRANCH"
cd ..
./scripts/rcar-driver.sh build kernel defconfig    # .config from the new branch
```

### config.ini

This configuration file contains the configurations for the build. Please make sure that you review all the settings carefully before performing a build.

- **PLATFORM**: Select the supported platform (`RCAR-V4H-SH`).
- **KERNEL_LOCALVERSION**: Optional suffix for `uname -r`. Commented out by default, so the
  suffix comes from the kernel branch's fragment (`-rcarv4h-sh`).

Paths, all optional. They are commented out in `config.ini` because the file is
sourced by the scripts, so even an empty assignment would overwrite the
environment. While a line stays commented out, the same variable can be set for
a single run: `KERNEL_MODULES_OUTPUT_DIR=/tmp/mods ./main_build.sh kernel modules-install`.

- **KERNEL_DIR**: Kernel source tree. Defaults to `<rcar-utils>/linux-sh`.
- **KERNEL_URL** / **KERNEL_BRANCH**: Repository and branch used when the kernel source has to be cloned.
- **WORKSPACE_DIR**: Parent of every output directory. Defaults to `<rcar-utils>/workspace`. Set it to move all of them at once.
- **KERNEL_MODULES_OUTPUT_DIR**, **EXT_MODULES_SRC_DIR**, **TFA_SRC_DIR**, **INITRAMFS_SRC_DIR**, **FIT_OUTPUT_DIR**, **DOWNLOAD_DIR**: One output directory each, all under `WORKSPACE_DIR` by default.

ARM Trusted Firmware settings, only used by the `bl31` target:

- **TFA_URL** / **TFA_SRCREV**: TF-A source and pinned revision.
- **TFA_OUTPUT_DIR**: Where `bl31-sparrow-hawk.{bin,elf,srec}` are written. Defaults to `${TFA_SRC_DIR}/release`.
- **TFA_CC_FLAGS**: Flags added to `CC`. Commented out in `config.ini`; unset means the default flags in `build_bl31.sh`, empty (`TFA_CC_FLAGS= ./main_build.sh bl31 all`) means the TF-A makefile flags only.

U-Boot settings, only used by the `uboot` target:

- **UBOOT_URL** / **UBOOT_SRCREV** / **UBOOT_DEFCONFIG**: U-Boot source, pinned revision and defconfig.
- **UBOOT_SRC_DIR** / **UBOOT_BUILD_DIR** / **UBOOT_OUTPUT_DIR**: Source, build and output directories, under `WORKSPACE_DIR` by default. Owned by the script, see [U-Boot](#u-boot).

Initramfs settings, used by the `initramfs` target:

- **INITRAMFS_OUTPUT_DIR**: Where `uInitramfs.cpio.gz` is written. Defaults to `INITRAMFS_SRC_DIR`.
- **BUSYBOX_URL** / **BUSYBOX_SHA256**: busybox release and its checksum.

PCIe PHY firmware, used by both the `initramfs` and the `kernel modules-install`
targets:

- **PCIE_FW_URL** / **PCIE_FW_SHA256**: Pinned PCIe PHY firmware source and checksum.
- **PCIE_FW_LIC_URL** / **PCIE_FW_LIC_SHA256**: Its licence, shipped next to the blob.

FIT image settings, only used by the `fitimage` target:

- **BL31_BIN**: TF-A BL31 blob (`bl31-sparrow-hawk.bin`) loaded by every FIT configuration. Mandatory. Defaults to the blob built by the `bl31` target.
- **INITRAMFS_CPIO**: Initramfs (`uInitramfs.cpio.gz`) used by the `#initramfs` FIT configuration. Optional. Defaults to the image built by the `initramfs` target.
- **FIT_KERNEL_LOADADDR** / **FIT_ATF_LOADADDR**: Load/entry addresses, must match the board's U-Boot environment.
- **FIT_ITS**: Optional path to a hand-written image tree source, used instead of the generated one.


Out-of-tree module settings, only used by the `ext-modules` target:

- **CMEM_URL** / **CMEM_SRCREV**: cmemdrv source and pinned revision.
- **CMEM_BSIZE**: Reserved size for `options cmemdrv bsize=...`.
- **QOS_URL** / **QOS_SRCREV**: QoS driver source and pinned revision. `(Unsupported for now)`
