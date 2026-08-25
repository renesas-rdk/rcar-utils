---
mode: agent
description: Build the R-Car V4H Sparrow Hawk kernel and fitImage, then verify the artifacts.
---

Build this repo's target and prove the result is consistent.

Context: [AGENTS.md](../../AGENTS.md). Deep guide:
[rcar-build](../../.claude/skills/rcar-build/SKILL.md).

Steps:

1. Check the host is ready:
   `./scripts/rcar-driver.sh preflight`
   If anything is missing, install it — the output names the fix.
2. Build what the user asked for. Full build from clean is:
   `./scripts/rcar-driver.sh build fitimage all`
   For an incremental kernel change:
   `./scripts/rcar-driver.sh build kernel modules` then
   `./scripts/rcar-driver.sh build fitimage image`
3. **Always finish with** `./scripts/rcar-driver.sh verify` and report the
   result. A build exiting 0 is not evidence: a stale fitImage, a missing
   `modules.dep` and a broken `.dtbo` all exit 0.

Never call `local-build-scripts/main_build.sh` directly — it only works with
cwd set to that directory and silently runs with an empty `PLATFORM` otherwise.

Report the actual command output. If verify fails, show which checks failed and
what the fix is; do not describe the build as successful.
