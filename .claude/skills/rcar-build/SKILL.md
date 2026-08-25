---
name: rcar-build
description: Build any rcar-utils target for the R-Car V4H Sparrow Hawk — kernel Image/dtbs/modules, out-of-tree modules (cmem/qos/gles), TF-A BL31, initramfs, and the U-Boot fitImage. Also builds the PREEMPT_RT (real-time) variant kernel via KERNEL_VARIANT. Use to build or rebuild after a source change. Do NOT use for editing kernel config, device trees, or boot.cmd — those have their own customize skills.
version: 0.0.1
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, build, phase-2]
  domain: build
---

# Build rcar-utils targets

## Purpose

Run the five build targets and get a fitImage that is actually consistent with
the sources. One skill for all targets because they share setup and dependency
order.

Shared facts: `AGENTS.md` at the repo root.

## Prerequisites

`/rcar-setup-workspace` has run (`rcar-driver.sh preflight` exits 0).

## Always build through the driver

```bash
./scripts/rcar-driver.sh build <target> <sub_command>
```

`main_build.sh` only works with cwd = `local-build-scripts/`; from anywhere
else it continues with an **empty `PLATFORM`** and fails with a misleading
"No such file or directory". The driver handles the cd and reports the exit
code. The human equivalent is `cd local-build-scripts && ./main_build.sh ...`.

## Dependency order

```
kernel ── modules-install ── ext-modules install ──→ deployable module tree
   └──────── Image + DTBs ─┐
bl31 ──────────────────────┼─→ fitImage
initramfs ─────────────────┘   (carries pcie-rcar-gen4.ko from this kernel)
```

`fitimage all` builds and installs the kernel and external modules, builds BL31
and the initramfs, then assembles the FIT, so from clean:

```bash
./scripts/rcar-driver.sh build fitimage all
```

That is the single command for a complete, deployable build. The rest of this
file is for building one piece at a time.

For the PREEMPT_RT kernel the same order applies but `fitimage all` is not
usable - the variant needs its own workspace and each step needs
`KERNEL_VARIANT` set. See *Run: the PREEMPT_RT kernel* below.

## Run: kernel

```bash
./scripts/rcar-driver.sh build kernel image            # Image only
./scripts/rcar-driver.sh build kernel dtbs             # device trees + overlays
./scripts/rcar-driver.sh build kernel all              # image + dtbs
./scripts/rcar-driver.sh build kernel modules          # image + dtbs + modules
./scripts/rcar-driver.sh build kernel modules-install  # install to workspace/kernel-modules
./scripts/rcar-driver.sh build kernel clean
./scripts/rcar-driver.sh build kernel distclean
```

Every target configures the kernel first (defconfig + fragment). See
`/rcar-customize-kernel-config` for how a hand-edited `.config` is preserved.

**`modules-install` exits 0 even when it did not finish.** Without `depmod` it
warns and returns success with no `modules.dep`. Always confirm:

```bash
./scripts/rcar-driver.sh verify
```

**Old module trees are never removed.** A kernel version bump leaves
`workspace/kernel-modules/usr/lib/modules/<old>/` beside `<new>/`; deploying
the directory wholesale ships both. `verify` flags it and prints the `rm -rf`.

## Run: the PREEMPT_RT kernel (and other variants)

`KERNEL_VARIANT=<name>` merges `local-build-scripts/kernel-config/<name>.config`
last — after the board defconfig and fragment — so it overrides them, including
`CONFIG_LOCALVERSION`. That gives the variant its own `uname -r` and its own
`/usr/lib/modules/<release>`, which is what lets both kernels' modules coexist
on the board.

| Variant | Kernel release | What it changes |
|---|---|---|
| `preempt-rt` | `<version>-arm64-renesas-rt` | `CONFIG_PREEMPT_RT=y` — fully preemptible real-time |

**The two variants take turns in `linux-sh/`.** The kernel tree is shared;
only the outputs are separated, and only if you separate them. Give the variant
its own `WORKSPACE_DIR` or it overwrites the stock fitImage and initramfs.

