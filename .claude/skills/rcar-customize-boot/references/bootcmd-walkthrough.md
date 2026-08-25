# boot.cmd — line-by-line

Source: `local-build-scripts/fit/rcar-v4h-sh/boot.cmd`. This runs **in U-Boot**,
after `load … /boot/fitImage` and `source ${loadaddr}:script`.

## Entry contract

The board's U-Boot environment must enter through commands equivalent to:

```
autoconf_mmc=setenv bootargs "rw root=/dev/mmcblk0p1 rootwait" && load mmc 0:1 ${loadaddr} /boot/fitImage && source ${loadaddr}:script
autoconf_nvme=pci e && nvme scan && setenv bootargs "rw root=/dev/nvme0n1p1 rootwait" && load nvme 0:1 ${loadaddr} /boot/fitImage && source ${loadaddr}:script
autoconf_usb=pci e && usb start && setenv bootargs "rw root=/dev/sda1 rootwait" && load usb 0:1 ${loadaddr} /boot/fitImage && source ${loadaddr}:script
```

So on entry the script can rely on: `${loadaddr}` set, `${bootargs}` set with a
`root=/dev/…`, fitImage already in RAM. Always **partition 1**, always
`/boot/fitImage`.

There is also a fixed fallback in `mmc_boot.cfg`:
`CONFIG_BOOTCOMMAND="load mmc 0:1 0x58000000 /boot/fitImage && bootm 0x58000000"`
— that path runs `bootm` with **no configuration string**, so it takes the FIT
default (`default = "default"`) and applies no overlays.

## The shared chip-ID reader

```sh
setenv imx708_read_id '
    i2c olen 0x1a 2
    i2c read 0x1a 0x0016 2 0x48000000
    setexpr.b id_high *0x48000000
    setexpr.b id_low  *0x48000001
    setexpr chip_id ${id_high} * 0x100
    setexpr chip_id ${chip_id} + ${id_low}
'
```

Defined once, `run imx708_read_id` from both camera blocks. Sets 2-byte
register addressing, reads 2 bytes from `0x0016` into scratch RAM at
`0x48000000`, then byte-swaps into `${chip_id}`.

`0x48000000` is a scratch address reused later by the display probe. Anything
you add that needs scratch RAM should stay clear of it or reload after use.

## Camera on J1 / J2

```sh
i2c dev 1                          # J1 (J2 uses: i2c dev 2)
if i2c probe 0x10; then            # IMX219 answers at 0x10
    setenv j1_conf '#j1-imx219';
fi
if i2c probe 0x1a; then            # IMX708 and IMX462 both answer at 0x1a
    run imx708_read_id
    if test 0x${chip_id} -eq 0x0708; then
        setenv j1_conf '#j1-imx708'
    else
        setenv j1_conf '#j1-imx462'   # fallback, NOT a positive match
    fi
fi
```

Two things to notice:

- **IMX462 is the else-branch.** Any unknown sensor at `0x1a` is declared an
  IMX462. Adding a third sensor at that address means adding an explicit
  chip-ID branch *before* the fallback.
- **`0x10` and `0x1a` are not mutually exclusive.** If both answered, the
  `0x1a` block runs second and wins.

## Display on J4

```sh
i2c dev 0 && i2c mw 0x71 0x0 0x7 && i2c speed 100000
```

Bus 0 goes through an I2C **mux at `0x71`**, switched to channel 7, then the
bus is slowed to 100 kHz. Every J4 probe below depends on that line having
succeeded.

```sh
if i2c probe 0x45; then
    i2c mw 0x45 0x02 0x00 && sleep 0.1 && i2c mw 0x45 0x02 0x03 && sleep 0.1
```

`0x45` is the display power controller — it must be powered **on** before the
touch controller at `0x5d` will answer. The two writes with `sleep 0.1` are a
power cycle; the delays are load-bearing.

