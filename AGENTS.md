# AGENTS.md — rcar-utils

Instructions for coding agents (Codex, GitHub Copilot, Claude Code, …) working
in this repo. Humans: this doubles as the orientation doc.

Standalone build and deployment scripts for the **R-Car V4H Sparrow Hawk**
(`PLATFORM=RCAR-V4H-SH`, SoC `r8a779g3`). They produce the kernel, modules,
firmware, initramfs, TF-A BL31, and U-Boot `fitImage` directly from source.
Branch `ubuntu/rcar-v4h-sh` is trimmed to the Sparrow Hawk build only.

## Two entry points — use these, not raw make

Both are plain bash with no dependencies beyond the build toolchain. Run them
from the repo root; they work from any cwd.

```bash
./scripts/rcar-driver.sh <preflight|build|verify|smoke|info> [args]
./scripts/rcar-deploy.sh --host <board-ip> [options]
```

Run either with no arguments for full usage.

## Read this before running anything

### 1. `main_build.sh` only works with cwd = `local-build-scripts/`

It does `source ./config.ini` and `source ./common.sh`. Run from anywhere else
it prints `./config.ini: No such file or directory`, then **carries on with an
empty `PLATFORM`** before failing on the sub-script — the error names a missing
file, not a wrong directory.

**Never call `main_build.sh` directly.** Use `./scripts/rcar-driver.sh build
<target> <sub_command>`, which handles the cd and propagates the exit code.

### 2. Three failure modes exit 0

A green build is **not** evidence the build is good:

| Failure | Why it is silent |
|---|---|
| Stale fitImage | `kernel` and `fitimage` are separate targets; rebuilding the kernel does not re-assemble the FIT |
| No `modules.dep` | `make modules_install` only **warns** when `depmod` is missing, then returns success |
| Broken `.dtbo` | An overlay that no longer applies still compiles; it fails at boot, only with that overlay selected |

`./scripts/rcar-driver.sh verify` catches all three. **Run it after every
build.** Treat a failing verify as a failing build.

### 3. Never hardcode the kernel version

It changes with the source and with `KERNEL_LOCALVERSION`. Always read it:

```bash
REL=$(cat linux-sh/include/config/kernel.release)
```

## Common tasks

```bash
# fresh machine: what is missing?
./scripts/rcar-driver.sh preflight

# build everything from clean (installed kernel/external modules + BL31 + initramfs + FIT)
./scripts/rcar-driver.sh build fitimage all

# incremental: rebuild kernel, re-assemble the FIT, check
./scripts/rcar-driver.sh build kernel modules
./scripts/rcar-driver.sh build fitimage image
./scripts/rcar-driver.sh verify

# complete build + verify in one step
./scripts/rcar-driver.sh smoke

# what is currently built?
./scripts/rcar-driver.sh info

# deploy to a running board, then reboot and verify it came back
./scripts/rcar-deploy.sh --host 192.168.1.50 --dry-run   # rehearse first
./scripts/rcar-deploy.sh --host 192.168.1.50
```

`build` takes the same `<target> <sub_command>` pairs as `main_build.sh`:

```
kernel        clean | distclean | defconfig | menuconfig | image | dtbs |
              all | modules | modules-install
ext-modules   all | fetch | install | clean
bl31          all | fetch | clean
initramfs     all | image | busybox | clean
fitimage      all | image | clean
```

## Setup

Ubuntu. Verified on 24.04 LTS.

```bash
sudo apt-get update
sudo apt-get install -y build-essential gcc-aarch64-linux-gnu \
    libc6-dev-arm64-cross bc bison flex libssl-dev u-boot-tools \
    kmod cpio curl git device-tree-compiler
```

The kernel source is cloned on demand, but **only when stdin is a TTY** — an
agent running non-interactively gets an error, not a clone. Pre-clone it:

