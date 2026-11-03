---
name: rcar-verify-hardware
description: Verify a deployed R-Car V4H Sparrow Hawk kernel on the live board over ssh, checking which FIT configuration U-Boot selected, whether overlay nodes reached the running device tree, and whether drivers bound. Guide user-visible functional checks without claiming they ran remotely. Use after deployment or when validating a device-tree change on hardware. Do NOT use to build, transfer files, or reboot.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, verify, hardware, devicetree, overlay, phase-3]
  domain: deploy
---

# Verify on real hardware

## Purpose

`rcar-verify-build` proves the artifacts are internally consistent on the
build host. It says so itself: *"`fdtoverlay` is not U-Boot"*, *"nothing here
executes aarch64 code"*. `rcar-deploy-image` step 8 then checks that the board came
back, but it only checks `uname -r`, `modules.dep`, firmware and module tree
count. **Neither one looks at the device tree the kernel is running.**

This skill checks FIT selection, node presence, and driver binding. Device function still needs an appropriate functional test and, for
cameras and displays, confirmation from the user.

Shared facts: `AGENTS.md` at the repo root.

## Read this first: the confirmation gate

**Before verifying any overlay that describes external hardware, ask the user
to confirm the hardware is physically connected. Do not skip this, do not
assume, and do not infer it from a previous session.**

On this board a missing overlay and missing hardware look **the same**.

`boot.cmd` picks camera and display overlays by probing I2C *in U-Boot*. With no
device on the bus, `i2c probe` gets no hit and `j1_conf`, `j2_conf`, or `j4_conf`
stays empty. The overlay is never appended to the FIT config, and its nodes never
appear in `/proc/device-tree`. A broken `.dtso`, an unregistered
`FIT_OVERLAY_IMAGES` entry, and an unplugged camera all look like that from inside
Linux.

So a "not applied" result on an unconfirmed board tells you nothing. It cannot
distinguish these four causes:

| Cause | Distinguished by |
|---|---|
| Hardware not plugged in | **the user's confirmation**, nothing else |
| U-Boot autodetect does not know the new device | serial console `--- Check J1 ---` output + `rcar-customize-boot` |
| Overlay broken / target node missing | `rcar-verify-build` (host-side `fdtoverlay`) |
| Overlay not embedded or not selectable in the FIT | `mkimage -l` and the four places in `rcar-customize-devicetree` |

**Confirm before you power the board, not after.** These are I2C/MIPI/DSI
connectors on a running SoC, and hot-plugging a camera or a DSI panel can damage
the board. U-Boot also probes the bus long before the prompt appears, so plugging
a camera in after boot changes nothing in the running DT.

### When to ask

| Overlay under test | Ask? |
|---|---|
| A **new** overlay for hardware not supported before | **Always.** This is the case the gate exists for |
| `camera-j{1,2}-imx{219,462,708}` | Yes. Ask which module, on which connector (J1 / J2) |
| `rpi-display-2-{5,7}in`, `ws-display-13in`, `olimex-dsi-hdmi` | Yes. Ask which panel, on J4 |
| `fan-argon40` | Yes. The HAT must be fitted **and** `fan=argon40` set in the U-Boot env |
| `fan-pwm` | Yes. The fan must be wired to the PWM header **and** `fan=pwm` set in the U-Boot env |
| `uio` | No. It is always applied and has no external hardware |
| A base-DTS-only change (`r8a779g3-sparrow-hawk.dts`) | No, unless the change describes something external |

### What to ask

> Before I verify the `<feature>` overlay on `<board-ip>`:
> 1. Is the `<device>` physically connected to `<connector>` right now?
> 2. Was it connected **before** the board was last powered on / rebooted?
> 3. Anything else on the shared connectors that could conflict (another
>    camera on J2, a panel on J4)?
> 4. Do you have serial console available if autodetection needs diagnosis?
>    SSH can read the selected FIT configuration; serial explains why U-Boot
>    did or did not select it.

**If the answer to 1 or 2 is no:** stop. Do not run the checks and do not
report a failure. Say what is needed: connect the device, power-cycle the
board, then re-run. A verify against an unpopulated connector produces a
false negative, which can send someone to edit a `.dtso` that was fine.

## Prerequisites

- A build deployed with `rcar-deploy-image` and its step 8 clean.
- Board reachable over ssh; the login user is a sudoer.
- Host: `sshpass`, `ssh`. Board: `dtc` helps but is not required.
- Serial console is optional for normal verification and recommended when an
  expected overlay is absent from `bootconf`. For how to attach (ports, baud,
  `dialout`), see *Getting on the serial console* in `rcar-deploy-image`.
