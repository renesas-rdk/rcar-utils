---
name: rcar-customize-boot
description: Change how the R-Car V4H Sparrow Hawk selects device tree overlays at boot — edit boot.cmd, the U-Boot hardware autodetection (camera I2C probing, display ID, fan), the FIT configuration string, and kernel/BL31 load addresses. Use to control which overlay applies on the board. Do NOT use to create or edit the overlay itself (that is rcar-customize-devicetree).
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, boot, uboot, fit, phase-2]
  domain: boot
---

# Customize the boot flow

## Purpose

Decide which FIT configurations get applied on the board. `boot.cmd` is a
U-Boot script embedded in the fitImage as the `script` image node; it probes
the hardware over I2C and composes a `#`-separated configuration string that it
hands to `bootm`.

Shared facts: `AGENTS.md` at the repo root.
Line-by-line walkthrough: [references/bootcmd-walkthrough.md](references/bootcmd-walkthrough.md).

## Prerequisites

- The overlay you want to select already exists and is in the FIT →
  `rcar-customize-devicetree`.
- Understand that **this code runs in U-Boot, not Linux.** It cannot be tested
  on the build host. Nothing here is exercised by `rcar-driver.sh`.

## Files

| What | Path |
|---|---|
| Boot script source | `local-build-scripts/fit/rcar-v4h-sh/boot.cmd` |
| Config names it may use | `FIT_OVERLAY_CONFIGS` in `local-build-scripts/build_fitimage.sh` |
| Load addresses | `FIT_KERNEL_LOADADDR`, `FIT_ATF_LOADADDR` in `config.ini` |
| Board-side U-Boot env | Saved on the board; loads partition 1 `/boot/fitImage` and sources its `script` node |

`boot.cmd` is staged into `workspace/fitimage/` and compiled into the FIT by
the fitimage target. It is **plain text in the repo** — no build step of its
own, but the fitImage must be re-assembled after an edit.

## The configuration string

The last three lines of `boot.cmd` are the whole point:

```sh
# UIO/CMEM overlay is applied by default
setenv conf "${initramfs_conf}#uio${j1_conf}${j2_conf}${j4_conf}${fan_conf}${conf_append}"
echo bootcmd: bootm ${loadaddr}${conf}
bootm ${loadaddr}${conf}
```

Composed left to right, so **later overlays override earlier ones** when they
write the same property:

| Slot | Set by | Possible values |
|---|---|---|
| `initramfs_conf` | boot device detection | `#default` or `#initramfs` |
| *(literal)* | always | `#uio` — UIO/CMEM, unconditional |
| `j1_conf` | I2C bus 1 probe | `#j1-imx219` / `#j1-imx462` / `#j1-imx708` / empty |
| `j2_conf` | I2C bus 2 probe | `#j2-imx219` / `#j2-imx462` / `#j2-imx708` / empty |
| `j4_conf` | I2C bus 0 probe | `#rpi-display-2-{5,7}in` / `#ws-display-13in` / `#olimex-dsi-hdmi` / empty |
| `fan_conf` | `${fan}` env + I2C probe | `#fan-pwm` / `#fan-argon40` / empty |
| `conf_append` | **U-Boot env, unset by default** | anything — the supported override hook |

Every name here must exist in `FIT_OVERLAY_CONFIGS`, plus `default` and
`initramfs`. Selecting a configuration that is not in the FIT fails at boot.

## A new overlay: decide how it gets selected

**Ask the user before writing any detection code.** A new overlay does not
automatically deserve a probe in `boot.cmd`, and the answer changes what you
build. Ask, in one go:

> 1. How does the device identify itself — I2C address, an ID register, or
>    nothing readable at all?
> 2. Which connector/bus is it on? (`boot.cmd` already brings up I2C 0, 1, 2, 3)
> 3. Is it safe to assume it, or must the board work with it absent?
> 4. Is it mutually exclusive with something already detected on that bus?

Then pick one of three. They are ordered by how much they cost and how much
they can break:

| Selection | Use when | Cost |
|---|---|---|
| `conf_append` at the U-Boot prompt | identification is impossible, one-off, or you are still bringing the overlay up | none — no rebuild, per board |
| env var + probe (the `fan` pattern) | the device is detectable but **optional even when present**, or its address collides with something else | small `boot.cmd` edit; user must `setenv` once |
| full autodetect (the camera/display pattern) | the device is reliably identifiable and should Just Work on any board | `boot.cmd` edit + a new slot; every board pays the probe |

