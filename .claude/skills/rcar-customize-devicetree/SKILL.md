---
name: rcar-customize-devicetree
description: Edit or add R-Car V4H Sparrow Hawk device tree sources and overlays — the base r8a779g3-sparrow-hawk.dts and the .dtso overlays for cameras, displays, fans and UIO. Use to change board hardware description or add a new overlay. Do NOT use for selecting which overlay boots at run time (that is rcar-customize-boot) or for kernel Kconfig options.
version: 0.0.1
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, devicetree, overlay, phase-2]
  domain: kernel
---

# Customize the device tree

## Purpose

Change what hardware the kernel sees on the Sparrow Hawk: edit the base DTS, or
add/modify a `.dtso` overlay.

**Adding an overlay means editing four places in lockstep.** Miss one and the
failure is silent in a different way each time — see the table below. That is
the whole reason this skill exists.

Shared facts: `AGENTS.md` at the repo root.
Deep detail: [references/overlay-registration.md](references/overlay-registration.md).

## Prerequisites

- `/rcar-setup-workspace` done; `fdtoverlay` and `dtc` on PATH.
- Know whether your change belongs in the **base** (always present) or an
  **overlay** (selected at boot). Anything optional or mutually exclusive —
  a camera on J1, one of four displays on J4 — must be an overlay.

## Where the files live

| What | Path |
|---|---|
| Base DTS | `linux-sh/arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk.dts` |
| Overlay sources | `linux-sh/arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-*.dtso` |
| Build registration | `linux-sh/arch/arm64/boot/dts/renesas/Makefile` (~line 97+) |
| FIT registration | `local-build-scripts/build_fitimage.sh` (`FIT_OVERLAY_IMAGES`, `FIT_OVERLAY_CONFIGS`) |
| Boot selection | `local-build-scripts/fit/rcar-v4h-sh/boot.cmd` → `/rcar-customize-boot` |

Current overlays: `uio`, `camera-j{1,2}-imx{219,462,708}` (6),
`fan-{argon40,pwm}`, `rpi-display-2-{5,7}in`, `ws-display-13in`,
`olimex-dsi-hdmi` — 13 total.

## The four places

| # | Place | Miss it and… |
|---|---|---|
| 1 | `.dtso` source file | nothing to build |
| 2 | Kernel `Makefile` — 3 lines | `.dtbo` never compiled; the fitimage target aborts with "missing overlay" |
| 3 | `FIT_OVERLAY_IMAGES` in `build_fitimage.sh` | blob not embedded in the FIT |
| 4 | `FIT_OVERLAY_CONFIGS` in `build_fitimage.sh` | blob embedded but **no selectable config** — `boot.cmd` appending `#name` fails at boot with a config that does not exist |

Place 4 without 3 is the nastiest: the build succeeds, `mkimage -l` shows the
configuration, and it fails only on the board.

## Procedure: edit an existing overlay

```bash
$EDITOR linux-sh/arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-fan-pwm.dtso
./scripts/rcar-driver.sh build kernel dtbs
./scripts/rcar-driver.sh build fitimage image
./scripts/rcar-driver.sh verify
```

`verify` applies every `.dtbo` to the base with `fdtoverlay` and fails loudly
on one that no longer applies.

## Procedure: add a new overlay

Full worked example in
[references/overlay-registration.md](references/overlay-registration.md).
Summary, for an overlay named `<feature>`:

**1.** Create
`linux-sh/arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-<feature>.dtso`,
starting from the simplest existing one (`fan-pwm.dtso`). It must open with:

```dts
/dts-v1/;
/plugin/;
```

**2.** Register in `linux-sh/arch/arm64/boot/dts/renesas/Makefile`, next to the
other Sparrow Hawk entries — **three** lines:

