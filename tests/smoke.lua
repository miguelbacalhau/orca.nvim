-- Headless smoke test for orca.nvim. Run by tests/run.sh from inside the
-- feature worktree of the disposable bare-with-worktrees fixture (which has
-- .orca/ at the fixture root — the plugin is orca-only).
local function out(s) io.write(s .. '\n') end
local failed = 0
local function check(cond, label)
  if cond then out('OK   ' .. label) else failed = failed + 1; out('FAIL ' .. label) end
end
local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'x', false)
end
local function drain(cond)
  vim.wait(1000, cond, 10)
end

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

local orca = require('orca')
local NS = vim.api.nvim_create_namespace('orca_notes')
local PNS = vim.api.nvim_create_namespace('orca_panel')

-- Panel introspection: one owned buffer (orca://review), one window at most.
local function panel_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == 'orca://review' then
      return b
    end
  end
end
local function panel_win()
  local b = panel_buf()
  if not b then return nil end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == b then return w end
  end
end
local function panel_lines()
  return vim.api.nvim_buf_get_lines(panel_buf(), 0, -1, false)
end
-- 1-based row of the panel line matching pat (a lua pattern), or nil when
-- no row shows it. Rows are the panel's *view* — with the two test files
-- hidden by default they coincide with entry indices for all six visible
-- files (the hidden pair sorts last), which is what lets the rest of this
-- file keep passing a row to orca.open().
local function idx_of(pat)
  for i, l in ipairs(panel_lines()) do
    if l:find(pat) then return i end
  end
end
-- The row carrying the full-line current-file mark.
local function panel_cur()
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), PNS, 0, -1, { details = true })) do
    if m[4].line_hl_group == 'OrcaPanelCurrent' then return m[2] + 1 end
  end
end
local function status_hl(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), PNS,
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    -- the status letter's mark spans cols 1-2 (after the padding space)
    if m[3] == 1 and m[4].end_col == 2 then return m[4].hl_group end
  end
end
-- The *n comment-count token on a row, or nil.
local function count_at(row)
  return panel_lines()[row]:match('%*%d+')
end
-- Is the count token on a row highlighted OrcaPanelCount?
local function count_hl_at(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), PNS,
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].hl_group == 'OrcaPanelCount' then return true end
  end
  return false
end
-- The `+n -n` line counts on a row: the right-aligned virt_text, as
-- "<text>|<hl>,...", or nil when the row carries none.
local function diffstat_at(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), PNS,
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].virt_text and m[4].virt_text_pos == 'right_align' then
      local parts = {}
      for _, c in ipairs(m[4].virt_text) do
        parts[#parts + 1] = ('%s|%s'):format(c[1], c[2] or '')
      end
      return table.concat(parts, ',')
    end
  end
end
local function panel_statusline()
  return vim.api.nvim_get_option_value('statusline', { win = panel_win() })
end

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

-- ========================= review notes =========================

-- Discovery: repo root is the parent of the common git dir — in the bare
-- layout, the worktree's parent, not the worktree itself.
local root = require('orca.git').repo_root()
check(root == vim.fn.fnamemodify(vim.fn.getcwd(), ':h'),
  'repo_root is the worktree parent (bare layout), got ' .. tostring(root))
local notes_path = root .. '/.orca/review-notes/feature.json'
check(vim.fn.filereadable(notes_path) == 0, 'no notes file before the first comment (lazy creation)')

local function read_notes()
  if vim.fn.filereadable(notes_path) == 0 then return nil end
  return vim.json.decode(table.concat(vim.fn.readfile(notes_path), '\n'),
    { luanil = { object = true, array = true } })
end

-- Create: :OrcaComment opens an acwrite scratch split; :w commits and the
-- whole file is rewritten under .orca/review-notes/<branch>.json.
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
check(vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) ~= nil,
  'OrcaComment opens the input scratch, got ' .. vim.api.nvim_buf_get_name(0))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'first thought', 'second line' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
