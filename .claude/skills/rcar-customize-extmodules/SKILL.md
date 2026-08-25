---
name: rcar-customize-extmodules
description: Add, patch, or re-pin the out-of-tree kernel modules built for the R-Car V4H Sparrow Hawk — cmemdrv, qos, and the PowerVR GPU driver (gles/pvrsrvkm). Use to bump a module revision, add a patch, or register a new external module. Do NOT use for in-tree kernel modules (rcar-customize-kernel-config) or device tree changes.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, modules, out-of-tree, phase-2]
  domain: kernel
---

# Customize the out-of-tree modules

## Purpose

Manage the three external kernel modules this standalone build fetches from
upstream, pins, patches, builds, and installs:

| Name | Source | Pinned by | Installs to |
|---|---|---|---|
| `cmem` | `github.com/renesas-rcar/cmem.git` | `CMEM_SRCREV` | `updates/` |
| `qos` | `github.com/renesas-rcar/qos_drv.git` | `QOS_SRCREV` | `extra/` |
| `gles` | PowerVR tarball from `rcar-community/rcar-gfx` | `GLES_SHA256` | `extra/` |

`qos` is marked *"Unsupported for now"* in `local-build-scripts/README.md`, but
it is in the build table and does build.

Shared facts: `AGENTS.md` at the repo root.

## Prerequisites

A built kernel. The script checks for `linux-sh/Module.symvers` and refuses
otherwise:

```
Error: <kernel>/Module.symvers not found.
       External modules link against the kernel build, so build it
       first: ./main_build.sh kernel modules
```

## The registration table

`local-build-scripts/build_ext_modules.sh`, near the top:

```sh
EXT_MODULES=(
	"cmem|git|${CMEM_URL}|${CMEM_SRCREV}|.|*.ko|updates"
	"qos|git|${QOS_URL}|${QOS_SRCREV}|qos-module/files/qos/drv|qos-module/files/qos/drv/*.ko|extra"
	"gles|tar|${GLES_URL}|${GLES_SHA256}|rogue_km/build/linux/r8a779g_linux|rogue_km/pvrsrvkm.ko|extra"
)
```

Fields, `|`-separated:

| # | Field | Meaning |
|---|---|---|
| 1 | `name` | directory under `workspace/ext-modules/`, and `patches/<name>/` |
| 2 | `type` | `git` (clone + checkout rev) or `tar` (download + sha256 + extract) |
| 3 | `url` | source |
| 4 | `rev` | git commit for `git`; **sha256 for `tar`** — the checksum *is* the pin |
| 5 | `sub` | subdirectory to run `make` in, relative to the source root |
| 6 | `koglob` | glob of the `.ko` files to install |
| 7 | `instdir` | subdirectory under `/usr/lib/modules/<ver>/` |

## Run

```bash
./scripts/rcar-driver.sh build ext-modules all      # fetch if needed, then build
./scripts/rcar-driver.sh build ext-modules fetch    # re-clone at pinned rev, re-apply patches
./scripts/rcar-driver.sh build ext-modules install  # build + install into kernel-modules
./scripts/rcar-driver.sh build ext-modules clean
```

## Procedure: bump a revision

1. Edit the pin in `local-build-scripts/config.ini` (`CMEM_SRCREV`,
   `QOS_SRCREV`, or `GLES_SHA256` + `GLES_URL`).
2. Re-fetch — this is **destructive** to local edits in
   `workspace/ext-modules/<name>/`:

```bash
./scripts/rcar-driver.sh build ext-modules fetch
```

3. Rebuild and install:

```bash
./scripts/rcar-driver.sh build ext-modules install
./scripts/rcar-driver.sh verify
```

Expect patches to break on a bump. `fetch` re-applies `patches/<name>/series`
against the new revision and **exits 1** on the first failure:

```
Error: failed to apply <name>/<patch>
```

Refresh or drop the offending patch, then re-run.

## Procedure: add a patch

