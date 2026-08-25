# Adding an overlay — worked example

Every command and output below was executed against this repo. The example
overlay was added, built, deliberately broken to prove the build-time check
fires, then reverted.

## The four places, again

| # | File | Registers |
|---|---|---|
| 1 | `linux-sh/arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-<f>.dtso` | the source |
| 2 | `linux-sh/arch/arm64/boot/dts/renesas/Makefile` | how to compile it |
| 3 | `local-build-scripts/build_fitimage.sh` → `FIT_OVERLAY_IMAGES` | the FIT image node |
| 4 | `local-build-scripts/build_fitimage.sh` → `FIT_OVERLAY_CONFIGS` | the selectable config |

## 1. The source

`linux-sh/arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-smoketest.dtso`:

```dts
// SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause)
/dts-v1/;
/plugin/;

&{/} {
	rcar-utils-smoketest {
		compatible = "rcar-utils,smoketest";
		status = "okay";
	};
};
```

`&{/}` targets the root by path. Real overlays normally target a label the base
DTS exports (`&i2c0`, `&csi40`), or a full path when it does not.

Start from `r8a779g3-sparrow-hawk-fan-pwm.dtso` — it is the smallest real one
and its header comment documents the sysfs surface, which is the house style.

## 2. Kernel Makefile

Three lines, added beside the other Sparrow Hawk entries (~line 97+ of
`linux-sh/arch/arm64/boot/dts/renesas/Makefile`):

```make
dtb-$(CONFIG_ARCH_R8A779G0) += r8a779g3-sparrow-hawk-smoketest.dtbo
r8a779g3-sparrow-hawk-smoketest-dtbs := r8a779g3-sparrow-hawk.dtb r8a779g3-sparrow-hawk-smoketest.dtbo
dtb-$(CONFIG_ARCH_R8A779G0) += r8a779g3-sparrow-hawk-smoketest.dtb
```

- Line 1 compiles the overlay → `.dtbo`. This is the blob the FIT embeds.
- Lines 2–3 build a **pre-merged** `.dtb` (base + overlay applied at build
  time). Nothing consumes this artifact — its value is that producing it
  **fails the build** when the overlay does not apply. Keep them.

## 3 + 4. FIT registration

In `local-build-scripts/build_fitimage.sh`, add to `FIT_OVERLAY_IMAGES`:

```sh
"fdt-smoketest|${BOARD_DTB}-smoketest.dtbo"
```

and to `FIT_OVERLAY_CONFIGS`:

```sh
"smoketest|fdt-smoketest|"
```

Formats:

- `FIT_OVERLAY_IMAGES` — `"<fdt node label>|<dtbo file name>"`
- `FIT_OVERLAY_CONFIGS` — `"<config name>|<fdt node label>|<comment>"`

The config name is what `boot.cmd` appends as `#smoketest`. Two config entries
may point at one node — that is how the `rpi-display-2` and `waveshare-panel`
aliases are kept for backward compatibility:

```sh
"rpi-display-2|fdt-rpi-display-2-7in| // For backward compatibility"
"rpi-display-2-7in|fdt-rpi-display-2-7in|"
```

## 5. Build

```bash
./scripts/rcar-driver.sh build kernel dtbs
./scripts/rcar-driver.sh build fitimage image
```

The kernel build shows both steps:

```
  DTC     arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-smoketest.dtbo
  OVL     arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-smoketest.dtb
```

`DTC` compiled the overlay; `OVL` applied it to the base. Both must appear.

## 6. Confirm it landed in the FIT

```bash
mkimage -l workspace/fitimage/fitImage | grep -i smoketest
```

```
 Image 14 (fdt-smoketest)
 Configuration 11 (smoketest)
  FDT:          fdt-smoketest
```

An `Image` line **and** a `Configuration` line. One without the other means
place 3 or place 4 is missing.

## Proof the build-time check works

Point the overlay at a node that does not exist:

```dts
/dts-v1/;
/plugin/;
&{/nonexistent-node-xyz} {
	status = "okay";
};
```

```bash
./scripts/rcar-driver.sh build kernel dtbs
```

```
  DTC     arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-smoketest.dtbo
  OVL     arch/arm64/boot/dts/renesas/r8a779g3-sparrow-hawk-smoketest.dtb
Failed to apply '...-smoketest.dtbo': FDT_ERR_NOTFOUND
make[3]: *** [scripts/Makefile.dtbs:85: ...-smoketest.dtb] Error 1
```

Build exits **1**. Note `DTC` still succeeded — `dtc` compiles a broken overlay
happily. Only the `OVL` step catches it, and only because lines 2–3 of the
Makefile exist. Drop them and this failure moves to the board.

`rcar-driver.sh verify` is the second net, checking every `.dtbo` against the base
with `fdtoverlay` after the fact.

## Removing an overlay

Reverse order, all four places, then rebuild:

```bash
./scripts/rcar-driver.sh build kernel dtbs
./scripts/rcar-driver.sh build fitimage image
mkimage -l workspace/fitimage/fitImage | grep -c smoketest   # expect 0
```

Stale `.dtbo`/`.dtb` files are **not** cleaned automatically — delete them from
`linux-sh/arch/arm64/boot/dts/renesas/`, or the fitimage target may still stage
a blob whose source is gone.

Also remove any `#<name>` reference from `boot.cmd`
(`rcar-customize-boot`); selecting a configuration that no longer exists
fails at boot.
