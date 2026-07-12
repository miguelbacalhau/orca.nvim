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

-- A competing FileType-qf autocmd registered BEFORE the session starts,
-- mapping <CR> back to itself — exactly what qf ftplugins and plugins like
-- mini.jump2d's <CR> revert do on every copen. The session's own re-assert
-- autocmd registers later, so it must win every same-event race; the
-- keystroke checks further down are the regression test for that.
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'qf',
  callback = function(ev)
    vim.keymap.set('n', '<CR>', '<CR>', { buffer = ev.buf, nowait = true })
  end,
})

local orca = require('orca')
local NS = vim.api.nvim_create_namespace('orca_notes')

-- Bare review: trunk...HEAD, trunk resolved from the common dir (main).
orca.review('')
local qf = vim.fn.getqflist({ id = 0, items = true, title = true, size = true })
local orca_qfid = qf.id
check(qf.title == 'OrcaReview main...HEAD', 'qf title is OrcaReview main...HEAD, got: ' .. qf.title)
check(qf.size == 5, 'five changed files, got ' .. qf.size)
local texts = {}
for i, item in ipairs(qf.items) do
  texts[i] = item.text .. ' | ' .. vim.fn.fnamemodify(vim.fn.bufname(item.bufnr), ':t')
end
out('LIST ' .. table.concat(texts, ' ;; '))
-- trunk-only.txt (trunk moved after branch point) must NOT be in the list
check(not table.concat(texts, ';'):find('trunk%-only'), 'merge-base diff excludes trunk-only.txt')
check(table.concat(texts, ';'):find('renamed%-from%.txt → renamed%-to%.txt') ~= nil, 'rename shown as old → new')
check(table.concat(texts, ';'):find('%(binary%)') ~= nil, 'binary file marked (binary)')

-- The quickfix entry index of the file matching pat, in orca's list.
local function idx_of(pat)
  local q = vim.fn.getqflist({ id = 0, items = true })
  for i, item in ipairs(q.items) do
    if vim.fn.bufname(item.bufnr):find(pat, 1, true) then return i end
  end
end

-- Review auto-opens the first file (deleted a.txt): both sides scratch, diff on.
local wins = vim.api.nvim_tabpage_list_wins(0)
local diffwins, scratchbufs = 0, 0
for _, w in ipairs(wins) do
  if vim.wo[w].diff then diffwins = diffwins + 1 end
  local b = vim.api.nvim_win_get_buf(w)
  if vim.bo[b].buftype == 'nofile' then scratchbufs = scratchbufs + 1 end
