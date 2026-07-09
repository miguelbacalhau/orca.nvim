-- The side-by-side pair for one reviewed file: the real working-tree buffer
-- on the right (LSP attaches, editable — fixing nits during review is a
-- feature), the merge-base content in a scratch buffer on the left, native
-- diff mode on both. Scratch buffers are nofile + bufhidden=wipe, so however
-- a pair goes away, no trace survives it.

local git = require('orca.git')

local M = {}

local function scratch_buf(name, lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  if ft and ft ~= '' then vim.bo[buf].filetype = ft end
  return buf
end

local function edit(path)
  local ok, err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path))
  if not ok then return nil, err end
  return vim.api.nvim_get_current_buf()
end

-- Show `entry`'s diff pair, with the right side in `win`. Returns a pair
-- record { bufs, scratch, left_win, right_win }, or nil plus a message.
function M.open(entry, mergebase, toplevel, win)
  vim.api.nvim_set_current_win(win)
  local abs = toplevel .. '/' .. entry.path

  -- Binary files get no diff pair: just open the file itself.
  if entry.binary then
    local buf, err = edit(abs)
    if not buf then return nil, err end
    return { bufs = { buf }, scratch = {}, right_win = win }
  end

  -- Right side: the working-tree file. A deleted file has none, so the
  -- empty scratch side is the "real" side here.
  local right, scratch
  if entry.status == 'D' then
    right = scratch_buf('orca://gone/' .. entry.path, {},
      vim.filetype.match({ filename = entry.path }))
    vim.api.nvim_win_set_buf(win, right)
    scratch = { right }
  else
    local buf, err = edit(abs)
    if not buf then return nil, err end
    right = buf
    scratch = {}
  end

  -- Left side: the file as the merge-base had it (empty for additions);
  -- filetype copied from the right so syntax highlighting matches.
  local lines = {}
  if entry.status ~= 'A' then
    local shown, err = git.show(mergebase, entry.old_path)
    if not shown then return nil, err end
    lines = shown
  end
  local ft = vim.bo[right].filetype
  if (not ft or ft == '') and entry.status == 'D' then
    ft = vim.filetype.match({ filename = entry.old_path, contents = lines })
  end
  local left = scratch_buf(('orca://%s/%s'):format(mergebase:sub(1, 12), entry.old_path),
    lines, ft)
  scratch[#scratch + 1] = left

  vim.cmd('leftabove vertical sbuffer ' .. left)
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd('diffthis')
  vim.api.nvim_set_current_win(win)
  vim.cmd('diffthis')
  pcall(vim.cmd, 'normal! gg]c')

  return { bufs = { left, right }, scratch = scratch, left_win = left_win, right_win = win }
end

-- Tear a pair down: diff mode off, the left split closed (closing it wipes
-- its scratch buffer), any scratch still displayed wiped explicitly. The
-- right window survives as the target for the next pair. A window the user
-- already stole for another buffer (`:edit` in a pair split) is only
-- diffoff'd, never closed — the buffer they navigated to must stay visible.
function M.close(pair)
  for _, key in ipairs({ 'left_win', 'right_win' }) do
    local w = pair[key]
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_call(w, function() vim.cmd('diffoff') end)
    end
  end
  if pair.left_win and vim.api.nvim_win_is_valid(pair.left_win)
    and vim.tbl_contains(pair.scratch, vim.api.nvim_win_get_buf(pair.left_win)) then
    pcall(vim.api.nvim_win_close, pair.left_win, true)
  end
  for _, buf in ipairs(pair.scratch) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
