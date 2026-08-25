---
name: rcar-print-build-info
description: Print a host-side summary of the current rcar-utils build state for the R-Car V4H Sparrow Hawk — resolved paths plus which key artifacts exist, their sizes, and mtimes. Also provides commands for inspecting the kernel release and fitImage contents. Use to answer "what is built right now?" before deciding what to rebuild. Do NOT use to build or to assert correctness — that is rcar-verify-build.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, inspection]
  domain: build
---

# Print build info

## Purpose

Read-only snapshot of the workspace. Answers "what is built, how old is it,
where did it go" without building or judging. For pass/fail use
`rcar-verify-build`.

Shared facts: `AGENTS.md` at the repo root.

## Run

```bash
./scripts/rcar-driver.sh info
```

Prints the resolved layout (repo / kernel / workspace — reflecting any
`KERNEL_DIR` or `WORKSPACE_DIR` override) and one line per key artifact with
mtime and size, or `(absent)`:

```
Artifacts
  09:01:54       23976448  linux-sh/arch/arm64/boot/Image
  06:57:40       25536651  workspace/fitimage/fitImage
  06:57:39          69344  workspace/fitimage/r8a779g3-sparrow-hawk.dtb
  06:57:39        1201714  workspace/fitimage/uInitramfs.cpio.gz
  06:54:39         131172  workspace/arm-trusted-firmware/release/bl31-sparrow-hawk.bin
```

Reading it: if `Image` is **newer** than `fitImage`, the FIT is stale — see
`rcar-build`. `rcar-driver.sh verify` confirms.

## Other useful one-liners

All verified. Paths assume the default workspace.

Kernel release the tree is configured for:

```bash
cat linux-sh/include/config/kernel.release
```

Full fitImage contents — images, load addresses, hashes, configurations:

```bash
mkimage -l workspace/fitimage/fitImage
```

Just the configuration names `boot.cmd` can select with `#<name>`:

```bash
mkimage -l workspace/fitimage/fitImage | grep -E '^ Configuration'
```

Installed module trees, and whether each has a `modules.dep`:

```bash
for d in workspace/kernel-modules/usr/lib/modules/*/; do
  echo "$d -> $([ -s "$d/modules.dep" ] && wc -l < "$d/modules.dep" || echo NO-DEP)"
done
```

More than one line here means a stale tree is present.

Initramfs contents, excluding the busybox applet symlinks:

```bash
zcat workspace/fitimage/uInitramfs.cpio.gz | cpio -t 2>/dev/null | grep -vE '^bin/|^sbin/|^usr/'
```

Out-of-tree modules actually built:

```bash
find workspace/ext-modules -name '*.ko'
```

Pinned revisions the build is using:

```bash
grep -E '^(CMEM_SRCREV|QOS_SRCREV|GLES_SHA256|TFA_SRCREV|BUSYBOX_SHA256|PCIE_FW_SHA256)=' \
    local-build-scripts/config.ini
```

## Gotchas

- **`workspace/` and `linux-sh/` are gitignored**, so `git status` says nothing
  about build state. This skill is the only view.
- **`workspace/fitimage/Image` is a copy**, staged by the fitimage target. It
  is not the build output — `linux-sh/arch/arm64/boot/Image` is. A mismatch
  between them is exactly the stale-fitImage case.
- **mtime is not provenance.** A file can be newer than the source it was built
  from if a target was re-run without changes.