end
check(#wins == 3, 'three windows (left, right, quickfix), got ' .. #wins)
check(diffwins == 2, 'two windows in diff mode, got ' .. diffwins)
check(scratchbufs == 2, 'deleted file: both sides scratch, got ' .. scratchbufs)

-- Regression: the qf <CR> map survives the competing FileType autocmd and
-- every list refresh. Only keystroke-level simulation reproduces the
-- clobber — API calls bypass the mapping entirely.
vim.cmd('copen')
keys('2G')
keys('<CR>')
local cur = vim.api.nvim_buf_get_name(0)
check(cur:find('c.txt', 1, true) ~= nil, '<CR> on entry 2 opens its pair despite competing FileType-qf map, got ' .. cur)
check(vim.wo.diff, 'entry 2 right window is in diff mode')

-- Modified file: right side is the real working-tree buffer, left scratch.
local bidx = idx_of('src/b.lua')
orca.open(bidx)
local name = vim.api.nvim_buf_get_name(0)
check(name:find('src/b.lua', 1, true) ~= nil, 'right side is working-tree src/b.lua, got ' .. name)
check(vim.bo.buftype == '', 'right side is a real buffer')
check(vim.wo.diff, 'right window in diff mode')
check(vim.fn.maparg(']q', 'n', false, true).buffer == 1, ']q is buffer-local on the right side')
-- The default surface is native keys only — nothing leader-shaped ships.
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
check(#vim.api.nvim_buf_get_extmarks(0, NS, 0, -1, {}) == 1, 'comment shown as an extmark in the buffer')

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

-- Delete: :OrcaCommentDelete anywhere inside the covered range clears it.
vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.cmd('OrcaCommentDelete')
data = read_notes()
check(data and #data.comments == 1 and data.comments[1].line == 2,
  'OrcaCommentDelete removes the covering comment')

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
-- the session alive.
orca.open(bidx) -- src/b.lua; focus on the right side
vim.cmd('edit unchanged.txt')
local shown_orca = 0
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):find('^orca://') then
    shown_orca = shown_orca + 1
  end
end
check(count_diff_wins() == 0, 'collapse: no window left in diff mode, got ' .. count_diff_wins())
check(shown_orca == 0, 'collapse: no orca:// buffer displayed')
check(#vim.api.nvim_tabpage_list_wins(0) == 2, 'collapse: left split closed (qf + wandered window)')
check(vim.api.nvim_buf_get_name(0):find('unchanged.txt', 1, true) ~= nil, 'collapse leaves the wandered-to buffer alone')
check(vim.fn.getqflist({ size = true }).size == 5, 'collapse keeps the quickfix list')

-- Entering a changed file from the collapsed state reopens its pair around
-- the window the user is in, quickfix selection synced. Navigation-driven
-- opens are deferred one tick (mid-:close splits are illegal), so drain
-- the event loop before asserting.
vim.cmd('edit c.txt')
drain(function() return count_diff_wins() == 2 end)
check(count_diff_wins() == 2, ':edit of a changed file reopens its pair, diff wins: ' .. count_diff_wins())
check(vim.api.nvim_buf_get_name(0):find('c.txt', 1, true) ~= nil, 'reopened pair holds the entered file')
check(vim.fn.getqflist({ idx = 0 }).idx == 2, 'qf selection synced to the entered file, got ' .. vim.fn.getqflist({ idx = 0 }).idx)

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
local before_idx = vim.fn.getqflist({ idx = 0 }).idx
orca.next()
check(vim.fn.getqflist({ idx = 0 }).idx == before_idx + 1, ':OrcaReviewNext resumes the walk after collapse/reopen')
check(count_diff_wins() == 2, 'walk resumed with a live diff pair')

-- ]q/[q honor a count (the native contract): 3]q moves three files, an
-- overshooting count clamps at the list edge, the bare edge case keeps the
-- polite message and stays put.
local function qfidx() return vim.fn.getqflist({ idx = 0 }).idx end
orca.open(1)
keys('3]q')
check(qfidx() == 4, '3]q moves three files, got ' .. qfidx())
keys('9]q')
check(qfidx() == 5, 'overshooting count clamps to the last file, got ' .. qfidx())
keys(']q')
check(qfidx() == 5, 'plain ]q at the edge stays put, got ' .. qfidx())
keys('2[q')
check(qfidx() == 3, '2[q moves two files back, got ' .. qfidx())

-- List-identity guard: a foreign list landing in the qf window mid-session
-- gets native behavior from orca's keys, not a hijacked M.open.
orca.open(1)
vim.fn.setqflist({}, ' ', { title = 'foreign', items = {
  { filename = 'unchanged.txt', lnum = 1, text = 'one' },
  { filename = 'unchanged.txt', lnum = 1, text = 'two' },
} })
vim.cmd('copen')
keys('1G')
keys('<CR>')
check(vim.api.nvim_buf_get_name(0):find('unchanged.txt', 1, true) ~= nil,
  'guard: <CR> on a foreign list does the stock jump, got ' .. vim.api.nvim_buf_get_name(0))
vim.cmd('copen')
keys(']q')
check(qfidx() == 2 and vim.api.nvim_buf_get_name(0):find('unchanged.txt', 1, true) ~= nil,
  'guard: ]q on a foreign list runs :cnext, foreign idx ' .. qfidx())
vim.cmd('silent colder') -- back to orca's list for the close checks

-- Close: no scratch buffers survive, diff off everywhere, qf list stays.
orca.close()
local leftovers = 0
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b):find('^orca://') then
    leftovers = leftovers + 1
  end
end
check(leftovers == 0, 'no orca:// scratch buffers survive close')
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  check(not vim.wo[w].diff, 'diff off in window ' .. w)
end
check(vim.fn.getqflist({ size = true }).size == 5, 'quickfix list left in place')
check(vim.fn.maparg(']q', 'n', false, true).buffer ~= 1, 'buffer-local maps removed from real buffer')
check(vim.fn.filereadable(notes_path) == 1, 'notes file survives close — that is the point')