```make
dtb-$(CONFIG_ARCH_R8A779G0) += r8a779g3-sparrow-hawk-<feature>.dtbo
r8a779g3-sparrow-hawk-<feature>-dtbs := r8a779g3-sparrow-hawk.dtb r8a779g3-sparrow-hawk-<feature>.dtbo
dtb-$(CONFIG_ARCH_R8A779G0) += r8a779g3-sparrow-hawk-<feature>.dtb
```

The 2nd and 3rd lines build a **pre-merged** `.dtb`, which makes the kernel
build itself fail if the overlay does not apply. Keep them — that is a
build-time check you get for free.

**3.** Add to `FIT_OVERLAY_IMAGES` in `local-build-scripts/build_fitimage.sh`:

```sh
"fdt-<feature>|${BOARD_DTB}-<feature>.dtbo"
```

**4.** Add to `FIT_OVERLAY_CONFIGS` in the same file:

```sh
"<feature>|fdt-<feature>|"
```

Format is `<config name>|<fdt node label>|<comment>`. The config name is what
`boot.cmd` appends as `#<feature>`. Two names may point at the same node — that
is how `rpi-display-2` and `waveshare-panel` are kept as backward-compatible
aliases.

**5.** Build and verify:

```bash
./scripts/rcar-driver.sh build kernel dtbs
./scripts/rcar-driver.sh build fitimage image
./scripts/rcar-driver.sh verify
mkimage -l workspace/fitimage/fitImage | grep -E '^ Configuration'
```

**6.** Make it selectable at boot → `/rcar-customize-boot`.

## Verification

Apply the overlay by hand before trusting the build:

```bash
cd workspace/fitimage
fdtoverlay -i r8a779g3-sparrow-hawk.dtb -o /tmp/merged.dtb \
    r8a779g3-sparrow-hawk-<feature>.dtbo && echo APPLIES
```

Inspect the merged result:

```bash
fdtdump /tmp/merged.dtb | grep -A10 '<your-node>'
```

`rcar-driver.sh verify` does the apply check for all overlays automatically.

## Gotchas

- **A broken overlay still compiles.** `dtc` happily produces a `.dtbo` whose
  target node does not exist in the base; `fdtoverlay` reports
  `FDT_ERR_NOTFOUND` only when applying. Without the pre-merged `.dtb` line in
  the Makefile, nothing catches it until boot.
- **`&{/path}` vs `&label`.** Overlays here target labels exported by the base
  DTS. If the base does not export a label, use the full path form
  `&{/soc/i2c@e6508000}`. Renaming a label in the base silently breaks every
  overlay referencing it.
- **Overlays are applied in the order `boot.cmd` composes them**, not the order
  they appear in the FIT. Two overlays writing the same property — last one
  wins. The UIO overlay is applied first and always.
- **`DTC_FLAGS_r8a779g3-sparrow-hawk += -Wno-spi_bus_bridge`** in the Makefile
  suppresses a known warning for this board. `build_kernel.sh` also exports
  `DTC_FLAGS` per platform; it is *appended* to by `scripts/Makefile.dtbs`, so
  in-tree suppressions survive.
- **`kernel dtbs` does not refresh the fitImage.** Always follow with
  `fitimage image`.
- **Overlay `.dtb`, `.dtbo`, `.dtso` all sit in the same directory** with
  similar names. The build consumes `.dtbo`; `.dtb` is the pre-merged check
  artifact; `.dtso` is the source.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `does NOT apply` + `FDT_ERR_NOTFOUND` from verify | Target node/label absent in base | Fix the target in the `.dtso`, or add it to the base DTS |
| fitimage target reports a missing overlay | Place 2 missing — `.dtbo` not built | Add the Makefile lines |
| Config appears in `mkimage -l` but board fails to boot with it | Place 3 missing — node not embedded | Add to `FIT_OVERLAY_IMAGES` |
| Overlay in FIT but `#name` unknown at boot | Place 4 missing | Add to `FIT_OVERLAY_CONFIGS` |
| Changes not on the board | fitImage stale | `rcar-driver.sh build fitimage image` |
