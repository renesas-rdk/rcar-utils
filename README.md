# R-Car Utility - R-Car V4H Sparrow Hawk

Standalone scripts to build and deploy the Linux kernel, modules, firmware,
initramfs, TF-A BL31, and U-Boot FIT image (`fitImage`) for the R-Car V4H
Sparrow Hawk.

This branch (`ubuntu/rcar-v4h-sh`) is trimmed down to the Sparrow Hawk build
only.

## Hierarchy

```
.
├── linux-sh/               kernel source, cloned on demand (gitignored)
├── local-build-scripts/
├── workspace/              everything the build produces (gitignored)
├── LICENSE
└── README.md
```

### local-build-scripts

Build scripts for the Sparrow Hawk kernel and fitImage. See
[local-build-scripts/README.md](local-build-scripts/README.md) for the
configuration and usage details.

## Quick start

```bash
./scripts/rcar-driver.sh preflight
./scripts/rcar-driver.sh smoke
```

`smoke` builds the complete deployable output—installed kernel and external
modules, BL31, initramfs, and fitImage—then verifies the artifacts.

No configuration is needed. The kernel source is expected in `linux-sh/` and
the build offers to clone it (single branch) when it is missing; everything
produced is written under `workspace/`, next to these scripts. Uncomment a path
in `config.ini` only to build somewhere else.

Every input and deployable artifact is produced directly by this repository.
No external build system, packaging step, or pre-populated deploy directory is
required.
