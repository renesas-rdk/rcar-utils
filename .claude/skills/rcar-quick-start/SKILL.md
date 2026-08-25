---
name: rcar-quick-start
description: Entry point for the R-Car V4H Sparrow Hawk build (rcar-utils) — orients you in the repo and dispatches to the right rcar-* skill for setup, building, kernel config, device trees, boot overlays, external modules, initramfs, verification, or deploy. Use when you are new to this repo or unsure which skill applies.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, entry-point]
  domain: meta
---

# rcar-utils — start here

Skill references use bare names such as `rcar-build`. Invoke that name through
the skill picker, mention, or command syntax supported by the current client;
Claude's slash form is not assumed to be portable to Codex or Copilot.

Standalone scripts producing the kernel, modules, firmware, initramfs, TF-A
BL31, and U-Boot FIT image for the **R-Car V4H Sparrow Hawk** (`r8a779g3`,
`PLATFORM=RCAR-V4H-SH`).

Shared facts every skill assumes: `AGENTS.md` at the repo root.
The harness they all wrap: `scripts/rcar-driver.sh`.

## First run, in order

```bash
./scripts/rcar-driver.sh preflight   # host tools + kernel source
./scripts/rcar-driver.sh smoke       # complete deployable build + verify
```

`preflight` failing → `rcar-setup-workspace`. Never seen this repo before →
read `AGENTS.md`, it is short.

## Pick a skill

| You want to… | Skill |
|---|---|
| Prepare a fresh machine / fix a missing tool | `rcar-setup-workspace` |
| Build anything (kernel, modules, BL31, initramfs, fitImage) | `rcar-build` |
| Build the PREEMPT_RT / real-time kernel | `rcar-build` (see *Run: the PREEMPT_RT kernel*) |
| Check a build is actually consistent | `rcar-verify-build` |
| See what is currently built | `rcar-print-build-info` |
| Enable/disable a kernel option or driver | `rcar-customize-kernel-config` |
| Edit board hardware description, add an overlay | `rcar-customize-devicetree` |
| Change which overlay applies at boot | `rcar-customize-boot` |
| Bump/patch cmem, qos, or the PowerVR GPU module | `rcar-customize-extmodules` |
| Change early boot, NVMe/USB boot, busybox | `rcar-customize-initramfs` |
| Get artifacts onto hardware | `rcar-deploy-image` |
| Prove it works on the live board | `rcar-verify-hardware` |

Boundaries that are easy to get wrong:

- **devicetree vs boot** — `rcar-customize-devicetree` creates and registers an
  overlay; `rcar-customize-boot` decides when it is applied. Adding an overlay
  needs both.
- **kernel-config vs extmodules** — in-tree drivers (`=y`/`=m`) are Kconfig;
  cmem/qos/gles are fetched from upstream and are extmodules.
- **verify vs deploy vs verify-hardware** — `rcar-verify-build` is host-side
  and proves artifact consistency; `rcar-deploy-image` is the on-target
  contract; `rcar-verify-hardware` is the only one that inspects the device
  tree the board is actually running, and the only one that asks whether the
  hardware is plugged in.

## Typical flows

**Change a kernel option:**

```
rcar-customize-kernel-config → rcar-build (kernel modules-install)
→ rcar-build (ext-modules install, initramfs all, fitimage image)
→ rcar-verify-build
```

**Add a device tree overlay:** four registration places, then boot selection.

```
rcar-customize-devicetree → rcar-customize-boot
→ rcar-build (kernel dtbs, fitimage image) → rcar-verify-build
```

**Full build from clean:**

```
rcar-setup-workspace → rcar-build (fitimage all) → rcar-verify-build
```

**A real-time kernel:**

```
rcar-customize-kernel-config (variant fragment, if it needs changing)
→ rcar-build (KERNEL_VARIANT=preempt-rt, own WORKSPACE_DIR)
→ rcar-verify-build → rcar-deploy-image
```

The stock and RT kernels take turns in `linux-sh/`, so build the one you want
immediately before deploying it.

`fitimage all` builds and installs kernel and external modules, builds BL31 and
the initramfs, and assembles the FIT — one command.

## The two rules that cause the most lost time

**1. `main_build.sh` only runs with cwd = `local-build-scripts/`.** It
`source`s `./config.ini` and `./common.sh`; from anywhere else it continues
with an **empty `PLATFORM`** and fails with a misleading "No such file or
directory". Use `rcar-driver.sh build <target> <sub>`, which handles the cd.

**2. Three failure modes exit 0.** A green build is not evidence:

| Failure | Why silent |
|---|---|
| Stale fitImage | `kernel` and `fitimage` are separate targets |
| No `modules.dep` | `make modules_install` only *warns* without `depmod` |
| Broken `.dtbo` | compiles fine, fails at boot with that overlay |

`rcar-driver.sh verify` catches all three. Run it after every build.

## Layout

```
<rcar-utils>/
├── AGENTS.md              shared context, every agent reads this
├── linux-sh/              kernel source, cloned on demand (gitignored)
├── local-build-scripts/   build scripts + config.ini
├── scripts/               rcar-driver.sh, rcar-deploy.sh
├── workspace/             all outputs (gitignored)
├── workspace-<variant>/   a KERNEL_VARIANT build's outputs (gitignored)
└── .claude/skills/        these per-task guides
```

`workspace/` and `linux-sh/` are gitignored, so `git status` tells you nothing
about build state — `rcar-print-build-info` is the view.