```sh
    if i2c probe 0x5d; then
        i2c read 0x5d 0x8047.2 0x1 0x48000000
        setexpr.b config_version *0x48000000
        if test 0x${config_version} -eq 0x41; then   # 'A'
            setenv j4_conf '#rpi-display-2-7in';
        fi
        if test 0x${config_version} -eq 0x42; then   # 'B'
            setenv j4_conf '#rpi-display-2-5in';
        fi
    fi
    if i2c probe 0x41; then
        setenv j4_conf '#ws-display-13in';           # Waveshare
    fi
elif i2c probe 0x48; then
    setenv j4_conf '#olimex-dsi-hdmi';               # LT8912B bridge
fi
```

- `0x8047.2` is register `0x8047` with **2-byte addressing** (the `.2` suffix).
- Goodix config version `0x41`/`0x42` distinguishes 7in from 5in. A newer panel
  revision reporting `0x43` matches **neither** and leaves `j4_conf` empty — no
  display overlay, silently.
- The Waveshare check is **inside** the `0x45` branch and runs after the RPi
  check, so it overrides it if both match.
- Olimex is `elif` — only reached when `0x45` does **not** answer.

## Fan

```sh
setenv fan_conf ''
if test "${fan}" -eq "pwm" ; then
    setenv fan_conf '#fan-pwm'
fi
if test "${fan}" -eq "argon40" ; then
    i2c dev 3
    if i2c probe 0x1a; then
        setenv fan_conf '#fan-argon40'
    fi
fi
```

**Opt-in.** `${fan}` is never set by this script — it comes from the saved
U-Boot environment. No `fan` env means no fan overlay, whatever is plugged in:

```
setenv fan pwm
saveenv
```

`-eq` is U-Boot's `test` numeric operator being used on strings. It behaves
here, but `itest.s` is the string comparison (as used for `bootdev` below).

Only `argon40` additionally verifies hardware (`0x1a` on bus 3); `pwm` is taken
on the env var alone.

## Boot device → initramfs

```sh
setenv bootdev ${bootargs}
setexpr bootdev gsub ".*root=/dev/" ""
setexpr bootdev gsub "[0-9].*" ""

setenv initramfs_conf '#default'
if itest.s "${bootdev}" != "mmcblk"; then
    setenv initramfs_conf '#initramfs'
fi
```

Two regex substitutions reduce `rw root=/dev/nvme0n1p1 rootwait` to `nvme`.
Anything that is not exactly `mmcblk` selects `#initramfs`, because NVMe and
USB need `pcie-rcar-gen4.ko` loaded from the initramfs before the real root is
reachable.

**Failure mode:** a `bootargs` using `root=PARTUUID=…` or `root=LABEL=…` never
matches `.*root=/dev/`, so `bootdev` keeps the whole string, compares
unequal to `mmcblk`, and takes the initramfs path. The initramfs then tests that
literal value with `-b`; it does not resolve filesystem identifiers, so it
times out and enters the rescue shell. Use a direct `root=/dev/...` pathname
unless identifier resolution is added to `local-build-scripts/initramfs/init`.

## Final composition

```sh
setenv conf "${initramfs_conf}#uio${j1_conf}${j2_conf}${j4_conf}${fan_conf}${conf_append}"
bootm ${loadaddr}${conf}
```

A typical result:

```
bootm 0x48080000#default#uio#j1-imx219#rpi-display-2-7in
```

- `#uio` is a **literal** — the UIO/CMEM overlay always applies.
- `${conf_append}` is last, so it overrides everything. It is unset by default
  and is the intended per-board override hook.
- Unset slots contribute nothing (empty string), not an empty `#`.

## Testing changes

There is no host-side test for this file. The most you can do:

1. Re-assemble and confirm the script node is embedded:
   `mkimage -l workspace/fitimage/fitImage | grep -A3 '(script)'`
2. Confirm every `#name` the script can emit exists as a configuration:
   `mkimage -l workspace/fitimage/fitImage | grep -E '^ Configuration'`
3. On the board, read the echoed line before `bootm` — the script prints
   `bootcmd: bootm ${loadaddr}${conf}` so the composed string is visible on the
   console.

Step 3 is the only real test. Steps 1–2 catch the common mistake (a config name
that does not exist) without a board.
