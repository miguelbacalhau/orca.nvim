require('helpers')

-- The navigation verbs are mapped globally while a session lives, so they
-- answer from buffers orca does not own — the whole point of a review you
-- can walk while standing in a grep result or a file outside the diff. The
-- key's previous global meaning is captured and handed back at close.
-- What a key meant before the session, for the restore assertion below.
-- Compared as a signature rather than deep-equal: a Lua-callback map holds
-- a function value, and ]q/[q are Neovim's own :cnext/:cprevious defaults
-- on 0.11+ and nothing at all before that — either way the test only cares
-- that what comes back is what was there.
local function map_sig(lhs)
  local m = vim.fn.maparg(lhs, 'n', false, true)
  return ('%s|%s|%s'):format(m.rhs or '', m.desc or '', m.buffer or '')
end
vim.keymap.set('n', ']q', '<Cmd>let g:orca_smoke_prev = 1<CR>', { desc = 'user map' })
local sig_next, sig_prev = map_sig(']q'), map_sig('[q')

vim.g.orca_mappings = { next = ']q', prev = '[q', comment = '<leader>rc' }
orca.review('')
local bidx = idx_of('src/b%.lua')
orca.open(1)
vim.cmd('edit unchanged.txt') -- a file that is not part of the review at all
drain(function() return vim.api.nvim_buf_get_name(0):find('unchanged.txt', 1, true) end)
check(vim.fn.maparg(']q', 'n', false, true).desc == 'orca: next file',
  'orca took ]q globally for the session')
check(vim.fn.maparg(']q', 'n', false, true).buffer == 0, 'globally, not in this buffer')
-- ...while `comment` does not travel: it needs a changed file's
-- working-tree line to anchor to, so it stays where it can act. (<leader>
-- is \\ here — maparg does not expand the notation.)
check(vim.fn.maparg('\\rc', 'n') == '',
  'comment is not global: unmapped in a buffer outside the review')
local cur_before = panel_cur()
keys(']q')
check(panel_cur() == cur_before + 1,
  ']q walks the review from a buffer outside it, got ' .. tostring(panel_cur()))
orca.open(bidx)
check(vim.fn.maparg('\\rc', 'n', false, true).buffer == 1,
  'comment is buffer-local in the working-tree side of a pair')
orca.close()
check(map_sig(']q') == sig_next,
  'the user\'s own ]q is handed back at session close, got ' .. map_sig(']q'))
check(map_sig('[q') == sig_prev,
  '[q goes back to whatever it was, got ' .. map_sig('[q'))
vim.keymap.del('n', ']q')
vim.g.orca_mappings = nil

-- Close: no orca buffers survive (panel included), diff off everywhere,
-- and the notes file stays.
orca.review('')
orca.open(bidx)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'outlives the session' })
commit()
orca.close()
local leftovers = 0
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b):find('^orca://') then
    leftovers = leftovers + 1
  end
end
check(leftovers == 0, 'no orca:// buffers survive close')
check(panel_buf() == nil, 'panel buffer destroyed at close')
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  check(not vim.wo[w].diff, 'diff off in window ' .. w)
end
check(vim.fn.filereadable(notes_path) == 1, 'notes file survives close — that is the point')

finish()
