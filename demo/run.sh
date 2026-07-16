#!/usr/bin/env sh
# Manual-testing playground for orca.nvim. Builds a disposable demo repo at
# demo/sandbox/ (a plain checkout on a `feature` branch, .orca/ at the top,
# review notes pre-seeded from a "previous sitting"), then drops you into
# nvim inside it with this working copy of the plugin on the runtimepath.
#
#   demo/run.sh               your own config (colors, LSP, muscle memory)
#   demo/run.sh --clean       isolated nvim, no user config
#   demo/run.sh --build-only  rebuild the sandbox, don't launch nvim
#
# The sandbox is wiped and rebuilt every run — that is the reset button.
# Comment, edit, delete, wander freely; rerun for a pristine playground.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SANDBOX="$ROOT/demo/sandbox"

CLEAN='' BUILD_ONLY=''
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    *) echo "unknown flag: $arg (known: --clean, --build-only)" >&2; exit 2 ;;
  esac
done

rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
git init -q -b main "$SANDBOX"
git -C "$SANDBOX" config user.name orca-demo
git -C "$SANDBOX" config user.email demo@orca.invalid

# --- main: a tiny lua project ---------------------------------------------
cd "$SANDBOX"
mkdir src

cat > README.md <<'EOF'
# wordcount

A toy word counter, here to be reviewed.
EOF

cat > src/wordcount.lua <<'EOF'
-- Count words, lines, and characters in a file.

local M = {}

function M.words(text)
  local n = 0
  for _ in text:gmatch('%S+') do
    n = n + 1
  end
  return n
end

function M.lines(text)
  local n = 0
  for _ in text:gmatch('[^\n]*\n?') do
    n = n + 1
  end
  return n
end

function M.chars(text)
  return #text
end

return M
EOF

cat > src/legacy.lua <<'EOF'
-- Deprecated: the old shell-out implementation.
local M = {}

function M.count(path)
  local pipe = assert(io.popen('wc -w < ' .. path))
  local n = tonumber(pipe:read('*a'))
  pipe:close()
  return n
end

return M
EOF

cat > notes.txt <<'EOF'
wordcount usage
===============

Run the word counter with one or more files as arguments, and it prints
one summary line per file:

  lua wc.lua README.md src/wordcount.lua

Each summary line reports the number of words, the number of lines, and
the number of characters in the file, in that order.

Words are runs of non-whitespace characters. Lines are counted the way
wc(1) counts them, so a trailing newline does not add an empty line.
EOF

printf 'PNG\000\001\002\003old-logo-bytes\n' > logo.png

git add -A
git commit -qm 'initial project'
git branch feature

# --- main advances after the branch point: this change must NOT appear in
# the review (the diff is merge-base, not tip-to-tip).
cat >> README.md <<'EOF'

Trunk moved on after the branch point — if you can read this line in the
review, the merge-base diff is broken.
EOF
git add README.md
git commit -qm 'trunk-only change'

# --- feature: one of every status ------------------------------------------
git checkout -q feature

# M with three separate hunks: header comment, lines() rewrite, new function.
cat > src/wordcount.lua <<'EOF'
-- Count words, lines, characters, and the longest word in a file.

local M = {}

function M.words(text)
  local n = 0
  for _ in text:gmatch('%S+') do
    n = n + 1
  end
  return n
end

function M.lines(text)
  local _, n = text:gsub('\n', '\n')
  if #text > 0 and not text:match('\n$') then
    n = n + 1
  end
  return n
end

function M.chars(text)
  return #text
end

function M.longest(text)
  local best = ''
  for word in text:gmatch('%S+') do
    if #word > #best then best = word end
  end
  return best
end

return M
EOF

# A: a new entry point.
cat > src/cli.lua <<'EOF'
-- Command-line entry point: lua src/cli.lua <file>...
local wordcount = require('src.wordcount')

local function read(path)
  local f = assert(io.open(path, 'r'))
  local text = f:read('*a')
  f:close()
  return text
