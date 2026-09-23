-- One reviewed file's diff pair: the working-tree buffer on the right, the
-- merge base in a nofile, bufhidden=wipe scratch on the left.

local git = require('orca.git')

local M = {}

-- `name` may be left for later: a buffer name is unique, and a scratch that
-- replaces one of the same name can only take it once the old one is gone.
local function scratch_buf(name, lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  if name then pcall(vim.api.nvim_buf_set_name, buf, name) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  if ft and ft ~= '' then vim.bo[buf].filetype = ft end
  return buf
end

-- :edit the file into the current window, unless it is already there: a
-- re-read loses the view, and fails (E37) over unwritten changes.
local function edit(path)
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) == path then return buf end
  local ok, err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path))
  if not ok then return nil, err end
  return vim.api.nvim_get_current_buf()
end

-- Can `pair` be handed straight to `entry`? Only with both its windows still
-- showing orca's buffers, and an entry that wants a left side (not binary).
function M.reusable(pair, entry, win)
  if not (pair and entry and win) or entry.binary then return false end
  if pair.right_win ~= win or not vim.api.nvim_win_is_valid(win) then return false end
  local lw = pair.left_win
  return lw ~= nil and lw ~= win and vim.api.nvim_win_is_valid(lw)
    and vim.tbl_contains(pair.scratch, vim.api.nvim_win_get_buf(lw))
end

-- Show `entry`'s diff pair, right side in `win`. An `old` pair M.reusable()
-- cleared is taken over — its windows keep, only their buffers change, so
-- nothing reflows. Returns { bufs, scratch, left_win, right_win }, or nil
-- plus a message.
function M.open(entry, mergebase, toplevel, win, old)
  vim.api.nvim_set_current_win(win)
  local abs = toplevel .. '/' .. entry.path
  -- Whatever goes wrong from here on, the pair being taken over must not be
  -- left half-dismantled on screen.
  local function fail(err)
    if old then M.close(old) end
    return nil, err
  end
  -- The outgoing pair leaves diff mode before the incoming one enters it:
  -- its buffers have to come off the tab page's diff list first (see
  -- M.diffoff), and they are about to stop being displayed anywhere.
  if old then M.diffoff(old) end

  -- Binary files get no diff pair: just open the file itself.
  if entry.binary then
    local buf, err = edit(abs)
    if not buf then return fail(err) end
    return { bufs = { buf }, scratch = {}, right_win = win }
  end

  -- Right side: the working-tree file. A deleted file has none, so the
  -- empty scratch side is the "real" side here.
  local right, scratch
  if entry.status == 'D' then
    right = scratch_buf(nil, {}, vim.filetype.match({ filename = entry.path }))
    vim.api.nvim_win_set_buf(win, right)
    pcall(vim.api.nvim_buf_set_name, right, 'orca://gone/' .. entry.path)
    scratch = { right }
  else
    local buf, err = edit(abs)
    if not buf then return fail(err) end
    right = buf
    scratch = {}
  end

  -- Left side: the file as the merge-base had it (empty for additions);
  -- filetype copied from the right so syntax highlighting matches.
  local lines = {}
  if entry.status ~= 'A' then
    local shown, err = git.show(mergebase, entry.old_path)
    if not shown then return fail(err) end
    lines = shown
  end
  local ft = vim.bo[right].filetype
  if (not ft or ft == '') and entry.status == 'D' then
    ft = vim.filetype.match({ filename = entry.old_path, contents = lines })
  end
  -- Named only once it is displayed: reopening the file on screen replaces
  -- a scratch of the same name, which wipes only when it leaves its window.
  local left = scratch_buf(nil, lines, ft)
  scratch[#scratch + 1] = left

  -- Into the split the outgoing pair was using, when there is one: the
  -- scratch it displaces wipes itself on the way out (bufhidden=wipe), which
  -- is the same cleanup closing the split would have done.
  local left_win
  if old then
    left_win = old.left_win
    vim.api.nvim_win_set_buf(left_win, left)
  else
    vim.cmd('leftabove vertical sbuffer ' .. left)
    left_win = vim.api.nvim_get_current_win()
  end
  pcall(vim.api.nvim_buf_set_name, left, ('orca://%s/%s'):format(mergebase:sub(1, 12), entry.old_path))
  vim.api.nvim_win_call(left_win, function() vim.cmd('diffthis') end)
  vim.api.nvim_set_current_win(win)
  vim.cmd('diffthis')
  pcall(vim.cmd, 'normal! gg]c')

  return { bufs = { left, right }, scratch = scratch, left_win = left_win, right_win = win }
end

-- Take `pair` out of diff mode with :diffoff!, which empties the tab page's
-- diff buffer list. Plain :diffoff misses a buffer a jump swapped out of a
-- pair window, and that ghost joins the next pair's diff as a third side.
function M.diffoff(pair)
  for _, key in ipairs({ 'left_win', 'right_win' }) do
    local w = pair[key]
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_call(w, function() vim.cmd('diffoff!') end)
    end
  end
end

-- Tear a pair down: diff off, the left split closed, scratches wiped. The
-- right window survives for the next pair, and a window the user put their
-- own buffer in is never closed.
function M.close(pair)
  M.diffoff(pair)
  if pair.left_win and vim.api.nvim_win_is_valid(pair.left_win)
    and vim.tbl_contains(pair.scratch, vim.api.nvim_win_get_buf(pair.left_win)) then
    pcall(vim.api.nvim_win_close, pair.left_win, true)
  end
  -- A deleted file's right side is a scratch too, and wiping a displayed
  -- buffer closes its window: park a placeholder there first, so the window
  -- survives and the panel doesn't balloon into the space.
  if pair.right_win and vim.api.nvim_win_is_valid(pair.right_win)
    and vim.tbl_contains(pair.scratch, vim.api.nvim_win_get_buf(pair.right_win)) then
    local placeholder = vim.api.nvim_create_buf(false, true)
    vim.bo[placeholder].bufhidden = 'wipe'
    vim.api.nvim_win_set_buf(pair.right_win, placeholder)
  end
  for _, buf in ipairs(pair.scratch) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

return M