-- ================== notes round-trip across sessions ==================

-- Orca's write-back lands in the same file: status/resolution set there
-- render under the anchor in the next session, and the explicit range
-- resolves to the same branch key.
data = read_notes()
data.comments[1].status = 'addressed'
data.comments[1].resolution = 'debounced it'
vim.fn.writefile({ vim.json.encode(data) }, notes_path)
orca.review('main...feature')
qf = vim.fn.getqflist({ title = true })
check(qf.title == 'OrcaReview main...feature', 'explicit range title, got: ' .. qf.title)
orca.open(idx_of('src/b.lua'))
local marks = vim.api.nvim_buf_get_extmarks(0, NS, 0, -1, { details = true })
check(#marks == 1, 'reloaded comment decorated after restart, got ' .. #marks .. ' extmarks')
local shown = {}
for _, vl in ipairs(marks[1] and marks[1][4].virt_lines or {}) do
  for _, chunk in ipairs(vl) do shown[#shown + 1] = chunk[1] end
end
shown = table.concat(shown, '\n')
check(shown:find('edited thought', 1, true) ~= nil, 'virtual lines carry the comment text')
check(shown:find('addressed', 1, true) ~= nil and shown:find('debounced it', 1, true) ~= nil,
  'virtual lines carry orca\'s status and resolution')
orca.close()

-- Unknown version: the coordination contract fails loud — commenting is
-- blocked and the file is never touched.
vim.fn.writefile({ vim.json.encode({ version = 2, comments = {} }) }, notes_path)
orca.review('')
orca.open(idx_of('src/b.lua'))
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
orca.open(idx_of('src/b.lua'))
local rwin = vim.api.nvim_get_current_win()
local rbuf = vim.api.nvim_get_current_buf()
local function virt_chunks()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do out[#out + 1] = vl[1][1] end
  end
  return out
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

-- vim.g.orca_mappings resolves at session start: per-action override,
-- per-action disable, untouched actions keep their defaults, and the
-- unbound-by-default comment attaches (n and x) when the user opts in.
vim.g.orca_mappings = { next = ')f', prev = false, comment = '<leader>v' }
orca.review('')
check(vim.fn.maparg(')f', 'n', false, true).buffer == 1, 'orca_mappings: next remapped to )f')
check(vim.fn.maparg(']q', 'n', false, true).buffer ~= 1, 'orca_mappings: default ]q gone when remapped')
check(vim.fn.maparg('[q', 'n', false, true).buffer ~= 1, 'orca_mappings: prev = false disables the map')
check(vim.fn.maparg('<leader>v', 'n', false, true).buffer == 1, 'orca_mappings: opt-in comment binding attaches')
check(vim.fn.maparg('<leader>v', 'x', false, true).buffer == 1, 'orca_mappings: comment binding also maps visual mode')
-- and the configured key still opens the comment input (default mapleader
-- is backslash, so <leader>v arrives as \v)
orca.open(idx_of('src/b.lua'))
keys('\\v')
check(vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) ~= nil,
  'configured comment key opens the input, got ' .. vim.api.nvim_buf_get_name(0))
vim.cmd('quit') -- abort: nothing typed, nothing written
orca.close()

-- setup() is sugar over the same variable; false drops every map, and the
-- stock qf <CR> still opens pairs through the navigation follower.
orca.setup({ mappings = false })
check(vim.g.orca_mappings == false, 'setup({mappings = ...}) writes vim.g.orca_mappings')
orca.review('')
check(vim.fn.maparg(')f', 'n', false, true).buffer ~= 1
  and vim.fn.maparg(']q', 'n', false, true).buffer ~= 1, 'mappings = false: no session maps set')
vim.cmd('copen')
check(vim.fn.maparg('<CR>', 'n', false, true).desc == nil, 'mappings = false: qf <CR> not claimed')
keys('2G')
keys('<CR>')
drain(function() return count_diff_wins() == 2 end)
check(count_diff_wins() == 2, 'mappings = false: stock qf <CR> still opens the pair via BufEnter follow')
orca.close()
vim.g.orca_mappings = nil

out(failed == 0 and 'SMOKE PASS' or ('SMOKE FAIL (' .. failed .. ')'))
if failed > 0 then vim.cmd('cquit') end
