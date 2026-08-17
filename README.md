# rv — reversible shell actions

Undo for the thing Claude Code's checkpointing explicitly doesn't cover: **files changed by shell commands.**
Snapshots the git worktree as a content-addressed tree before/after each action, journals it, restores byte-exactly. Stdlib Python, git as the store. See [SPEC.md](SPEC.md).

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
    "PreToolUse":  [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "/Users/tonyjagodka/reversible/rv hook-pre" }] }],
    "PostToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "/Users/tonyjagodka/reversible/rv hook-post" }] }]
  }
}
```

The hooks are silent, ~0.2 s per Bash call, no-op outside a git repo, and never fail the tool call (errors go to `~/.rv-hook-errors.log`). Journal + private index live in `.git/rv/`; snapshot trees are pinned under `refs/rv/trees/` (delete that namespace to reclaim space).

## Limits (stated in every record, not hidden)
gitignored files · anything outside the worktree · processes/network · `HEAD`/ref moves (flagged, compensator hinted, not auto-reversed).
