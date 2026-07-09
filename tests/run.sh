#!/usr/bin/env sh
# Smoke test: build a disposable bare-repo-with-worktrees fixture (orca's
# layout — trunk is the bare repo's symbolic HEAD, the branch under review
# lives in a worktree), then run tests/smoke.lua in headless nvim from
# inside that worktree.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- seed repo: main with an init commit, feature branched off it,
#     main advanced afterwards so the merge-base diff has something to exclude.
SEED="$TMP/seed"
git init -q -b main "$SEED"
git -C "$SEED" config user.name t
git -C "$SEED" config user.email t@t

printf 'one\n' > "$SEED/a.txt"
printf 'P1\000\t\bbinary1\n' > "$SEED/img.bin"
printf 'keepme\n' > "$SEED/renamed-from.txt"
mkdir "$SEED/src"
printf 'line1\nline2\nline3\n' > "$SEED/src/b.lua"
git -C "$SEED" add -A
git -C "$SEED" commit -qm init
git -C "$SEED" branch feature

printf 'x\n' > "$SEED/trunk-only.txt"
git -C "$SEED" add trunk-only.txt
git -C "$SEED" commit -qm trunk-advance

git -C "$SEED" checkout -q feature
git -C "$SEED" rm -q a.txt
printf 'new file\n' > "$SEED/c.txt"
printf 'P1\000\t\bbinary2\n' > "$SEED/img.bin"
git -C "$SEED" mv renamed-from.txt renamed-to.txt
printf 'line1\nline2 CHANGED\nline3\nline4\n' > "$SEED/src/b.lua"
git -C "$SEED" add -A
git -C "$SEED" commit -qm change

# --- fixture: bare repo + .git pointer file + feature worktree
FIX="$TMP/fixture"
mkdir "$FIX"
git clone -q --bare "$SEED" "$FIX/.bare"
printf 'gitdir: ./.bare\n' > "$FIX/.git"
git --git-dir="$FIX/.bare" symbolic-ref HEAD refs/heads/main
git -C "$FIX" worktree add -q feature feature

# --- run the smoke test from inside the worktree
cd "$FIX/feature"
OUT=$(nvim --clean --headless --cmd "set rtp+=$ROOT" \
  "+luafile $ROOT/tests/smoke.lua" +qa! 2>&1) || {
  printf '%s\n' "$OUT"
  exit 1
}
printf '%s\n' "$OUT"
case "$OUT" in
  *"SMOKE PASS"*) exit 0 ;;
  *) echo 'smoke.lua did not report SMOKE PASS' >&2; exit 1 ;;
esac
