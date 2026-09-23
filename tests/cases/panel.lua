require('helpers')

-- A competing FileType autocmd mapping <CR> back to itself in the panel's
-- filetype — the blanket-ftplugin pattern that used to clobber the qf map.
-- Panel maps are set after the buffer (and its filetype) exist, and nothing
-- ever re-runs ftplugins on an orca-owned buffer, so orca's <CR> must win.
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'orca-panel',
  callback = function(ev)
    vim.keymap.set('n', '<CR>', '<CR>', { buffer = ev.buf, nowait = true })
  end,
})

-- Bare review: trunk...HEAD, trunk resolved from the common dir (main).
orca.review('')
check(panel_buf() ~= nil, 'panel buffer orca://review exists')
check(panel_win() ~= nil, 'panel window is open')
check(panel_statusline() == 'OrcaReview main...HEAD',
  'panel statusline is OrcaReview main...HEAD, got: ' .. tostring(panel_statusline()))
local lines = panel_lines()
out('LIST ' .. table.concat(lines, ' ;; '))
-- Eight changed files, two of them claimed by the default `tests` group:
-- six rows plus the summary row that says so.
check(#lines == 7, 'six visible files + the summary row, got ' .. #lines)
check(lines[7]:find('2 files hidden %(tests%)') ~= nil,
  'summary row names the hidden count and group, got: ' .. lines[7])
check(idx_of('z_test') == nil and idx_of('b_spec') == nil,
  'the tests group is folded away by default')
check(not table.concat(lines, ';'):find('trunk%-only'), 'merge-base diff excludes trunk-only.txt')
check(table.concat(lines, ';'):find('R  renamed%-from%.txt → renamed%-to%.txt') ~= nil,
  'rename shown as R old → new')
check(table.concat(lines, ';'):find('M  img%.bin %(binary%)') ~= nil, 'binary file marked (binary)')
check(vim.bo[panel_buf()].filetype == 'orca-panel', 'panel filetype is orca-panel')
check(vim.bo[panel_buf()].modifiable == false, 'panel buffer is not modifiable')
check(vim.api.nvim_win_get_height(panel_win()) == 7,
  'panel height tracks the rendered rows, summary included (7)')
local lay = vim.fn.winlayout()
check(lay[1] == 'col' and lay[2][#lay[2]][1] == 'leaf' and lay[2][#lay[2]][2] == panel_win(),
  'panel is the full-width bottom strip')
check(status_hl(idx_of('a%.txt')) == 'OrcaPanelRemoved', 'D letter highlighted OrcaPanelRemoved')
check(status_hl(idx_of('c%.txt')) == 'OrcaPanelAdded', 'A letter highlighted OrcaPanelAdded')
check(status_hl(idx_of('renamed')) == 'OrcaPanelRenamed', 'R letter highlighted OrcaPanelRenamed')
check(status_hl(idx_of('src/b%.lua')) == 'OrcaPanelChanged', 'M letter highlighted OrcaPanelChanged')

-- Line counts ride the window's right edge, one column per side sized to
-- the widest on show (+2/-1 here, so two characters each), added in
-- OrcaPanelAdded and deleted in OrcaPanelRemoved.
check(diffstat_at(idx_of('src/b%.lua')) == '+2|OrcaPanelAdded, |,-1|OrcaPanelRemoved, |',
  'modified file shows +2 -1, got: ' .. tostring(diffstat_at(idx_of('src/b%.lua'))))
-- Both sides always show: a one-sided change states its zero.
check(diffstat_at(idx_of('c%.txt')) == '+1|OrcaPanelAdded, |,-0|OrcaPanelRemoved, |',
  'added file shows +1 -0, got: ' .. tostring(diffstat_at(idx_of('c%.txt'))))
check(diffstat_at(idx_of('a%.txt')) == '+0|OrcaPanelAdded, |,-1|OrcaPanelRemoved, |',
  'deleted file shows +0 -1, got: ' .. tostring(diffstat_at(idx_of('a%.txt'))))
check(diffstat_at(idx_of('renamed')) == '+0|OrcaPanelAdded, |,-0|OrcaPanelRemoved, |',
  'pure rename shows +0 -0, got: ' .. tostring(diffstat_at(idx_of('renamed'))))
check(diffstat_at(idx_of('img%.bin')) == nil, 'binary file shows no line counts')
check(diffstat_at(7) == nil, 'the summary row carries no line counts')

-- Review auto-opens the first file (deleted a.txt): both sides scratch, diff on.
local wins = vim.api.nvim_tabpage_list_wins(0)
local diffwins, scratchbufs = 0, 0
for _, w in ipairs(wins) do
  if vim.wo[w].diff then diffwins = diffwins + 1 end
  local b = vim.api.nvim_win_get_buf(w)
  if vim.bo[b].buftype == 'nofile' and b ~= panel_buf() then scratchbufs = scratchbufs + 1 end
end
check(#wins == 3, 'three windows (left, right, panel), got ' .. #wins)
check(diffwins == 2, 'two windows in diff mode, got ' .. diffwins)
check(scratchbufs == 2, 'deleted file: both sides scratch, got ' .. scratchbufs)
check(panel_cur() == 1, 'current-file mark on entry 1')

-- The `open` action: <CR> in the panel opens the file under the cursor and
-- focuses its diff — the old :cc feel. The buffer is orca's alone, so the
-- competing FileType map registered above must lose by ordering, forever
-- (nothing re-runs ftplugins on it). Keystroke-level simulation only — API
-- calls bypass mappings entirely.
vim.api.nvim_set_current_win(panel_win())
check(vim.fn.maparg('<CR>', 'n', false, true).desc == "orca: open this file's diff",
  "orca's <CR> beats the competing FileType-orca-panel map")
keys('2G')
keys('<CR>')
local cur = vim.api.nvim_buf_get_name(0)
check(cur:find('c.txt', 1, true) ~= nil, '<CR> on entry 2 opens its pair, got ' .. cur)
check(vim.wo.diff, 'entry 2 right window is in diff mode')
check(panel_cur() == 2, 'current-file mark follows the open')

-- `open` also ships on the double-click: the panel replaced the quickfix
-- list, where <2-LeftMouse> was <CR>. A real click needs a UI attached
-- (nvim_input_mouse is a no-op headless), so what this can check is that
-- the map is there and that it takes its row from the pointer, not the
-- cursor. With no pointer position at all — which is what a click on the
-- panel's statusline reports, and it fires this map too — the handler must
-- do nothing rather than open whatever the cursor happens to sit on.
vim.api.nvim_set_current_win(panel_win())
local click_map = vim.fn.maparg('<2-LeftMouse>', 'n', false, true)
check(click_map.buffer == 1 and click_map.desc == "orca: open the clicked file's diff",
  'double-click is bound in the panel, to the click handler')
vim.api.nvim_win_set_cursor(panel_win(), { 1, 0 })
local before_click = vim.api.nvim_buf_get_name(0)
local click_ok = pcall(click_map.callback)
check(click_ok and vim.api.nvim_buf_get_name(0) == before_click,
  'a click with no position on a panel row opens nothing, got ' .. vim.api.nvim_buf_get_name(0))
check(panel_cur() == 2, 'and leaves the current file where it was')

-- Modified file: right side is the real working-tree buffer, left scratch.
local bidx = idx_of('src/b%.lua')
orca.open(bidx)
local name = vim.api.nvim_buf_get_name(0)
check(name:find('src/b.lua', 1, true) ~= nil, 'right side is working-tree src/b.lua, got ' .. name)
check(vim.bo.buftype == '', 'right side is a real buffer')
check(vim.wo.diff, 'right window in diff mode')
-- next/prev ship unbound: with no orca quickfix list there is no native
-- key left to upgrade, and ]q must keep meaning the user's quickfix-next.
check(vim.fn.maparg(']q', 'n', false, true).buffer ~= 1, 'next/prev ship unbound — ]q left alone')
check(vim.fn.maparg('<leader>rc', 'n', false, true).buffer ~= 1
  and vim.fn.maparg('<leader>rq', 'n', false, true).buffer ~= 1, 'no leader-shaped defaults')
-- left side content is the merge-base version
local lwin = vim.fn.win_getid(vim.fn.winnr('h'))
local lbuf = vim.api.nvim_win_get_buf(lwin)
local llines = vim.api.nvim_buf_get_lines(lbuf, 0, -1, false)
check(table.concat(llines, '\n') == 'line1\nline2\nline3', 'left side holds merge-base content')
check(vim.bo[lbuf].modifiable == false, 'left side read-only')
check(vim.bo[lbuf].filetype == 'lua', 'left side filetype copied (lua)')

finish()
