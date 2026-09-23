# orca.nvim

The human half of [orca](https://github.com/miguelbacalhau/orca)'s review. An orca run's
independent reviewer already attacked the diff mechanically; `:OrcaReview` is the
look-through before `git merge --no-ff` — the branch's merge-base diff in your own
fully-configured Neovim: a review panel of changed files, native side-by-side diff
pairs, your LSP, your colors, your muscle memory. Comments you write on the way
persist under `.orca/` and flow back into the run: orca converts them to findings,
fixes them, and the next review session shows what it did about each one.

It requires an orca-managed repository — `.orca/` at the repo root. In a repo
without one, `:OrcaReview` points you at `/orca:init`. No required `setup()`, no
dependencies.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "miguelbacalhau/orca.nvim" }
```

Any other plugin manager works the same way — the repo root is a standard plugin
(`plugin/`, `lua/`, `doc/`). Without a manager, clone into Neovim's native packpath:

```sh
git clone https://github.com/miguelbacalhau/orca.nvim \
    ~/.local/share/nvim/site/pack/orca/start/orca.nvim
```

then `:helptags ALL`. (Native packages need `packpath` intact — if your config resets
it, use the manager route.) If you use the orca Claude Code plugin, `/orca:doctor`
checks the install and prescribes whichever path fits.

## Commands

| Command | What it does |
|---|---|
| `:OrcaReview [range]` | Start a session: `<base>...<head>` in the merge-base sense; bare `<base>` implies `...HEAD`; no argument defaults to `<trunk>...HEAD`. Opens the review panel, loads any existing review notes for the branch, and opens the first file's diff pair. |
| `:OrcaReviewNext` / `:OrcaReviewPrev` | Move to the next/previous changed file. |
| `:OrcaReviewPanel` | The panel's focus ladder: not there → open and focus; there but unfocused → focus; focused → back to the file. The panel stays open either way. |
| `:OrcaComment` | Create or edit the comment on the current line (visual mode: on the range). Opens a borderless float in place over the comment's virtual lines (a bottom split on Neovim 0.9). What you type is saved as you type — no `:w` needed (it's harmless, and `:wq` closes). A new comment exists from its first word; emptying one doesn't delete it. A file change just closes the editor, keeping the text. |
| `:OrcaCommentNext` / `:OrcaCommentPrev` | Jump to the next/previous review comment, crossing files in review order. |
| `:OrcaCommentDelete` | Delete the comment under the cursor. |
| `:OrcaReviewClose` | End the session and clean up. |

The right diff side is the real working-tree buffer — LSP attaches, and fixing nits
during review is a feature. Renames, additions, deletions, and binary files are all
handled; hunk motions (`]c`, `[c`, `do`, `dp`) are native diff mode.

## The panel

The changed-file list lives in a buffer orca owns (`orca://review`), a full-width
strip at the bottom — not the quickfix list, which is shared territory: the verbs
of reviewing (`:grep`, LSP references, test runners) all push new quickfix lists,
and each one would evict the review. Nothing external writes into the panel, so
the list survives everything short of `:OrcaReviewClose` — and so does its
window. The panel is the review's map: what's left, what you've already said
something about, where you are in the walk. A review that lost it is one
navigating blind with nothing on screen saying so, so it's pinned open for
the session. `:q`, `CTRL-W_c`, `:only`, a window-management plugin tidying
up, a foreign buffer landing in its window — it comes straight back,
re-rendered, without taking your cursor out of the file you were reading.
`vim.g.orca_panel_pinned = false` gives you the old closable panel.

One line per file — colored status letter, per-file comment count (a purple
`*2` between the status and the name, its column reserved so names stay
aligned, updating live as you comment), path, `(binary)` marker, renames as
`old → new`, and the file's `+18 -4` line counts held against the window's
right edge — with the current file marked full-line. `<CR>` or a double-click
on a line opens that file's diff pair, from the panel or from inside a diff —
the click lands where the pointer is, whatever the cursor was doing.
Highlight groups, all overridable: `OrcaPanelAdded`,
`OrcaPanelRemoved`, `OrcaPanelChanged`, `OrcaPanelRenamed`, `OrcaPanelCurrent`,
`OrcaPanelCount`, `OrcaPanelHidden`.

## Hidden files

An orca run's diff is usually mostly tests, and the look-through before merge
wants the source in front of it. So tests fold away, behind the panel's last
row:

```
 M *2 lua/orca/panel.lua
 A    lua/orca/filter.lua
 …    2 files hidden (tests) — <CR> shows
```

That row is both the indicator and the control — `<CR>` on it toggles, and it
stays in both states (inverted: `showing everything — <CR> hides 2`), so the
hiding is never something you discover after merging. There is no command for
it: like the panel's `<CR>`, this is an action on the panel. Bind a key that
works from anywhere in the session with
`vim.g.orca_mappings = { hidden = "<leader>rh" }`, or call
`require('orca').toggle_hidden()`.

Hiding is a *view*, never a filter on the session. A hidden file is still a
full entry: `:edit` opens its diff pair, `:OrcaComment` anchors to it, its
comments reach the notes file and orca's addressing step. Three things pin a
file visible whatever its group says — a comment on it (say something about a
file and it keeps its row; delete the last comment and it folds back), being
the file you're currently in, and being the last one left (hiding everything
would open a review with nothing in it, so an all-tests branch shows
everything and says why).