local data = read_notes()
check(data ~= nil and data.version == 1, 'notes file written with version 1')
check(data and data.range == 'main...HEAD', 'range recorded, got ' .. tostring(data and data.range))
check(data and data.head == require('orca.git').rev('HEAD'), 'head sha recorded')
local c1 = data and data.comments and data.comments[1]
check(c1 and c1.file == 'src/b.lua' and c1.line == 2, 'comment anchored at src/b.lua:2')
check(c1 and c1.text == 'first thought\nsecond line', 'multi-line text preserved')
check(c1 and c1.quoted == 'line2 CHANGED', 'quoted holds the anchor line text')
check(c1 and c1.status == 'open', 'new comment is open')
check(c1 and c1.id == 1, 'first comment carries id 1')
check(#vim.api.nvim_buf_get_extmarks(0, NS, 0, -1, {}) == 1, 'comment shown as an extmark in the buffer')
check(count_at(bidx) == '*1', 'panel counts the new comment — *1')
check(count_hl_at(bidx), 'count token highlighted OrcaPanelCount')
check(count_at(idx_of('c%.txt')) == nil, 'no count on an uncommented file')
-- The count column is reserved on comment-less rows: names stay aligned.
local commented = panel_lines()[bidx]
local plain = panel_lines()[idx_of('c%.txt')]
check(commented:find('src/b.lua', 1, true) == plain:find('c.txt', 1, true),
  'count column reserved — names aligned across commented and plain rows')

-- Edit: :OrcaComment on the commented line prefills; writing rewrites the
-- one comment instead of adding another.
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
check(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') == 'first thought\nsecond line',
  'reopening a commented line prefills the existing text')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited thought' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
data = read_notes()
check(data and #data.comments == 1 and data.comments[1].text == 'edited thought',
  'editing rewrites the comment, no duplicate')
check(data and data.comments[1].id == 1, 'editing keeps the id')

-- The left scratch side politely refuses — comments are right-side only.
vim.cmd('wincmd h')
vim.cmd('OrcaComment')
check(vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil,
  'left (base) side refuses to comment')
vim.cmd('wincmd l')

-- Drift: the anchor is an extmark, so an insertion above moves it, and the
-- next write records the shifted line with the same quoted text.
vim.fn.append(0, 'inserted top line')
require('orca.notes').save()
data = read_notes()
check(data and data.comments[1].line == 3, 'anchor rides an insertion above (2 → 3), got '
  .. tostring(data and data.comments[1].line))
check(data and data.comments[1].quoted == 'line2 CHANGED', 'quoted still describes the anchor line')
vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
require('orca.notes').save()
data = read_notes()
check(data and data.comments[1].line == 2, 'anchor rides the removal back (3 → 2)')
vim.bo.modified = false

-- Range comment: a :'<,'>-style range anchors line..end_line.
vim.cmd('3,4OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'range comment' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
data = read_notes()
check(data and #data.comments == 2, 'second comment lands next to the first')
local ranged
for _, c in ipairs(data and data.comments or {}) do if c.line == 3 then ranged = c end end
check(ranged ~= nil and ranged.end_line == 4, 'range comment records end_line')
check(ranged ~= nil and ranged.id == 2, 'ids increment globally — range comment is #2')
check(count_at(bidx) == '*2', 'panel count is live — *2 after the second comment')

-- Delete: :OrcaCommentDelete anywhere inside the covered range clears it.
vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.cmd('OrcaCommentDelete')
data = read_notes()
check(data and #data.comments == 1 and data.comments[1].line == 2,
  'OrcaCommentDelete removes the covering comment')
check(count_at(bidx) == '*1', 'panel count is live — back to *1 after the delete')

-- Ids never recycle: the next comment after a delete takes a fresh id, so
-- the deleted #2 stays a permanent gap and old #N references can't rebind.
vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'gap prober' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
data = read_notes()
local prober
for _, c in ipairs(data and data.comments or {}) do if c.text == 'gap prober' then prober = c end end
check(prober ~= nil and prober.id == 3, 'deleted id leaves a gap — next comment is #3, got '
  .. tostring(prober and prober.id))
vim.cmd('OrcaCommentDelete')
data = read_notes()
check(data and #data.comments == 1, 'gap prober cleaned up')

-- ======================= navigation (unchanged) =======================

-- The diff pair follows navigation (the session-wide BufEnter handler).
local function count_diff_wins()
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then n = n + 1 end
  end
  return n
end

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
-- The merge-base side on screen: its window and the path it was cut from.
local function left_side()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local n = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if n:find('^orca://') and n ~= 'orca://review' then return w, n end
  end
  return nil, ''
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

-- ================= the pinned panel and its ladder =================

-- The panel is pinned for the session's duration: closing its window puts
-- it straight back, re-rendered, without moving the cursor out of the file
-- under review. A review that lost its map is one navigating blind.
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

-- ==================== session-global navigation keys ====================

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

orca.review('')

-- Close: no orca buffers survive (panel included), diff off everywhere.
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

-- ================== notes round-trip across sessions ==================

-- Orca's write-back lands in the same file: status/resolution set there
-- render under the anchor in the next session, and the explicit range
-- resolves to the same branch key.
data = read_notes()
data.comments[1].status = 'addressed'
data.comments[1].resolution = 'debounced it'
data.comments[1].id = nil -- a file from before ids existed: backfilled on load
vim.fn.writefile({ vim.json.encode(data) }, notes_path)
orca.review('main...feature')
check(panel_statusline() == 'OrcaReview main...feature',
  'explicit range title, got: ' .. tostring(panel_statusline()))
check(count_at(idx_of('src/b%.lua')) == '*1', 'loaded comment already counted in the panel')
orca.open(idx_of('src/b%.lua'))
local marks = vim.api.nvim_buf_get_extmarks(0, NS, 0, -1, { details = true })
check(#marks == 1, 'reloaded comment decorated after restart, got ' .. #marks .. ' extmarks')
local shown = {}
for _, vl in ipairs(marks[1] and marks[1][4].virt_lines or {}) do
  for _, chunk in ipairs(vl) do shown[#shown + 1] = chunk[1] end
end
shown = table.concat(shown, '\n')
check(shown:find('#1 edited thought', 1, true) ~= nil,
  'virtual lines carry the comment text behind its backfilled id')
check(shown:find('addressed', 1, true) ~= nil and shown:find('debounced it', 1, true) ~= nil,
  'virtual lines carry orca\'s status and resolution')
orca.close()

-- Unknown version: the coordination contract fails loud — commenting is
-- blocked and the file is never touched.
vim.fn.writefile({ vim.json.encode({ version = 2, comments = {} }) }, notes_path)
orca.review('')
orca.open(idx_of('src/b%.lua'))
pcall(vim.cmd, 'OrcaComment') -- pcall: the ERROR-level notify throws in headless
check(vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil,
  'unknown notes version blocks commenting')
orca.close()
check(table.concat(vim.fn.readfile(notes_path), '\n'):find('"version":2', 1, true) ~= nil,
  'unknown-version file left untouched')
vim.fn.delete(notes_path)

-- ================= soft-wrap virt_lines + ranged sign =================

-- virt_lines never wrap on their own (each is one screen line, truncated
-- at the window edge), so the plugin soft-wraps each stored line at
-- placement time to the target window's text width.
orca.review('')
orca.open(idx_of('src/b%.lua'))
local rwin = vim.api.nvim_get_current_win()
local rbuf = vim.api.nvim_get_current_buf()
local function virt_chunks()
  local vout = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do vout[#vout + 1] = vl[1][1] end
  end
  return vout
end
local function text_width()
  local info = vim.fn.getwininfo(rwin)[1]
  return info.width - info.textoff
end

local long = ('soft wrap words '):rep(15) .. 'https://example.com/' .. ('x'):rep(90)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { long })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
local wrapped = virt_chunks()
check(#wrapped > 1, 'long comment wraps into multiple virt_lines, got ' .. #wrapped)
data = read_notes()
check(data and data.comments[1].text == long, 'stored text stays unwrapped')

-- Resize re-places through the WinResized → scheduled-refit path. Headless
-- runs never see the real event (it fires from the redraw loop, which a
-- UI-less startup script never enters), so fire the autocmd by hand — the
-- handler's no-v:event fallback refits every window in the tab.
vim.cmd('vertical resize 70')
vim.api.nvim_exec_autocmds('WinResized', {})
drain(function() return #virt_chunks() ~= #wrapped end)
local rewrapped = virt_chunks()
check(#rewrapped > 1 and #rewrapped < #wrapped,
  ('wider window rewraps into fewer chunks (%d -> %d)'):format(#wrapped, #rewrapped))
local fits, prefixed = true, true
for _, chunk in ipairs(rewrapped) do
  if vim.fn.strdisplaywidth(chunk) > text_width() then fits = false end
  if chunk:sub(1, #'┃ ') ~= '┃ ' then prefixed = false end
end
check(fits, 'no wrapped chunk exceeds the window text width (' .. text_width() .. ')')
check(prefixed, 'every continuation chunk keeps the ┃ prefix')

-- Refit preserves drift: sync first, then place at the synced line — an
-- anchor that rode an insertion must not snap back to its stored line.
vim.fn.append(0, 'drift line')
vim.cmd('vertical resize 40')
vim.api.nvim_exec_autocmds('WinResized', {})
drain(function() return #virt_chunks() ~= #rewrapped end)
local drifted = vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, {})[1]
check(drifted and drifted[2] == 2, 'resize refit keeps the drifted anchor (row 2), got '
  .. tostring(drifted and drifted[2]))
vim.api.nvim_buf_set_lines(rbuf, 0, 1, false, {})
vim.bo[rbuf].modified = false
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaCommentDelete')
check(#vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, {}) == 0, 'wrap fixture cleaned up')

-- Ranged comment: ONE extmark spanning line..end_line (no invisible end
-- tracker), and the sign renders on every covered gutter row — the old
-- anchor-only sign left inner range lines bare.
vim.cmd('3,4OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'range text' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
local ranged_marks = vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, { details = true })
check(#ranged_marks == 1, 'range comment is one ranged extmark, got ' .. #ranged_marks)
check(ranged_marks[1] and ranged_marks[1][4].end_row == 3, 'extmark end_row tracks end_line, got '
  .. tostring(ranged_marks[1] and ranged_marks[1][4].end_row))
vim.cmd('redraw')
local function sign_at(lnum)
  local sp = vim.fn.screenpos(rwin, lnum, 1)
  return sp.row > 0 and vim.fn.screenstring(sp.row, sp.col - 2) or '?'
end
check(sign_at(3) == '┃' and sign_at(4) == '┃',
  ('ranged sign covers every spanned row, got [%s][%s]'):format(sign_at(3), sign_at(4)))
check(sign_at(1) ~= '┃', 'row outside the range shows no sign')

-- The single ranged extmark drifts as one unit: an insertion above moves
-- both ends, read back from details.end_row on the next save.
vim.fn.append(0, 'drift line')
require('orca.notes').save()
data = read_notes()
check(data and data.comments[1].line == 4 and data.comments[1].end_line == 5,
  ('ranged anchor rides an insertion (3-4 -> 4-5), got %s-%s'):format(
    tostring(data and data.comments[1].line), tostring(data and data.comments[1].end_line)))
vim.api.nvim_buf_set_lines(rbuf, 0, 1, false, {})
vim.bo[rbuf].modified = false
orca.close()
vim.fn.delete(notes_path)

-- ==================== float comment edit (v2.2) ====================

-- Editing happens in a borderless float over spacer virt_lines: the gap
-- under the anchor stays open (spacers keep the ┃ prefix), float and gap
-- grow with the text, and closing the float restores the real virt_lines
-- whichever way it dies.
orca.review('')
orca.open(idx_of('src/b%.lua'))
local fsrc_win = vim.api.nvim_get_current_win()
local fsrc_buf = vim.api.nvim_get_current_buf()
local function first_mark()
  return vim.api.nvim_buf_get_extmarks(fsrc_buf, NS, 0, -1, { details = true })[1]
end

-- New comment: the input is a float, and a temporary extmark holds the
-- sign + gap while it is open.
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
local fwin = vim.api.nvim_get_current_win()
local fbuf = vim.api.nvim_get_current_buf()
check(vim.api.nvim_win_get_config(fwin).relative == 'editor',
  'comment input opens as an editor-relative float')
check(first_mark() ~= nil, 'temp extmark holds the gap for a new comment')
vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'float seed' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
check(not vim.api.nvim_win_is_valid(fwin), 'float closes on :w')
check(#vim.api.nvim_buf_get_extmarks(fsrc_buf, NS, 0, -1, {}) == 1,
  'temp mark deleted, real mark placed')
data = read_notes()
check(data and data.comments[1].text == 'float seed', 'float :w commits to JSON')

-- Edit: the existing mark swaps its virt_lines for prefix-only spacers,
-- count = the float's text height.
vim.api.nvim_set_current_win(fsrc_win)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
fwin = vim.api.nvim_get_current_win()
fbuf = vim.api.nvim_get_current_buf()
check(table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), '\n') == 'float seed',
  'edit float prefills the existing text')
local spacer_ok = true
for _, vl in ipairs(first_mark()[4].virt_lines or {}) do
  if vl[1][1] ~= '┃ ' then spacer_ok = false end
end
check(spacer_ok, 'edit-time virt_lines are prefix-only spacers')
check(#first_mark()[4].virt_lines == vim.api.nvim_win_get_height(fwin),
  'spacer count equals the float height')

-- Growth: more text -> taller float and more spacers, in lockstep.
vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'grown alpha', 'beta', 'gamma', 'delta' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = fbuf })
check(vim.api.nvim_win_get_height(fwin) == 4,
  'float grows to the text height, got ' .. vim.api.nvim_win_get_height(fwin))
check(#first_mark()[4].virt_lines == 4,
  'spacer count grows in lockstep, got ' .. #first_mark()[4].virt_lines)

-- :w commits: real virt_lines back with the new text.
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
local restored = {}
for _, vl in ipairs(first_mark()[4].virt_lines or {}) do restored[#restored + 1] = vl[1][1] end
check(table.concat(restored, '\n'):find('gamma', 1, true) ~= nil,
  'commit restores real virt_lines with the edited text')
data = read_notes()
check(data and data.comments[1].text == 'grown alpha\nbeta\ngamma\ndelta', 'edited text saved to JSON')

-- :q aborts an edit: original virt_lines back, stored text untouched.
vim.api.nvim_set_current_win(fsrc_win)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
fbuf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'discarded' })
vim.bo[fbuf].modified = false
vim.cmd('quit')
restored = {}
for _, vl in ipairs(first_mark()[4].virt_lines or {}) do restored[#restored + 1] = vl[1][1] end
check(table.concat(restored, '\n'):find('gamma', 1, true) ~= nil,
  ':q abort restores the original virt_lines')
data = read_notes()
check(data and data.comments[1].text == 'grown alpha\nbeta\ngamma\ndelta',
  'abort leaves stored text untouched')

-- :q on a *new* comment: temp mark gone, nothing recorded.
vim.api.nvim_set_current_win(fsrc_win)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd('OrcaComment')
check(#vim.api.nvim_buf_get_extmarks(fsrc_buf, NS, 0, -1, {}) == 2,
  'new comment holds a temp mark while open')
vim.cmd('quit')
check(#vim.api.nvim_buf_get_extmarks(fsrc_buf, NS, 0, -1, {}) == 1,
  ':q on a new comment deletes the temp mark')
data = read_notes()
check(data and #data.comments == 1, 'aborted new comment never reaches the file')

-- Session close with a float open: float gone, no dangling autocmds.
vim.api.nvim_set_current_win(fsrc_win)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
fwin = vim.api.nvim_get_current_win()
orca.close()
check(not vim.api.nvim_win_is_valid(fwin), 'session close takes the open float with it')
check(#vim.api.nvim_buf_get_extmarks(fsrc_buf, NS, 0, -1, {}) == 0,
  'no extmarks survive close with a float open')
-- (builtin matchparen owns a '*' WinScrolled; the float's autocmds are the
-- window-id-patterned ones)
local dangling = 0
for _, a in ipairs(vim.api.nvim_get_autocmds({ event = { 'WinScrolled', 'WinClosed' } })) do
  if tostring(a.pattern):match('^%d+$') then dangling = dangling + 1 end
end
check(dangling == 0, 'no dangling float autocmds after close, got ' .. dangling)

-- Forced split path (the 0.9 fallback) still runs the same contract.
require('orca.notes').float_input = false
orca.review('')
orca.open(idx_of('src/b%.lua'))
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
check(vim.api.nvim_win_get_config(0).relative == '', 'forced fallback opens a split, not a float')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'split text' })
-- The keystroke guard is the editor's, not the float's: the fallback split
-- holds a file change the same way.
local split_win = vim.api.nvim_get_current_win()
orca.prev()
check(vim.api.nvim_get_current_win() == split_win,
  'the split fallback holds the next-file key too')
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
data = read_notes()
check(data and data.comments[1].text == 'split text', 'split fallback still commits')
orca.close()
require('orca.notes').float_input = true
vim.fn.delete(notes_path)

-- ============ a file change with the editor open (v2.3) ============

-- The comment editor is glued to the file under it: the gap it floats in
-- is an extmark in that buffer, and its screen position is that window's
-- scroll. A next-file key pressed mid-comment used to leave it hanging
-- over the next file — still open, still owning state.input, still
-- anchored to a pair that had been torn down under it.
orca.review('')
local navidx = idx_of('c%.txt')
orca.open(navidx)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaComment')
local nav_win = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'mid sentence' })
orca.next()
check(vim.api.nvim_win_is_valid(nav_win) and vim.api.nvim_get_current_win() == nav_win,
  'unwritten text: the next-file key leaves you in the editor')
check(panel_cur() == navidx,
  'and the review stays on the file, row ' .. tostring(panel_cur()))

-- Committing releases it: the same key now walks.
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
orca.next()
check(panel_cur() == navidx + 1,
  'once written, the walk goes through, row ' .. tostring(panel_cur()))

-- An editor with nothing typed into it is not words worth keeping: it
-- closes and the walk continues.
orca.open(navidx)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaComment')
nav_win = vim.api.nvim_get_current_win()
orca.next()
check(not vim.api.nvim_win_is_valid(nav_win), 'an untouched editor closes on the file change')
check(panel_cur() == navidx + 1, 'and the walk goes through, row ' .. tostring(panel_cur()))

-- The same for a comment that does not exist yet: its temporary mark goes
-- with it, leaving the file as clean as if it had been :q'd.
orca.open(idx_of('src/b%.lua'))
local nav_src = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd('OrcaComment')
nav_win = vim.api.nvim_get_current_win()
orca.prev()
check(not vim.api.nvim_win_is_valid(nav_win), 'an untouched new comment closes too')
check(#vim.api.nvim_buf_get_extmarks(nav_src, NS, 0, -1, {}) == 0,
  'and its temporary mark goes with it')

-- Nothing of the abandoned editor is left holding the slot: the next
-- :OrcaComment is the new file's, not a jump back into the old one.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaComment')
check(vim.api.nvim_buf_get_name(0):find('orca://comment/renamed%-to') ~= nil,
  'the next comment belongs to the new file, got ' .. vim.api.nvim_buf_get_name(0))
vim.cmd('quit')
orca.close()
vim.fn.delete(notes_path)

-- ================= comment navigation: review-wide =================

-- Comments are orca's own extmarks — nothing native can walk them. The
-- walk is review-wide: file order, then line, crossing files via the pair.
orca.review('')
orca.open(idx_of('c%.txt'))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'walk one' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
orca.open(idx_of('src/b%.lua'))
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'walk two' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
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

-- ============== the restore snippet + eviction-proofing ==============

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
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
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

-- ==================== hidden groups ====================

-- Hiding is a view over the entry list, not a filter on it: the folded
-- files stay full session entries (they open, they anchor comments, they
-- come back), and the summary row keeps the omission on screen.
local function summary_row()
  local ls = panel_lines()
  return ls[#ls]
end

orca.review('')
check(summary_row():find('<CR> shows', 1, true) ~= nil,
  'summary row says what <CR> does, got: ' .. summary_row())
check(panel_lines()[7]:find('^ …') ~= nil, 'summary row wears the … status column')

-- The walk stops at the last *visible* file: what a group folded away is
-- not something :OrcaReviewNext lands on.
orca.open(6) -- src/café.lua, the last visible row
orca.next()
check(panel_cur() == 6, 'next stops at the last visible file, got ' .. tostring(panel_cur()))

-- <CR> on the summary row is the toggle. The row survives in both states,
-- inverted, so the way back is never something you have to know about.
vim.api.nvim_set_current_win(panel_win())
keys('7G')
keys('<CR>')
check(#panel_lines() == 9, 'showing: eight files + the summary row, got ' .. #panel_lines())
check(idx_of('src/z_test%.lua') ~= nil and idx_of('tests/b_spec%.lua') ~= nil,
  'both grouped files take rows when shown')
check(summary_row():find('<CR> hides 2 (tests)', 1, true) ~= nil,
  'shown state offers to hide, got: ' .. summary_row())
check(panel_cur() == 6, 'the current file keeps its row across the toggle')
-- and now the walk crosses them
orca.open(idx_of('src/caf'))
orca.next()
check(vim.api.nvim_buf_get_name(0):find('z_test.lua', 1, true) ~= nil,
  'shown: the walk enters the grouped files, got ' .. vim.api.nvim_buf_get_name(0))
-- Toggling back folds them away again — except the one you are in: the
-- panel has to be able to mark the current file, and a review should not
-- hide the thing on your screen.
vim.api.nvim_set_current_win(panel_win())
keys('9G')
keys('<CR>')
check(idx_of('src/z_test%.lua') ~= nil,
  'the file you are in keeps its row while its group is hidden')
check(#panel_lines() == 8, 'seven rows + the summary with the current file pinned, got '
  .. #panel_lines())
orca.open(idx_of('src/b%.lua'))
check(#panel_lines() == 7 and idx_of('src/z_test%.lua') == nil,
  'leaving it folds it back, got ' .. #panel_lines())

-- A hidden file is still a full entry: :edit opens its pair, because the
-- navigation follower resolves it by path out of the whole entry list.
vim.cmd('edit src/z_test.lua')
drain(function() return count_diff_wins() == 2 and idx_of('src/z_test%.lua') ~= nil end)
check(idx_of('src/z_test%.lua') ~= nil, 'a hidden file still opens by :edit, and shows while current')
check(count_diff_wins() == 2, ':edit of a hidden file opens its diff pair')

-- A comment pins it visible for good: the moment you have said something
-- about a file, no group takes it off the list.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'pins it visible' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
orca.open(1) -- leave it: without the comment it would fold away again
check(idx_of('src/z_test%.lua') ~= nil, 'a commented file stays visible after you leave it')
check(count_at(idx_of('src/z_test%.lua')) == '*1', 'and carries its comment count')
check(summary_row():find('1 file hidden (tests)', 1, true) ~= nil,
  'the summary drops to the one still folded, got: ' .. summary_row())

-- Deleting the last comment folds it back — the pin is the comment, not a
-- sticky flag.
orca.open(idx_of('src/z_test%.lua'))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaCommentDelete')
orca.open(1)
check(idx_of('src/z_test%.lua') == nil, 'deleting the last comment folds the file back')
check(summary_row():find('2 files hidden', 1, true) ~= nil, 'summary back to two')
orca.close()
vim.fn.delete(notes_path)

-- The `hidden` mapping action: the toggle without going to the panel.
vim.g.orca_mappings = { hidden = '<leader>h' }
orca.review('')
orca.open(idx_of('src/b%.lua'))
check(vim.fn.maparg('<leader>h', 'n', false, true).desc
  == 'orca: show or hide the grouped files',
  'orca_mappings: hidden binds for the whole session, diff pair included')
keys('\\h')
check(#panel_lines() == 9, 'the hidden key shows them from inside a diff, got ' .. #panel_lines())
keys('\\h')
check(#panel_lines() == 7, 'and hides them again, got ' .. #panel_lines())
orca.close()
vim.g.orca_mappings = nil

-- vim.g.orca_review_hidden = false opts out: everything listed, the row
-- still there offering to hide.
vim.g.orca_review_hidden = false
orca.review('')
check(#panel_lines() == 9, 'orca_review_hidden = false lists everything, got ' .. #panel_lines())
check(summary_row():find('<CR> hides 2', 1, true) ~= nil, 'opted out, the row offers to hide')
orca.close()
vim.g.orca_review_hidden = nil

-- Groups are configurable and additive: a new key adds a group, every
-- group rides the one toggle, and the summary breaks several down.
vim.g.orca_review_groups = { docs = { '*.txt' } }
orca.review('')
check(idx_of('a%.txt') == nil and idx_of('c%.txt') == nil and idx_of('renamed') == nil,
  'a custom group folds its files away too')
check(summary_row():find('5 files hidden (3 docs, 2 tests)', 1, true) ~= nil,
  'several groups break down, alphabetically, got: ' .. summary_row())
orca.close()

-- The one place the default overrides itself: hiding everything would
-- open a review with nothing in it, so it shows everything and says so.
vim.g.orca_review_groups = { tests = { '*' } }
local msgs = {}
local real_notify = vim.notify
vim.notify = function(m, ...) msgs[#msgs + 1] = m; return real_notify(m, ...) end
orca.review('')
vim.notify = real_notify
check(#panel_lines() == 9, 'all-grouped review lists everything, got ' .. #panel_lines())
check(table.concat(msgs, '\n'):find('showing all 8', 1, true) ~= nil,
  'and says why, got: ' .. table.concat(msgs, ' | '))
orca.close()
vim.g.orca_review_groups = nil

-- A malformed group config warns and falls back to the defaults rather
-- than hiding nothing (or everything) in silence.
vim.g.orca_review_groups = { tests = 'tests/' }
msgs = {}
vim.notify = function(m, ...) msgs[#msgs + 1] = m; return real_notify(m, ...) end
orca.review('')
vim.notify = real_notify
check(table.concat(msgs, '\n'):find('expected a list of globs', 1, true) ~= nil,
  'bad group config warns, got: ' .. table.concat(msgs, ' | '))
check(#panel_lines() == 7, 'and the shipped defaults still apply, got ' .. #panel_lines())
orca.close()
vim.g.orca_review_groups = nil

-- ==================== paths outside ASCII ====================

-- Without -z, git C-quotes any name outside ASCII — "src/caf\303\251.lua",
-- quotes included — and that is the path the session used to carry: shown
-- escaped, and naming no file on disk.
orca.review('')
local cafe = idx_of('src/café%.lua')
check(cafe ~= nil, 'the panel row shows the name as it is, got '
  .. table.concat(panel_lines(), ' ;; '))
orca.open(cafe)
check(vim.api.nvim_buf_get_name(0):sub(-#'src/café.lua') == 'src/café.lua'
  and vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'olá' and vim.wo.diff,
  'it opens as a pair on the real file, got ' .. vim.api.nvim_buf_get_name(0))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'accented' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
data = read_notes()
check(data and data.comments[1] and data.comments[1].file == 'src/café.lua'
  and data.comments[1].quoted == 'olá',
  'and a comment anchors to it under its real name')
orca.close()
vim.fn.delete(notes_path)

-- ==================== a :cd mid-session ====================

-- The cwd is the user's to move. Every git query the session makes asks
-- the reviewed repository, not wherever :cd went: the pair's merge-base
-- side, and the head sha the notes file records — which used to be the
-- other repository's HEAD, or nothing at all outside one.
local here = vim.fn.getcwd()
orca.review('')
orca.open(1)
vim.cmd('cd ' .. vim.fn.fnameescape(vim.fn.fnamemodify(root, ':h')))
orca.open(idx_of('src/b%.lua'))
local cd_left = vim.api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr('h')))
check(table.concat(vim.api.nvim_buf_get_lines(cd_left, 0, -1, false), '\n') == 'line1\nline2\nline3',
  'after :cd out of the repo, the next pair still shows the merge base')
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after cd' })
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
data = read_notes()
local feature_sha = vim.fn.systemlist({ 'git', '-C', here, 'rev-parse', 'HEAD' })[1]
check(data and data.head == feature_sha,
  'and the notes file records the reviewed repo\'s head, got ' .. tostring(data and data.head))
orca.close()
vim.cmd('cd ' .. vim.fn.fnameescape(here))
vim.fn.delete(notes_path)

-- ==================== a :OrcaReview that goes nowhere ====================

-- A range that resolves to nothing is refused before the running session
-- is touched. It used to close the session first and fail after, leaving
-- no review at all — panel, pair and position gone over a typo.
local function notices(fn)
  local got = {}
  local real = vim.notify
  vim.notify = function(m) got[#got + 1] = m end
  pcall(fn)
  vim.notify = real
  return table.concat(got, ' | ')
end
orca.review('')
orca.open(idx_of('src/b%.lua'))
local bad = notices(function() orca.review('nope...HEAD') end)
check(bad:find('nope', 1, true) ~= nil, 'an unknown base is an error, got: ' .. bad)
check(panel_win() ~= nil and panel_statusline() == 'OrcaReview main...HEAD'
  and count_diff_wins() == 2 and panel_cur() == idx_of('src/b%.lua'),
  'and the running session is still up, pair and panel both')
-- Two dots are a different diff (trunk's side included), not a typo for
-- three; the refusal says so by name rather than with a merge-base error.
local two = notices(function() orca.review('main..HEAD') end)
check(two:find('two-dot range', 1, true) ~= nil and two:find('main...HEAD', 1, true) ~= nil,
  'a two-dot range is refused by name, got: ' .. two)
check(panel_statusline() == 'OrcaReview main...HEAD', 'and leaves the session alone too')
orca.close()

-- The right side of a pair is the working tree, so reviewing a head that
-- is not checked out showed this worktree's files under another branch's
-- name, and filed the comments in that branch's notes. Refused, before any
-- notes file exists.
local other_path = root .. '/.orca/review-notes/other.json'
local elsewhere = notices(function() orca.review('main...other') end)
check(elsewhere:find('other is not checked out here', 1, true) ~= nil and panel_buf() == nil,
  'a head that is not checked out is refused, got: ' .. elsewhere)
check(vim.fn.filereadable(other_path) == 0, 'and no notes file is created for it')
local feature_wt = notices(function() orca.review('other...feature') end)
check(feature_wt == '' or feature_wt:find('not checked out', 1, true) == nil,
  'the checked-out branch named explicitly is fine, got: ' .. feature_wt)
orca.close()
vim.fn.system({ 'git', 'worktree', 'add', '-q', vim.fn.fnamemodify(root, ':p') .. 'other-wt', 'other' })
local pointed = notices(function() orca.review('main...other') end)
check(pointed:find(root .. '/other-wt', 1, true) ~= nil,
  'and one checked out elsewhere is pointed at its worktree, got: ' .. pointed)
vim.fn.system({ 'git', 'worktree', 'remove', '--force', root .. '/other-wt' })

-- ==================== git plumbing ====================

-- git writes warnings to stderr on a run that succeeds — here, rename
-- detection giving up past diff.renameLimit — and those must not arrive as
-- output. They used to, and became panel rows naming files that don't exist.
vim.fn.system({ 'git', 'config', 'diff.renameLimit', '1' })
check(vim.fn.system({ 'git', 'diff', '--name-status', '-M', 'main...HEAD' }):find('warning:', 1, true) ~= nil,
  'renameLimit=1 makes git warn on this fixture (the precondition)')
vim.g.orca_review_hidden = false
orca.review('')
local warned = false
for _, l in ipairs(panel_lines()) do
  if l:find('warning', 1, true) then warned = true end
end
check(not warned and #panel_lines() == 9,
  'stderr warnings are not files: eight rows + the summary, got ' .. table.concat(panel_lines(), ' ;; '))
orca.close()
vim.g.orca_review_hidden = nil
vim.fn.system({ 'git', 'config', '--unset', 'diff.renameLimit' })

out(failed == 0 and 'SMOKE PASS' or ('SMOKE FAIL (' .. failed .. ')'))
if failed > 0 then vim.cmd('cquit') end
