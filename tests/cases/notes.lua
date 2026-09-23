require('helpers')

orca.review('')
local bidx = idx_of('src/b%.lua')
orca.open(bidx)

-- Discovery: repo root is the parent of the common git dir — in the bare
-- layout, the worktree's parent, not the worktree itself.
check(root == vim.fn.fnamemodify(vim.fn.getcwd(), ':h'),
  'repo_root is the worktree parent (bare layout), got ' .. tostring(root))
check(vim.fn.filereadable(notes_path) == 0, 'no notes file before the first comment (lazy creation)')

-- Create: :OrcaComment opens an acwrite scratch split; :w commits and the
-- whole file is rewritten under .orca/review-notes/<branch>.json.
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
check(vim.api.nvim_buf_get_name(0):find('orca://comment/', 1, true) ~= nil,
  'OrcaComment opens the input scratch, got ' .. vim.api.nvim_buf_get_name(0))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'first thought', 'second line' })
commit()
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
check(vim.fn.filereadable(notes_path .. '.tmp') == 0, 'the save leaves no .tmp behind')

-- Written whole or not at all: a write that dies partway through used to
-- leave the notes file truncated, which the next session refuses as
-- invalid JSON. Now it dies on a scratch file, and the real one stays put.
local real_writefile = vim.fn.writefile
vim.fn.writefile = function(_, path)
  real_writefile({ '{"version":1,"comm' }, path)
  error('disk full')
end
pcall(require('orca.notes').save)
vim.fn.writefile = real_writefile
local _, after_crash = pcall(read_notes)
check(type(after_crash) == 'table' and after_crash.comments and after_crash.comments[1].text == 'first thought\nsecond line',
  'a save that dies mid-write leaves the previous file whole')
check(vim.fn.filereadable(notes_path .. '.tmp') == 0, 'and cleans up its .tmp')
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
commit()
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
commit()
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
commit()
data = read_notes()
local prober
for _, c in ipairs(data and data.comments or {}) do if c.text == 'gap prober' then prober = c end end
check(prober ~= nil and prober.id == 3, 'deleted id leaves a gap — next comment is #3, got '
  .. tostring(prober and prober.id))
vim.cmd('OrcaCommentDelete')
data = read_notes()
check(data and #data.comments == 1, 'gap prober cleaned up')

finish()
