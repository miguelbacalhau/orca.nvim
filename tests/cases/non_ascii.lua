require('helpers')

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
commit()
local data = read_notes()
check(data and data.comments[1] and data.comments[1].file == 'src/café.lua'
  and data.comments[1].quoted == 'olá',
  'and a comment anchors to it under its real name')
orca.close()
vim.fn.delete(notes_path)

finish()
