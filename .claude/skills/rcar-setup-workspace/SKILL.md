---
name: rcar-setup-workspace
description: Prepare a machine to build rcar-utils for the R-Car V4H Sparrow Hawk — install host packages, clone the linux-sh kernel source, and run a toolchain preflight. Use on a fresh container/host or when a build fails on a missing tool. Do NOT use for building, kernel config edits, or deploying to the board.
version: 0.0.1
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, setup, phase-1]
  domain: build
---

# Setup the rcar-utils build workspace

## Purpose

Get a clean Ubuntu host or container to the point where
`scripts/rcar-driver.sh smoke` passes. Everything else in this repo
assumes that has happened.

Shared facts: `AGENTS.md` at the repo root.

## Prerequisites

Ubuntu. **Verified on 22.04**, despite `local-build-scripts/README.md` asking
for 24.04 — nothing required 24.04.

## Procedure

### 1. Host packages

```bash
sudo apt-get update
sudo apt-get install -y build-essential gcc-aarch64-linux-gnu \
    libc6-dev-arm64-cross bc bison flex libssl-dev u-boot-tools \
    kmod cpio curl git device-tree-compiler
```

Two of these are easy to miss and neither fails loudly:

- **`kmod`** provides `depmod`. Without it `make modules_install` prints
  `Warning: 'make modules_install' requires depmod`, **returns 0**, and writes
  no `modules.dep`. The modules install fine and nothing modprobes on the
  board. `depmod` lives in `/usr/sbin`, which may be off a non-root `PATH`.
- **`device-tree-compiler`** provides `fdtoverlay`, which is how overlays are
  validated. Without it both `preflight` and `verify` fail.

The list in `local-build-scripts/README.md` omits `device-tree-compiler`.

### 2. Kernel source

`linux-sh/` is gitignored and cloned on demand — but the build only offers to
clone **when stdin is a TTY**. Non-interactively it prints the command and
exits 1 (`common.sh` checks `[ ! -t 0 ]`). Pre-clone it once:

```bash
git clone --single-branch --branch ubuntu/rcar-v4h-sh \
    https://github.com/renesas-rdk/linux-sh.git linux-sh
```

To build against a tree you already have, set `KERNEL_DIR` per run or uncomment
it in `config.ini`.

### 3. Preflight

```bash
./scripts/rcar-driver.sh preflight
```

Checks every tool above plus the kernel source, one `ok`/`FAIL` line each, and
names the fix for whatever is missing. Exit 0 when clean.

### 4. Confirm end to end

```bash
./scripts/rcar-driver.sh smoke
```

This performs the complete build and can take several minutes from a cold
workspace. Warm rebuild time depends mostly on the external modules.

## Verification

`preflight` exits 0 and reports `ok` for: `aarch64-linux-gnu-gcc`, `make`,
`bc`, `bison`, `flex`, `cpio`, `git`, `curl`, `mkimage`, `dtc`, `fdtoverlay`,
`depmod`, and the kernel source path.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Error: not running interactively, so the source cannot be cloned here` | Pre-clone `linux-sh/` (step 2) |
| `preflight` says `depmod not found` | `sudo apt-get install -y kmod`; check `/usr/sbin` is on `PATH` |
| `preflight` says `fdtoverlay not found` | `sudo apt-get install -y device-tree-compiler` |
| `Error: 'mkimage' not found` | `sudo apt-get install -y u-boot-tools` |
| `<dir> exists but is not a kernel source tree` | `linux-sh/` is non-empty but has no `Makefile` + `arch/arm64`; remove or point `KERNEL_DIR` elsewhere |

## Next

`/rcar-build` to build, `/rcar-quick-start` if you are not sure what you need.
