require('helpers')

-- Orca's write-back lands in the same file: status/resolution set there
-- render under the anchor in the next session, and the explicit range
-- resolves to the same branch key.
local data = { version = 1, range = 'main...HEAD', comments = {
  { id = 1, file = 'src/b.lua', line = 2, text = 'edited thought', quoted = 'line2 CHANGED',
    status = 'open' },
} }
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

finish()
