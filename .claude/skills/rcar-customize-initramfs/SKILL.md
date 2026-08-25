---
name: rcar-customize-initramfs
description: Change the R-Car V4H Sparrow Hawk initramfs (uInitramfs.cpio.gz) — the init script, the busybox configuration, the bundled PCIe driver and PHY firmware. Use when booting from NVMe/USB fails, or to add a tool or firmware blob to the early boot environment. Do NOT use for the real rootfs, kernel config, or overlay selection.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, initramfs, busybox, pcie, phase-2]
  domain: boot
---

# Customize the initramfs

## Purpose

The initramfs exists for exactly one reason: **`CONFIG_PCIE_RCAR_GEN4_HOST=m`**.
The PCIe controller driver is a module that lives in the rootfs, but on NVMe the
rootfs sits *behind* PCIe. The initramfs breaks that loop — load the driver,
wait for the root device, `switch_root`.

It is therefore only needed when the rootfs is **not** on eMMC/SD. `boot.cmd`
selects the `#initramfs` FIT configuration when the boot device is not
`mmcblk`.

Shared facts: `AGENTS.md` at the repo root.

## Prerequisites

Built kernel **modules** — the initramfs takes `pcie-rcar-gen4.ko` from that
build, and its vermagic must match the kernel in the same fitImage:

```bash
./scripts/rcar-driver.sh build kernel modules
```

## Files

| What | Path |
|---|---|
| Init script (template) | `local-build-scripts/initramfs/init` |
| Build script | `local-build-scripts/build_initramfs.sh` |
| busybox pin | `BUSYBOX_URL` / `BUSYBOX_SHA256` in `config.ini` |
| PCIe firmware pin | `PCIE_FW_URL` / `PCIE_FW_SHA256` in `config.ini` |
| Staging tree | `workspace/initramfs/rootfs/` (rebuilt from scratch each run) |
| Output | `workspace/initramfs/uInitramfs.cpio.gz` |

## Run

```bash
./scripts/rcar-driver.sh build initramfs all      # busybox if needed, then the cpio
./scripts/rcar-driver.sh build initramfs busybox  # static busybox only
./scripts/rcar-driver.sh build initramfs clean
./scripts/rcar-driver.sh build fitimage image     # re-embed it
```

## What the image contains

419 entries; the ones that are not busybox applet symlinks:

```
init                                  the script below
linuxrc                               busybox default entry
pcie-rcar-gen4.ko                     at the root, not under /lib/modules
lib -> usr/lib                        symlink
usr/lib/firmware/rcar_gen4_pcie.bin   PHY firmware
usr/lib/firmware/LICENCE.r8a779g_pcie_phy
proc dev sys mnt                      mount points
```

Inspect it:

```bash
zcat workspace/fitimage/uInitramfs.cpio.gz | cpio -t 2>/dev/null | grep -vE '^bin/|^sbin/|^usr/'
```

## The init script

`local-build-scripts/initramfs/init` — plain `/bin/sh`, runs under busybox:

1. Mounts `/proc`, `/sys`, `/dev` (devtmpfs), `/dev/pts`.
2. `insmod /pcie-rcar-gen4.ko` — **`insmod` from a fixed path, not `modprobe`.**
   The module has no dependencies, so no `depmod`/`modules.dep` is needed and
   the initramfs never has to know the kernel release string.
3. Parses `root=` out of `/proc/cmdline`.
4. Polls for the block device, `TIMEOUT=30` seconds, 1 s apart.
5. `mount -o ro`, then `exec switch_root /mnt /sbin/init`.

Any failure calls `rescue()`, which prints the kernel release, lists
`/dev/nvme* /dev/sd* /dev/mmcblk*`, and drops to a shell. That is deliberate —
a silent failure here surfaces only as `Attempted to kill init`, which says
nothing.

To change behaviour (longer timeout, extra module, different root handling),
edit the template and rebuild:

```bash
$EDITOR local-build-scripts/initramfs/init
./scripts/rcar-driver.sh build initramfs all
./scripts/rcar-driver.sh build fitimage image
./scripts/rcar-driver.sh verify
```

## The busybox build

Built **statically** for arm64 from the pinned tarball. The script patches the
generated `.config` with `sed`:

