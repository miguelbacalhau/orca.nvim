require('helpers')

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
commit()
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
-- The session's opening line says the same, in words: how the row's toggle
-- reads from here.
local function opening(fn)
  local got = {}
  local real = vim.notify
  vim.notify = function(m) got[#got + 1] = m end
  fn()
  vim.notify = real
  return got[1] or ''
end
local hint = opening(function() orca.review('') end)
check(hint:find(', 2 hidden', 1, true) ~= nil and hint:sub(-#'<CR> on the … row shows them') == '<CR> on the … row shows them',
  'hidden start: the hint ends "<CR> on the … row shows them", got: ' .. hint)
orca.close()
vim.g.orca_review_hidden = false
hint = opening(function() orca.review('') end)
check(#panel_lines() == 9, 'orca_review_hidden = false lists everything, got ' .. #panel_lines())
check(summary_row():find('<CR> hides 2', 1, true) ~= nil, 'opted out, the row offers to hide')
check(hint:sub(-#'<CR> on the … row hides 2') == '<CR> on the … row hides 2'
  and not hint:find('hidden', 1, true),
  'opted out: the hint says "hides 2", not "hides 2 them", got: ' .. hint)
orca.close()
vim.g.orca_review_hidden = nil
-- A review no group claims anything in has nothing hidden to mention.
vim.g.orca_review_groups = { tests = false, none = { 'nothing-matches-this' } }
hint = opening(function() orca.review('') end)
check(not hint:find('hidden', 1, true) and not hint:find('row', 1, true),
  'with nothing grouped, the hint leaves the row out, got: ' .. hint)
orca.close()
vim.g.orca_review_groups = nil

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
-- It warns once, at session start: the config is read then and not again,
-- where every panel refresh used to re-read it and warn afresh.
vim.g.orca_review_groups = { tests = 'tests/' }
msgs = {}
vim.notify = function(m, ...) msgs[#msgs + 1] = m; return real_notify(m, ...) end
orca.review('')
orca.open(idx_of('src/b%.lua'))
orca.prev()
orca.next()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'refreshes the panel' })
commit()
vim.notify = real_notify
local warnings = 0
for _, m in ipairs(msgs) do
  if m:find('expected a list of globs', 1, true) then warnings = warnings + 1 end
end
check(warnings == 1, 'bad group config warns exactly once across open, next and a comment, got '
  .. warnings)
check(#panel_lines() == 7, 'and the shipped defaults still apply, got ' .. #panel_lines())
orca.close()
vim.fn.delete(notes_path)
vim.g.orca_review_groups = nil

finish()
