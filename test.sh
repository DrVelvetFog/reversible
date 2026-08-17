#!/usr/bin/env bash
# Smoke test: rv reverses shell-command file effects byte-exactly, honors conflicts,
# and journals undo as its own reversible action.
set -euo pipefail
RV="$(cd "$(dirname "$0")" && pwd)/rv"
T=$(mktemp -d); cd "$T"
git init -q .; git config user.email t@t; git config user.name t
printf 'alpha\n' > a.txt; printf 'bravo\n' > b.txt; printf 'echo\n' > e.txt
mkdir -p keep; printf 'k\n' > keep/k.txt
printf 'ignored\n' > scratch.log; echo 'scratch.log' > .gitignore
git add -A && git commit -qm base
printf 'untracked\n' > u.txt              # untracked file, must be covered too

pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }

echo "1. shell action via hook adapter (simulated Claude Code hook JSON)"
PRE=$("$RV" snap)
CMD='rm a.txt; mv b.txt c.txt; echo new > d/dd/new.txt 2>/dev/null || (mkdir -p d/dd && echo new > d/dd/new.txt); echo more >> e.txt; rm u.txt; rm -r keep'
HOOK=$(printf '{"tool_name":"Bash","session_id":"s1","tool_use_id":"tu1","cwd":"%s","tool_input":{"command":%s}}' "$T" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$CMD")")
echo "$HOOK" | "$RV" hook-pre
bash -c "$CMD"
echo "$HOOK" | "$RV" hook-post
[ -f a.txt ] && no "rm happened" || ok "action really removed a.txt"
"$RV" log | grep -q '#1 .*\* .*shell' && ok "journaled as #1 changed" || no "journal"

echo "2. show == dry-run preview"
"$RV" show 1 | tee /tmp/rv-show.txt >/dev/null
grep -q '^  D a.txt' /tmp/rv-show.txt && grep -q '^  A c.txt' /tmp/rv-show.txt \
  && grep -q '^  M e.txt' /tmp/rv-show.txt && grep -q '^  D u.txt' /tmp/rv-show.txt \
  && grep -q '^  D keep/k.txt' /tmp/rv-show.txt && ok "preview lists A/M/D incl. untracked + nested" || { no "preview"; cat /tmp/rv-show.txt; }

echo "3. undo restores pre tree byte-exactly"
"$RV" undo 1 >/tmp/rv-undo.txt
cat /tmp/rv-undo.txt | sed 's/^/     /'
POST=$("$RV" snap)
[ "$POST" = "$PRE" ] && ok "tree hash identical to pre ($PRE)" || no "tree mismatch $PRE vs $POST"
[ "$(cat a.txt)" = alpha ] && [ ! -e c.txt ] && [ ! -e d ] && [ "$(cat e.txt)" = echo ] \
  && [ -f u.txt ] && [ -f keep/k.txt ] && ok "files/dirs exactly as before" || no "content"
[ -f scratch.log ] && ok "gitignored file untouched (out of scope, honestly)" || no "ignored"

echo "4. undo is journaled and itself reversible (redo)"
"$RV" log | grep -q '#2 .*undo' && ok "undo journaled as #2" || no "undo record"
"$RV" undo 2 >/dev/null
[ ! -f a.txt ] && [ -f c.txt ] && ok "redo (undo of undo) reapplied the action" || no "redo"
"$RV" undo 3 >/dev/null   # back to base for next test
[ "$("$RV" snap)" = "$PRE" ] && ok "back at pre" || no "back at pre"

echo "5. conflict: file edited after the action is skipped without --force"
CMD2='echo v2 > a.txt'
H2=$(printf '{"tool_name":"Bash","tool_use_id":"tu2","cwd":"%s","tool_input":{"command":"%s"}}' "$T" "$CMD2")
echo "$H2" | "$RV" hook-pre; bash -c "$CMD2"; echo "$H2" | "$RV" hook-post
echo v3 > a.txt                             # a human edits afterwards
"$RV" undo 5 | grep -q 'SKIP' && [ "$(cat a.txt)" = v3 ] && ok "conflict skipped, human edit preserved" || no "conflict"
"$RV" undo 5 --force >/dev/null; [ "$(cat a.txt)" = alpha ] && ok "--force restores" || no "force"

echo "6. HEAD move is recorded, flagged, and NOT silently restored"
CMD3='git commit -qam bump'
echo v9 > a.txt
H3=$(printf '{"tool_name":"Bash","tool_use_id":"tu3","cwd":"%s","tool_input":{"command":"%s"}}' "$T" "$CMD3")
echo "$H3" | "$RV" hook-pre; bash -c "$CMD3"; echo "$H3" | "$RV" hook-post
"$RV" show 8 | grep -q "HEAD moved" && "$RV" log | grep -q "#8 .* H " && ok "head_moved flagged with compensator hint" || no "head"

echo "7. out-of-scope heuristic"
"$RV" wrap -- 'echo hi >/dev/null && true' 2>/dev/null
"$RV" wrap -- 'git push --dry-run 2>/dev/null || true' 2>/dev/null
"$RV" log | grep '#9 ' | grep -q unknown && "$RV" log | grep '#10 ' | grep -q possible && ok "unknown vs possible" || no "oos"

echo "8. non-Bash hook events are ignored; hook never fails"
echo '{"tool_name":"Edit"}' | "$RV" hook-pre && echo 'garbage' | "$RV" hook-post && ok "quiet no-op" || no "hook robustness"

echo "9. trees pinned against gc"
git gc -q --prune=now
"$RV" undo 1 --dry-run >/dev/null && ok "pre tree survives gc --prune=now" || no "gc pruned snapshot"

echo; echo "pass=$pass fail=$fail  (repo: $T)"
[ $fail -eq 0 ]
