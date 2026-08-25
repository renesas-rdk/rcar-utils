---
mode: agent
description: Verify R-Car V4H Sparrow Hawk build artifacts without a board.
---

Check the current build is internally consistent and would boot.

Context: [AGENTS.md](../../AGENTS.md). Deep guide:
[rcar-verify-build](../../.claude/skills/rcar-verify-build/SKILL.md).

Run:

```bash
./scripts/rcar-driver.sh verify
```

Then report, per failing check, what it means and the fixing command. The
common ones:

- `fitImage kernel is STALE` → `./scripts/rcar-driver.sh build fitimage image`
- `modules.dep missing or empty` → install `kmod`, then
  `./scripts/rcar-driver.sh build kernel modules-install`
- `does NOT apply: <name>.dtbo` → the overlay's target node is gone from the
  base DTB
- `stale module tree: <ver>` → build output from an older kernel; it prints the
  `rm -rf`, but **ask the user before deleting anything under `workspace/`**

Do not "fix" a failure by passing a skip flag. Exit 0 means every check passed.
