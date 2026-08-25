# Copilot instructions — rcar-utils

Standalone scripts producing the kernel, modules, firmware, initramfs, TF-A
BL31, and U-Boot FIT image (`fitImage`) for the **R-Car V4H Sparrow Hawk**
(`PLATFORM=RCAR-V4H-SH`, SoC `r8a779g3`).

**Read [`AGENTS.md`](../AGENTS.md) at the repo root first** — it holds the full
context, the command reference, the setup steps and the safety rules. This file
is the short version; `AGENTS.md` is authoritative and kept up to date.

## Entry points

Never call `local-build-scripts/main_build.sh` directly. Use:

```bash
./scripts/rcar-driver.sh <preflight|build|verify|smoke|info> [args]
./scripts/rcar-deploy.sh --host <board-ip> [options]
```

Both are plain bash and run from any cwd. No arguments prints usage.

## Three rules that matter more than anything else

1. **`main_build.sh` only works with cwd = `local-build-scripts/`.** From
   anywhere else it continues with an empty `PLATFORM` and fails with a
   misleading "No such file or directory". `./scripts/rcar-driver.sh build
   <target> <sub>` handles the cd.

2. **A green build is not evidence.** Three failure modes exit 0 — a stale
   fitImage, a missing `modules.dep` (`make modules_install` only *warns*
   without `depmod`), and a broken `.dtbo` that compiles but fails at boot.
   Always finish with:

   ```bash
   ./scripts/rcar-driver.sh verify
   ```

3. **Never hardcode the kernel version.** Read it:

   ```bash
   REL=$(cat linux-sh/include/config/kernel.release)
   ```

## When suggesting changes

- Device tree overlays must be registered in **four** places — the `.dtso`, the
  kernel `Makefile` (3 lines), and both `FIT_OVERLAY_IMAGES` and
  `FIT_OVERLAY_CONFIGS` in `local-build-scripts/build_fitimage.sh`. Missing one
  fails differently each time; see
  `.claude/skills/rcar-customize-devicetree/SKILL.md`.
- Kernel options belong in the `sparrow_hawk.config` fragment, not in a
  hand-edited `.config` — a customized `.config` is preserved and then stops
  picking up fragment updates.
- `boot.cmd` is a **U-Boot** script, not POSIX sh. There is no host-side syntax
  check; a typo becomes a boot failure.
- A device-tree change is not verified until it has been checked on the board.
  `rcar-driver.sh verify` is host-side only; what U-Boot actually selected is
  in `/proc/device-tree/chosen/u-boot,bootconf`. See
  `.claude/skills/rcar-verify-hardware/SKILL.md`, and always confirm the
  hardware is plugged in before reading a missing overlay as a fault.
- `workspace/` and `linux-sh/` are gitignored build output. Do not propose
  deleting anything there without asking.

## Safety

`./scripts/rcar-deploy.sh` overwrites `/boot` and `/usr/lib/modules` on a real
board and reboots it. Confirm with the user first, name the board, and suggest
`--dry-run` before the real run.

## Deeper docs

Per-task guides are in `.claude/skills/<topic>/SKILL.md` — plain markdown, not
Claude-only. The index is at the bottom of `AGENTS.md`.