### Can it be autodetected?

Full autodetect needs **all** of these. If any fails, drop to one of the rows
above rather than forcing it:

- The device answers on a bus `boot.cmd` already initialises (`i2c dev 0..3`).
  A device on a bus nobody brings up needs that added first.
- Its address, **or** a readable ID register, uniquely distinguishes it.
  Address alone is enough for IMX219 (`0x10`); it is *not* enough at `0x1a`,
  which is why `imx708_read_id` exists — and why anything unrecognised there
  becomes IMX462.
- Probing it is harmless. `i2c probe` writes to the bus; hitting an address
  that belongs to another device can wedge it. The J4 path already has to
  power the panel on (`i2c mw 0x45 …`) before `0x5d` answers.
- It does not collide with a slot already in use. `0x1a` is taken three times
  over — J1/J2 sensors and the Argon40 HAT on bus 3.

**A device with no readable identity cannot be autodetected.** GPIO-strapped
HATs, SPI-only and USB devices, and passive panels have nothing to probe. Say
so plainly, hand the user the manual selection in *Procedure: force an overlay
without touching boot.cmd*, and tell them which `#name` to type — do not invent
a probe that guesses.

### Adding a slot

A new slot is a variable set by the probe, then spliced into the composition
line — the last three lines of `boot.cmd`:

```sh
setenv conf "${initramfs_conf}#uio${j1_conf}${j2_conf}${j4_conf}${fan_conf}${myslot_conf}${conf_append}"
```

Position matters: composed left to right, later wins. Keep `${conf_append}`
**last** so the manual override always beats detection. Initialise the slot
empty (`setenv myslot_conf ''`) so an absent device contributes nothing.

## Procedure: force an overlay without touching boot.cmd

Preferred for one-off or per-board changes, and the answer whenever a device
cannot be autodetected. `conf_append` is spliced in **last**, so it wins over
everything detection chose:

```
setenv conf_append '#fan-pwm'
saveenv
boot
```

Typed at the U-Boot prompt on the board. No rebuild, no reflash. Reach for this
before editing `boot.cmd`.

Chain several: `setenv conf_append '#fan-pwm#j2-imx219'`.
Undo it: `setenv conf_append` with no value, then `saveenv`.

Be honest with the user about what this is:

- **Per board.** It lives in the U-Boot environment, not in the fitImage, so it
  does not travel with a deploy and is lost if the environment is erased.
- **It selects, it cannot create.** The name must already be a configuration in
  the FIT — confirm before telling anyone to type it:
  `mkimage -l workspace/fitimage/fitImage | grep -E '^ Configuration'`
- **It shows up in the readback.** Because it is part of `${conf}`, a forced
  overlay appears in `/chosen/u-boot,bootconf` exactly like a detected one —
  so the verification below works the same either way.

## Procedure: change the autodetection

```bash
$EDITOR local-build-scripts/fit/rcar-v4h-sh/boot.cmd
./scripts/rcar-driver.sh build fitimage image
./scripts/rcar-driver.sh verify
```

`verify` confirms the `script` node is present in the FIT — it cannot check the
script's logic. Read back what actually got embedded:

```bash
mkimage -l workspace/fitimage/fitImage | grep -A3 '(script)'
```

Then confirm every `#name` your edit can emit exists as a configuration:

```bash
mkimage -l workspace/fitimage/fitImage | grep -E '^ Configuration'
```

**Do this check by hand.** It is the one mistake that gets past every host-side
tool and only shows up as a board that will not boot.

### Read back what the detection decided

Host-side checks stop at "the name exists". To see what your edited logic
actually *chose*, deploy and read the string U-Boot recorded in the device tree
it handed the kernel:

```bash
ssh <board> "tr -d '\0' < /proc/device-tree/chosen/u-boot,bootconf; echo"
```

```
default#uio#j1-imx708#fan-argon40
```

That is the composed `${conf}` — the same string `boot.cmd` echoes before
`bootm` — and it is the only direct evidence your detection edit works. No
serial console, no sudo. Full procedure: `rcar-verify-hardware`.

Serial console still answers the other half: `bootconf` says **what** was
chosen, the `--- Check J1 ---` / `J2` / `J4` lines say **why** — which probes
hit and what chip ID came back. Reach for it when a name you expected is
missing from `bootconf`.

