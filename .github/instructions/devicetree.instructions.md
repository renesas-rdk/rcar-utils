---
applyTo: "**/*.dtso,**/*.dts,**/dts/renesas/Makefile"
---

Sparrow Hawk device tree sources. See
[rcar-customize-devicetree](../../.claude/skills/rcar-customize-devicetree/SKILL.md).

- An overlay must be registered in **four** places: the `.dtso`, the kernel
  `Makefile`, `FIT_OVERLAY_IMAGES` and `FIT_OVERLAY_CONFIGS` in
  `local-build-scripts/build_fitimage.sh`.
- The kernel `Makefile` entry is **three** lines, not one:

  ```make
  dtb-$(CONFIG_ARCH_R8A779G0) += r8a779g3-sparrow-hawk-<f>.dtbo
  r8a779g3-sparrow-hawk-<f>-dtbs := r8a779g3-sparrow-hawk.dtb r8a779g3-sparrow-hawk-<f>.dtbo
  dtb-$(CONFIG_ARCH_R8A779G0) += r8a779g3-sparrow-hawk-<f>.dtb
  ```

  Lines 2–3 build a pre-merged `.dtb` that nothing consumes. Keep them: they
  make the **build fail** when the overlay does not apply. `dtc` compiles a
  broken overlay happily — without these the failure moves to the board.
- Overlays target labels exported by the base DTS. Renaming a label there
  silently breaks every overlay referencing it.
- After editing: `./scripts/rcar-driver.sh build kernel dtbs`, then
  `./scripts/rcar-driver.sh build fitimage image`, then
  `./scripts/rcar-driver.sh verify`. `kernel dtbs` alone does not refresh the
  fitImage.