```bash
git clone --single-branch --branch ubuntu/rcar-v4h-sh \
    https://github.com/renesas-rdk/linux-sh.git linux-sh
```

`scripts/rcar-deploy.sh` additionally needs `sshpass` and `rsync` on the host.

## Layout

```
<rcar-utils>/
├── linux-sh/              kernel source, cloned on demand (gitignored)
├── local-build-scripts/   build scripts + config.ini
├── scripts/               rcar-driver.sh, rcar-deploy.sh  ← agent entry points
├── workspace/             every output (gitignored)
│   ├── kernel-modules/    installed modules + firmware
│   ├── ext-modules/       cmem, qos, gles sources
│   ├── arm-trusted-firmware/
│   ├── initramfs/         busybox tree + uInitramfs.cpio.gz
│   ├── fitimage/          FIT inputs + fitImage
│   └── downloads/         checksum-verified download cache
└── .claude/skills/        per-task deep docs (plain markdown, any agent can read)
```

`workspace/` and `linux-sh/` are gitignored, so `git status` says nothing about
build state. `./scripts/rcar-driver.sh info` is the view.

## config.ini

Sourced *before* `common.sh`, so anything assigned there wins over the
environment. Paths are left **commented out** on purpose: an assignment — even
an empty one — would overwrite an env var. While a line stays commented, the
same variable can be set per run:

```bash
KERNEL_MODULES_OUTPUT_DIR=/tmp/mods ./scripts/rcar-driver.sh build kernel modules-install
```

Pinned inputs live here too: `CMEM_SRCREV`, `QOS_SRCREV`, `GLES_SHA256`,
`TFA_SRCREV`, `BUSYBOX_SHA256`, `PCIE_FW_SHA256`, plus
`FIT_KERNEL_LOADADDR=0x50200000` / `FIT_ATF_LOADADDR=0x46400000` and
`KERNEL_LOCALVERSION=-arm64-renesas`.

## Kernel variants

`KERNEL_VARIANT=<name>` builds a second kernel from the same source tree with
`local-build-scripts/kernel-config/<name>.config` merged **last**, so it can
override anything the board configuration set - including
`CONFIG_LOCALVERSION`, which gives the variant its own `uname -r` and its own
`/usr/lib/modules/<release>`. One variant ships today:

| Variant | Kernel release | What it changes |
|---|---|---|
| `preempt-rt` | `<version>-arm64-renesas-rt` | `CONFIG_PREEMPT_RT=y` (fully preemptible real-time) |

Give a variant its own `WORKSPACE_DIR`, or it overwrites the stock build's
fitImage and initramfs:

```bash
export KERNEL_VARIANT=preempt-rt
export WORKSPACE_DIR=$PWD/workspace-preempt-rt
./scripts/rcar-driver.sh build kernel modules-install
./scripts/rcar-driver.sh build ext-modules install
./scripts/rcar-driver.sh build initramfs all
./scripts/rcar-driver.sh build fitimage image
WORKSPACE_DIR=$PWD/workspace-preempt-rt ./scripts/rcar-driver.sh verify
```

The kernel tree itself is shared, so the two variants take turns in
`linux-sh/` - switching `KERNEL_VARIANT` regenerates `.config` and recompiles.
Only the outputs under `WORKSPACE_DIR` are kept apart.

**A variant fragment has to pin back what its own dependencies unhide.**
`PREEMPT_RT` depends on `EXPERT`, and a number of unrelated symbols are
declared `default y if !EXPERT` - turning `EXPERT` on silently flipped 13
`HID_*` quirk drivers off and the whole media/DVB menu on (+116 modules) before
`preempt-rt.config` pinned them back. After adding or editing a variant, diff
its `.config` against the stock one and check every difference is one you
meant.

## The deliverable is the artifacts

`rcar-utils` produces build artifacts, not packages. A finished build leaves

```
WORKSPACE_DIR/fitimage/            fitImage, Image, *.dtb, *.dtbo
WORKSPACE_DIR/kernel-modules/usr/  modules, firmware, headers, modprobe.d
```

