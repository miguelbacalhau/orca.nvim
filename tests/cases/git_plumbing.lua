require('helpers')

-- git writes warnings to stderr on a run that succeeds — here, rename
-- detection giving up past diff.renameLimit — and those must not arrive as
-- output. They used to, and became panel rows naming files that don't exist.
vim.fn.system({ 'git', 'config', 'diff.renameLimit', '1' })
check(vim.fn.system({ 'git', 'diff', '--name-status', '-M', 'main...HEAD' }):find('warning:', 1, true) ~= nil,
  'renameLimit=1 makes git warn on this fixture (the precondition)')
vim.g.orca_review_hidden = false
orca.review('')
local warned = false
for _, l in ipairs(panel_lines()) do
  if l:find('warning', 1, true) then warned = true end
end
check(not warned and #panel_lines() == 9,
  'stderr warnings are not files: eight rows + the summary, got ' .. table.concat(panel_lines(), ' ;; '))
orca.close()
vim.g.orca_review_hidden = nil
vim.fn.system({ 'git', 'config', '--unset', 'diff.renameLimit' })

finish()
