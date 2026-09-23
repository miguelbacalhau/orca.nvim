require('helpers')

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
commit()
local data = read_notes()
local feature_sha = vim.fn.systemlist({ 'git', '-C', here, 'rev-parse', 'HEAD' })[1]
check(data and data.head == feature_sha,
  'and the notes file records the reviewed repo\'s head, got ' .. tostring(data and data.head))
orca.close()
vim.cmd('cd ' .. vim.fn.fnameescape(here))
vim.fn.delete(notes_path)

finish()
