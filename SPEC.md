# Reversible Actions

**Status:** draft `v0` · working name `rv`
**Purpose:** give every agent action a checkpoint, an honest reversibility class, and a defined way to reverse it — so an agent can act freely *and* the operator can always get back.

Companion to [Change-Evidence Binding](../change-evidence/SPEC.md): that spec binds a *change* to the evidence it was reviewed; this one binds an *action* to the evidence of what it did and whether it can be undone. Same primitive (a content-addressed git tree), same discipline (say which fields are recomputed and which are asserted).

---

## 1. The gap this closes

Agent harnesses checkpoint the edits they make through their own file tools. Nothing checkpoints what their *shell commands* do (`rm`, `mv`, `sed -i`, build scripts, migrations), and nothing at all covers effects outside the filesystem. Claude Code's own docs: *"Checkpointing does not track files modified by bash commands."*

On the standards side, MCP tool annotations describe an action (`readOnlyHint`, `destructiveHint`, `idempotentHint`) and a live proposal (SEP-1984) adds a `reversibleHint` boolean. The objection that stalled it is the right one: **a hint without a defined client behavior is not interoperable.** "Reversible" is not a property a tool can assert about itself; it is a claim about *pre-state capture* and *a restore procedure*, and both are things a client can check.

The consequence for agents is behavioral, not cosmetic. When actions are one-way, a careful agent hedges, asks, or under-acts. When actions are cheap to reverse, it can proceed — and the operator is safer, not less safe.

## 2. Terminology

| Term | Meaning |
|---|---|
| **action** | One side-effecting operation: a shell command, a tool call, an HTTP request. |
| **scope** | The state an action's checkpoint actually covers (e.g. one git worktree, honoring `.gitignore`). |
| **pre / post** | Content hashes of the scope immediately before / after the action. |
| **tier** | The action's reversibility class: `S` snapshot-restorable, `C` compensable, `N` not reversible. |
| **compensator** | A second action that offsets the first when no snapshot restore exists (`DELETE` after `POST`; recall after send). |
| **record** | The journal entry binding one action to its pre/post state, tier, and coverage. |

## 3. Design rules

**R1 — Reversibility is a claim about capture, not a hint about the tool.** A record MAY say `tier: S` only if it holds a `pre` hash the client captured. A record MAY say `tier: C` only if it names a concrete compensator. Everything else is `N`. A tool's self-description (`reversibleHint`) MAY inform the *expected* tier; it MUST NOT be recorded as the *achieved* tier.

**R2 — Bind to content, never to a name.** `pre` and `post` are content hashes of the scope (git tree objects in the reference implementation), never timestamps, commit IDs or paths. Restore is "make the scope's content equal `pre` for the paths this action touched," which is checkable.

**R3 — Coverage is stated, never implied.** A record MUST name its `scope`, and MUST mark effects outside it as `unknown` or `possible` — never `none`. A shell snapshot cannot know whether `curl` was in the command; it can say the command *matched* a network pattern. The honest default is *unknown*.

**R4 — Undo touches only what the action touched.** Restore is computed from `diff(pre, post)`, applied per path, and refuses any path whose current content no longer equals `post` (someone edited since). Whole-scope rollback is a different, blunter operation and MUST NOT be what "undo" means by default.

**R5 — Undo is an action.** It is journaled with its own `pre`/`post`, so it is itself reversible (redo) and the ledger stays append-only. There is no privileged "restore" that escapes the record.

**R6 — Separate what is recomputed from what is asserted.** `pre`, `post`, `changed`, and the diff are recomputed. `out_of_scope_effects`, `tier` expectations from tool hints, and compensator success are asserted. The record marks which is which. (Inherited from Change-Evidence R5.)

## 4. Tiers and REQUIRED client behavior

This is the table SEP-1984 lacks. A client that adopts the vocabulary adopts the behavior.

