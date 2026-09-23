require('helpers')

-- The one-line README snippet restores the old feel: bound next/prev honor
-- counts, clamp at the edge, and keep the polite edge message.
vim.g.orca_mappings = { next = ']q', prev = '[q' }
orca.review('')
orca.open(1)
check(vim.fn.maparg(']q', 'n', false, true).desc == 'orca: next file'
  and vim.fn.maparg(']q', 'n', false, true).buffer == 0,
  'restored ]q is one of the session\'s global maps')
keys('3]q')
check(panel_cur() == 4, '3]q moves three files, got ' .. tostring(panel_cur()))
keys('9]q')
check(panel_cur() == 6, 'overshooting count clamps to the last file, got ' .. tostring(panel_cur()))
keys(']q')
check(panel_cur() == 6, 'plain ]q at the edge stays put, got ' .. tostring(panel_cur()))
keys('2[q')
check(panel_cur() == 4, '2[q moves two files back, got ' .. tostring(panel_cur()))

-- The point of the change: a foreign quickfix list mid-session (:grep, LSP
-- references) changes nothing about the panel or the keys — where it used
-- to evict the review list and demand :colder.
orca.open(1)
vim.fn.setqflist({}, ' ', { title = 'foreign', items = {
  { filename = 'unchanged.txt', lnum = 1, text = 'one' },
  { filename = 'unchanged.txt', lnum = 1, text = 'two' },
} })
vim.cmd('botright copen')
check(#panel_lines() == 7 and panel_win() ~= nil, 'foreign qf list leaves the panel untouched')
check(panel_cur() == 1, 'current-file mark untouched by the foreign list')
vim.api.nvim_set_current_win(panel_win())
keys(']q')
check(panel_cur() == 2, 'orca keys stay orca\'s with a foreign list current, got ' .. tostring(panel_cur()))
check(vim.fn.getqflist({ title = true }).title == 'foreign', 'the foreign list stays the user\'s')
vim.api.nvim_set_current_win(panel_win())
keys('5G')
keys('<CR>')
check(vim.api.nvim_buf_get_name(0):find('src/b.lua', 1, true) ~= nil,
  '<CR> in the panel still opens the pair, got ' .. vim.api.nvim_buf_get_name(0))
local qf_still = false
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == 'quickfix' then qf_still = true end
end
check(qf_still, 'the pair never opens into the foreign quickfix window')
vim.cmd('cclose')
orca.close()
vim.g.orca_mappings = nil

-- vim.g.orca_mappings resolves at session start: per-action override, and
-- the unbound-by-default actions (comment/delete/panel/comment_next)
-- attach when the user opts in (comment in n and x).
vim.g.orca_mappings = { next = ')f', comment = '<leader>v', delete = '<leader>x',
  panel = '<leader>p', comment_next = ')c' }
orca.review('')
check(vim.fn.maparg(')f', 'n', false, true).desc == 'orca: next file',
  'orca_mappings: next bound to )f')
check(vim.fn.maparg(']q', 'n', false, true).desc ~= 'orca: next file',
  'orca_mappings: ]q stays unbound — orca took only what was configured')
check(vim.fn.maparg('<leader>v', 'n', false, true).buffer == 1, 'orca_mappings: opt-in comment binding attaches')
check(vim.fn.maparg('<leader>v', 'x', false, true).buffer == 1, 'orca_mappings: comment binding also maps visual mode')
check(vim.fn.maparg(')c', 'n', false, true).desc == 'orca: next comment',
  'orca_mappings: opt-in comment_next binding attaches')
-- and the configured key still opens the comment input (default mapleader
-- is backslash, so <leader>v arrives as \v)
orca.open(idx_of('src/b%.lua'))
local mapped_src_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
keys('\\v')
check(vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) ~= nil,
  'configured comment key opens the input, got ' .. vim.api.nvim_buf_get_name(0))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'doomed' })
commit()
check(vim.fn.filereadable(notes_path) == 1, 'delete setup: comment written to disk')
vim.api.nvim_set_current_win(mapped_src_win)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
check(vim.fn.maparg('<leader>x', 'n', false, true).buffer == 1,
  'orca_mappings: opt-in delete binding attaches')
keys('\\x')
check(vim.fn.filereadable(notes_path) == 0,
  'configured delete key removes the comment (empty file deleted)')
-- The panel action rides the same ladder as :OrcaReviewPanel, from
-- wherever you are: it is one of the session's global maps.
local from_win = vim.api.nvim_get_current_win()
keys('\\p')
check(vim.api.nvim_get_current_win() == panel_win(), 'panel key focuses the visible panel')
keys('\\p')
check(panel_win() ~= nil and vim.api.nvim_get_current_win() == from_win,
  'panel key on the focused panel goes back to the file, panel still open')
