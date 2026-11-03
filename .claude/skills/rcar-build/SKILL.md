---
name: rcar-build
description: Build any rcar-utils target for the R-Car V4H Sparrow Hawk, including the kernel Image/dtbs/modules, out-of-tree modules (cmem/qos/gles), TF-A BL31, initramfs, the U-Boot fitImage, and the IPL burning package (flash.bin). Also builds the PREEMPT_RT (real-time) variant kernel via KERNEL_VARIANT. Use to build or rebuild after a source change. Do NOT use for editing kernel config, device trees, or boot.cmd. Those have their own customize skills.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, build, phase-2]
  domain: build
---

# Build rcar-utils targets

## Purpose

Run the build targets and get a fitImage that matches the sources. One skill
covers all targets because they share setup and dependency order.

Shared facts: `AGENTS.md` at the repo root.

## Prerequisites

`rcar-setup-workspace` has run (`rcar-driver.sh preflight` exits 0).

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
usable. The variant needs its own workspace and each step needs
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
`rcar-customize-kernel-config` for how a hand-edited `.config` is preserved.

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
last, after the board defconfig and fragment, so it overrides them, including
`CONFIG_LOCALVERSION`. That gives the variant its own `uname -r` and its own
`/usr/lib/modules/<release>`, which is what lets both kernels' modules coexist
on the board.

| Variant | Kernel release | What it changes |
|---|---|---|
| `preempt-rt` | `<version>-rcarv4h-sh-rt` | `CONFIG_PREEMPT_RT=y` (fully preemptible real-time) |

**Both variants build in the same `linux-sh/` tree.** Only the outputs can be
kept apart. Give the variant its own `WORKSPACE_DIR` or it overwrites the stock
fitImage and initramfs. Any name works because `.gitignore` globs
`/workspace-*/`, so reuse the name already in the repo instead of adding a second
one.

### Full RT build

```bash
cd <rcar-utils>

export KERNEL_VARIANT=preempt-rt

# Reuse the variant workspace if one already exists - building into a new name
# duplicates the whole tree and leaves two RT workspaces to tell apart:
ls -d "$PWD"/workspace-*/ 2>/dev/null       # e.g. workspace-rt/
export WORKSPACE_DIR=$PWD/workspace-rt      # or the name that printed above
export DOWNLOAD_DIR=$PWD/workspace/downloads   # reuse the checksum-verified cache
export BL31_BIN=$PWD/workspace/arm-trusted-firmware/release/bl31-sparrow-hawk.bin

./scripts/rcar-driver.sh build kernel modules-install
./scripts/rcar-driver.sh build ext-modules install
./scripts/rcar-driver.sh build initramfs all
./scripts/rcar-driver.sh build fitimage image
./scripts/rcar-driver.sh verify
```

`BL31_BIN` reuses the blob the stock build already produced, because BL31 does not
depend on the kernel. Drop that line and run `build bl31 all` first if there is
no blob at that path.

`verify` and `info` read `WORKSPACE_DIR` too. Keep it exported for them, or
they inspect the stock workspace and report the variant's kernel as stale.

The build leaves the variant's artifacts in `$WORKSPACE_DIR/fitimage/` and
`$WORKSPACE_DIR/kernel-modules/usr/`. To put them on a board, keep
`WORKSPACE_DIR` exported and use `rcar-deploy-image`.

### Confirm the kernel is RT

A green build is not proof of the preemption model. Check both:

```bash
cat linux-sh/include/config/kernel.release
#  → 6.18.39-rcarv4h-sh-rt

strings $WORKSPACE_DIR/fitimage/Image | grep -m1 'Linux version'
#  → ... # SMP PREEMPT_RT          <- the part that matters
```

`verify` must report **0 failed**. The pass count varies with the number of
device-tree overlays staged in the workspace.

### RT changes driver behaviour as well as latency

Neither check above says anything about run time, and a clean build plus a
clean `verify` is compatible with a kernel that warns on every boot. Under
`CONFIG_PREEMPT_RT` any handler registered without `IRQF_NO_THREAD`,
`IRQF_PERCPU` or `IRQF_ONESHOT` is *force-threaded*, so it runs in a kthread with
hardirqs enabled rather than in hardirq context. Drivers that were correct on
the stock kernel can break that way, and interrupt-controller demux handlers
are the common case: dispatching a child interrupt from thread context triggers

```
irq N handler <fn> enabled interrupts
WARNING: ... __handle_irq_event_percpu
```

It is a `WARN_ONCE`, so it prints once per boot and is easy to miss. After
booting a new RT kernel, read the log before assuming the variant is healthy:

```bash
dmesg | grep -iE 'enabled interrupts|__handle_irq_event'
```

The expected result is no output. A hit is a real defect, not RT noise to filter
out, because the flow handler takes `desc->lock` with a plain `raw_spin_lock()`
that assumes hardirqs are off. The fix belongs in the offending
driver's `request_irq` flags, not in the RT fragment.

### Incremental, after a kernel source change

```bash
./scripts/rcar-driver.sh build kernel modules-install
./scripts/rcar-driver.sh build ext-modules install
./scripts/rcar-driver.sh build initramfs all
./scripts/rcar-driver.sh build fitimage image     # separate target - see below
./scripts/rcar-driver.sh verify
```

The external modules and the PCIe module bundled into the initramfs are built
against the kernel. Rebuilding only the kernel and FIT can leave ABI-stale
modules while still producing an image, so do not omit those two steps.

### Back to the stock kernel

```bash
unset KERNEL_VARIANT WORKSPACE_DIR
./scripts/rcar-driver.sh build fitimage all
./scripts/rcar-driver.sh verify
```

