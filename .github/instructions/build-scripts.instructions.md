---
applyTo: "local-build-scripts/**"
---

These are the Sparrow Hawk build scripts. See [AGENTS.md](../../AGENTS.md).

- Every script `source`s `./config.ini` and `./common.sh` with **relative**
  paths, so they only run with cwd = `local-build-scripts/`. Preserve that
  assumption; do not "fix" it by rewriting the sources to absolute paths
  without also updating `scripts/rcar-driver.sh`.
- `config.ini` paths are commented out **on purpose**: the file is sourced, so
  an assignment — even an empty one — overwrites the caller's environment.
  Never uncomment a path to give it an empty value.
- Sub-scripts exit non-zero on failure and `main_build.sh` propagates it. Keep
  that: a target that swallows a failure makes a broken build look fine.
- Adding a device tree overlay means editing **both** `FIT_OVERLAY_IMAGES` and
  `FIT_OVERLAY_CONFIGS` in `build_fitimage.sh`. Registering the image without a
  configuration builds cleanly and fails only on the board.
- `patches/<name>/series` is the required application order and is deliberately
  **not** alphabetical. Do not sort it.
- External modules read different env vars for the kernel path (`KERNEL_SRC`,
  `KERNELSRC`, `KERNELDIR`) because the upstream Makefiles disagree. Keep all
  of them exported.
