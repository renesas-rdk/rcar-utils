# R-Car Utility - R-Car V4H Sparrow Hawk

Scripts to build the Linux kernel and a U-Boot FIT image (`fitImage`) for the
R-Car V4H Sparrow Hawk, outside of Yocto.

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
cd local-build-scripts
./main_build.sh bl31 all          # ARM Trusted Firmware BL31
./main_build.sh kernel modules    # kernel, device trees and modules
./main_build.sh initramfs all     # only needed to boot from NVMe/USB
./main_build.sh fitimage all
```

No configuration is needed. The kernel source is expected in `linux-sh/` and
the build offers to clone it (single branch) when it is missing; everything
produced is written under `workspace/`, next to these scripts. Uncomment a path
in `config.ini` only to build somewhere else.

Every input the fitImage needs is built from source, so no Yocto deploy
directory is involved.
