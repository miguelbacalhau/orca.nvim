#!/usr/bin/env sh
# Smoke test: build a disposable bare-repo-with-worktrees fixture (orca's
# layout — trunk is the bare repo's symbolic HEAD, the branch under review
# lives in a worktree), then run each of tests/cases/*.lua in its own
# headless nvim from inside a fresh copy of it. `sh tests/run.sh notes cd`
# runs just those cases.
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
# a name outside ASCII, which git C-quotes unless asked not to
printf 'ol\303\241\n' > "$SEED/src/$(printf 'caf\303\251')".lua
# two files the default `tests` group claims — one by file name, one by
# directory. Both sort after every visible file, so panel rows and entry
# indices still coincide for the six files the panel shows.
printf 'unit one\nunit two\n' > "$SEED/src/z_test.lua"
mkdir "$SEED/tests"
printf 'spec one\nspec two\n' > "$SEED/tests/b_spec.lua"
git -C "$SEED" add -A
git -C "$SEED" commit -qm change
# a second branch off main, with a change of its own, checked out nowhere
git -C "$SEED" checkout -q -b other main
printf 'other\n' > "$SEED/other.txt"
git -C "$SEED" add other.txt
git -C "$SEED" commit -qm other
git -C "$SEED" checkout -q main # so clones of seed get origin/HEAD = main

# --- fixture: bare repo + .git pointer file + feature worktree, orca-managed
# (.orca/ at the fixture root — the parent of the common git dir, where the
# plugin must discover it from inside the worktree). Each case gets a fresh
# one, so nothing a case leaves behind can reach the next.
fixture() {
  FIX="$TMP/$1"
  mkdir "$FIX"
  git clone -q --bare "$SEED" "$FIX/.bare"
  printf 'gitdir: ./.bare\n' > "$FIX/.git"
  git --git-dir="$FIX/.bare" symbolic-ref HEAD refs/heads/main
  git -C "$FIX" worktree add -q feature feature
  mkdir "$FIX/.orca"
}

# --- the smoke cases: tests/cases/*.lua, or the ones named on the command
# line, each in its own headless nvim from inside its fixture's worktree.
# A case prints OK/FAIL per check and CASE PASS when all of them held; its
# output is shown only when it failed.
if [ $# -gt 0 ]; then
  CASES=$(for n in "$@"; do printf '%s/tests/cases/%s.lua\n' "$ROOT" "$n"; done)
else
  CASES=$(ls "$ROOT"/tests/cases/*.lua)
fi
FAILED=0
for CASE in $CASES; do
  NAME=$(basename "$CASE" .lua)
  fixture "case-$NAME"
  OUT=$(cd "$TMP/case-$NAME/feature" && nvim --clean --headless -n --cmd "set rtp+=$ROOT" \
    --cmd "lua package.path = '$ROOT/tests/?.lua;' .. package.path" \
    "+luafile $CASE" +qa! 2>&1) || true
  case "$OUT" in
    *"CASE PASS"*) echo "PASS $NAME ($(printf '%s\n' "$OUT" | grep -o 'OK   ' | wc -l | tr -d ' ') checks)" ;;
    *)
      FAILED=$((FAILED + 1))
      echo "FAIL $NAME"
      printf '%s\n' "$OUT" | sed 's/^/     /'
      ;;
  esac
done
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED case(s) failed" >&2
  exit 1
fi
[ $# -gt 0 ] && exit 0

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
  "+lua local p = require('orca.panel'); local w = p.win(); print(('NORMAL %s %d'):format(vim.api.nvim_get_option_value('statusline', { win = w }), vim.api.nvim_buf_line_count(p.buf())))" \
  +qa! 2>&1)
case "$NOUT" in
  *"NORMAL OrcaReview main...HEAD 7"*) echo 'OK   normal checkout: bare review defaults to main...HEAD' ;;
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
