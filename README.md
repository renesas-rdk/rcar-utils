# R-Car Utility - R-Car X5H Ironhide

Standalone scripts to build and deploy the Linux kernel, modules, device trees,
a U-Boot FIT image (`fitImage`), and the separately-flashed boot-chain stages
(TF-A BL31, OP-TEE, U-Boot) for the R-Car X5H Ironhide board - directly from
source, with no Yocto or bitbake anywhere.

This branch (`ubuntu/rcar-x5h-ironhide`) is a port of `ubuntu/rcar-v4h-sh`, which
targets the R-Car V4H Sparrow Hawk. The structure is the same; the board facts,
the boot architecture and two of the targets are not - see
[AGENTS.md](AGENTS.md).

## Hierarchy

```
.
├── .claude/skills/         AI agent skills (see "AI Agent Skills" below)
├── linux-sh/               kernel source, cloned on demand (gitignored)
├── local-build-scripts/
├── scripts/                rcar-driver.sh and helpers
├── workspace/              everything the build produces (gitignored)
├── AGENTS.md               the authoritative orientation doc
├── LICENSE
└── README.md
```

### local-build-scripts

Build scripts for the kernel, fitImage, BL31, OP-TEE and U-Boot. See
[local-build-scripts/README.md](local-build-scripts/README.md) for the
configuration and usage details.

## Quick start

```bash
./scripts/rcar-driver.sh preflight
./scripts/rcar-driver.sh smoke
```

`smoke` builds the complete deployable set - installed kernel and modules, the
fitImage, BL31, OP-TEE and U-Boot - then verifies the artifacts.

Two things are needed before the first build:

1. **The kernel source**, cloned on demand when stdin is a TTY, or by hand:
   ```bash
   git clone --single-branch --branch v6.12.80/rcar-6.1.0 \
       https://github.com/renesas-rcar/linux-bsp.git linux-sh
   git -C linux-sh checkout e1e83b5711610d83941c51dcf48418eda209f339
   ```

2. **Three firmware blobs** in `/lib/firmware` on the build host. The kernel
   and U-Boot embed them at build time, so a missing blob is a hard build
   failure. They are not downloadable - they ship only inside the Renesas SDK
   v4.39.0 package (My Renesas login):
   <https://www.renesas.com/en/document/mas/sdk-documentation-sdk-v4390>
   -> `<SDK v4.39.0>/user_manual/current/linux_bsp/_attachments/` ->
   `rcar_gen5_mp_phy.bin`, `rcar_gen5_pcie6_iccm.bin`,
   `rcar_gen5_pcie6_dccm.bin`. Point `FW_DIR` in `config.ini` at them, or copy
   them to `/lib/firmware` yourself.

Everything else is produced under `workspace/`, next to these scripts.
Uncomment a path in `config.ini` only to build somewhere else.

## What this does NOT build

Two targets from the V4H original are present but deliberately stubbed - they
exit 1 with an explanation rather than appearing to work:

- `ext-modules` (cmem / qos / PowerVR GPU module) - X5H's out-of-tree module
  set has not been researched.
- `initramfs` - X5H boots its rootfs from eMMC/UFS; the PCIe-NVMe-root case
  that makes this mandatory on V4H has not been confirmed here.

## Flashing

`scripts/rcar-deploy.sh` deploys the **kernel side** (fitImage, modules, dtbs)
to a running board over ssh. BL31, OP-TEE and U-Boot are not deployed this way:
they are flashed as raw `.srec` at fixed offsets with the Flash Programmer,
which needs USB/serial and physical DIP switch access. The addresses are in
AGENTS.md under "Boot contract".

## AI Agent Skills

These scripts ship with a set of *AI Agent Skills* so an AI agent (Claude,
Codex, GitHub Copilot, etc.) can set up, build, verify, and deploy the Linux
kernel and related components for this board.

Each skill lives in `.claude/skills/<name>/SKILL.md` and is picked up
automatically when an AI agent runs from the root of this repository.

| Skill | Purpose | Use when |
| --- | --- | --- |
| `rcar-quick-start` | Entry point; orients you in the repo and dispatches to the right skill | New to the repo, or unsure which skill applies |
| `rcar-setup-workspace` | Install host packages, clone `linux-sh`, stage firmware blobs, run preflight | Fresh host/container, or a build fails on a missing tool |
| `rcar-build` | Build kernel, dtbs, modules, BL31, OP-TEE, U-Boot, fitImage | Building or rebuilding after a source change |
| `rcar-customize-kernel-config` | Edit the defconfig / config fragment, menuconfig, `KERNEL_VARIANT` | Enabling or disabling a driver or kernel feature |
| `rcar-customize-devicetree` | Edit the board `.dts` files and the four device tree variants | Changing the board hardware description |
| `rcar-customize-boot` | Edit `boot.cmd`, FIT configuration selection, load addresses | Controlling which device tree is used at boot |
| `rcar-customize-bootchain` | TF-A BL31 and OP-TEE: revisions, build flags, flash offsets | Changing the secure-world boot stages |
| `rcar-customize-uboot` | U-Boot: revision, defconfig, the MP-PHY firmware dependency | Changing U-Boot itself |
| `rcar-customize-extmodules` | Out-of-tree modules - **not implemented for X5H** | Picking up that unfinished port |
| `rcar-customize-initramfs` | Initramfs - **not implemented for X5H** | Picking up that unfinished port |
| `rcar-print-build-info` | Print current build state: resolved paths, artifacts, sizes, times | Answering "what is built right now?" |
| `rcar-verify-build` | Verify artifacts without a board: fitImage, dtbs, `modules.dep`, boot chain | After any build, before deploying |
| `rcar-deploy-image` | Back up, rsync fitImage/modules over ssh, reboot, confirm new kernel | Pushing a finished build to real hardware |
| `rcar-verify-hardware` | Check the live board: selected FIT config, device tree nodes, driver binding | After deploy, or validating a device tree change on hardware |

### Typical flow

```
rcar-setup-workspace
  -> rcar-customize-*      (kernel-config | devicetree | boot | bootchain | uboot)
  -> rcar-build
  -> rcar-verify-build
  -> rcar-deploy-image
  -> rcar-verify-hardware
```

Start with `rcar-quick-start` if you are not sure which step you are on.