- `CONFIG_STATIC=y` — no glibc in the image at all.
- `CONFIG_TC` off — `tc` uses kernel headers that changed after 1.36.1 and does
  not build against a current `linux-libc-dev`. Useless in an initramfs anyway.

Then `make silentoldconfig` (busybox's kconfig predates `olddefconfig`).

Two guards run after the build, and both matter:

| Guard | Catches |
|---|---|
| `file` output must say `statically linked` | missing `libc6-dev-arm64-cross` (no `/usr/aarch64-linux-gnu/lib/libc.a`) |
| `file` output must say `ARM aarch64` | **missing `CROSS_COMPILE`** — a host x86 binary links fine and passes the first check, then fails only when the board runs `/init` |

To add a busybox applet, extend the `sed` block in
`local-build-scripts/build_initramfs.sh` (`mk_busybox`) and rebuild with
`initramfs busybox`.

## Adding a firmware blob or file

The staging tree is wiped and rebuilt on every run (`rm -rf "${STAGE_DIR}"`), so
copying a file into `workspace/initramfs/rootfs/` by hand **does not persist**.
Add it in `mk_stage()` in `build_initramfs.sh`, next to the existing
`install -m 644` calls.

Note the layout constraint: `lib` is a symlink to `usr/lib`, because the kernel
firmware loader only searches `/lib/firmware` and `/lib/firmware/<release>`.
Firmware goes in `usr/lib/firmware/` and is reached through that symlink.

## Gotchas

- **The initramfs is optional.** With no `uInitramfs.cpio.gz`, the fitImage is
  generated *without* the `initramfs` configuration and the board can only boot
  a rootfs on eMMC/SD. No error — a smaller FIT and a boot failure later.
- **`pcie-rcar-gen4.ko` is copied from the kernel build**, so a kernel rebuild
  requires an initramfs rebuild. `fitimage all` handles this;
  `fitimage image` does **not**, it reuses the existing cpio.
- **`initramfs all` reuses an existing image** when called via `fitimage`'s
  `ensure_initramfs` in `reuse` mode. Only `fitimage all` forces a rebuild.
- **Switching `CONFIG_PCIE_RCAR_GEN4_HOST` to `=y`** makes this whole image
  unnecessary for PCIe — the driver would be built in. The initramfs would
  still be selected by `boot.cmd` for non-MMC boots.
- **`insmod` not `modprobe`** means adding a module *with* dependencies to the
  initramfs requires either loading them in order by hand, or bringing in
  `depmod` and a `/lib/modules/<release>/` tree.
- **`switch_root` requires `/sbin/init` on the real rootfs.** A rootfs using a
  different init path needs the last line of the script changed.
- **Firmware is duplicated on purpose** — once in the initramfs, once under
  `workspace/kernel-modules/usr/lib/firmware/` for the real rootfs. The module
  calls `request_firmware()` on every probe, in both environments.

## Verification

```bash
./scripts/rcar-driver.sh verify
```

Checks the image is readable and contains `init`, `linuxrc`,
`pcie-rcar-gen4.ko` and `usr/lib/firmware/rcar_gen4_pcie.bin`.

Confirm the bundled module matches the kernel:

```bash
modinfo linux-sh/drivers/pci/controller/dwc/pcie-rcar-gen4.ko | grep vermagic
cat linux-sh/include/config/kernel.release
```

Confirm busybox is static arm64:

```bash
file workspace/initramfs/busybox/busybox
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Error: ... pcie-rcar-gen4.ko not found` | Kernel modules not built | `rcar-driver.sh build kernel modules` |
| `Error: busybox is not statically linked` | Missing `libc6-dev-arm64-cross` | `sudo apt-get install -y libc6-dev-arm64-cross` |
| `Error: busybox was not built for arm64` | `CROSS_COMPILE` unset | Build through `main_build.sh`/`rcar-driver.sh`, which export it |
| Board: `initramfs: could not insmod` | vermagic mismatch | Rebuild initramfs after the kernel |
| Board: `<dev> did not appear after 30s` | PCIe link/firmware, or slow device | Check the firmware blob is present; raise `TIMEOUT` |
| Board: `Attempted to kill init` | initramfs missing from the FIT | Rebuild with `fitimage all` |
| fitImage has no `initramfs` config | cpio absent at assembly time | `rcar-driver.sh build initramfs all`, then `fitimage image` |