- Hardware confirmed per the gate above.

## Connect

Same credentials and the same lab-network caveat as `rcar-deploy-image`
(host key checking is off, because a reflashed board changes its key):

```bash
HOST=<board-ip>
BOARD_USER=<ssh-user>
read -rsp "Board password: " RCAR_BOARD_PASSWORD; echo
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=10"
sshb() {
    SSHPASS="$RCAR_BOARD_PASSWORD" sshpass -e \
        ssh $SSH_OPTS "${BOARD_USER}@${HOST}" "$@"
}
```

`sshpass -e` reads `SSHPASS` from the environment instead of exposing the
password in the process argument list. Do not use the shell's existing `USER`
variable for the board login; it normally names the local build user.

Every check below is read-only. Nothing here writes to the board.

## Check 1: which FIT configuration did U-Boot select?

**U-Boot records it in the device tree it hands the kernel.** Reading it takes one file,
with no sudo and no serial console:

```bash
sshb "tr -d '\0' < /proc/device-tree/chosen/u-boot,bootconf; echo"
```

```
default#uio#j1-imx708#fan-argon40
```

That is the exact string `boot.cmd` composed, the same one it echoes as
`bootcmd: bootm ${loadaddr}${conf}`, so you can trust it. It separates
"U-Boot never selected the overlay" from "U-Boot selected it and it did not
take effect".

Read the other `/chosen` properties too:

```bash
sshb "ls /proc/device-tree/chosen/; tr -d '\0' < /proc/device-tree/chosen/u-boot,version; echo"
```

`/chosen` also has `bootargs` (the real root device, which is what decides
`#default` vs `#initramfs`) and `stdout-path`.

**How to read the string:** the first element is `default` or `initramfs`, then
one `#name` per overlay in the order `boot.cmd` applied them, with `uio` always
first. A name that is absent was never selected. Aliases print as themselves (`rpi-display-2` and `rpi-display-2-7in` are
the same blob).

**The serial console answers a different question.** `bootconf` says *what was
chosen*. The console's `--- Check J1 ---`, `J2`, and `J4` lines say *why*: which
I2C probes hit, and what chip ID `imx708_read_id` read back. When `bootconf` is
missing an overlay you expected, the console shows whether U-Boot saw the device.

**A name missing from `bootconf` is not always a fault.** A new overlay has no
detection until someone writes it, and the fan overlays are opt-in, so
neither is selected without `fan=` in the U-Boot environment. Before calling the
detection broken, check what it can emit in *Detection mechanisms currently in
use* in `rcar-customize-boot`. If the overlay is meant to be
selected by hand, the user sets it at the U-Boot prompt and it lands in
`bootconf` like any other:

```
setenv conf_append '#<feature>'
saveenv
boot
```

`fw_printenv` is **not** a substitute: it is absent on the stock Ubuntu image
(no `libubootenv-tool`), and it would show the *stored* environment rather than
what this boot composed. Use `bootconf`.

## Check 2: did the overlay's nodes reach the running device tree?

```bash
# what board is the kernel actually running?
sshb "cat /proc/device-tree/model; echo"          # -> Retronix Sparrow Hawk board based on r8a779g3
sshb "tr '\0' ' ' < /proc/device-tree/compatible; echo"

# does the overlay's node exist? (name it from the .dtso target)
sshb "find /proc/device-tree -maxdepth 4 -iname '*<feature>*'"
```

If `/proc/device-tree/model` is not the Sparrow Hawk string from the base DTS,
U-Boot loaded a different fitImage. The cause is the same as a `uname -r`
mismatch at deploy step 8. Fix that before running the checks below.

### Get the whole running DT

**`dtc` is not installed on the stock image.** Do not use
`dtc -I fs -O dts /proc/device-tree`. Pull the raw blob instead. U-Boot's
own FDT is exported whole at `/sys/firmware/fdt`, and decompiling it on the
host is faster and exact:

```bash
# root-only (mode 0400), so read it through sudo and bring it back as base64
printf '%s\n' "$RCAR_BOARD_PASSWORD" \
    | sshb "sudo -S -p '' cat /sys/firmware/fdt | base64 -w0" \
    | base64 -d > /tmp/board-running.dtb
dtc -I dtb -O dts /tmp/board-running.dtb > /tmp/board-running.dts
```

