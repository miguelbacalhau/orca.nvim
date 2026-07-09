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