| Tier | Meaning | Before the action | After the action |
|---|---|---|---|
| **S** snapshot | Pre-state of `scope` captured as a content hash; restore procedure exists | MAY proceed without confirmation for in-scope effects | MUST journal `pre`/`post`; MUST offer per-path undo with conflict check |
| **C** compensable | No snapshot possible; a compensator is known (`DELETE /things/{id}`, `git push --force-with-lease <prev>`, message recall within window) | SHOULD offer `dry_run` where the tool supports it; MAY require confirmation | MUST journal the compensator *with the arguments it needs* (ids returned by the action); undo runs it and journals its result as asserted |
| **N** not reversible | Money moved, email delivered, message published, data destroyed outside any snapshot | MUST require explicit confirmation or a dry-run first; MUST NOT be auto-approved by any hint | MUST journal as `N` with a reason; there is no undo, and the record says so |

An action can be `S` for its in-scope effects and `possible`-out-of-scope at once (`git commit` is `S` for the worktree and moves `HEAD`, which is journaled and offered a compensator, not silently reversed). Records carry both facts rather than collapsing them into one boolean.

## 5. The record

```jsonc
{
  "schema": "reversible/v0",
  "seq": 12,                              // append-only ordinal within the journal
  "ts": "2026-08-17T14:02:05Z",
  "actor": { "tool": "Bash", "adapter": "claude-code-hook", "session": "…" },
  "action": { "kind": "shell", "command": "rm a.txt; mv b.txt c.txt" },
  "scope": { "kind": "git-worktree", "root": "/repo", "excludes": "gitignore" },
  "pre":  { "tree": "git-sha1:…", "head": "…", "captured": true },   // RECOMPUTED
  "post": { "tree": "git-sha1:…", "head": "…" },                     // RECOMPUTED
  "changed": true,                                                    // RECOMPUTED (pre != post)
  "head_moved": false,                                                // RECOMPUTED
  "reversibility": {
    "tier": "S",
    "method": "tree-restore",
    "coverage": "scope-only",
    "out_of_scope_effects": "unknown" | "possible",                   // ASSERTED (heuristic)
    "compensator": { "kind": "shell", "command": "…" }                // tier C only
  }
}
```

An `undo` record has `"action": {"kind": "undo", "of": 12, "skipped": [...]}` and its own `pre`/`post`.

## 6. Verification

Anyone with the repository and the journal, offline, can recompute:

1. `pre` and `post` resolve to tree objects in the repository (they are pinned under `refs/rv/`).
2. `changed == (pre != post)`.
3. `diff-tree(pre, post)` is exactly the set of paths an undo would touch — the preview *is* the dry-run.
4. For an undo record `u` of action `a`: `u.post == a.pre` iff nothing was skipped and nothing was out of scope. The reference implementation prints `pre tree REACHED` / `not reached` from exactly this comparison.

## 7. What v0 implements, measured

- Scope: one git worktree, tracked + untracked, `.gitignore` honored. Snapshot = `git add -A` into a private index + `git write-tree`; trees pinned as `refs/rv/trees/<hash>` so `gc --prune=now` cannot remove them (tested).
- Adapters: Claude Code `PreToolUse`/`PostToolUse` hooks on `Bash`; `rv wrap -- <cmd>` for any shell.
- Cost: cold 0.27 s / warm 0.10 s per snapshot on a 2,786-file repo (Git 2.50.1, M1); ~0.2 s per Bash call. The private index leaves `git status` untouched.
- Restore: per-path, conflict-checked, exec bits preserved via `checkout-index`, created directories pruned. Byte-exact (`post == pre` after undo) across `rm`, `mv`, create-in-new-dir, append, untracked delete, recursive delete — 15/15 in `test.sh`.
- Not covered, and the record says so: gitignored files, effects outside the worktree, processes, network, `HEAD`/ref moves (flagged with a compensator hint, not auto-reversed).

## 8. Non-goals

- Not a replacement for git history or for the harness's own file-tool checkpoints; it fills the hole between them.
- Not per-API knowledge. The spec defines the compensator *slot*; a Stripe or Gmail adapter fills it. v0 ships no tier-C adapters.
- Not enforcement. Like MCP annotations, the record can be lied to by a tool; unlike a hint, the parts that matter (`pre`, `post`, the diff) are recomputable, so a lie is detectable.

## 9. Relationship to evidence tiers (next spec)

Every field above already carries a "how do we know this" label — recomputed vs asserted, `captured: true`, `out_of_scope_effects: unknown`. That labeling, lifted out of this record and made portable across any agent output, is the next spec.
