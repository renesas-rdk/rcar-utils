---
agent: agent
description: Verify a deployed R-Car V4H Sparrow Hawk kernel on the live board over ssh. Checks the FIT configuration, device tree nodes, and driver binding.
---

Verify what the board is running, after `rcar-deploy.sh` reported a
clean step 8.

Context: [AGENTS.md](../../AGENTS.md). Deep guide:
[rcar-verify-hardware](../../.claude/skills/rcar-verify-hardware/SKILL.md).

**Ask the user to confirm the hardware is physically connected before running
anything**, and confirm it was connected *before* the board was last powered
on. On this board an unplugged camera and a broken `.dtso` are the same
observation from inside Linux: U-Boot probes I2C at power-on, so a device that
was not there is absent from the running device tree. A "not applied"
result on an unconfirmed board tells you nothing.

Then, over ssh (read-only, nothing here writes to the board):

1. Which FIT configuration U-Boot selected. Quote it verbatim:
   `tr -d '\0' < /proc/device-tree/chosen/u-boot,bootconf; echo`
2. Whether the overlay's nodes reached `/proc/device-tree`.
3. Whether a driver bound. Look for a `driver` symlink under
   `/sys/bus/*/devices/<dev>/`, and check `dmesg` for `-EPROBE_DEFER`.
4. Whether the device functions. This usually needs the user.

Report those four separately. `dtc` and `fw_printenv` are
**not** on the stock image, so use `/sys/firmware/fdt` and `bootconf`.

If an expected overlay is missing from `bootconf`, say the cause is not
determinable from Linux and name the serial console as the next step. Do not
guess between "not plugged in" and "autodetect does not know it".
