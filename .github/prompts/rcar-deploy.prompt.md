---
mode: agent
description: Deploy a built kernel to a running Sparrow Hawk board over ssh, then verify it rebooted onto it.
---

Deploy the current build to a real board.

Context: [AGENTS.md](../../AGENTS.md). Deep guide:
[rcar-deploy-image](../../.claude/skills/rcar-deploy-image/SKILL.md).

**This is destructive and outward-facing**: it overwrites `/boot` and
`/usr/lib/modules` on the board and reboots it. Before doing anything:

1. Ask the user for the board IP/hostname, ssh user (stock default `ubuntu`),
   password (stock default `ubuntu`) and port (default 22). Confirm the
   defaults rather than assuming them.
2. Confirm explicitly which board is about to be rebooted.
3. Rehearse first:
   `./scripts/rcar-deploy.sh --host <ip> --dry-run`
4. Then the real run:
   `./scripts/rcar-deploy.sh --host <ip>`

Pass the password via the `RCAR_DEPLOY_PASSWORD` environment variable or let
the script prompt — `--password` is visible in `ps` to every user on the host.

The script gates itself: it refuses to deploy when
`./scripts/rcar-driver.sh verify` fails, backs up `/boot/fitImage` and the
module tree before overwriting, and checksums the transferred fitImage **before**
rebooting. Do not pass `--skip-verify` to get past a failing build.

If the board does not come back, report the backup path the script printed —
restoring `/boot/fitImage` over serial is the fastest recovery.
