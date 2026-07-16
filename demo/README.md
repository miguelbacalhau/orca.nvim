# Manual-testing demo

`demo/run.sh` builds a disposable repo at `demo/sandbox/` and opens nvim
inside it with this working copy of the plugin on the runtimepath. The
sandbox is wiped and rebuilt on every run — that's the reset button; break
things freely.

```sh
demo/run.sh               # your own config: colors, LSP, muscle memory
demo/run.sh --clean       # isolated nvim, when you suspect config interference
demo/run.sh --build-only  # rebuild the sandbox without launching nvim
```

The sandbox is a plain checkout on a `feature` branch with one file of
every status — modified (three separate hunks), added, deleted, renamed
with edits, binary — plus a trunk that moved on after the branch point,
and review notes seeded from a "previous sitting": one open comment and
one already answered by orca's write-back.

## Walkthrough

**Session + panel.** `:OrcaReview`. Expect five files in the panel at the
bottom (colored status letters, `R notes.txt → docs/usage.md`,
`M logo.png (binary)`), `*1` counts on `src/cli.lua` and
`src/wordcount.lua`, the range in the panel's statusline, and the first
file's diff pair open. The trunk-only README paragraph must *not* appear
anywhere in the review.

**Panel keys.** `j`/`k` + `<CR>` opens the file under the cursor. The
current file carries the full-line highlight, and entering the panel lands
on it. `:OrcaReviewPanel` runs the ladder: focused → closes the window;
hidden → reopens and focuses; visible but unfocused → focuses. Close the
panel with `:q` and navigate anyway — the session doesn't care.

**Seeded notes.** Open `src/wordcount.lua`: the open comment renders under
its anchor with a `┃` gutter bar spanning lines 14–18, soft-wrapped to the
window (resize to watch it rewrap). Open `src/cli.lua`: the answered
comment shows orca's `✔ answered — …` resolution line.

**Commenting.** On the right (working-tree) side: `:OrcaComment` on a
line, type, `:w`. The panel count ticks up immediately. Re-run it on the
same line to edit; commit empty text (or `:OrcaCommentDelete`) to delete.
Try a visual-range comment, and one on the left side (politely refused).
Comments survive edits above them — insert a line and `:OrcaCommentNext`
still lands on the text, not the stale number.

**Comment walk.** `:OrcaCommentNext` / `:OrcaCommentPrev` cross files in
panel order and clamp at the ends with a message.

**Eviction-proofing.** `:vimgrep /words/ src/*.lua` then `:copen`. The
panel is untouched, its keys still work, and the quickfix window stays
yours. This is the reason the panel exists.

**Navigation follow.** Open a changed file by any route (`:e src/cli.lua`,
a picker) — its pair assembles around you. Wander to an unchanged file
inside a pair window — the pair collapses, the session lives.

**Mappings.** Defaults bind only `<CR>` in the panel. To test the restore
snippet and opt-in keys, set before `:OrcaReview`:

```vim
:lua vim.g.orca_mappings = { next = ']q', prev = '[q', comment = '<leader>rc', panel = '<leader>rp' }
```

Then `3]q`, `[q` at the first file (polite message), `<leader>rc` on a
line, `<leader>rp` for the panel ladder.

**Round trip.** `:OrcaReviewClose`, then look at
`.orca/review-notes/feature.json` — your comments are there, complete
snapshots on every write. `:OrcaReview` again reloads them.
