# rv — reversible shell actions

Undo for the thing Claude Code's checkpointing explicitly doesn't cover: **files changed by shell commands.**
Snapshots the git worktree as a content-addressed tree before/after each action, journals it, restores byte-exactly. Stdlib Python, git as the store. See [SPEC.md](SPEC.md).

![rv restoring files an agent's `rm -rf` deleted](assets/demo.gif)

```bash
./test.sh                     # 15 checks in a throwaway repo
bash examples/quickstart.sh   # verified example (see llms.txt / examples/attest.json)
rv wrap [--actor NAME] -- 'rm -rf build && make'   # any shell; reports `rv: #N changed|no-change root=…` on stderr
rv log                        # #seq  ts  [*changed][H head-moved]  kind  out-of-scope  cmd
rv show 12                    # exactly what undo would do (dry-run)
rv undo 12 [--dry-run] [--force]
```

## Claude Code hooks (opt-in — not installed by default)

Add to `~/.claude/settings.json` (or a project's `.claude/settings.json`):

```json
{
  "hooks": {
    "PreToolUse":  [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "/path/to/reversible/rv hook-pre" }] }],
    "PostToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "/path/to/reversible/rv hook-post" }] }]
  }
}
```

The hooks are silent, ~0.2 s per Bash call, no-op outside a git repo, and never fail the tool call (errors go to `~/.rv-hook-errors.log`). Journal + private index live in `.git/rv/`; snapshot trees are pinned under `refs/rv/trees/` (delete that namespace to reclaim space).

## Limits (stated in every record, not hidden)
gitignored files · anything outside the worktree · processes/network · `HEAD`/ref moves (flagged, compensator hinted, not auto-reversed).

## Part of a stack

rv is the undo layer of a small accountability toolkit for agent work, each piece usable alone:

- **[source-review-coverage](https://github.com/DrVelvetFog/source-review-coverage)** — a one-line [GitHub Action](https://github.com/marketplace/actions/source-review-coverage) emitting signed, recomputable evidence that the code which shipped is the code a human approved. rv runs under it in CI.
- **[ev — evidence tiers](https://github.com/DrVelvetFog/evidence-tier)** — every claim an agent makes labelled ran / read / told / recalled / inferred; "ran" claims resolve against the rv journal.
- **[xv — verified examples](https://github.com/DrVelvetFog/verified-examples)** — documentation examples an agent can check instead of recall; rv's own examples are attested with it.
