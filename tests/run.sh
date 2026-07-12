#!/usr/bin/env sh
# Smoke test: build a disposable bare-repo-with-worktrees fixture (orca's
# layout — trunk is the bare repo's symbolic HEAD, the branch under review
# lives in a worktree), then run tests/smoke.lua in headless nvim from
# inside that worktree.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolate nvim from the caller's state dirs: --clean skips user config but
# still writes swap/state files, which fails in restricted environments
# (E303). Writable XDG dirs inside the fixture plus -n (no swap) below.
export XDG_CONFIG_HOME="$TMP/xdg/config" XDG_DATA_HOME="$TMP/xdg/data" \
  XDG_STATE_HOME="$TMP/xdg/state" XDG_CACHE_HOME="$TMP/xdg/cache"

# --- seed repo: main with an init commit, feature branched off it,
#     main advanced afterwards so the merge-base diff has something to exclude.
SEED="$TMP/seed"
git init -q -b main "$SEED"
git -C "$SEED" config user.name t
git -C "$SEED" config user.email t@t

printf 'one\n' > "$SEED/a.txt"
printf 'P1\000\t\bbinary1\n' > "$SEED/img.bin"
printf 'keepme\n' > "$SEED/renamed-from.txt"
printf 'same\n' > "$SEED/unchanged.txt"
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
git -C "$SEED" checkout -q main # so clones of seed get origin/HEAD = main

# --- fixture: bare repo + .git pointer file + feature worktree, orca-managed
# (.orca/ at the fixture root — the parent of the common git dir, where the
# plugin must discover it from inside the worktree)
FIX="$TMP/fixture"
mkdir "$FIX"
git clone -q --bare "$SEED" "$FIX/.bare"
printf 'gitdir: ./.bare\n' > "$FIX/.git"
git --git-dir="$FIX/.bare" symbolic-ref HEAD refs/heads/main
git -C "$FIX" worktree add -q feature feature
mkdir "$FIX/.orca"

# --- run the smoke test from inside the worktree
cd "$FIX/feature"
OUT=$(nvim --clean --headless -n --cmd "set rtp+=$ROOT" \
  "+luafile $ROOT/tests/smoke.lua" +qa! 2>&1) || {
  printf '%s\n' "$OUT"
  exit 1
}
printf '%s\n' "$OUT"
case "$OUT" in
  *"SMOKE PASS"*) ;;
  *) echo 'smoke.lua did not report SMOKE PASS' >&2; exit 1 ;;
esac

# --- repo without .orca/: the plugin is orca-only and refuses with a
# pointer at /orca:init.
cd "$SEED"
GOUT=$(nvim --clean --headless -n --cmd "set rtp+=$ROOT" \
  "+lua vim.notify = function(m) print('N: ' .. m) end" \
  "+lua require('orca').review('')" +qa! 2>&1)
case "$GOUT" in
  *"no .orca/"*) echo 'OK   non-orca repo refused with /orca:init pointer' ;;
  *) printf '%s\n' "$GOUT"; echo 'non-orca gate failed' >&2; exit 1 ;;
esac

# --- normal (non-worktree) checkout on a feature branch: bare :OrcaReview
# must default to trunk, not the current branch (regression: the common git
# dir's HEAD *is* the current branch here, which made the default review
# empty). The clone's origin/HEAD supplies main.
CLONE="$TMP/clone"
git clone -q "$SEED" "$CLONE"
git -C "$CLONE" checkout -q feature
mkdir "$CLONE/.orca"
cd "$CLONE"
NOUT=$(nvim --clean --headless -n --cmd "set rtp+=$ROOT" \
  "+lua require('orca').review('')" \
  "+lua local q = vim.fn.getqflist({ title = true, size = true }); print(('NORMAL %s %d'):format(q.title, q.size))" \
  +qa! 2>&1)
case "$NOUT" in
  *"NORMAL OrcaReview main...HEAD 5"*) echo 'OK   normal checkout: bare review defaults to main...HEAD' ;;
  *) printf '%s\n' "$NOUT"; echo 'normal-checkout default range failed' >&2; exit 1 ;;
esac

# --- same checkout, remote gone: trunk falls back to a local main.
git -C "$CLONE" remote remove origin
NOUT=$(nvim --clean --headless -n --cmd "set rtp+=$ROOT" \
  "+lua print('TRUNK=' .. tostring(require('orca.git').trunk()))" +qa! 2>&1)
case "$NOUT" in
  *"TRUNK=main"*) echo 'OK   remote-less checkout: trunk falls back to local main' ;;
  *) printf '%s\n' "$NOUT"; echo 'remote-less trunk fallback failed' >&2; exit 1 ;;
esac
