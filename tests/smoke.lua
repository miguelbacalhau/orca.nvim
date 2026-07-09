-- Headless smoke test for orca.nvim. Run by tests/run.sh from inside the
-- feature worktree of the disposable bare-with-worktrees fixture.
local function out(s) io.write(s .. '\n') end
local failed = 0
local function check(cond, label)
  if cond then out('OK   ' .. label) else failed = failed + 1; out('FAIL ' .. label) end
end
local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'x', false)
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

-- Bare review: trunk...HEAD, trunk resolved from the common dir (main).
orca.review('')
local qf = vim.fn.getqflist({ id = 0, items = true, title = true, size = true })
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
qf = vim.fn.getqflist({ id = 0, items = true })
local bidx
for i, item in ipairs(qf.items) do
  if vim.fn.bufname(item.bufnr):find('src/b.lua', 1, true) then bidx = i end
end
orca.open(bidx)
local name = vim.api.nvim_buf_get_name(0)
check(name:find('src/b.lua', 1, true) ~= nil, 'right side is working-tree src/b.lua, got ' .. name)
check(vim.bo.buftype == '', 'right side is a real buffer')
check(vim.wo.diff, 'right window in diff mode')
check(vim.fn.maparg(']f', 'n', false, true).buffer == 1, ']f is buffer-local on the right side')
-- left side content is the merge-base version
local lwin = vim.fn.win_getid(vim.fn.winnr('h'))
local lbuf = vim.api.nvim_win_get_buf(lwin)
local llines = vim.api.nvim_buf_get_lines(lbuf, 0, -1, false)
check(table.concat(llines, '\n') == 'line1\nline2\nline3', 'left side holds merge-base content')
check(vim.bo[lbuf].modifiable == false, 'left side read-only')
check(vim.bo[lbuf].filetype == 'lua', 'left side filetype copied (lua)')

-- Mark: ✓ appears and session advances.
orca.mark()
qf = vim.fn.getqflist({ id = 0, items = true })
local marked = 0
for _, item in ipairs(qf.items) do if item.text:find('✓', 1, true) then marked = marked + 1 end end
check(marked == 1, 'exactly one ✓ after mark, got ' .. marked)
check(vim.api.nvim_buf_get_name(0) ~= name, 'mark advanced to another file')

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
local function drain(cond)
  vim.wait(1000, cond, 10)
end
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
check(vim.fn.maparg(']f', 'n', false, true).buffer ~= 1, 'buffer-local maps removed from real buffer')

-- Restart with an explicit range works and replaces the session.
orca.review('main...feature')
qf = vim.fn.getqflist({ title = true, size = true })
check(qf.title == 'OrcaReview main...feature', 'explicit range title, got: ' .. qf.title)
orca.close()

out(failed == 0 and 'SMOKE PASS' or ('SMOKE FAIL (' .. failed .. ')'))
if failed > 0 then vim.cmd('cquit') end
