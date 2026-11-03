---
name: rcar-verify-build
description: Verify R-Car V4H Sparrow Hawk build artifacts without a board. Asserts the fitImage carries the current kernel, every device tree overlay still applies, modules.dep exists, and the initramfs holds the files the boot path needs. Use after any build or before deploying. Do NOT use to build, or to validate on a running board.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, verify, phase-3]
  domain: build
---

# Verify the build artifacts

## Purpose

The product is a boot artifact for an aarch64 board, so nothing here can be
launched on the build host. Instead, this skill checks that the artifacts are
consistent and contain what the boot path needs.

**Three real failure modes exit 0**, so a green build does not prove the build
is good. Shared facts: `AGENTS.md` at the repo root.

## Run

```bash
./scripts/rcar-driver.sh verify
```

It prints one `ok`/`FAIL` line per check and a `N passed, M failed` summary, and
exits 0 only if everything passed. It has no build side effects, so you can run
it at any time.

To produce a complete deployable build and verify it in one step:

```bash
./scripts/rcar-driver.sh smoke
```

`verify` honours `KERNEL_DIR`, `WORKSPACE_DIR` and `FIT_OUTPUT_DIR`, so it can
check a build that was pointed elsewhere:

```bash
FIT_OUTPUT_DIR=/tmp/other-fit ./scripts/rcar-driver.sh verify
```

## Verifying a kernel variant

`verify` reads `WORKSPACE_DIR`, so point it at the variant's workspace:

```bash
WORKSPACE_DIR=$(ls -d "$PWD"/workspace-*/ | head -1) \
    ./scripts/rcar-driver.sh verify
```

It compares the fitImage against `linux-sh/arch/arm64/boot/Image`, and both
variants build in that one tree. So a workspace whose variant is not the
one currently built reports `fitImage kernel is STALE` **and** `no module tree
for the built kernel <other-release>`. Those two together mean "wrong variant
in the tree", not a corrupt artifact. Rebuild the variant you want to check
before trusting the failure.

## What it asserts

| Check | Silent failure it catches |
|---|---|
| `Image` has the arm64 magic (`ARMd` at offset 56) | not an arm64 kernel |
| fitImage parses under `mkimage -l` | corrupt FIT |
| nodes `kernel-1`, `fdt-1`, `atf-1`, `ramdisk-1`, `script` present | every FIT config loads BL31; `boot.cmd` needs the initramfs config for non-MMC boot |
| ≥2 FIT configurations | overlays not exposed as selectable configs |
| fitImage kernel size == `linux-sh` `Image` size | **stale fitImage**, so the board boots the previous kernel |
| every currently staged FIT `.dtbo` applies to the base DTB via `fdtoverlay` | broken overlay; only shows at boot, only with that overlay selected |
| `modules.dep` present and non-empty | `depmod` missing, so nothing modprobes on the board |
| exactly one tree under `usr/lib/modules` | stale tree from an older kernel gets deployed too |
| module tree matches the built kernel release | modules belong to a different kernel |
| `cmemdrv.ko`, `qos.ko`, and `pvrsrvkm.ko` installed | deployable external-module set is incomplete |
| `usr/lib/firmware/rcar_gen4_pcie.bin` staged | PCIe PHY firmware missing next to the module |
| initramfs has `init`, `linuxrc`, `pcie-rcar-gen4.ko`, `usr/lib/firmware/rcar_gen4_pcie.bin` | PCIe never comes up, real rootfs unreachable |
| BL31 blob present | fitImage cannot be assembled |
| IPL package files present (when `workspace/ipl-burning/` exists) | burning tool or licence missing from the package |
| `flash.bin` ≤ `0x300000` bytes | it would overwrite the PCIe firmware in QSPI |
| package `flash.bin` == U-Boot build's | an interrupted build left the previous bootloader in the package |
| U-Boot FIT at `0x80000` has `uboot` and `fdt-1` | SPL has nothing to load |
| `flash.bin` has `bootcmd=run autoconf_mmc`, `autoconf_nvme`, `renesas_rcar_gen4_load_firmware` | board cannot find the fitImage or the PCIe firmware |
| `load_uenv` exists and `autoconf_{mmc,nvme,usb}` run it | `/boot/uEnv.txt` is ignored without any message at boot |
| `rcar_gen4_pcie.bin` matches `PCIE_FW_SHA256` and is `0x8000` bytes | U-Boot reads a fixed size from QSPI |
| embedded Python `._pth` enables `import site` | `run.bat` cannot install pip |

## Reading the output

```
  FAIL  fitImage kernel is STALE: tree=23976448 vs fit=21297664
        Re-assemble it: rcar-driver.sh build fitimage image
```

Every `FAIL` prints the fixing command. Common ones:

| `FAIL` | Fix |
|---|---|
| `fitImage kernel is STALE` | `rcar-driver.sh build fitimage image` |
| `modules.dep missing or empty` | `sudo apt-get install -y kmod`, then `rcar-driver.sh build kernel modules-install` |
| `stale module tree: <ver>` | `rm -rf` the path it prints (it is build output, so confirm before deleting) |
| `does NOT apply: <name>.dtbo` + `FDT_ERR_NOTFOUND` | The overlay's target node is gone from the base DTB. See `rcar-customize-devicetree` |
| `no module tree for the built kernel <ver>` | `rcar-driver.sh build kernel modules-install` |
| `external module ... missing` | `rcar-driver.sh build ext-modules install` |
| `fdtoverlay not installed` | `sudo apt-get install -y device-tree-compiler` |

## Limits

- **Size comparison, not hash.** The stale-fitImage check compares the FIT
  kernel's `Data Size` against the tree's `Image` size. A rebuild that produces
  a byte-identical size would not be flagged. It catches the realistic case
  (a kernel change that also changes the size), not a crafted one.
- **`fdtoverlay` is not U-Boot.** An overlay applying on the host is strong
  evidence, not proof it applies at boot.
- **Nothing here executes aarch64 code.** No boot, no module load, no runtime
  behaviour is tested. That includes `flash.bin`: only its layout and contents
  are checked, not that it brings up the board.
- **Nothing checks against the board's real U-Boot environment.** Load
  addresses are taken from `config.ini`, not read from the target.
- **Verification follows the FIT staging directory.** Reassembling the FIT
  removes obsolete Sparrow Hawk `.dtbo` files before staging the current list,
  preventing deleted overlays from creating false passes or failures.

These limits follow from running without a board. Once a build is on hardware,
`rcar-verify-hardware` checks which FIT configuration U-Boot chose, whether the overlay's nodes reached the
running device tree, and whether a driver bound.

## Extending

`rcar-driver.sh` is plain bash at `scripts/rcar-driver.sh`. Each check is
a `verify_*` function using `ok`/`bad`/`note`. To add one, write the function
and call it from `do_verify`.

When adding a check, prove it **fails when it should**, not only that it passes.
Point `KERNEL_DIR` at a fake tree, or put a broken `.dtbo` into a copy of
`FIT_OUTPUT_DIR`. The stale-fitImage and overlay checks were tested that way.
