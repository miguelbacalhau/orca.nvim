require('helpers')

-- A range that resolves to nothing is refused before the running session
-- is touched. It used to close the session first and fail after, leaving
-- no review at all — panel, pair and position gone over a typo.
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

finish()
