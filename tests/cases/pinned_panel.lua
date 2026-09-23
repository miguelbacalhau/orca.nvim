require('helpers')

-- The panel is pinned for the session's duration: closing its window puts
-- it straight back, re-rendered, without moving the cursor out of the file
-- under review. A review that lost its map is one navigating blind.
orca.review('')
local bidx = idx_of('src/b%.lua')
orca.open(1)
orca.next() -- src/b.lua's pair; focus on the right side
local before_win = vim.api.nvim_get_current_win()
local before_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_close(panel_win(), true)
check(panel_win() == nil, 'the panel window is gone the instant it is closed')
drain(function() return panel_win() ~= nil end)
check(panel_win() ~= nil, 'pinned: the closed panel window comes back')
check(vim.api.nvim_get_current_win() == before_win
  and vim.api.nvim_get_current_buf() == before_buf,
  'pinned: the panel returns without stealing focus')
check(panel_cur() == 2, 'the returned panel is re-rendered from session state')

-- :only is the same story through a different door — every other window
-- goes, and the panel is back beside the survivor a tick later.
vim.cmd('only')
drain(function() return panel_win() ~= nil end)
check(panel_win() ~= nil, 'pinned: the panel survives :only')

-- A foreign buffer taking the panel's window never closes a window at all;
-- the BufEnter follower catches that route.
orca.open(bidx)
local stolen = panel_win()
vim.api.nvim_win_set_buf(stolen, vim.fn.bufadd('unchanged.txt'))
drain(function() return panel_win() ~= nil end)
check(panel_win() ~= nil, 'pinned: the panel comes back from a stolen window too')
check(panel_win() ~= stolen, 'and in a window of its own, leaving the thief where it landed')

-- The ladder's third rung under a pin is the round trip, not a close.
orca.open(bidx)
local diff_win = vim.api.nvim_get_current_win()
vim.cmd('OrcaReviewPanel')
check(vim.api.nvim_get_current_win() == panel_win(), 'ladder: unfocused → focus')
check(vim.api.nvim_win_get_cursor(panel_win())[1] == panel_cur(),
  'the focused panel parks the cursor on the current file')
vim.cmd('OrcaReviewPanel')
check(panel_win() ~= nil, 'ladder: focused → the panel stays open')
check(vim.api.nvim_get_current_win() == diff_win,
  'ladder: focused → back to the file under review')

-- Opting out restores the closable panel: the third rung closes, and
-- nothing brings it back but :OrcaReviewPanel.
orca.close()
vim.g.orca_panel_pinned = false
orca.review('')
check(panel_win() ~= nil, 'unpinned session still opens with a panel')
vim.api.nvim_win_close(panel_win(), true)
vim.wait(100)
check(panel_win() == nil, 'unpinned: closing the panel window hides the view')
check(panel_buf() ~= nil, 'unpinned: the panel buffer survives its window')
orca.next() -- navigation keeps working with the panel hidden
check(panel_cur() == 2, 'hidden panel keeps rendering session state')
vim.cmd('OrcaReviewPanel')
check(panel_win() ~= nil and vim.api.nvim_get_current_win() == panel_win(),
  'unpinned ladder: hidden → open and focus')
vim.cmd('OrcaReviewPanel')
check(panel_win() == nil, 'unpinned ladder: focused → close the window')
orca.close()
vim.g.orca_panel_pinned = nil

finish()