### Full RT build

```bash
cd <rcar-utils>

export KERNEL_VARIANT=preempt-rt
export WORKSPACE_DIR=$PWD/workspace-preempt-rt
export DOWNLOAD_DIR=$PWD/workspace/downloads   # reuse the checksum-verified cache
export BL31_BIN=$PWD/workspace/arm-trusted-firmware/release/bl31-sparrow-hawk.bin

./scripts/rcar-driver.sh build kernel modules-install
./scripts/rcar-driver.sh build ext-modules install
./scripts/rcar-driver.sh build initramfs all
./scripts/rcar-driver.sh build fitimage image
./scripts/rcar-driver.sh verify
```

`BL31_BIN` reuses the blob the stock build already produced — BL31 does not
depend on the kernel. Drop that line and run `build bl31 all` first if there is
no blob at that path.

`verify` and `info` read `WORKSPACE_DIR` too. Keep it exported for them, or
they inspect the stock workspace and report the variant's kernel as stale.

The build leaves the variant's artifacts in `$WORKSPACE_DIR/fitimage/` and
`$WORKSPACE_DIR/kernel-modules/usr/`. To put them on a board, keep
`WORKSPACE_DIR` exported and use `/rcar-deploy-image`.

### Confirm it really is RT

A green build is not proof of the preemption model. Check both:

```bash
cat linux-sh/include/config/kernel.release
#  → 6.18.39-arm64-renesas-rt

strings $WORKSPACE_DIR/fitimage/Image | grep -m1 'Linux version'
#  → ... # SMP PREEMPT_RT          <- the part that matters
```

`verify` must report **0 failed**. The pass count varies with the number of
device-tree overlays staged in the workspace.

### Incremental, after a kernel source change

```bash
./scripts/rcar-driver.sh build kernel modules-install
./scripts/rcar-driver.sh build fitimage image     # separate target - see below
./scripts/rcar-driver.sh verify
```

### Back to the stock kernel

```bash
unset KERNEL_VARIANT WORKSPACE_DIR
./scripts/rcar-driver.sh build fitimage all
./scripts/rcar-driver.sh verify
```

Switching or dropping `KERNEL_VARIANT` regenerates `.config` and recompiles.

**Expect `verify` to fail against a workspace whose variant is not the one
currently in the tree** — it compares `linux-sh/arch/arm64/boot/Image` with the
fitImage, so after building stock, a `verify` pointed at the RT workspace
reports `fitImage kernel is STALE` and `no module tree for the built kernel`.
That is the tree having taken its turn, not a broken artifact. Rebuild the
variant you want to check.

### Editing or adding a variant

The fragment is `local-build-scripts/kernel-config/<name>.config`; a new file
there is a new variant, and `KERNEL_VARIANT` picks it up with no code change.
An unknown name errors out and lists the valid ones.

**After every edit, diff the generated `.config` against the stock one and
confirm every difference is one you meant.** A fragment's own dependencies can
silently change unrelated symbols: `PREEMPT_RT` requires `EXPERT`, and `EXPERT`
flips everything declared `default y if !EXPERT` — that turned 13 `HID_*` quirk
drivers off and the entire media/DVB menu on (+116 modules) until
`preempt-rt.config` grew a block pinning them back. Keep the release suffix to
letters, digits, `.` and `-` - it becomes `uname -r` and the module directory
name.

```bash
cp linux-sh/.config /tmp/variant.config
unset KERNEL_VARIANT && ./scripts/rcar-driver.sh build kernel defconfig
diff <(sort /tmp/variant.config) <(sort linux-sh/.config)
```

## Run: ext-modules

```bash
./scripts/rcar-driver.sh build ext-modules all      # fetch if needed, then build
./scripts/rcar-driver.sh build ext-modules fetch    # re-clone at pinned rev, re-apply patches
./scripts/rcar-driver.sh build ext-modules install  # build + install to kernel-modules
./scripts/rcar-driver.sh build ext-modules clean
```