end

for _, path in ipairs(arg) do
  local text = read(path)
  print(('%s: %d words, %d lines, %d chars, longest %q'):format(
    path, wordcount.words(text), wordcount.lines(text),
    wordcount.chars(text), wordcount.longest(text)))
end
EOF

# D: the deprecated module goes away.
git rm -q src/legacy.lua

# R with edits: renamed and lightly reworded, similar enough for -M detection.
mkdir docs
git mv notes.txt docs/usage.md
cat > docs/usage.md <<'EOF'
# wordcount usage

Run the word counter with one or more files as arguments, and it prints
one summary line per file:

  lua src/cli.lua README.md src/wordcount.lua

Each summary line reports the number of words, the number of lines, and
the number of characters in the file, in that order.

Words are runs of non-whitespace characters. Lines are counted the way
wc(1) counts them, so a trailing newline does not add an empty line.
EOF

# M (binary).
printf 'PNG\000\001\002\003new-logo-bytes\n' > logo.png

git add -A
git commit -qm 'feature: cli entry point, faster lines(), drop legacy'

# --- .orca/ gate + review notes from a "previous sitting" -------------------
# One open comment (long, to show virt_lines soft-wrap) and one already
# answered by orca's write-back — loaded counts, resolution rendering, and
# :OrcaCommentNext across files all work out of the box.
mkdir -p .orca/review-notes
HEAD_SHA=$(git rev-parse HEAD)
cat > .orca/review-notes/feature.json.in <<'EOF'
{"version":1,"range":"main...HEAD","head":"@HEAD@","created":"2026-07-15T09:00:00Z","updated":"2026-07-15T09:30:00Z","comments":[{"id":1,"file":"src/cli.lua","line":5,"text":"What happens on a missing file? assert will blow up with a raw traceback here.","quoted":"  local f = assert(io.open(path, 'r'))","status":"answered","resolution":"Intentional for now — cli is a thin demo shim, and the raw assert keeps it short."},{"id":2,"file":"src/wordcount.lua","line":14,"end_line":18,"text":"Nice fix — gsub counting is much cleaner than the pattern loop, and the no-trailing-newline case used to be off by one. It deserves a regression test though, so the next refactor does not quietly reintroduce the bug this just fixed.","quoted":"  local _, n = text:gsub('\\n', '\\n')","status":"open"}]}
EOF
sed "s/@HEAD@/$HEAD_SHA/" .orca/review-notes/feature.json.in > .orca/review-notes/feature.json
rm .orca/review-notes/feature.json.in

[ -n "$BUILD_ONLY" ] && { echo "sandbox rebuilt at $SANDBOX"; exit 0; }

cat <<'EOF'
── orca.nvim demo ──────────────────────────────────────────────────────────
Sandbox: demo/sandbox (feature branch, wiped and rebuilt every run).
Things to try, in order — the full walkthrough is in demo/README.md:

  :OrcaReview                     5 files in the panel, 2 comments loaded
  <CR> / j / k in the panel       open a file's diff pair
  :OrcaReviewPanel                the ladder: focus it, close it, bring it back
  :OrcaComment                    comment a line on the right side; :w commits
  :OrcaCommentNext / Prev         walk comments across files
  :vimgrep /words/ src/* | copen  the panel must not care
  :OrcaReviewClose                then inspect .orca/review-notes/feature.json

  :lua vim.g.orca_mappings = { next = ']q', prev = '[q' }   -- before :OrcaReview
────────────────────────────────────────────────────────────────────────────
EOF

if [ -n "$CLEAN" ]; then
  exec nvim --clean -n --cmd "set rtp^=$ROOT"
else
  # Sourced *after* the user's config so this working copy wins over an
  # installed orca.nvim, whatever the plugin manager did — see demo/rtp.lua.
  exec nvim "+luafile $ROOT/demo/rtp.lua"
fi
