-- Small helpers every orca module shares.

local M = {}

-- Every message the plugin shows, prefixed so it is clear whose it is.
function M.notify(msg, level)
  vim.notify('orca: ' .. msg, level or vim.log.levels.INFO)
end

return M