`/sys/firmware/fdt` is the blob **after** U-Boot merged the overlays, which is
what the kernel booted with.

### Comparing against the host merge

Reproduce the merge in `boot.cmd` order (the order `bootconf` printed), then
compare:

```bash
cd workspace/fitimage
fdtoverlay -i r8a779g3-sparrow-hawk.dtb -o /tmp/expected.dtb \
    r8a779g3-sparrow-hawk-uio.dtbo \
    r8a779g3-sparrow-hawk-camera-j1-imx708.dtbo \
    r8a779g3-sparrow-hawk-fan-argon40.dtbo
dtc -I dtb -O dts /tmp/expected.dtb > /tmp/expected.dts

# structural comparison using full node paths, not ambiguous leaf names
walk_fdt() {
    local blob=$1 path=$2 child
    printf '%s\n' "$path"
    while IFS= read -r child; do
        walk_fdt "$blob" "${path%/}/$child"
    done < <(fdtget -l "$blob" "$path")
}
diff -u <(walk_fdt /tmp/expected.dtb / | sort) \
        <(walk_fdt /tmp/board-running.dtb / | sort)
```

Start with the subtree for the feature being tested. A measured board had no
node-path differences and had these U-Boot-added property differences:

| Property | Added by |
|---|---|
| `/chosen/u-boot,bootconf` | the config string from Check 1 |
| `/chosen/u-boot,version` | U-Boot build id |
| `/chosen/smbios3-entrypoint` | SMBIOS table address |
| `local-mac-address` (ethernet node) | the board's real MAC |

Treat that list as a baseline, not a fixed set. U-Boot versions and
board firmware may add other runtime fixups. Investigate unexpected differences
in the relevant subtree, but do not fail a board only because the total property
delta is not exactly four.

## Check 3: did a driver bind?

**Host-side verification cannot do this check.** A node
in `/proc/device-tree` only means the description arrived. Binding means the
kernel found a driver, matched `compatible`, and `probe()` returned 0.

```bash
# the node is bound iff it has a driver symlink
sshb "ls -l /sys/bus/i2c/devices/*/driver 2>/dev/null"
sshb "ls -l /sys/bus/platform/devices/*/driver 2>/dev/null | grep -i <feature>"

# devices that appeared but never bound
sshb "ls /sys/bus/i2c/devices/ /sys/bus/platform/devices/"

# probe failures, deferrals and DT complaints
if sshb "dmesg >/dev/null 2>&1"; then
    sshb "dmesg | grep -iE 'probe|deferr|failed|error|OF:' | grep -iv 'no error' || true"
else
    printf '%s\n' "$RCAR_BOARD_PASSWORD" \
        | sshb "sudo -S -p '' dmesg | grep -iE 'probe|deferr|failed|error|OF:' | grep -iv 'no error' || true"
fi
```

`-EPROBE_DEFER` that never resolves is a common overlay bug: the node is
right, but it references a regulator/clock/PHY the overlay forgot to enable.
`fdtoverlay` and node-presence checks cannot see it.

## Check 4: does the device work?

Pick the row for the overlay under test. Everything in the
*Expected* column below was **observed on a live board** except where marked.

| Overlay | Expected on the board |
|---|---|
| `camera-j1-imx{219,462,708}` | I2C `1-00XX` bound to the sensor driver; bus `i2c-1` present |
| `camera-j2-imx{219,462,708}` | same on bus `2-`; **the overlay enables `&i2c2` itself**, so without a J2 overlay there is no `i2c-2` |
| `imx219` cameras | address `0x10`, device `<bus>-0010` |
| `imx462` / `imx708` cameras | address `0x1a`, device `<bus>-001a`; U-Boot picks `imx708` only when the chip ID read is `0x0708`, else falls back to `imx462` |
| any camera | `/dev/media0` + `v4l-subdev*` in `/sys/class/video4linux/`; `video0..11` are the VIN/CSI pipeline and exist **with or without** a sensor |
| `rpi-display-2-{5,7}in` | a DSI connector appears under `/sys/class/drm/`; Goodix touch at `0-005d` creates a `/dev/input/event*` (none exist without a panel) |
| `ws-display-13in` | DSI connector; panel controller at `0-0041` |
| `olimex-dsi-hdmi` | LT8912B at `0-0048` bound; DSI connector |
| `fan-argon40` | `3-001a` bound to `argon-fan-hat`, **and** a second platform device `/sys/devices/platform/pwm-fan-ext` (driver `pwm-fan`) with its own hwmon |
| `fan-pwm` | **no new node**. It only rewrites properties on the base `&fan`. See the gotcha below |
| `uio` | `/dev/uio*` count == `generic-uio` node count in the running DT |