Requires a built kernel — it checks for `linux-sh/Module.symvers` and tells you
to run `kernel modules` first. Builds cmem, qos and gles (PowerVR). See
`/rcar-customize-extmodules` to add or patch one.

## Run: bl31

```bash
./scripts/rcar-driver.sh build bl31 all
./scripts/rcar-driver.sh build bl31 fetch
./scripts/rcar-driver.sh build bl31 clean
```

Independent of the kernel. Every FIT configuration loads BL31, so `fitimage`
needs it. Produces `bl31-sparrow-hawk.{bin,elf,srec}` in
`workspace/arm-trusted-firmware/release/`.

## Run: initramfs

```bash
./scripts/rcar-driver.sh build initramfs all      # busybox if needed, then the cpio
./scripts/rcar-driver.sh build initramfs busybox  # static busybox only
./scripts/rcar-driver.sh build initramfs clean
```

Only needed to boot a rootfs that is **not** on eMMC/SD — `boot.cmd` selects
the `#initramfs` FIT configuration when the boot device is not `mmcblk`.
Requires built kernel modules: it takes `pcie-rcar-gen4.ko` from that build,
and its vermagic must match the kernel in the same fitImage.

## Run: fitimage

```bash
./scripts/rcar-driver.sh build fitimage all    # complete deployable build
./scripts/rcar-driver.sh build fitimage image  # assemble from existing builds
./scripts/rcar-driver.sh build fitimage clean
```

**`kernel` and `fitimage` are separate targets.** Rebuilding the kernel does
*not* update `workspace/fitimage/`. Use `fitimage image` after a kernel build,
or `verify` will report `fitImage kernel is STALE`.

`BL31_BIN` / `INITRAMFS_CPIO` set in `config.ini` mean "a blob from another
build" — those are taken as-is and never rebuilt here.

## After every build

```bash
./scripts/rcar-driver.sh verify
```

Non-negotiable: three of this build's failure modes exit 0. See
`/rcar-verify-build`.

## Timings

Measured on a 96-core container with the kernel already built:

| Command | Time |
|---|---|
| `build kernel image` (incremental, no change) | ~4 s |
| `build kernel modules` (incremental) | ~7 s |
| `build fitimage image` | ~1 s |
| `build fitimage all` | depends on external-module state |
| `build initramfs all` (busybox already built) | ~7 s |
| `build bl31 all` (after `bl31 clean`) | ~3 s |
| `rcar-driver.sh smoke` | same full build, then verify |

A cold `kernel all` from a clean tree is far longer and was not timed.

**Switching `KERNEL_VARIANT` is never incremental.** It regenerates `.config`,
so the whole tree recompiles - minutes, not seconds. `preempt-rt` also enables
`CONFIG_DEBUG_INFO`, which makes both the compile and the resulting `.ko` files
noticeably larger. Neither was timed precisely; budget for a full rebuild, not
a top-up.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `./config.ini: No such file or directory`, `Target platform` empty | Wrong cwd — use `rcar-driver.sh build` |
| `Warning: 'make modules_install' requires depmod` | `sudo apt-get install -y kmod`, re-run |
| `Error: Module.symvers not found` | `build kernel modules` before `ext-modules` |
| `verify` says `fitImage kernel is STALE` | `build fitimage image` |
| `Error: kernel image not found` from fitimage | `build fitimage all`, or build the kernel first |
| `Error: BL31 blob not found` | `BL31_BIN` in `config.ini` points at a missing file; fix or unset it |
| `Error: unknown KERNEL_VARIANT '<x>'` | Typo; the error lists the valid names (fragments in `local-build-scripts/kernel-config/`) |
| `verify` says STALE *and* `no module tree for the built kernel` | `linux-sh/` holds the other variant; re-run the build for the variant you are checking |
| Variant build overwrote the stock fitImage | `WORKSPACE_DIR` was not set; it is not optional for a variant |
| Variant kernel came out as `-arm64-renesas` | `KERNEL_VARIANT` not exported for that command — every `build` call needs it |