Switching or dropping `KERNEL_VARIANT` regenerates `.config` and recompiles.

**Expect `verify` to fail against a workspace whose variant is not the one
currently in the tree.** It compares `linux-sh/arch/arm64/boot/Image` with the
fitImage, so after building stock, a `verify` pointed at the RT workspace
reports `fitImage kernel is STALE` and `no module tree for the built kernel`.
That means the tree holds the other variant, not that the artifact is broken.
Rebuild the variant you want to check.

### Editing or adding a variant

The fragment is `local-build-scripts/kernel-config/<name>.config`; a new file
there is a new variant, and `KERNEL_VARIANT` picks it up with no code change.
An unknown name errors out and lists the valid ones.

**After every edit, diff the generated `.config` against the stock one and
confirm every difference is one you meant.** A fragment's own dependencies can
silently change unrelated symbols: `PREEMPT_RT` requires `EXPERT`, and `EXPERT`
flips everything declared `default y if !EXPERT`. That turned 13 `HID_*` quirk
drivers off and the entire media/DVB menu on (+116 modules) until
`preempt-rt.config` added a block pinning them back. Keep the release suffix to
letters, digits, `.` and `-`, because it becomes `uname -r` and the module directory
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

Requires a built kernel. It checks for `linux-sh/Module.symvers` and tells you
to run `kernel modules` first. Builds cmem, qos and gles (PowerVR). See
`rcar-customize-extmodules` to add or patch one.

## Run: bl31

```bash
./scripts/rcar-driver.sh build bl31 all      # 'image' is an alias for 'all'
./scripts/rcar-driver.sh build bl31 fetch
./scripts/rcar-driver.sh build bl31 clean
```

Independent of the kernel. Every FIT configuration loads BL31, so `fitimage`
needs it. Produces `bl31-sparrow-hawk.{bin,elf,srec}` in
`workspace/arm-trusted-firmware/release/`.

## Run: ipl

```bash
./scripts/rcar-driver.sh build ipl all      # 'image' is an alias for 'all'
./scripts/rcar-driver.sh build ipl fetch    # destructive: resets workspace/u-boot
./scripts/rcar-driver.sh build ipl clean
```

Independent of the kernel, and not part of `fitimage all` or `smoke`. Builds
`flash.bin` from U-Boot (`r8a779g3_sparrowhawk_defconfig` plus the fragments and
`sparrowhawk.env` in `local-build-scripts/ipl/u-boot/`), then installs the
burning package to `workspace/ipl-burning/`: `flash.bin`, the PCIe firmware, the
flash writer, the Linux and Windows burning tools, embedded Python and licences.

`flash.bin` does not contain BL31; that stays in the fitImage. Run `verify`
afterwards. A first build takes minutes, mostly fetching U-Boot.

Writing the package to a board is `./run.sh` (Linux) or `run.bat` (Windows) from
that directory, over the serial console, with DIP switches set by hand as the
tool prompts. It overwrites the bootloader in QSPI: **ask the user first.**
`run.sh` uses the system Python when it already has `pyserial`, `colorama` and
`tqdm`; otherwise it installs them into `.venv/` in that directory, which needs
`python3-venv`.

## Run: initramfs

```bash
./scripts/rcar-driver.sh build initramfs all      # busybox if needed, then the cpio
./scripts/rcar-driver.sh build initramfs busybox  # static busybox only
./scripts/rcar-driver.sh build initramfs clean
```

`initramfs image` is an alias for `all`.

Only needed to boot a rootfs that is **not** on eMMC/SD. `boot.cmd` selects
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
build". The build uses those as they are and never rebuilds them.

## After every build

```bash
./scripts/rcar-driver.sh verify
```

Always run it, because three of this build's failure modes exit 0. See
`rcar-verify-build`.

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
| `build ipl all` (cold, in a clean container) | ~5 min |
| `rcar-driver.sh smoke` | same full build, then verify |

A cold `kernel all` from a clean tree is far longer and was not timed.

**Switching `KERNEL_VARIANT` is never incremental.** It regenerates `.config`,
so the whole tree recompiles, which takes minutes rather than seconds.
`preempt-rt` also enables `CONFIG_DEBUG_INFO`, which makes the compile slower and
the resulting `.ko` files larger. Neither was timed precisely, so plan for a full
rebuild.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `./config.ini: No such file or directory`, `Target platform` empty | Wrong cwd. Use `rcar-driver.sh build` |
| `Warning: 'make modules_install' requires depmod` | `sudo apt-get install -y kmod`, re-run |
| `Error: Module.symvers not found` | `build kernel modules` before `ext-modules` |
| `verify` says `fitImage kernel is STALE` | `build fitimage image` |
| `Error: kernel image not found` from fitimage | `build fitimage all`, or build the kernel first |
| `Error: python3 cannot find pyelftools, setuptools or Python.h` | Install the packages the error lists |
| `_libfdt.so: undefined symbol: PyInt_AsLong` from binman | `swig` is too new (4.5.1 fails, Ubuntu 24.04's 4.2.0 works); use the distro package |
| `Error: BL31 blob not found` | `BL31_BIN` in `config.ini` points at a missing file; fix or unset it |
| `Error: unknown KERNEL_VARIANT '<x>'` | Typo; the error lists the valid names (fragments in `local-build-scripts/kernel-config/`) |
| `verify` says STALE *and* `no module tree for the built kernel` | `linux-sh/` holds the other variant; re-run the build for the variant you are checking |
| Variant build overwrote the stock fitImage | `WORKSPACE_DIR` was not set; it is not optional for a variant |
| Variant kernel came out as `-rcarv4h-sh` | `KERNEL_VARIANT` not exported for that command. Every `build` call needs it |