Generic commands:

```bash
sshb 'echo video=$(ls /dev/video* 2>/dev/null | wc -l) uio=$(ls /dev/uio* 2>/dev/null | wc -l) \
           media=$(ls /dev/media* 2>/dev/null | wc -l) input=$(ls /dev/input/event* 2>/dev/null | wc -l)'
sshb "ls /sys/bus/i2c/devices/ | grep -v '^i2c-'"          # populated addresses
sshb 'for d in /sys/bus/i2c/devices/*/; do [ -e "$d/driver" ] && \
        echo "$(basename $d) -> $(basename $(readlink -f $d/driver))"; done'
sshb 'for c in /sys/class/drm/card*/card*-*/status; do [ -e "$c" ] && echo "$c = $(cat $c)"; done'
sshb "grep -H . /sys/class/hwmon/*/name"
```

A healthy stock board with a camera on J1 and the Argon40 HAT reports:

```
0-0071 -> pca954x                    (base: I2C mux boot.cmd writes at 0x71)
1-001a -> imx708                     (overlay: camera on J1)
3-001a -> argon-fan-hat              (overlay: fan-argon40)
6-002c -> ti_sn65dsi86               (base: DSI->eDP bridge)
7-001a -> da7213                     (base: audio codec)
8-0068 -> clk-renesas-pcie-9series   (base: PCIe clock generator)
```

Everything on that list except `1-001a` and `3-001a` is **base DTS**. Do not
read a populated I2C address as evidence an overlay applied.

**`/dev/video*` existing is not proof a camera streams.** On this board those
12 nodes are the VIN/CSI pipeline and appear with no sensor attached.
The sensor shows up as an I2C binding and a `v4l-subdev`. Streaming a frame is
the only functional test, and it needs the user, who can see the sensor, the lens
cap, and the lighting.

## Check 5: the UIO contract

This fails without any message when the module option is missing:

```bash
sshb "cat /usr/lib/modprobe.d/uio_pdrv_genirq.conf"
sshb "ls /dev/uio*"
```

`uio_pdrv_genirq` has a single OF match entry that is filled in **only** from a
module parameter. Without `options uio_pdrv_genirq of_id="generic-uio"` no
`generic-uio` node binds. The DT is correct and `/dev/uio*` is still empty.

Compare counts, because equal counts show that *every* node bound:

```bash
sshb "ls /dev/uio* | wc -l"                        # -> 313 on a measured board
grep -c 'generic-uio' /tmp/board-running.dts       # -> 313
```

Equal counts mean the overlay applied **and** every node it declared got a
driver. A short count is a partial bind, which no other check here would
notice.

## Reporting the result

Say which of these you established:

1. U-Boot selected the config (Check 1, `u-boot,bootconf`).
2. The nodes are in the running DT (Check 2).
3. A driver bound (Check 3).
4. The device functions (Check 4, or "needs the user").

Quote the `bootconf` string verbatim, because every other result depends on it. If an expected overlay is missing from it, say that the cause
is not determinable from Linux and name serial console as the next step, rather
than guessing between "not plugged in" and "autodetect does not know it". Also
state which hardware the user confirmed was connected, because the whole result
depends on that confirmation.

## Gotchas

- **No `OF: overlay` in dmesg is normal.** U-Boot merges before boot; the
  kernel never sees an overlay. Do not treat its absence as a failure, and do
  not go looking for configfs overlay support. `/chosen/u-boot,bootconf` is the
  record the kernel *does* get. See Check 1.
- **Neither `dtc` nor `fw_printenv` is on the stock image.** Use
  `/sys/firmware/fdt` and `/proc/device-tree/chosen/u-boot,bootconf`.
- **A node present with no driver is the common outcome**, not a rare one.
  Check 2 passing and Check 3 failing is a real bug, usually a
  missing `status = "okay"`, a wrong `compatible`, or an unmet dependency.
- **When two overlays write the same property, the last one wins**, in the order
  `boot.cmd` composes them (`uio` first, always). A property that looks ignored
  may have been overwritten by a later overlay, not dropped.