orca.close()
check(vim.fn.maparg(')f', 'n', false, true).desc == nil, 'session maps removed at close')
check(vim.fn.maparg('\\v', 'n', false, true).buffer ~= 1,
  'and the buffer-local ones with them')

-- An action's value is one key or a list of them: `open` ships as <CR>
-- plus the double-click, and rewriting it says what open is. A plain
-- string is the one-key case — which is how a config written before the
-- mouse binding existed keeps meaning exactly what it said.
vim.g.orca_mappings = { open = { 'go', '<2-LeftMouse>' } }
orca.review('')
vim.api.nvim_set_current_win(panel_win())
check(vim.fn.maparg('go', 'n', false, true).desc == "orca: open this file's diff"
  and vim.fn.maparg('<2-LeftMouse>', 'n', false, true).buffer == 1,
  'orca_mappings: a list binds every key in it')
check(vim.fn.maparg('<CR>', 'n', false, true).desc == nil, 'and the default <CR> is gone')
keys('3G')
keys('go')
check(vim.api.nvim_buf_get_name(0):find('img.bin', 1, true) ~= nil,
  'the listed key opens the pair, got ' .. vim.api.nvim_buf_get_name(0))
orca.close()
check(vim.fn.maparg('<2-LeftMouse>', 'n', false, true).buffer ~= 1,
  'every key in the list is removed at close')

vim.g.orca_mappings = { open = '<CR>' }
orca.review('')
vim.api.nvim_set_current_win(panel_win())
check(vim.fn.maparg('<CR>', 'n', false, true).desc == "orca: open this file's diff"
  and vim.fn.maparg('<2-LeftMouse>', 'n', false, true).buffer ~= 1,
  'orca_mappings: a string means that key and no other')
orca.close()

vim.g.orca_mappings = { open = false }
orca.review('')
vim.api.nvim_set_current_win(panel_win())
check(vim.fn.maparg('<CR>', 'n', false, true).desc == nil
  and vim.fn.maparg('<2-LeftMouse>', 'n', false, true).buffer ~= 1,
  'orca_mappings: open = false drops the keyboard and the mouse together')
orca.close()
vim.g.orca_mappings = nil

-- setup() is sugar over the same variable; false drops every map, and the
-- BufEnter navigation follower still opens pairs without any keys.
orca.setup({ mappings = false })
check(vim.g.orca_mappings == false, 'setup({mappings = ...}) writes vim.g.orca_mappings')
orca.review('')
check(vim.fn.maparg(')f', 'n', false, true).buffer ~= 1, 'mappings = false: no session maps set')
vim.api.nvim_set_current_win(panel_win())
check(vim.fn.maparg('<CR>', 'n', false, true).desc == nil, 'mappings = false: panel <CR> not claimed')
vim.cmd('wincmd k')
vim.cmd('edit c.txt')
drain(function() return count_diff_wins() == 2 end)
check(count_diff_wins() == 2, 'mappings = false: navigation follower still opens pairs')
orca.close()
vim.g.orca_mappings = nil

-- A buffer's own mapping on a key orca borrows is handed back as it was
-- found: orca maps `comment` buffer-locally in the pair it opens, and used
-- to delete the key on the way out, taking the user's map with it.
vim.cmd('edit src/b.lua')
local own_buf = vim.api.nvim_get_current_buf()
-- A Lua function, as an ftplugin's or on_attach's usually is.
vim.keymap.set('n', '<leader>m', function() vim.g.orca_own = 1 end, { buffer = own_buf, desc = 'my own' })
vim.g.orca_mappings = { comment = '<leader>m' }
orca.review('')
orca.open(idx_of('src/b%.lua'))
local function own_map(mode)
  local got
  vim.api.nvim_buf_call(own_buf, function() got = vim.fn.maparg('\\m', mode, false, true) end)
  return got
end
local in_pair = own_map('n')
check(in_pair.desc == 'orca: comment on this line', 'orca borrows the key while the pair is up')
orca.next()
local own = function() return own_map('n') end
check(own().desc == 'my own' and own().buffer == 1,
  'moving on hands the buffer its own map back, got ' .. tostring(own().desc))
orca.open(idx_of('src/b%.lua'))
orca.close()
check(own().desc == 'my own' and own().buffer == 1,
  'and so does closing the session, got ' .. tostring(own().desc))
check(next(own_map('x')) == nil,
  'while the visual-mode map orca added is simply gone')
vim.keymap.del('n', '<leader>m', { buffer = own_buf })
vim.g.orca_mappings = nil

finish()
