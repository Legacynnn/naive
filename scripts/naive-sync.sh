#!/usr/bin/env bash
# Merges zeronsh/zeron's main into the current branch, renamed to Naive.
# Branch naive/upstream holds renamed snapshots of upstream; merging it keeps
# the base renamed too, so only upstream's own changes show up.
#
#   scripts/naive-sync.sh            # fetch, snapshot, merge
#   scripts/naive-sync.sh <ref>      # sync to an upstream ref instead of main
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
VENDOR=naive/upstream
REF="${1:-main}"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "naive-sync: commit or stash your changes first" >&2
  exit 1
fi
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/zeronsh/zeron.git
git fetch upstream "$REF"
TARGET="$(git rev-parse FETCH_HEAD)"

WT="$(mktemp -d)/wt"
trap 'git worktree remove --force "$WT" 2>/dev/null || true' EXIT

snapshot() {
  git worktree add -q --detach "$WT" "$1"
  (
    cd "$WT"
    python3 "$ROOT/scripts/naive-rename.py"
    cargo metadata --format-version 1 >/dev/null
    (cd apps/zgx && cargo metadata --format-version 1 >/dev/null)
    git add -u
    git write-tree
  )
  git worktree remove --force "$WT"
}

if ! git rev-parse -q --verify "refs/heads/$VENDOR" >/dev/null; then
  BASE="$(git merge-base HEAD "$TARGET")"
  echo "naive-sync: seeding $VENDOR from upstream ${BASE:0:10}" >&2
  SEED="$(git commit-tree "$(snapshot "$BASE")" -m "upstream: zeronsh/zeron@${BASE:0:10}, renamed to naive")"
  git branch "$VENDOR" "$SEED"
  git merge -s ours --no-edit -m "naive-sync: $VENDOR seeded at upstream ${BASE:0:10}" "$SEED"
fi

PREV="$(git rev-parse "$VENDOR")"
TREE="$(snapshot "$TARGET")"
if [[ "$TREE" == "$(git rev-parse "$PREV^{tree}")" ]]; then
  echo "naive-sync: already at upstream ${TARGET:0:10}" >&2
else
  NEXT="$(git commit-tree "$TREE" -p "$PREV" -m "upstream: zeronsh/zeron@${TARGET:0:10}, renamed to naive")"
  git update-ref "refs/heads/$VENDOR" "$NEXT" "$PREV"
fi

SWIFT=apps/ios/Naive/Core/Generated/naive_core.swift
if ! git merge --no-edit -m "naive-sync: merge upstream ${TARGET:0:10}" "$VENDOR"; then
  echo "naive-sync: resolve the conflicts and commit; if $SWIFT conflicts, take either side then run scripts/naive-bindings.sh" >&2
  exit 1
fi
if ! git diff --quiet "$PREV" "$VENDOR" -- crates/mobile "$SWIFT"; then
  echo "naive-sync: mobile FFI changed, regenerate bindings: scripts/naive-bindings.sh" >&2
fi
