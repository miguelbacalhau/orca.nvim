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
-- 1-based row of the entry whose panel line matches pat (a lua pattern) —
-- rows follow entry order, the old quickfix idx.
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
check(#lines == 5, 'five changed files, got ' .. #lines)
check(not table.concat(lines, ';'):find('trunk%-only'), 'merge-base diff excludes trunk-only.txt')
check(table.concat(lines, ';'):find('R  renamed%-from%.txt → renamed%-to%.txt') ~= nil,
  'rename shown as R old → new')
check(table.concat(lines, ';'):find('M  img%.bin %(binary%)') ~= nil, 'binary file marked (binary)')
check(vim.bo[panel_buf()].filetype == 'orca-panel', 'panel filetype is orca-panel')
check(vim.bo[panel_buf()].modifiable == false, 'panel buffer is not modifiable')
check(vim.api.nvim_win_get_height(panel_win()) == 5, 'panel height tracks the entry count (5)')
local lay = vim.fn.winlayout()
check(lay[1] == 'col' and lay[2][#lay[2]][1] == 'leaf' and lay[2][#lay[2]][2] == panel_win(),
  'panel is the full-width bottom strip')
check(status_hl(idx_of('a%.txt')) == 'OrcaPanelRemoved', 'D letter highlighted OrcaPanelRemoved')
check(status_hl(idx_of('c%.txt')) == 'OrcaPanelAdded', 'A letter highlighted OrcaPanelAdded')
check(status_hl(idx_of('renamed')) == 'OrcaPanelRenamed', 'R letter highlighted OrcaPanelRenamed')
check(status_hl(idx_of('src/b%.lua')) == 'OrcaPanelChanged', 'M letter highlighted OrcaPanelChanged')

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
check(#panel_lines() == 5 and panel_win() ~= nil, 'collapse keeps the panel')

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

-- ==================== panel toggle ladder ====================

-- Closing the panel window hides the view; the session lives, and
-- :OrcaReviewPanel is the discoverable, always-alive way back (where
-- :colder was manual, position-dependent, and mortal).
orca.open(1)
vim.api.nvim_win_close(panel_win(), true)
check(panel_win() == nil, 'closing the panel window hides the view')
check(panel_buf() ~= nil, 'panel buffer survives its window')
orca.next() -- navigation keeps working with the panel hidden
check(panel_cur() == 2, 'hidden panel keeps rendering session state')
vim.cmd('OrcaReviewPanel')
check(panel_win() ~= nil and vim.api.nvim_get_current_win() == panel_win(),
  'ladder: hidden → open and focus')
check(vim.api.nvim_win_get_cursor(panel_win())[1] == 2,
  'reopened panel parks the cursor on the current file')
vim.cmd('OrcaReviewPanel')
check(panel_win() == nil, 'ladder: focused → close the window')
vim.cmd('OrcaReviewPanel') -- back open, focused
vim.cmd('wincmd k')
check(vim.api.nvim_get_current_win() ~= panel_win(), 'moved focus off the panel')
vim.cmd('OrcaReviewPanel')
check(vim.api.nvim_get_current_win() == panel_win(), 'ladder: visible but unfocused → focus')

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
vim.cmd('write')
drain(function() return vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) == nil end)
data = read_notes()
check(data and data.comments[1].text == 'split text', 'split fallback still commits')
orca.close()
require('orca.notes').float_input = true
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
check(vim.fn.maparg(']q', 'n', false, true).buffer == 1, 'restored ]q is buffer-local on the pair')
keys('3]q')
check(panel_cur() == 4, '3]q moves three files, got ' .. tostring(panel_cur()))
keys('9]q')
check(panel_cur() == 5, 'overshooting count clamps to the last file, got ' .. tostring(panel_cur()))
keys(']q')
check(panel_cur() == 5, 'plain ]q at the edge stays put, got ' .. tostring(panel_cur()))
keys('2[q')
check(panel_cur() == 3, '2[q moves two files back, got ' .. tostring(panel_cur()))

-- The point of the change: a foreign quickfix list mid-session (:grep, LSP
-- references) changes nothing about the panel or the keys — where it used
-- to evict the review list and demand :colder.
orca.open(1)
vim.fn.setqflist({}, ' ', { title = 'foreign', items = {
  { filename = 'unchanged.txt', lnum = 1, text = 'one' },
  { filename = 'unchanged.txt', lnum = 1, text = 'two' },
} })
vim.cmd('botright copen')
check(#panel_lines() == 5 and panel_win() ~= nil, 'foreign qf list leaves the panel untouched')
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
check(vim.fn.maparg(')f', 'n', false, true).buffer == 1, 'orca_mappings: next bound to )f')
check(vim.fn.maparg(']q', 'n', false, true).buffer ~= 1, 'orca_mappings: ]q stays unbound')
check(vim.fn.maparg('<leader>v', 'n', false, true).buffer == 1, 'orca_mappings: opt-in comment binding attaches')
check(vim.fn.maparg('<leader>v', 'x', false, true).buffer == 1, 'orca_mappings: comment binding also maps visual mode')
check(vim.fn.maparg(')c', 'n', false, true).buffer == 1, 'orca_mappings: opt-in comment_next binding attaches')
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
-- The panel action rides the same ladder as :OrcaReviewPanel.
keys('\\p')
check(vim.api.nvim_get_current_win() == panel_win(), 'panel key focuses the visible panel')
keys('\\p')
check(panel_win() == nil, 'panel key closes the focused panel')
keys('\\p') -- focus fell back into a session buffer, which carries the map
check(panel_win() ~= nil and vim.api.nvim_get_current_win() == panel_win(),
  'panel key reopens from a session buffer')
orca.close()
check(vim.fn.maparg(')f', 'n', false, true).buffer ~= 1, 'buffer-local maps removed at close')

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

out(failed == 0 and 'SMOKE PASS' or ('SMOKE FAIL (' .. failed .. ')'))
if failed > 0 then vim.cmd('cquit') end
