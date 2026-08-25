---
name: rcar-customize-kernel-config
description: Change Linux kernel config options for the R-Car V4H Sparrow Hawk — edit sparrow_hawk_defconfig or the sparrow_hawk.config fragment, add a KERNEL_VARIANT fragment such as the PREEMPT_RT one, use menuconfig, and understand how a hand-edited .config is preserved or discarded. Use to enable/disable a driver or kernel feature. Do NOT use for device tree overlays, out-of-tree modules, or boot.cmd.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, kernel, kconfig, phase-2]
  domain: kernel
---

# Customize the kernel configuration

## Purpose

Enable or disable a kernel option for the Sparrow Hawk, and keep the change
across rebuilds. The non-obvious part is **which of your two possible edits
survives** — the scripts regenerate `.config` on every build unless they can
tell you customized it.

Shared facts: `AGENTS.md` at the repo root.

## How the config is produced

Every kernel target configures first through `build_kernel.sh` and
`mk_config_merged`:

1. `arch/arm64/configs/sparrow_hawk_defconfig` and
   `arch/arm64/configs/sparrow_hawk.config` are **concatenated** into a temp
   file (`mktemp -t rcar-merged-config.XXXXXX`, so `$TMPDIR` or `/tmp`).
2. Two lines are appended last, so they always win:
   `CONFIG_LOCALVERSION_AUTO=n` and
   `CONFIG_LOCALVERSION="${KERNEL_LOCALVERSION}"` (default `-arm64-renesas`).
3. `make KCONFIG_ALLCONFIG=<merged> alldefconfig` fills in every other symbol.

**Last assignment wins.** The fragment overrides the defconfig, which is what
produces the `warning: override: reassigning to symbol ...` noise on every
build. That is the fragment doing its job, not a problem.

## The `.rcar-config.stamp` mechanism

After generating `.config`, the script saves a copy as
`linux-sh/.rcar-config.stamp`. On the next build it compares:

| State | What happens |
|---|---|
| `.config` **matches** the stamp | Treated as generated → **regenerated** from defconfig + fragment, so updates to either are picked up |
| `.config` **differs** from the stamp | Treated as customized → **kept**, only `make olddefconfig` is run |
| No stamp beside `.config` | Counts as customized → **kept** (a tree from an older checkout, or a hand-written `.config`) |

Consequence worth internalising: **editing `.config` directly is preserved, but
silently stops you picking up defconfig/fragment updates** until you run
`defconfig` again.

## Variants: a second kernel from the same tree

A change that should produce a *separate* kernel rather than change the board's
one belongs in a variant fragment, not in `sparrow_hawk.config`:
`local-build-scripts/kernel-config/<name>.config`, selected with
`KERNEL_VARIANT=<name>`. It is merged last - after the defconfig, the board
fragment and the `CONFIG_LOCALVERSION` lines - so it overrides all of them and
can give the kernel its own `uname -r`.

`preempt-rt` ships today: `CONFIG_PREEMPT_RT=y`, release
`<version>-arm64-renesas-rt`.

Two things to know before writing one:

- **Check what your own dependencies unhide.** `PREEMPT_RT` requires `EXPERT`,
  and `EXPERT` flips every symbol declared `default y if !EXPERT`. That turned
  13 `HID_*` quirk drivers off and the whole media/DVB menu on (+116 modules)
  until the fragment grew a block pinning them back. Always diff the generated
  `.config` against the stock one.
- **Keep the `CONFIG_LOCALVERSION` suffix to letters, digits, `.` and `-`.**
  It becomes the module directory name and `uname -r`; underscores and other
  punctuation trip up downstream tooling that consumes the release string.

Building one is `rcar-build`'s job - see *Run: the PREEMPT_RT kernel* in
`.claude/skills/rcar-build/SKILL.md`.

## Choosing where to make the change

| Goal | Where | Survives? |
|---|---|---|
| Permanent, tracked, shared with the team | `arch/arm64/configs/sparrow_hawk.config` fragment | yes — it is the intended override point |
| Permanent board baseline change | `arch/arm64/configs/sparrow_hawk_defconfig` | yes, but the fragment can still override it |
| Local experiment | `menuconfig` / edit `.config` | yes, until you run `kernel defconfig` |

