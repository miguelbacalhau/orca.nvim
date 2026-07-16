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
| `:OrcaReviewPanel` | The panel's focus-or-toggle ladder: hidden → open and focus; visible but unfocused → focus; focused → close the window. |
| `:OrcaComment` | Create or edit the comment on the current line (visual mode: on the range). Opens a borderless float in place over the comment's virtual lines (a bottom split on Neovim 0.9) — `:w` commits, quitting without writing aborts, committing empty text deletes. |
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
the list survives everything short of `:OrcaReviewClose`. Closing its window
(`:q`) only hides the view; `:OrcaReviewPanel` brings it back, re-rendered.

One line per file — colored status letter, per-file comment count (a purple
`*2` between the status and the name, its column reserved so names stay
aligned, updating live as you comment), path, `(binary)` marker, renames as
`old → new` — with the current file marked full-line. `<CR>` on a line opens
that file's diff pair. Highlight groups, all overridable: `OrcaPanelAdded`,
`OrcaPanelRemoved`, `OrcaPanelChanged`, `OrcaPanelRenamed`, `OrcaPanelCurrent`,
`OrcaPanelCount`.

## Review notes

`:OrcaComment` anchors a comment to the line (or visual range) under the cursor,
on the working-tree side of the diff. While the session lives each comment is an
extmark, so anchors ride buffer edits; every create/edit/delete rewrites the notes
file from the extmarks' current positions — a crash loses nothing.

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

Buffer-local maps in session-owned buffers only. One key ships bound: `<CR>` in
the panel opens the file under the cursor — in an orca-owned buffer it shadows
nothing (the fugitive/oil precedent). Everything else ships unbound: orca never
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
`panel`, `close`; `false` drops one map), or `false` wholesale for commands only.
A `comment` binding maps both normal and visual mode; `delete` removes the comment
on the cursor line; `panel` rides the `:OrcaReviewPanel` ladder. Hunk motion inside
a pair is native diff mode — `]c` / `[c` need no orca binding.
`require('orca').setup{ mappings = ... }` is optional sugar over the same variable,
so lazy.nvim's `opts` works too.

`:checkhealth orca` answers "why doesn't `:OrcaReview` work here".

## Direction

v2 shipped review notes; v3 the owned panel and comment navigation. Deferred,
addable behind the file's version field: left-side (deletion) comments,
threads/replies, a severity taxonomy in the editor. Deferred on the panel side:
a `:cdo`-style quickfix export, side placement, grouping.
