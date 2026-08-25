# Observed Sparrow Hawk hardware baseline

Observed on August 25, 2026, on a board running
`6.18.39-arm64-renesas` from an MMC rootfs, with an IMX708 camera on J1,
an Argon40 fan HAT on CN7, and no J4 panel.

| Check | Observed result |
|---|---|
| `/proc/device-tree/chosen/u-boot,bootconf` | `default#uio#j1-imx708#fan-argon40`, readable as the login user |
| `/proc/device-tree/model` | `Retronix Sparrow Hawk board based on r8a779g3` |
| I2C bindings | `1-001a` to `imx708`, `3-001a` to `argon-fan-hat`, plus four base-DTS devices |
| UIO | 313 `generic-uio` nodes and 313 `/dev/uio*` devices; the `of_id` option was present |
| Host merge vs running DT | Full node paths matched; four U-Boot-added properties differed on this firmware |
| Fan | Both `/sys/devices/platform/pwm-fan` and overlay device `pwm-fan-ext`; `pwm1` readable |
| Host build verification | 34 passed, 0 failed after obsolete staged overlays were excluded |

The board also established these reusable facts:

- `/chosen/u-boot,bootconf` reports U-Boot's selected configuration without a
  serial console or sudo.
- `fw_printenv` and `dtc` were absent from the stock Ubuntu image.
- `/sys/firmware/fdt` was root-readable and provided the complete running FDT.
- A base-DTS `pwmfan` hwmon exists without a fan overlay.
- `fan-pwm` adds no node; it changes properties on the existing fan node.

Still unverified on real hardware: every display overlay
(`rpi-display-2-*`, `ws-display-13in`, `olimex-dsi-hdmi`), the J2 camera path,
the `imx219` and `imx462` paths, and `fan-pwm`. Their checks are derived from
`boot.cmd` and the device-tree sources and must not be described as observed.
