-- The session's keymaps (:help orca-keymaps): vim.g.orca_mappings resolved,
-- mapped, and every key handed back as it was found. The actions are the
-- session's, passed to new(), so this module never requires orca/init.lua.

local panel = require('orca.panel')
local notify = require('orca.util').notify

local M = {}

-- Only `open` ships bound, on keys that shadow nothing in orca's own panel.
-- Everything else is opt-in: orca never takes a key that means something.
local DEFAULT_MAPPINGS = {
  open = { '<CR>', '<2-LeftMouse>' }, -- panel only
}

local VALID_ACTIONS = {
  next = true, prev = true, open = true, comment = true, delete = true,
  comment_next = true, comment_prev = true, panel = true, close = true,
  hidden = true,
}

-- Actions mapped globally for the session: they don't care which buffer
-- you are in. The rest are buffer-local — comment and delete need a
-- working-tree line, and a global <CR> would shadow everyone's.
local GLOBAL_ACTIONS = {
  next = true, prev = true, panel = true, hidden = true, close = true,
  comment_next = true, comment_prev = true,
}

-- Rows are { action, rhs-or-fn, desc [, x-mode rhs] } — comment also maps
-- in visual mode, where the command's range anchors the whole selection.
-- `on` is the session's action table.
local function action_rows(on)
  return {
    { 'next', function() on.next(vim.v.count1) end, 'orca: next file' },
    { 'prev', function() on.prev(vim.v.count1) end, 'orca: previous file' },
    { 'comment', function() on.comment(vim.fn.line('.'), vim.fn.line('.')) end,
      'orca: comment on this line', ':OrcaComment<CR>' },
    { 'delete', function() on.delete() end, 'orca: delete the comment on this line' },
    { 'comment_next', function() on.comment_next() end, 'orca: next comment' },
    { 'comment_prev', function() on.comment_prev() end, 'orca: previous comment' },
    { 'panel', function() on.panel() end, 'orca: focus the review panel, or go back' },
    { 'hidden', function() on.hidden() end, 'orca: show or hide the grouped files' },
    { 'close', function() on.close() end, 'orca: close review' },
  }
end

-- One action, one or more keys: `open` is both <CR> and the double-click,
-- and a user's plain string is the one-key case. Non-strings are dropped
-- rather than handed to vim.keymap.set, which would error out of the
-- session start; an empty list means the same as false.
local function lhs_list(v)
  if type(v) == 'string' then return { v } end
  if type(v) ~= 'table' then return {} end
  local out = {}
  for _, lhs in ipairs(v) do
    if type(lhs) == 'string' then out[#out + 1] = lhs end
  end
  return out
end

local function resolve_mappings()
  local user = vim.g.orca_mappings
  local maps = {}
  if user == false then return maps end
  for action, lhs in pairs(DEFAULT_MAPPINGS) do maps[action] = lhs_list(lhs) end
  if type(user) == 'table' then
    for action, lhs in pairs(user) do
      if not VALID_ACTIONS[action] then
        notify(('vim.g.orca_mappings: unknown action %q (valid: next, prev, open, comment, delete, comment_next, comment_prev, panel, hidden, close)')
          :format(action), vim.log.levels.WARN)
      else
        local keys = lhs == false and {} or lhs_list(lhs)
        maps[action] = #keys > 0 and keys or nil
      end
    end
  end
  return maps
end

-- Pointer keys, which carry a position of their own. Release and drag are
-- the same family under different names — someone binding `open` to
-- <LeftRelease> wants single-click-opens, and that click lands where the
-- pointer is, not where the cursor was.
local function is_pointer(lhs)
  local s = lhs:lower()
  return (s:find('mouse') or s:find('release') or s:find('drag')) ~= nil
end

-- Open the panel row under the pointer, not the cursor. A click on the
-- statusline, or past the last row (getmousepos clamps it onto that row),
-- opens nothing.
local function open_click(open_row)
  local win = panel.win()
  local pos = vim.fn.getmousepos()
  if not win or pos.winid ~= win or pos.line < 1 then return end
  -- The panel never wraps, folds, or carries virtual lines, so the row
  -- under the pointer is exactly topline + winrow - 1.
  local top = vim.api.nvim_win_call(win, function() return vim.fn.line('w0') end)
  if top + pos.winrow - 1 > vim.api.nvim_buf_line_count(panel.buf()) then return end
  open_row(pos.line)
end

-- What `lhs` means in `mode` inside `buf`, as maparg()'s dict. Carried out
-- of the buf_call by upvalue: on 0.9 nvim_buf_call cannot return a dict
-- holding a Lua callback, and a map made with a Lua function holds one.
local function maparg_in(buf, lhs, mode)
  local got
  vim.api.nvim_buf_call(buf, function() got = vim.fn.maparg(lhs, mode, false, true) end)
  return got
end

local Keys = {}
Keys.__index = Keys

-- One session's keys. `on` holds the session's actions: next(count),
-- prev(count), comment(line1, line2), delete, comment_next, comment_prev,
-- panel, hidden, close and open_row(row).
function M.new(on)
  return setmetatable({
    on = on,
    rows = action_rows(on),
    maps = resolve_mappings(),
    mapped = {},  -- buf → { [mode .. lhs] = { mode, lhs, prev } }
    globals = {}, -- lhs → what it meant before, or false
  }, Keys)
end

-- The key an action is announced by: the first one bound, which is the
-- keyboard one — "<2-LeftMouse> opens a diff" is not a hint anybody needs.
function Keys:key_of(action)
  local keys = self.maps[action]
  return keys and keys[1]
end

-- Map `lhs` in `buf`, remembering what the buffer itself had on it — only
-- the first time: a re-assert would otherwise record orca's own map as the
-- one to give back.
function Keys:buf_map(buf, lhs, rhs, desc, mode)
  mode = mode or 'n'
  self.mapped[buf] = self.mapped[buf] or {}
  local key = mode .. lhs
  if self.mapped[buf][key] == nil then
    local prev = maparg_in(buf, lhs, mode)
    self.mapped[buf][key] = { mode = mode, lhs = lhs,
      prev = (type(prev) == 'table' and prev.buffer == 1) and prev or false }
  end
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, desc = desc })
end