Prefer the **fragment**. It is the last file concatenated, it is small, and its
diff shows intent.

## Procedure: permanent change via the fragment

```bash
grep -n 'CONFIG_PCIE_RCAR_GEN4' linux-sh/arch/arm64/configs/sparrow_hawk.config
```

Edit the fragment, then rebuild — the generated `.config` is refreshed
automatically because it still matches the stamp:

```bash
./scripts/rcar-driver.sh build kernel modules-install
./scripts/rcar-driver.sh build ext-modules install
./scripts/rcar-driver.sh build initramfs all
./scripts/rcar-driver.sh build fitimage image
./scripts/rcar-driver.sh verify
```

Do not stop after the in-tree modules. Kernel configuration can change module
ABI and the PCIe module copied into the initramfs, so external modules and the
initramfs must be rebuilt before the FIT is reassembled.

Confirm the symbol landed:

```bash
grep -E '^CONFIG_PCIE_RCAR_GEN4(_HOST)?=' linux-sh/.config
```

**If you had previously customized `.config`, it is kept and your fragment edit
will not appear.** Discard the local state first:

```bash
./scripts/rcar-driver.sh build kernel defconfig
```

## Procedure: local experiment via menuconfig

```bash
cd local-build-scripts && ./main_build.sh kernel menuconfig
```

Interactive — needs a TTY, so run it yourself rather than from an agent.
It generates a `.config` first when the tree has none, so it never starts from
plain arm64 defaults. Builds afterwards keep what it saved.

To go back to the board configuration and throw local changes away:

```bash
./scripts/rcar-driver.sh build kernel defconfig
```

## Changing the module suffix

`KERNEL_LOCALVERSION` in `config.ini` (default `-arm64-renesas`) becomes the
`uname -r` suffix and therefore the **module install path**
`/usr/lib/modules/<version><suffix>/`.

Changing it renames the module tree. The old one is **not** removed —
`workspace/kernel-modules/usr/lib/modules/` ends up with both and deploying
that directory ships both. `rcar-driver.sh verify` flags the stale tree.

## Gotchas

- **`m` vs `y` changes the deploy surface.** A driver built `=m` must be
  installed (`kernel modules-install`) and needs `modules.dep`; `=y` does not.
  Switching `PCIE_RCAR_GEN4` to `=y` would make the initramfs copy of
  `pcie-rcar-gen4.ko` dead weight — see `rcar-customize-initramfs`.
- **`alldefconfig` silently drops an option whose dependencies are unmet.** If
  a symbol you added is absent from `.config` afterwards, check its `depends
  on` — there is no error.
- **`CONFIG_LOCALVERSION*` in the board fragment is overridden** by the two
  lines appended in step 2. Set `KERNEL_LOCALVERSION` in `config.ini` instead.
  A `KERNEL_VARIANT` fragment is appended later and may override the suffix.
- **`LOCALVERSION=""` is exported** by the scripts so `scripts/setlocalversion`
  does not append `+` to the release string. No `.scmversion` is needed.
- **A config change usually invalidates the fitImage.** Rebuild it:
  `rcar-driver.sh build fitimage image`.
- **`distclean` removes both `.config` and the stamp**, so the next build is a
  clean regeneration.

## Verification

```bash
grep -E '^CONFIG_<SYMBOL>' linux-sh/.config          # option took effect
cat linux-sh/include/config/kernel.release           # release string / suffix
./scripts/rcar-driver.sh verify            # artifacts still consistent
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Fragment edit does not appear in `.config` | `.config` counts as customized | `rcar-driver.sh build kernel defconfig` |
| `Error: missing kernel config input: .../sparrow_hawk.config` | Fragment renamed/absent in the tree | Restore it; both defconfig and fragment are required |
| Module tree appears under a new version | `KERNEL_LOCALVERSION` changed | Expected; remove the stale tree |
| Symbol set to `y` but shows `m` (or vice-versa) | A later line in the merged file wins | Put the assignment in the fragment, not the defconfig |
