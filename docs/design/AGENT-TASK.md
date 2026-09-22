# Task: implement phase-aware skill capabilities in `claude-container`

You are working in the `claude-container` repo (this checkout), on branch
`skill-capabilities`, freshly branched from `origin/main` (9c41de6).

## What to do

Implement the proposal in **`docs/design/claude-container-skill-capabilities.md`**.
Read it in full first — it is self-contained and written for exactly this task.

Work the phases in **§8 Suggested implementation phases**, in order:

1. Manifest (`skill.json`) + IMAGE fragment folding + RUNTIME `overlay.json` merge
2. BOOT `startup.d` ordered drop-ins
3. Preflight (`requires`) + adopt/accept consent & privilege diff
4. HOST SERVICES primitive, with `host-deploy` as the first consumer

Each phase in §8 states its own *Acceptance* criterion — treat those as the
definition of done and verify against them.

**Phase 5 is out of scope here.** It migrates `flash_server.py` /
`ios_build_server.py` and `tools/iosctl`, which live in a different repo
(`led_mapper`), not this one. Stop after phase 4 and note what phase 5 would need
from the primitive you build.

## Reference material

`docs/design/reference-skills/` holds read-only copies of the three skills the
design generalizes from (copied in from `led_mapper`'s
`.claude-container-overlay/skills/`) — they are the concrete inputs for phases 1–4:

- `tailnet/` — `SKILL.md`, `Dockerfile.snippet`, `tailnet-up.sh`
- `host-deploy/` — `SKILL.md`, `hostdeploy.py`, `hostrun.sh`
- `bazel-polyglot-nix/` — already ships an `overlay.Dockerfile` fragment under
  the *current* mechanism; it is the working example of what §5.1 must generalize.

Preserve the gotchas §9 calls out — notably `--accept-dns=false` on
`tailscale up`, and `hostdeploy.py`'s un-wedgeable properties (stdin `/dev/null`,
wall-clock timeout, process-group kill, id-matched cancel, liveness heartbeat,
`argv[0]` allowlist).

## Constraints

- The launcher is `bin/` in this repo; `~/.local/bin/claude-container` is an
  installed copy — do not edit the installed copy, edit the repo and let
  `install.sh` handle deployment.
- Keep backward compatibility per §7: a skill with no `skill.json` must behave
  exactly as today, and every capability skill keeps its "wire it by hand"
  section.
- There is a `tests/` directory — extend it, and run it before you call a phase
  done.
- Commit per phase with a clear message. Do not push or open a PR without asking.

## When you finish

Summarise what landed per phase, what you verified against each Acceptance
criterion, and anything in the design you deviated from and why.