Patches live in `local-build-scripts/patches/<name>/`, applied with
`patch -p1` in the order listed in `series`.

**The order is not alphabetical** — it is the required patch application
order. The current `cmem` series is deliberately out of numeric order:

```
fix_build_error_612.patch
0001-WIP-Fix-DMA-mask-not-set.patch
0002-Fix-allocation-of-cmem-_other-regions.patch
0001-Fix-bit_ranges-is-not-correct-value.patch
0001-WIP-Use-physical-address-directly.patch
```

To add one:

```bash
cd workspace/ext-modules/cmem
# make your change, then:
git diff > ../../../local-build-scripts/patches/cmem/0003-my-change.patch
```

Add the filename to `patches/cmem/series` **at the right position**, then prove
it applies from scratch:

```bash
./scripts/rcar-driver.sh build ext-modules fetch
```

Blank lines and `#` comments in `series` are skipped.

## Procedure: register a new module

1. Add a row to `EXT_MODULES` (fields above).
2. Add `URL`/`SRCREV` (or `SHA256`) variables to `config.ini`, following the
   existing naming.
3. Optionally create `patches/<name>/series`.
4. Build and confirm the `.ko` appears:

```bash
./scripts/rcar-driver.sh build ext-modules all
find workspace/ext-modules/<name> -name '*.ko'
```

5. Install and verify:

```bash
./scripts/rcar-driver.sh build ext-modules install
./scripts/rcar-driver.sh verify
```

## Gotchas

- **`fetch` runs `git checkout -f` then `git clean -qxfd`.** Uncommitted work
  in `workspace/ext-modules/<name>/` is destroyed without a prompt. Export a
  patch first.
- **Different modules read different env vars for the kernel path.** The script
  exports all three because the upstream Makefiles disagree — `cmem` uses
  `KERNEL_SRC`, `qos` uses `KERNELSRC`, and `KERNELDIR` is set too. A new
  module may need a fourth; check its Makefile.
- **`LDFLAGS=""` is exported deliberately.** Inheriting a host `LDFLAGS`
  breaks these module builds.
- **`LOCALVERSION=""` is exported** so the module vermagic matches the kernel.
- **A `tar` module is pinned by checksum, not revision.** Changing `GLES_URL`
  without updating `GLES_SHA256` fails the download verification — that is the
  intended behaviour, not a bug.
- **The gles build prints
  `WARNING: You are not specifying how to find dependent libraries … SYSROOT`.**
  Expected; it still produces `pvrsrvkm.ko` and exits 0.
- **Module vermagic must match the kernel in the same fitImage.** After a
  kernel config or version change, rebuild the external modules too — nothing
  checks this on the host, it fails at `insmod` on the board.
- **`ext-modules install` refreshes `modules.dep`.** It requires `depmod` from
  the `kmod` package and fails rather than leaving stale dependency metadata.

## Verification

```bash
find workspace/ext-modules -name '*.ko'
find workspace/kernel-modules/usr/lib/modules/*/extra \
     workspace/kernel-modules/usr/lib/modules/*/updates -name '*.ko' 2>/dev/null
./scripts/rcar-driver.sh verify
```

Check a module's vermagic against the kernel release:

```bash
modinfo workspace/ext-modules/cmem/cmemdrv.ko | grep vermagic
cat linux-sh/include/config/kernel.release
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Module.symvers not found` | Kernel not built | `rcar-driver.sh build kernel modules` |
| `Error: failed to apply <name>/<patch>` | Patch does not fit the pinned revision | Refresh the patch or fix `series` order |
| Checksum mismatch on a `tar` module | `*_URL` changed without `*_SHA256` | Update both together |
| `.ko` built but not installed | Wrong `koglob` or `sub` in `EXT_MODULES` | Fix the row; paths are relative to the source root |
| `insmod` fails on the board with vermagic mismatch | Modules built against a different kernel | Rebuild kernel then `ext-modules install` |
