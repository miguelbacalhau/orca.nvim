require('helpers')

-- Comments are orca's own extmarks — nothing native can walk them. The
-- walk is review-wide: file order, then line, crossing files via the pair.
orca.review('')
orca.open(idx_of('c%.txt'))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'walk one' })
commit()
orca.open(idx_of('src/b%.lua'))
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'walk two' })
commit()
check(count_at(idx_of('c%.txt')) == '*1' and count_at(idx_of('src/b%.lua')) == '*1',
  'both walk comments counted in the panel')

-- From src/b.lua:3, prev crosses back into c.txt:1 through its pair.
vim.cmd('OrcaCommentPrev')
check(vim.api.nvim_buf_get_name(0):find('c.txt', 1, true) ~= nil and vim.fn.line('.') == 1,
  ('OrcaCommentPrev crosses into the previous file, got %s:%d')
    :format(vim.api.nvim_buf_get_name(0), vim.fn.line('.')))
check(vim.wo.diff, 'cross-file jump landed in a live pair')
vim.cmd('OrcaCommentPrev')
check(vim.api.nvim_buf_get_name(0):find('c.txt', 1, true) ~= nil and vim.fn.line('.') == 1,
  'clamped at the first comment — stays put')
vim.cmd('OrcaCommentNext')
check(vim.api.nvim_buf_get_name(0):find('src/b.lua', 1, true) ~= nil and vim.fn.line('.') == 3,
  ('OrcaCommentNext crosses forward, got %s:%d')
    :format(vim.api.nvim_buf_get_name(0), vim.fn.line('.')))
vim.cmd('OrcaCommentNext')
check(vim.fn.line('.') == 3, 'clamped at the last comment — stays put')

-- From the panel (no cursor in a reviewed file), the walk enters the
-- current file from its near boundary.
vim.api.nvim_set_current_win(panel_win())
vim.cmd('OrcaCommentNext')
check(vim.api.nvim_buf_get_name(0):find('src/b.lua', 1, true) ~= nil and vim.fn.line('.') == 3,
  'walk from the panel enters the current file at its first comment')
-- That walk reopens the file already on screen, taking its own pair over.
-- The new merge-base scratch was named while the old one still held the
-- name, so the rename failed (E95) and the side went nameless.
local walk_left = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr('h'))))
check(walk_left:find('^orca://%x+/src/b%.lua$') ~= nil,
  'reopening the current file keeps its merge-base side named, got ' .. walk_left)
-- The deleted-file pair has a scratch on both sides, and both keep theirs.
orca.open(1)
orca.open(1)
local gone_names = {}
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local n = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
  if n:find('a.txt', 1, true) then gone_names[#gone_names + 1] = n end
end
check(#gone_names == 2, 'and so does a reopened deleted file, both sides, got '
  .. table.concat(gone_names, ', '))
orca.open(idx_of('src/b%.lua'))
vim.api.nvim_win_set_cursor(0, { 3, 0 })

-- Anchors are extmarks: an insertion above the src/b.lua comment moves the
-- walk target too (positions self-heal, no stale line numbers).
vim.fn.append(0, 'walk drift line')
orca.open(idx_of('c%.txt'))
vim.cmd('OrcaCommentNext')
check(vim.api.nvim_buf_get_name(0):find('src/b.lua', 1, true) ~= nil and vim.fn.line('.') == 4,
  'walk target rides buffer edits (extmark-resolved), got line ' .. vim.fn.line('.'))
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
vim.bo.modified = false
orca.close()
vim.fn.delete(notes_path)

finish()