Groups are globs, where the `/` decides what gets matched: no slash matches
the basename (`*_test.go`), a trailing slash a directory at any depth
(`tests/`), a slash inside the whole repo-relative path (`spec/**/*.rb`), a
leading slash anchors at the repo root (`/tests/`). `*` stops at a separator,
`**` crosses it. A rename folds away only when both its names match — a file
moving out of `tests/` is exactly the change you want to see.

```lua
vim.g.orca_review_hidden = false            -- start showing everything
vim.g.orca_review_groups = {
  generated = { "*.pb.go", "package-lock.json", "__snapshots__/" },
  tests = false,                            -- stop hiding tests
}
```

Every defined group rides the one toggle, so a group you never want hidden is
a group you shouldn't define. The shipped `tests` group is deliberately
literal (`tests/ test/ spec/ __tests__/ testdata/`, `*_test.* *_spec.*
*.test.* *.spec.* test_*.py conftest.py`) — a too-greedy glob would silently
drop real code from every review in every repo, which is the one thing this
must never do.

## Review notes

`:OrcaComment` anchors a comment to the line (or visual range) under the cursor,
on the working-tree side of the diff. While the session lives each comment is an
extmark, so anchors ride buffer edits; every create/edit/delete rewrites the notes
file from the extmarks' current positions — a crash loses nothing.

The editor belongs to the file under it — the gap it hangs in is an extmark in
that buffer — so a file change resolves it first rather than leaving it floating
over the next file. An editor nobody typed into closes and the move goes through;
one holding unwritten text keeps the keystroke and puts the cursor back in it.
Nobody presses "next file" meaning "throw that away".

Each comment carries a stable global id, shown as `#N` in its virtual text —
write `#2` in one comment to reference another, even across files, and the
addressing step resolves it. Ids are assigned once and never reused: deleting a
comment leaves a gap, so a stale reference dangles visibly instead of silently
pointing at a newer comment.

Notes persist to `.orca/review-notes/<key>.json`, where `<key>` is the sanitized
head branch (or the full range when head isn't a branch). The path is derived from
git state alone, so quitting Neovim on Tuesday and reopening the worktree on
Wednesday finds the same file — and so does orca. The file is versioned: it is the
plugin↔skill coordination contract, and either side fails loud on a version it
doesn't know.

The round trip: you comment, orca's addressing step converts each `open` comment
to a finding (severity High — if you bothered to write it, it matters), runs the
fix machinery, and writes `status` (`addressed` | `answered`) plus a `resolution`
note back into the same file. The next `:OrcaReview` shows resolutions inline
under each anchor. Comments are right-side only in v1 — the left buffer is a
base-version scratch with no working-tree anchor.

## Keymaps

The session's navigation verbs — `next`, `prev`, `panel`, `hidden`, `close`,
`comment_next`, `comment_prev` — are mapped **globally for as long as the
session lives**: "which file is next" is a property of the review, not of the
window you happen to be standing in, so they answer from a `:grep` result,
`:help`, a terminal, a file that isn't in the diff at all — the way the
commands always have. Whatever such a key meant before is captured and handed
back at `:OrcaReviewClose`. The rest are buffer-local, in session-owned buffers
only, because there they're the honest answer: `comment` and `delete` need a
changed file's working-tree line to anchor to, and `open` is the panel's alone.

One action ships bound: `open`
in the panel, as `<CR>` on the cursor's line and `<2-LeftMouse>` on the pointer's
— in an orca-owned buffer neither shadows anything (the fugitive/oil precedent,
and the quickfix list the panel replaced had the same double-click). Everything
else ships unbound: orca never
binds a key that doesn't already mean what orca makes it do, and no native key
means "next reviewed file" or "comment this line". The commands are the API, and
one line adds keys — to restore the old quickfix feel:

```lua
vim.g.orca_mappings = { next = "]q", prev = "[q" }
```

(counts work — `3]q` moves three files). Or bind the rest:

```lua
vim.g.orca_mappings = { comment = "<leader>rc", close = "<leader>rq" }
```

`vim.g.orca_mappings` is read when a session starts: a table overrides per action
(keys `next`, `prev`, `open`, `comment`, `delete`, `comment_next`, `comment_prev`,
`panel`, `hidden`, `close`; `false` drops one map), or `false` wholesale for
commands only. A value is one key or a list of them — `open` ships as
`{ "<CR>", "<2-LeftMouse>" }`, so rewriting it says what open is:

```lua
vim.g.orca_mappings = { open = "<CR>" }                          -- keyboard only
vim.g.orca_mappings = { open = { "<CR>", "<LeftRelease>" } }     -- single click opens
```

(single click is yours to opt into, not a default: it makes clicking the panel
to focus or scroll it open a file, and it leaves a double-click in visual mode.)
A `comment` binding maps both normal and visual mode; `delete`
removes the comment on the cursor line; `panel` rides the `:OrcaReviewPanel`
ladder; `hidden` toggles the hidden groups from anywhere. Hunk motion inside
a pair is native diff mode — `]c` / `[c` need no orca binding.
`require('orca').setup{ mappings = ... }` is optional sugar over the same variable,
so lazy.nvim's `opts` works too.

`:checkhealth orca` answers "why doesn't `:OrcaReview` work here".

## Direction

v2 shipped review notes; v3 the owned panel, comment navigation, and hidden
groups. Deferred, addable behind the file's version field: left-side (deletion)
comments, threads/replies, a severity taxonomy in the editor. Deferred on the
panel side: a `:cdo`-style quickfix export, side placement, grouping — and on
the hiding side, per-group toggling plus a `!pattern` escape hatch for "hide
tests except `tests/helpers/`".