and `scripts/rcar-deploy.sh` copies exactly those onto a running board. That is
the whole path from source to hardware - there is no packaging step here and
nothing else to run.

## Boot contract

The board's U-Boot environment loads the fitImage from **partition 1** and
sources the boot script embedded in it:

```
load mmc 0:1  ${loadaddr} /boot/fitImage && source ${loadaddr}:script
load nvme 0:1 ${loadaddr} /boot/fitImage && source ${loadaddr}:script
load usb 0:1  ${loadaddr} /boot/fitImage && source ${loadaddr}:script
```

On-target layout:

```
/boot/                    fitImage (the only file U-Boot reads), *.dtb, *.dtbo
/usr/lib/modules/<rel>/   modules + modules.dep
/usr/lib/firmware/        rcar_gen4_pcie.bin, LICENCE, rgx.fw.*, rgx.sh.*
/usr/lib/modules-load.d/  cmemdrv, pvrsrvkm, uio_pdrv_genirq .conf
/usr/lib/modprobe.d/      cmemdrv, uio_pdrv_genirq .conf
```

The target rootfs must be **usrmerged** (`/lib` → `/usr/lib`): modules install
under `/usr/lib/modules/`, and `depmod` searches `/lib/modules`.

## Expected build noise — not errors

- `warning: override: reassigning to symbol ...` — the defconfig and the
  `sparrow_hawk.config` fragment are concatenated then run through
  `make alldefconfig`; the overrides are the fragment doing its job.
- `Description: unavailable` / `Kernel: unavailable` in `mkimage -l` for the
  overlay configurations — they carry only an `fdt` property and inherit the
  kernel from the `default` config.
- `WARNING: You are not specifying how to find dependent libraries ... SYSROOT`
  during the gles (PowerVR) build.

## Safety

- **Deploying is destructive and outward-facing.** `scripts/rcar-deploy.sh`
  overwrites `/boot` and `/usr/lib/modules` on the board and reboots it. Ask
  the user before the first real run, name the board, and prefer `--dry-run`
  first. It backs up automatically and refuses to run when `verify` fails.
- **Do not delete anything under `workspace/`** without asking — it is build
  output the user may still need, even when `verify` flags it as stale.
- **`ext-modules fetch` is destructive**: it runs `git checkout -f` and
  `git clean -qxfd` in `workspace/ext-modules/<name>/`.

## Deeper documentation

Task-specific guides live in `.claude/skills/<topic>/SKILL.md`. They are plain
markdown with a YAML header — readable by any agent or human, not Claude-only.
Open the one that matches the task:

| Task | File |
|---|---|
| Prepare a machine | `.claude/skills/rcar-setup-workspace/SKILL.md` |
| Build any target | `.claude/skills/rcar-build/SKILL.md` |
| Verify artifacts | `.claude/skills/rcar-verify-build/SKILL.md` |
| Inspect build state | `.claude/skills/rcar-print-build-info/SKILL.md` |
| Kernel Kconfig | `.claude/skills/rcar-customize-kernel-config/SKILL.md` |
| Device trees / overlays | `.claude/skills/rcar-customize-devicetree/SKILL.md` |
| Boot-time overlay selection | `.claude/skills/rcar-customize-boot/SKILL.md` |
| cmem / qos / PowerVR modules | `.claude/skills/rcar-customize-extmodules/SKILL.md` |
| Initramfs, NVMe/USB boot | `.claude/skills/rcar-customize-initramfs/SKILL.md` |
| Deploy to hardware | `.claude/skills/rcar-deploy-image/SKILL.md` |
| Where do I start? | `.claude/skills/rcar-quick-start/SKILL.md` |

Two have extra depth in a `references/` subdirectory: the device tree overlay
registration walkthrough, and a line-by-line reading of `boot.cmd`.
