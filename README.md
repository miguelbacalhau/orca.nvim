# orca.nvim

The human half of [orca](https://github.com/miguelbacalhau/orca)'s review. An orca run's
independent reviewer already attacked the diff mechanically; `:OrcaReview` is the
look-through before `git merge --no-ff` — the branch's merge-base diff in your own
fully-configured Neovim: a quickfix list of changed files, native side-by-side diff
pairs, your LSP, your colors, your muscle memory.

It happens to work standalone in any git repository — no Claude Code session, no
`setup()`, no dependencies.

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
| `:OrcaReview [range]` | Start a session: `<base>...<head>` in the merge-base sense; bare `<base>` implies `...HEAD`; no argument defaults to `<trunk>...HEAD`. Populates the quickfix list and opens the first file's diff pair. |
| `:OrcaReviewNext` / `:OrcaReviewPrev` | Move to the next/previous changed file. |
| `:OrcaReviewMark` | Toggle reviewed (✓) on the current file; marking advances to the next unreviewed one. |
| `:OrcaReviewClose` | End the session and clean up. The quickfix list stays — it's yours. |

The right diff side is the real working-tree buffer — LSP attaches, and fixing nits
during review is a feature. Renames, additions, deletions, and binary files are all
handled; hunk motions (`]c`, `[c`, `do`, `dp`) are native diff mode.

Buffer-local maps in session-owned buffers: `]f` / `[f` next/previous file,
`<leader>rm` mark, `<leader>rq` close, and `<CR>` in the quickfix window opens that
file's pair.

`:checkhealth orca` answers "why doesn't `:OrcaReview` work here".

## Direction

v2 grows review notes — findings written from the editor that flow back into the orca
run's artifacts. The file format will carry a version so the skill and plugin
coordinate the way orca already coordinates everything else.