-- The buffer-local actions, in a buffer the session owns.
function Keys:attach(buf)
  for _, a in ipairs(self.rows) do
    if not GLOBAL_ACTIONS[a[1]] then
      for _, lhs in ipairs(self.maps[a[1]] or {}) do
        self:buf_map(buf, lhs, a[2], a[3])
        if a[4] then self:buf_map(buf, lhs, a[4], a[3], 'x') end
      end
    end
  end
end

-- The panel buffer is orca's alone — no ftplugin re-runs, no last-writer
-- mapping race, no list identity to check. Maps are set once per buffer
-- (the buffer outlives its window, so reopening needs no re-assert).
function Keys:attach_panel(buf)
  self:attach(buf)
  for _, lhs in ipairs(self.maps.open or {}) do
    if is_pointer(lhs) then
      self:buf_map(buf, lhs, function() open_click(self.on.open_row) end,
        "orca: open the clicked file's diff")
    else
      self:buf_map(buf, lhs, function() self.on.open_row(vim.fn.line('.')) end,
        "orca: open this file's diff")
    end
  end
end

-- The comment editor answers to the `delete` key too. Its buffer is orca's
-- and wipes on close, so there is nothing to hand back.
function Keys:attach_editor(buf)
  for _, lhs in ipairs(self.maps.delete or {}) do
    vim.keymap.set('n', lhs, self.on.delete,
      { buffer = buf, nowait = true, desc = 'orca: delete this comment' })
  end
end

-- Hand a buffer's keys back as they were found, the way detach_globals
-- does for the global ones. mapset() sets a buffer-local dict in the
-- current buffer, hence the buf_call.
function Keys:detach(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    for _, m in pairs(self.mapped[buf] or {}) do
      pcall(vim.keymap.del, m.mode, m.lhs, { buffer = buf })
      if m.prev then
        vim.api.nvim_buf_call(buf, function() pcall(vim.fn.mapset, m.mode, false, m.prev) end)
      end
    end
  end
  self.mapped[buf] = nil
end

-- The session's global maps. What each key meant before is asked from an
-- empty scratch buffer, since maparg() prefers the current buffer's map and
-- would otherwise hand an LSP's buffer map back globally.
function Keys:attach_globals()
  local probe = vim.api.nvim_create_buf(false, true)
  local function previous(lhs)
    local ok, prev = pcall(maparg_in, probe, lhs, 'n')
    if ok and type(prev) == 'table' and next(prev) ~= nil then return prev end
    return false
  end
  for _, a in ipairs(self.rows) do
    if GLOBAL_ACTIONS[a[1]] then
      for _, lhs in ipairs(self.maps[a[1]] or {}) do
        if self.globals[lhs] == nil then self.globals[lhs] = previous(lhs) end
        vim.keymap.set('n', lhs, a[2], { desc = a[3] })
      end
    end
  end
  pcall(vim.api.nvim_buf_delete, probe, { force = true })
end

-- Hand every taken key back exactly as it was found: restored when it meant
-- something, deleted when it meant nothing.
function Keys:detach_globals()
  for lhs, prev in pairs(self.globals) do
    pcall(vim.keymap.del, 'n', lhs)
    if prev then pcall(vim.fn.mapset, 'n', 0, prev) end
  end
  self.globals = {}
end

-- Session close: every buffer's keys and every global one handed back.
function Keys:release()
  for buf in pairs(self.mapped) do self:detach(buf) end
  self:detach_globals()
end

return M
