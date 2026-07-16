-- Force this working copy of orca.nvim to win over any installed copy,
-- whatever the user's config or plugin manager did. Sourced by demo/run.sh
-- (+luafile) after the user's config has fully loaded.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

vim.opt.rtp:prepend(root)

-- Evict already-required orca modules: a config that calls setup() eagerly
-- (lazy.nvim's `opts`) has cached the installed copy in package.loaded.
for k in pairs(package.loaded) do
  if k == 'orca' or k:find('^orca%.') then package.loaded[k] = nil end
end

-- Pin a searcher that resolves orca.* from this copy ahead of everything.
-- Prepending to rtp is not enough: plugin managers (lazy.nvim) install
-- spec-aware loaders that answer require() before rtp order is consulted.
table.insert(package.loaders, 1, function(mod)
  local rel
  if mod == 'orca' then
    rel = 'lua/orca/init.lua'
  elseif mod:find('^orca%.') then
    rel = 'lua/orca/' .. mod:sub(#'orca.' + 1):gsub('%.', '/') .. '.lua'
  end
  local path = rel and (root .. '/' .. rel)
  if path and (vim.uv or vim.loop).fs_stat(path) then
    return assert(loadfile(path))
  end
end)
require('orca')

-- Re-run the plugin file from this copy: it recreates the full command set
-- (:command! semantics), replacing an installed copy's commands and any
-- lazy-load stubs — so commands new in this version exist even beside an
-- older installed one.
vim.g.loaded_orca = nil
vim.cmd('runtime! plugin/orca.lua')

-- :help should match this version too (doc/tags is gitignored).
vim.cmd('helptags ' .. vim.fn.fnameescape(root .. '/doc'))
