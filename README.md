# R-Car Utility - R-Car V4H Sparrow Hawk

Standalone scripts to build and deploy the Linux kernel, modules, firmware,
initramfs, TF-A BL31, and U-Boot FIT image (`fitImage`) for the R-Car V4H
Sparrow Hawk.

This branch (`ubuntu/rcar-v4h-sh`) is trimmed down to the Sparrow Hawk build
only.

## Hierarchy

```
.
├── .claude/skills/         AI agent skills (see "AI Agent Skills" below)
├── linux-sh/               kernel source, cloned on demand (gitignored)
├── local-build-scripts/
├── scripts/                rcar-driver.sh and helpers
├── workspace/              everything the build produces (gitignored)
├── LICENSE
└── README.md
```

### local-build-scripts

Build scripts for the Sparrow Hawk kernel and fitImage. See
[local-build-scripts/README.md](local-build-scripts/README.md) for the
configuration and usage details.

## Quick start

```bash
./scripts/rcar-driver.sh preflight
./scripts/rcar-driver.sh smoke
```

`smoke` builds the complete deployable output—installed kernel and external
modules, BL31, initramfs, and fitImage—then verifies the artifacts.

No configuration is needed. The kernel source is expected in `linux-sh/` and
the build offers to clone it (single branch) when it is missing; everything
produced is written under `workspace/`, next to these scripts. Uncomment a path
in `config.ini` only to build somewhere else.

Every input and deployable artifact is produced directly by this repository.
No external build system, packaging step, or pre-populated deploy directory is
required.

## AI Agent Skills

These scripts ship with a set of *AI Agent Skills* so an AI agent (Claude, Codex, GitHub Copilot, etc.) can set up,
build, verify, and deploy the Linux kernel and related components for the R-Car
V4H Sparrow Hawk.

Each skill lives in `.claude/skills/<name>/SKILL.md` and is picked up
automatically when AI Agent runs from the root of this repository.

| Skill | Purpose | Use when |
| --- | --- | --- |
| `rcar-quick-start` | Entry point; orients you in the repo and dispatches to the right skill | New to the repo, or unsure which skill applies |
| `rcar-setup-workspace` | Install host packages, clone `linux-sh`, run toolchain preflight | Fresh host/container, or a build fails on a missing tool |
| `rcar-build` | Build kernel, dtbs, modules, external modules, TF-A BL31, initramfs, fitImage (incl. PREEMPT_RT) | Building or rebuilding after a source change |
| `rcar-customize-kernel-config` | Edit `sparrow_hawk_defconfig` / config fragment, menuconfig, `KERNEL_VARIANT` | Enabling or disabling a driver or kernel feature |
| `rcar-customize-devicetree` | Edit or add the base `.dts` and `.dtso` overlays (camera, display, fan, UIO) | Changing the board hardware description |
| `rcar-customize-boot` | Edit `boot.cmd`, U-Boot auto-detection, FIT config string, load addresses | Controlling which overlay is selected at boot |
| `rcar-customize-extmodules` | Add, patch, or re-pin out-of-tree modules: cmemdrv, qos, gles (pvrsrvkm) | Bumping a module revision or registering a new one |
| `rcar-customize-initramfs` | Edit the init script, busybox config, bundled PCIe driver and PHY firmware | NVMe/USB boot fails, or an early-boot tool/firmware is needed |
| `rcar-print-build-info` | Print current build state: resolved paths, artifacts, sizes, times | Answering "what is built right now?" |
| `rcar-verify-build` | Verify artifacts without a board: fitImage, overlay apply, `modules.dep`, initramfs | After any build, before deploying |
| `rcar-deploy-image` | Back up, rsync fitImage/modules/firmware over ssh, reboot, confirm new kernel | Pushing a finished build to real hardware |
| `rcar-verify-hardware` | Check the live board: selected FIT config, overlay nodes, driver binding | After deploy, or validating a device tree change on hardware |

### Typical flow

```
rcar-setup-workspace
  -> rcar-customize-*      (kernel-config | devicetree | boot | extmodules | initramfs)
  -> rcar-build
  -> rcar-verify-build
  -> rcar-deploy-image
  -> rcar-verify-hardware
```

Start with `rcar-quick-start` if you are not sure which step you are on.
