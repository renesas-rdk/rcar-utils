---
name: rcar-deploy-image
description: Deploy a freshly built R-Car V4H Sparrow Hawk kernel to a running board over ssh — ask for the board IP/user/password, verify the build, back up what is on the board, rsync the fitImage/modules/firmware, reboot, and verify the board came back on the new kernel. Use when a build is finished and needs to reach hardware. Do NOT use to build artifacts or to edit boot.cmd.
license: "Apache-2.0"
metadata:
  data-classification: public
  tags: [rcar, sparrow-hawk, deploy, rsync, phase-3]
  domain: deploy
---

# Deploy to a running board

## Purpose

One command takes a verified local build to a live board and proves it booted:
`scripts/rcar-deploy.sh`.

It verifies → connects → backs up → transfers → `depmod` → checksums → reboots
→ waits → verifies what actually came up. Every step is a gate: nothing is
copied before the build verifies, nothing is overwritten before it is backed
up, and the reboot only fires once the transfer checksums match.

Shared facts: `AGENTS.md` at the repo root.

## Ask the user first

The script needs a board to talk to. Ask for, in one go:

| Field | Default | Notes |
|---|---|---|
| Board IP / hostname | — | required |
| SSH user | `ubuntu` | stock image default |
| Password | `ubuntu` | stock image default |
| SSH port | `22` | rarely changed |

Confirm the defaults rather than assuming them — a board that has been through
`ubuntu_installer` may have had its password changed.

**This is a destructive, outward-facing action**: it overwrites `/boot` and
`/usr/lib/modules` on the board and reboots it. Confirm with the user before
the first non-dry run, and state which board is about to be rebooted. A backup
is taken automatically, but a board that fails to boot needs serial console
access to recover.

## Run

```bash
./scripts/rcar-deploy.sh --host <ip>
```

Prompts for the password. Prefer this, or the env var, over `--password` —
an argument is visible in `ps` to every user on the host:

```bash
RCAR_DEPLOY_PASSWORD=ubuntu ./scripts/rcar-deploy.sh \
    --host 192.168.1.50 --user ubuntu
```

Rehearse without writing anything:

```bash
./scripts/rcar-deploy.sh --host 192.168.1.50 --dry-run
```

Options:

| Flag | Effect |
|---|---|
| `--host <ip>` | required |
| `--user <name>` | default `ubuntu` |
| `--password <pw>` | else `$RCAR_DEPLOY_PASSWORD`, else prompt |
| `--port <n>` | default 22 |
| `--dry-run` | connect and report, write nothing |
| `--no-reboot` | transfer + depmod, leave the board on the old kernel |
| `--no-backup` | skip the backup — not advised |
| `--skip-verify` | deploy despite a failing `rcar-driver.sh verify` |
| `--reboot-wait <s>` | how long to wait for the board, default 180 |
| `--prefix <path>` | install under a prefix instead of `/` (staging/testing) |

## Deploying a kernel variant (PREEMPT_RT)

`rcar-deploy.sh` reads `WORKSPACE_DIR` too, so the RT kernel deploys the same
way - export it, and the script picks up that fitImage and that module tree:

```bash
export WORKSPACE_DIR=$PWD/workspace-preempt-rt
./scripts/rcar-deploy.sh --host <board-ip> --dry-run
./scripts/rcar-deploy.sh --host <board-ip>
```

The module trees are keyed by `uname -r`, so the RT modules land beside the
stock ones and neither is lost. `/boot/fitImage` is single, though: deploying
either variant replaces the kernel the board boots. Say which variant you are
about to push when you ask the user - "deploy to 192.168.1.50" and "replace the
board's kernel with the real-time one" are not the same sentence.

**Build the variant you intend to deploy immediately before deploying it.**
The release string comes from the kernel tree
(`linux-sh/include/config/kernel.release`), not from the workspace, and it is
what selects the module tree to send. The two variants take turns in that one
tree, so a stale tree means deploying the wrong kernel's modules - or nothing,
because the script dies with `no module tree for <release>`. `verify` fails in
that situation too, and the script refuses to run on a failed verify.

Switching a board between the stock and RT kernels is just deploying the other
one: the fitImage is replaced, and because the module trees are keyed by
`uname -r` the previous kernel's modules stay where they are. To go back, build
the other variant and deploy again.

## What it does, in order

| # | Step | Gate |
|---|---|---|
| 1 | Read `kernel.release`, run `rcar-driver.sh verify` | **aborts** unless verify passes |
| 2 | ssh in, report the running kernel, confirm sudo | aborts if unreachable or no root |
| 3 | Back up `/boot/fitImage` + the `$REL` module tree to `/var/backups/rcar-deploy/<stamp>/` | aborts if backup fails |
| 4 | rsync into `~/.rcar-deploy-staging`, then install as root | aborts on transfer failure |
| 5 | `depmod $REL` natively on the board | aborts if depmod fails |
| 6 | sha256 the deployed fitImage against the local one | **aborts before reboot** on mismatch |
| 7 | Reboot, wait for the port to drop then return | aborts if it does not return |
| 8 | Verify `uname -r`, `modules.dep`, firmware, tree count | reports pass/fail |

In the normal rebooting flow, exit 0 only when step 8 is clean. `--dry-run` and
`--no-reboot` intentionally exit successfully at their earlier stopping point.

**Step 8 proves the board came back, not that the hardware works.** It checks
`uname -r`, `modules.dep`, firmware and tree count — it never looks at the
running device tree. After a device tree or overlay change, follow with
`rcar-verify-hardware`.

