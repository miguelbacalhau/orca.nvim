# orca.nvim

The human half of [orca](https://github.com/miguelbacalhau/orca)'s review. An orca run's
independent reviewer already attacked the diff mechanically; `:OrcaReview` is the
look-through before `git merge --no-ff` — the branch's merge-base diff in your own
fully-configured Neovim: a quickfix list of changed files, native side-by-side diff
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
| `:OrcaReview [range]` | Start a session: `<base>...<head>` in the merge-base sense; bare `<base>` implies `...HEAD`; no argument defaults to `<trunk>...HEAD`. Populates the quickfix list, loads any existing review notes for the branch, and opens the first file's diff pair. |
| `:OrcaReviewNext` / `:OrcaReviewPrev` | Move to the next/previous changed file. |
| `:OrcaComment` | Create or edit the comment on the current line (visual mode: on the range). Opens a borderless float in place over the comment's virtual lines (a bottom split on Neovim 0.9) — `:w` commits, quitting without writing aborts, committing empty text deletes. |
| `:OrcaCommentDelete` | Delete the comment under the cursor. |
| `:OrcaReviewClose` | End the session and clean up. The quickfix list stays — it's yours. |

The right diff side is the real working-tree buffer — LSP attaches, and fixing nits
during review is a feature. Renames, additions, deletions, and binary files are all
handled; hunk motions (`]c`, `[c`, `do`, `dp`) are native diff mode.

## Review notes

`:OrcaComment` anchors a comment to the line (or visual range) under the cursor,
on the working-tree side of the diff. While the session lives each comment is an
extmark, so anchors ride buffer edits; every create/edit/delete rewrites the notes
file from the extmarks' current positions — a crash loses nothing.

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

Buffer-local maps in session-owned buffers, every one a native key upgraded in place:
`]q` / `[q` next/previous file (counts work — `3]q` moves three), and `<CR>` in the
quickfix window opens that file's pair. If another list lands in the quickfix window
mid-session (`:grep`, LSP references), the keys fall back to stock behavior until
orca's list is current again. Comment, delete and close ship unbound — the commands
are the API, and one line adds keys:

```lua
vim.g.orca_mappings = { comment = "<leader>rc", close = "<leader>rq" }
```

`vim.g.orca_mappings` is read when a session starts: a table overrides per action
(keys `next`, `prev`, `comment`, `delete`, `close`, `open`; `false` drops one map),
or `false` wholesale for commands only. A `comment` binding maps both normal and
visual mode; `delete` removes the comment on the cursor line.
`require('orca').setup{ mappings = ... }` is optional sugar over the same variable,
so lazy.nvim's `opts` works too.

`:checkhealth orca` answers "why doesn't `:OrcaReview` work here".

## Direction

v2 shipped review notes. Deferred, addable behind the file's version field:
left-side (deletion) comments, threads/replies, a severity taxonomy in the editor.