## Detection mechanisms currently in use

| Device | Bus | How | Notes |
|---|---|---|---|
| IMX219 | J1→`i2c dev 1`, J2→`i2c dev 2` | `i2c probe 0x10` | address alone identifies it |
| IMX708 / IMX462 | same | probe `0x1a`, then read chip ID reg `0x0016` | `0x0708` → IMX708, **anything else falls back to IMX462** |
| RPi Touch Display 2 | `i2c dev 0` via mux `0x71` ch 7 | probe `0x45`, power on, probe `0x5d`, read `0x8047` | `0x41` → 7in, `0x42` → 5in |
| Waveshare 13in | same | probe `0x41` | |
| Olimex DSI-HDMI | same | `elif i2c probe 0x48` (LT8912B) | only when `0x45` absent |
| Fan | `i2c dev 3` | `${fan}` env var **must** be set to `pwm`/`argon40`; argon40 additionally probes `0x1a` | no env → no fan overlay |
| Boot device | — | regex over `${bootargs}` `root=/dev/…` | non-`mmcblk` → `#initramfs` |

The IMX462 path is a **fallback, not a detection** — any unrecognised sensor at
`0x1a` is treated as IMX462.

The fan is **opt-in**: `fan_conf` starts empty and `${fan}` is not set by the
script, so a board with no `fan` env gets no fan overlay regardless of hardware.

## Load addresses

`FIT_KERNEL_LOADADDR=0x50200000` and `FIT_ATF_LOADADDR=0x46400000` in
`config.ini` are written into the generated `.its`. They **must match the
board's U-Boot environment** — `${loadaddr}` in `sparrowhawk.env`. Nothing on
the build host validates this; a mismatch is a silent hang at `bootm`.

Read back what the FIT actually declares. Use the generated `.its`, not
`mkimage -l`: the BL31 node is typed `Unknown Image`, so `mkimage -l` prints no
load address for it and you would only see the kernel's.

```bash
grep -nE 'load|entry' workspace/fitimage/fit-image.its | head
```

```
14:			load = <0x50200000>;     # kernel
15:			entry = <0x50200000>;
37:			load = <0x46400000>;     # BL31
38:			entry = <0x46400000>;
```

## Gotchas

- **U-Boot shell is not POSIX sh.** `if`/`test`/`setexpr`/`itest.s` are U-Boot
  builtins with their own syntax. Bash intuition does not transfer, and there
  is no host-side syntax check — a typo becomes a boot failure.
- **`test "${fan}" -eq "pwm"`** uses numeric `-eq` on a string. That is what
  the script does today; it works in U-Boot's `test`, but it is not the string
  comparison it looks like. `itest.s` is the string form, used for `bootdev`.
- **The initramfs decision is parsed out of `bootargs`**, by stripping
  `.*root=/dev/` then `[0-9].*`. A rootfs specified by `PARTUUID=` or `LABEL=`
  leaves `bootdev` unparsed and takes the **non-MMC** branch, selecting
  `#initramfs`. The initramfs currently requires a direct `/dev/...` pathname,
  so these forms then time out and enter its rescue shell.
- **`#uio` is unconditional** — the UIO/CMEM overlay always applies. Removing
  that literal changes behaviour for every board.
- **Editing `boot.cmd` requires re-assembling the fitImage.** It is embedded,
  not read from disk at boot.
- **Aliases exist for compatibility**: `rpi-display-2` → the 7in node,
  `waveshare-panel` → the 13in node. Keep them when renaming configs.
- **`rcar-driver.sh verify` cannot validate this file.** It checks the `script`
  node exists, nothing more. The composed result is only observable on a booted
  board, via `/chosen/u-boot,bootconf` — see *Read back what the detection
  decided*.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Board hangs at `bootm` | Config name not in the FIT, or load address mismatch | Check `mkimage -l` configurations and `Load Address` |
| Wrong camera overlay applied | IMX462 fallback caught an unknown sensor at `0x1a` | Add an explicit chip-ID branch |
| No fan overlay despite hardware | `${fan}` not set in U-Boot env | `setenv fan pwm; saveenv` |
| Initramfs times out waiting for `PARTUUID=…`/`LABEL=…` | Root is not a direct device pathname | Use `root=/dev/<device>`, or add identifier resolution to the initramfs |
| boot.cmd edit has no effect | fitImage not re-assembled | `rcar-driver.sh build fitimage image` |
