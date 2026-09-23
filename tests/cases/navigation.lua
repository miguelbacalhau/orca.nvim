require('helpers')

-- The diff pair follows navigation (the session-wide BufEnter handler).
orca.review('')
local bidx = idx_of('src/b%.lua')
orca.open(1)

-- An unrelated buffer in a *separate* split breaks nothing: the pair only
-- collapses when one of its own windows loses its buffer.
orca.open(2) -- c.txt; focus lands on the pair's right side
vim.cmd('botright new')
vim.cmd('edit unchanged.txt')
check(count_diff_wins() == 2, 'pair intact under unrelated buffer in a separate split, diff wins: ' .. count_diff_wins())
vim.cmd('close')

-- Wandering off inside the right diff window collapses the pair but keeps
-- the session (and the panel) alive.
orca.open(bidx) -- src/b.lua; focus on the right side
vim.cmd('edit unchanged.txt')
local shown_gone = 0
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local n = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
  if n:find('^orca://') and n ~= 'orca://review' then shown_gone = shown_gone + 1 end
end
check(count_diff_wins() == 0, 'collapse: no window left in diff mode, got ' .. count_diff_wins())
check(shown_gone == 0, 'collapse: no orca:// pair buffer displayed')
check(#vim.api.nvim_tabpage_list_wins(0) == 2, 'collapse: left split closed (panel + wandered window)')
check(vim.api.nvim_buf_get_name(0):find('unchanged.txt', 1, true) ~= nil, 'collapse leaves the wandered-to buffer alone')
check(#panel_lines() == 7 and panel_win() ~= nil, 'collapse keeps the panel')

-- Entering a changed file from the collapsed state reopens its pair around
-- the window the user is in, panel selection synced. Navigation-driven
-- opens are deferred one tick (mid-:close splits are illegal), so drain
-- the event loop before asserting.
vim.cmd('edit c.txt')
drain(function() return count_diff_wins() == 2 end)
check(count_diff_wins() == 2, ':edit of a changed file reopens its pair, diff wins: ' .. count_diff_wins())
check(vim.api.nvim_buf_get_name(0):find('c.txt', 1, true) ~= nil, 'reopened pair holds the entered file')
check(panel_cur() == 2, 'panel selection synced to the entered file, got ' .. tostring(panel_cur()))

-- Stealing the *left* (scratch) split collapses the pair too — and must
-- not close the window the user's buffer now occupies.
vim.cmd('wincmd h')
vim.cmd('edit unchanged.txt')
check(count_diff_wins() == 0, 'left steal: diff off everywhere, got ' .. count_diff_wins())
check(vim.api.nvim_buf_get_name(0):find('unchanged.txt', 1, true) ~= nil, 'left steal: wandered-to buffer keeps its window')
check(#vim.api.nvim_tabpage_list_wins(0) == 3, 'left steal: no window closed under the user')
vim.cmd('close') -- focus falls back into c.txt's window: BufEnter reopens its pair
drain(function() return count_diff_wins() == 2 end)
check(count_diff_wins() == 2, 'focus fallback into a changed file reopens its pair, diff wins: ' .. count_diff_wins())

-- A binary entry entered directly opens plainly, and re-entering it is a
-- no-op — the already-open guard cuts the open → BufEnter → open loop.
vim.cmd('edit img.bin')
drain(function() return #vim.api.nvim_tabpage_list_wins(0) == 2 end)
vim.cmd('edit img.bin')
vim.wait(50) -- settle: a (wrong) second open would run in this window
local binshown = 0
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('img.bin', 1, true) then
    binshown = binshown + 1
  end
end
check(#vim.api.nvim_tabpage_list_wins(0) == 2 and binshown == 1, 'binary entry stable across re-entry: one window shows it')
check(count_diff_wins() == 0, 'binary entry: no diff mode')

-- The session still answers after all the wandering.
local before_idx = panel_cur()
orca.next()
check(panel_cur() == before_idx + 1, ':OrcaReviewNext resumes the walk after collapse/reopen')
check(count_diff_wins() == 2, 'walk resumed with a live diff pair')

-- Wandering straight from one pair into another changed file — the LSP jump
-- and the CTRL-O — must leave the new pair's highlighting its own. Neovim
-- clears a window's 'diff' when a jump swaps its buffer, but leaves that
-- buffer on the tab page's diff list; a pair torn down afterwards used to
-- leave it there, and the next pair compared against the ghost too, which
-- painted every line of the new file changed. The hunks themselves are the
-- only assertion that catches it — the window flags all look right.
local function diff_hl(lnum)
  local id = vim.fn.diff_hlID(lnum, 1)
  return id == 0 and '-' or vim.fn.synIDattr(id, 'name')
end
-- What a jump costs, counted: a pair taken over in place opens no window and
-- closes none. Rebuilding it instead closed the merge-base split and
-- reopened it, reflowing the layout to full width and back — the flicker.
local churn = { WinNew = 0, WinClosed = 0 }
local churn_au = vim.api.nvim_create_autocmd({ 'WinNew', 'WinClosed' }, {
  callback = function(a) churn[a.event] = churn[a.event] + 1 end,
})
local function jump_to(path, side)
  churn = { WinNew = 0, WinClosed = 0 }
  vim.cmd('edit ' .. path)
  drain(function()
    local _, n = left_side()
    return n:find(side, 1, true) and count_diff_wins() == 2
  end)
end
orca.open(bidx) -- src/b.lua, from a pair already on screen
local left_before = left_side()
-- The working-tree side the jump lands on is the buffer the jump already
-- put there. Opening the pair used to :edit it again — a reload, which
-- throws the view away for nothing and refuses outright (E37) once there
-- are unwritten changes in it. 'changedtick' is what tells the two apart:
-- switching to a buffer leaves it alone, re-reading one bumps it.
local b_tick = vim.api.nvim_buf_get_changedtick(vim.api.nvim_get_current_buf())
jump_to('renamed-to.txt', 'renamed-from.txt') -- a rename with identical content: no hunks
check(diff_hl(1) == '-',
  'jump into a pure rename shows no hunk — no ghost buffer in the tab diff, got ' .. diff_hl(1))
check(left_side() == left_before,
  'the jump took the merge-base split over rather than rebuilding it')
check(churn.WinNew == 0 and churn.WinClosed == 0,
  ('no window opened or closed under the jump, got %d new / %d closed')
    :format(churn.WinNew, churn.WinClosed))
jump_to('src/b.lua', 'src/b.lua') -- and back out again
check(diff_hl(1) == '-' and diff_hl(2) ~= '-' and diff_hl(3) == '-' and diff_hl(4) == 'DiffAdd',
  ('jumping back marks only the real hunks, got %s %s %s %s')
    :format(diff_hl(1), diff_hl(2), diff_hl(3), diff_hl(4)))
check(vim.api.nvim_buf_get_changedtick(vim.api.nvim_get_current_buf()) == b_tick,
  'the file the jump landed on is not re-read under it')
-- What that re-read cost, beyond the view it threw away: the working-tree
-- side is editable on purpose (fixing nits during review is the point), and
-- re-reading a file with unwritten changes in it refuses — E37, and the pair
-- never opened at all. Taking the buffer as it stands has nothing to refuse.
vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'line1 UNWRITTEN' })
jump_to('c.txt', 'c.txt')
vim.cmd('buffer ' .. vim.fn.bufnr('src/b.lua'))
drain(function()
  local _, n = left_side()
  return n:find('src/b.lua', 1, true) and count_diff_wins() == 2
end)
check(vim.bo.modified and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'line1 UNWRITTEN',
  'a pair opens over unwritten changes rather than refusing to re-read the file')
vim.cmd('edit!') -- and the fixture goes back the way it was
vim.api.nvim_del_autocmd(churn_au)

-- A jump that lands in a window of its own — :vsplit to something else,
-- then :edit a changed file there — opens the pair around that window.
-- The old pair's teardown used to point the session back at its own right
-- window, so the new pair was built over there instead, and the window you
-- were looking at was left out of it.
orca.open(idx_of('c%.txt'))
local old_right = vim.api.nvim_get_current_win()
local old_left = vim.fn.win_getid(vim.fn.winnr('h'))
vim.cmd('vsplit unchanged.txt')
local landed = vim.api.nvim_get_current_win()
vim.cmd('edit src/b.lua')
drain(function() return vim.wo[landed].diff and count_diff_wins() == 2 end)
check(vim.api.nvim_get_current_win() == landed and vim.wo[landed].diff,
  'the pair opens around the window the jump landed in, which keeps focus')
local _, landed_left = left_side()
check(landed_left:find('src/b.lua', 1, true) ~= nil and count_diff_wins() == 2,
  'with src/b.lua\'s merge base beside it, got ' .. landed_left)
check(not (vim.api.nvim_win_is_valid(old_right) and vim.wo[old_right].diff)
  and not (vim.api.nvim_win_is_valid(old_left) and vim.wo[old_left].diff),
  'and the old pair\'s windows are out of diff mode')
vim.cmd('only')
drain(function() return panel_win() ~= nil end)

-- A failed open must not switch the navigation follower off. M.open
-- raises session.navigating while it rebuilds, and an error thrown while
-- the old pair came down skipped the reset: every later jump into a changed
-- file was ignored for the rest of the session.
orca.open(idx_of('c%.txt'))
local pv = require('orca.diff')
local real_close = pv.close
pv.close = function()
  pv.close = real_close
  error('teardown failed')
end
pcall(orca.open, idx_of('img%.bin')) -- binary: the c.txt pair has to come down
pv.close = real_close
vim.cmd('only')
drain(function() return panel_win() ~= nil end)
vim.cmd('edit src/b.lua')
drain(function() return count_diff_wins() == 2 end)
check(count_diff_wins() == 2 and panel_cur() == idx_of('src/b%.lua'),
  'after an open that threw, the next :edit of a changed file still gets its pair')

-- Leaving a deleted-file pair must not mangle the layout: its right side
-- is a scratch too, and wiping a displayed scratch closes its window —
-- which left the panel as the last window standing, ballooned to fill the
-- screen. The right window must survive as the next pair's anchor.
orca.open(1) -- deleted a.txt: both sides scratch
local h_before = vim.api.nvim_win_get_height(panel_win())
orca.open(bidx)
check(vim.api.nvim_win_get_height(panel_win()) == h_before,
  ('panel height survives leaving a deleted-file pair (%d), got %d')
    :format(h_before, vim.api.nvim_win_get_height(panel_win())))
check(count_diff_wins() == 2 and #vim.api.nvim_tabpage_list_wins(0) == 3,
  'next pair opened in the surviving right window')

finish()