- **A `pwmfan` hwmon proves nothing about the fan overlays.** The base DTS
  already declares a root `pwm-fan` node, so `/sys/class/hwmon/*/name` reports
  `pwmfan` on a board with no fan overlay at all. Distinguish by *platform
  device*, not by hwmon name: `/sys/devices/platform/pwm-fan` is the base one,
  `/sys/devices/platform/pwm-fan-ext` is the one `fan-argon40` adds. A measured
  board with the HAT fitted shows **both**. (The hwmon name is `pwmfan`, not
  `pwm-fan`, because hwmon names cannot contain a hyphen.)
- **`fan-pwm` adds no node, so node-presence checks cannot see it.** The
  overlay only rewrites properties on the existing `&fan`: `pwms`,
  `cooling-levels`, `pulses-per-revolution`. Detect it by *value* in the
  running DT. The base has `cooling-levels = <0xff>` and no `pwms` property. The
  overlay sets `cooling-levels = <0 50 100 150 200 255>` and adds `pwms`.
- **The fan overlays need `fan=` in the U-Boot environment.** Hardware alone
  never selects them; `fan-argon40` needs *both* the env var and an I2C hit at
  `3-001a`. Confirm the selection with `bootconf` (Check 1), not by guessing.
- **An overlay can enable the I2C bus it lives on.** `camera-j2-*` does
  `&i2c2 { status = "okay" }`, so with no J2 camera the bus `i2c-2` does not
  appear in `/sys/bus/i2c/devices/` at all. Bus absence is a legitimate
  signal, not a fault.
- **`rpi-display-2` and `waveshare-panel` are aliases** kept for backward
  compatibility, pointing at `-2-7in` and `ws-display-13in`. Both config names
  point at one blob, so a console line naming either is the same overlay.
- **Do not hot-plug to make a check pass.** U-Boot probed the bus at power-on;
  connecting afterwards changes nothing in the running DT and risks the board.
- **Never hardcode the kernel version.** Read it with `cat linux-sh/include/config/kernel.release`.
- **Stale module trees on the board are reported by deploy, never deleted.**
  A driver may be loading from an older release's tree.

## Troubleshooting

| Symptom | Likely cause | Next step |
|---|---|---|
| Overlay's nodes absent from `/proc/device-tree` | U-Boot never selected the config, because the hardware is absent or autodetect does not know the device | Re-confirm the gate; read the serial console; `rcar-customize-boot` |
| Console shows the config, nodes still absent | Blob not embedded, `FIT_OVERLAY_IMAGES` entry missing | `rcar-customize-devicetree`, place 3 |
| U-Boot errors on the `#name` at boot | `FIT_OVERLAY_CONFIGS` missing | `rcar-customize-devicetree`, place 4 |
| Nodes present, no `driver` symlink | `compatible` mismatch, `status` not `okay`, or driver not built | `rcar-customize-kernel-config`; check `dmesg` |
| `-EPROBE_DEFER` repeating in dmesg | Overlay references a regulator/clock/PHY it did not enable | Fix the `.dtso` (see `rcar-customize-devicetree`) |
| `/proc/device-tree/model` is not Sparrow Hawk | U-Boot loaded a fitImage from elsewhere | Boot medium must be partition 1, `/boot/fitImage` |
| Device node exists but the device is dead | Wiring, power rail, or a wrong DT description | User-side; nothing here can resolve it |
| `/dev/uio*` empty with the uio overlay applied | `modprobe.d` `of_id` option missing | Check 5 |

## Limits

- **U-Boot's selection is observed, not inferred.** `/chosen/u-boot,bootconf`
  records it. It does *not* tell you **why** a name is missing: device absent,
  autodetect does not know it, or the user never set `fan=`. The serial console
  answers that. Nothing in Linux does.
- **Node presence and driver binding are not device function.** Only the user
  can confirm a camera produces a usable image or a panel shows a picture.
- **Nothing here can prove hardware is connected.** That is a physical fact
  supplied by the user, and every conclusion rests on it.
- **The board's running DT is not byte-comparable to the host merge.** U-Boot
  fixes up memory, chosen and phandles. Subtree diffs only.
- **Read-only.** This skill never modifies the board. Changing the U-Boot
  environment is `rcar-customize-boot`; changing what is on the board is
  `rcar-deploy-image`.

## Not covered

U-Boot recovery, partitioning, and building the Ubuntu rootfs. For attaching to
the serial console, see *Getting on the serial console* in `rcar-deploy-image`.