## Why staging instead of rsync straight to /boot

`--rsync-path="sudo rsync"` does **not** work with a password sudo: rsync's
stdin *is* the protocol stream, so there is nowhere to feed the password
without corrupting it. The script rsyncs into the login user's home — no
privilege needed — then does one privileged local copy. That also shrinks the
window where system files are half-updated to a single `cp`.

## Recovery

The backup path is printed twice — after the backup and again if anything
fails:

```
restore: sudo cp /var/backups/rcar-deploy/<stamp>/fitImage /boot/fitImage && sudo reboot
```

The module tree is kept beside it as `modules-<release>.tar.gz`, and
`previous-kernel-release` records what the board was running.

If the board does not come back, `/boot/fitImage` is the only file that decides
whether it boots — restoring it over serial/U-Boot is the fastest recovery.

## Requirements

**Host:** `sshpass`, `rsync`, `ssh` (`sudo apt-get install -y sshpass rsync`).

**Board:**

- Reachable over ssh, user is a sudoer.
- **usrmerged rootfs (`/lib` → `/usr/lib`).** Modules install to
  `/usr/lib/modules/<release>/`, and `depmod` searches `/lib/modules`. Without
  the symlink `depmod` reports `could not open directory
  /lib/modules/<release>` and the deploy aborts at step 5.
- Enough free space in the login user's home for the staging copy (~35 MB: fitImage plus the module tree and firmware).

## Gotchas

- **Host key checking is disabled** (`StrictHostKeyChecking=no`,
  `UserKnownHostsFile=/dev/null`). A reflashed board changes its host key, so
  checking would only ever produce a false alarm. This is a lab-network tool —
  do not point it across an untrusted network.
- **Only the `$REL` module tree is sent.** Syncing the `modules/` parent would
  ship every stale release the workspace accumulated. The board's own stale
  trees are reported at step 8 but never deleted.
- **The module tree is merged, never replaced.** When the board already runs
  this release, deleting the directory first would pull modules out from under
  the running kernel.
- **`fitImage` lands as a temp file and is renamed**, so an interrupted write
  cannot leave an unbootable stub. Never change this to an in-place write.
- **Step 6 is the last safe abort point.** After the reboot the board is
  committed to whatever is in `/boot/fitImage`.
- **`uname -r` mismatch at step 8** usually means U-Boot loaded a fitImage from
  a different partition or path — the contract is partition 1, `/boot/fitImage`.
- **Root login:** `--user root` skips the sudo wrapper automatically.

## Boot contract

Required board-side U-Boot contract:

```
load mmc 0:1  ${loadaddr} /boot/fitImage && source ${loadaddr}:script
load nvme 0:1 ${loadaddr} /boot/fitImage && source ${loadaddr}:script
load usb 0:1  ${loadaddr} /boot/fitImage && source ${loadaddr}:script
```

Always **partition 1**, always `/boot/fitImage`, then the embedded boot script
runs (`rcar-customize-boot`).

On-target layout the script maintains:

```
/boot/                     fitImage (the only file U-Boot reads), *.dtb, *.dtbo
/usr/lib/modules/<rel>/     modules + modules.dep
/usr/lib/firmware/          rcar_gen4_pcie.bin, LICENCE, rgx.fw.*, rgx.sh.*
/usr/lib/modules-load.d/    cmemdrv, pvrsrvkm, uio_pdrv_genirq .conf
/usr/lib/modprobe.d/        cmemdrv, uio_pdrv_genirq .conf
```

`<rel>` is whatever the build produced — never assume it:

```bash
cat linux-sh/include/config/kernel.release
```

The `.d` files are not optional: `uio_pdrv_genirq` has a single OF match entry
filled in only from a module parameter, so without
`options uio_pdrv_genirq of_id="generic-uio"` no `generic-uio` node binds.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `rcar-driver.sh verify FAILED - not deploying` | Local build inconsistent | Fix it — see `rcar-verify-build`. `--skip-verify` only if you know why |
| `cannot ssh to ...` | Wrong IP/port/credentials | Check the board is up and the password is right |
| `no root on the board` | User is not a sudoer, or wrong password | Use a sudo-capable account |
| `depmod: could not open directory /lib/modules/...` | Rootfs not usrmerged | `sudo ln -sfn usr/lib /lib` on the board |
| `fitImage checksum mismatch` | Truncated transfer | Re-run; the script stops **before** rebooting |
| `board did not come back` | Bad kernel/DT, or slow boot | Raise `--reboot-wait`; else restore the backup over serial |
| `running <old>, expected <new>` | U-Boot read a different fitImage | Check the boot medium is partition 1 |
| `N module trees on the board` | Older releases still installed | Remove the unwanted release dir on the board |

## Not covered

Serial console setup, U-Boot recovery, partitioning, and building the Ubuntu
rootfs. Those live in `../ubuntu_installer/` (`QuickStartGuide.md`) — a
separate repo that may not be present if `rcar-utils` was cloned on its own.

## Verified vs not

Written and exercised against a local sshd standing in for a board: argument
handling, verify gate, connect, sudo, backup (including backing up an existing
fitImage on a second run), staged rsync, privileged install, `depmod`,
checksum comparison, staging cleanup, and the down/up wait loop.

Treat the first deployment of a new kernel, boot script, or device-tree change
as supervised: run `--dry-run` first, confirm the backup and checksum stages,
and keep serial recovery available before authorizing the reboot. Never deploy
or reboot merely because this skill was selected; obtain explicit user
confirmation immediately before the mutating command.
