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

-- :edit the file into the current window — unless it is already the buffer
-- there, which is the common case when a jump *into* a changed file is what
-- opened this pair. Re-reading it would throw away the syntax state, folds
-- and cursor the user is looking at, and would fail outright (E37) on a
-- working-tree side they have edited but not written.
local function edit(path)
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) == path then return buf end
  local ok, err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path))
  if not ok then return nil, err end
  return vim.api.nvim_get_current_buf()
end

-- Can `pair` be handed straight to `entry`, or does it have to come down
-- first? Reuse needs both its windows still orca's — the user may have put
-- their own buffer in either side — and an entry of the same shape: a
-- binary entry has no merge-base side at all, so that split has to go.
function M.reusable(pair, entry, win)
  if not (pair and entry and win) or entry.binary then return false end
  if pair.right_win ~= win or not vim.api.nvim_win_is_valid(win) then return false end
  local lw = pair.left_win
  return lw ~= nil and lw ~= win and vim.api.nvim_win_is_valid(lw)
    and vim.tbl_contains(pair.scratch, vim.api.nvim_win_get_buf(lw))
end

-- Show `entry`'s diff pair, with the right side in `win`. When `old` is a
-- pair M.reusable() has cleared for this entry, it is taken over rather than
-- rebuilt: the two windows stay and only their buffers change. Nothing
-- closes, nothing opens, the layout never reflows — which is the difference
-- between following a jump and flickering through one. Returns a pair record
-- { bufs, scratch, left_win, right_win }, or nil plus a message.
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
    right = scratch_buf('orca://gone/' .. entry.path, {},
      vim.filetype.match({ filename = entry.path }))
    vim.api.nvim_win_set_buf(win, right)
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
  local left = scratch_buf(('orca://%s/%s'):format(mergebase:sub(1, 12), entry.old_path),
    lines, ft)
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
  vim.api.nvim_win_call(left_win, function() vim.cmd('diffthis') end)
  vim.api.nvim_set_current_win(win)
  vim.cmd('diffthis')
  pcall(vim.cmd, 'normal! gg]c')

  return { bufs = { left, right }, scratch = scratch, left_win = left_win, right_win = win }
end

-- Take `pair` out of diff mode — with the bang, which is the whole point.
-- Diff mode is not just the windows' 'diff' flag: the tab page keeps a list
-- of the buffers taking part, and every window with 'diff' set compares
-- against all of them. Plain `:diffoff` unregisters the window's *current*
-- buffer, and by teardown time that is often no longer the pair's: the user
-- navigated the right window somewhere else (an LSP jump, CTRL-O), and
-- Neovim cleared that window's 'diff' on the swap without ever taking the
-- working-tree buffer off the list. The ghost then joins the *next* pair's
-- comparison as a third buffer, which agrees with neither side, so every
-- line of the new file reads as changed. `:diffoff!` empties the tab page's
-- list outright (`:h :diffoff`) — the only route back to a clean slate.
-- It resets 'diff' tab-page-wide, which is orca's to reset: a foreign diff
-- sharing the tab was already being compared against the pair's buffers.
function M.diffoff(pair)
  for _, key in ipairs({ 'left_win', 'right_win' }) do
    local w = pair[key]
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_call(w, function() vim.cmd('diffoff!') end)
    end
  end
end

-- Tear a pair down: diff mode off, the left split closed (closing it wipes
-- its scratch buffer), any scratch still displayed wiped explicitly. The
-- right window survives as the target for the next pair. A window the user
-- already stole for another buffer (`:edit` in a pair split) is only
-- diffoff'd, never closed — the buffer they navigated to must stay visible.
function M.close(pair)
  M.diffoff(pair)
  if pair.left_win and vim.api.nvim_win_is_valid(pair.left_win)
    and vim.tbl_contains(pair.scratch, vim.api.nvim_win_get_buf(pair.left_win)) then
    pcall(vim.api.nvim_win_close, pair.left_win, true)
  end
  -- A deleted file's "right side" is a scratch too, and wiping a displayed
  -- buffer closes its window — but the right window must survive as the
  -- next pair's anchor (with only the panel left, the layout collapses and
  -- the panel balloons to fill the screen). Park a throwaway buffer in it
  -- first; the next :edit into the window wipes the placeholder.
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
