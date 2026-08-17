#!/usr/bin/env bash
# rv quickstart — the README usage block, runnable. Output is deterministic (no timestamps/paths).
set -euo pipefail
RV="$(cd "$(dirname "$0")/.." && pwd)/rv"
T=$(mktemp -d); cd "$T"; git init -q; git config user.email x@x; git config user.name x
echo hello > a.txt; git add -A; git commit -qm init
"$RV" wrap -- 'rm a.txt; echo bye > b.txt' 2>/dev/null
echo "after action: a.txt exists? $([ -e a.txt ] && echo yes || echo no), b.txt exists? $([ -e b.txt ] && echo yes || echo no)"
"$RV" show 1 | grep -E '^  [AMD] '
"$RV" undo 1 | tail -1 | sed 's/pre tree.*/pre tree REACHED/'
echo "after undo:   a.txt=$(cat a.txt), b.txt exists? $([ -e b.txt ] && echo yes || echo no)"
