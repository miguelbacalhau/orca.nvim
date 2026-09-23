-- The session's keymaps: vim.g.orca_mappings resolved into keys, and those
-- keys mapped and handed back. Convenience maps; the :Orca* commands are the
-- public API. The session's navigation verbs are mapped globally for as
-- long as it lives (GLOBAL_ACTIONS) and the line-anchored ones only in the
-- buffers it owns; both go away when it lets go, and whatever a key meant
-- before — globally or in a buffer — is what it means after.
--
-- The actions themselves are the session's (orca/init.lua), handed in to
-- new(), so neither module requires the other.

local panel = require('orca.panel')
local notify = require('orca.util').notify

local M = {}

-- vim.g.orca_mappings reshapes the maps: a table overrides per action (a
-- string, a list of keys for one action, or false to drop it), false
-- wholesale drops them all. Resolved once per session.
-- Only `open` ships bound: in an orca-owned buffer <CR> shadows nothing
-- (the fugitive/oil precedent), and neither does a double-click — the
-- panel replaced the quickfix list, where <2-LeftMouse> was <CR>, and in
-- a nofile list buffer the native double-click (select the word under the
-- pointer, in visual mode) is noise. Everything else ships unbound — orca
-- never binds a key that doesn't already mean what orca makes it do, and
-- with no orca quickfix list there is no native key left to upgrade (]q/[q
-- would shadow the user's real quickfix motion for the whole session).
-- The commands and config keys remain.
local DEFAULT_MAPPINGS = {
  open = { '<CR>', '<2-LeftMouse>' }, -- panel only
}

local VALID_ACTIONS = {
  next = true, prev = true, open = true, comment = true, delete = true,
  comment_next = true, comment_prev = true, panel = true, close = true,
  hidden = true,
}

-- Actions that don't care which buffer you are in. These are mapped
-- globally for the session's lifetime instead of in the buffers orca owns,
-- because "which file is next" is a property of the review, not of the
-- window you happen to be standing in: a grep result, :help, a terminal, a
-- file outside the diff — the session's keys answer from all of them, the
-- way the :Orca* commands always have. Whatever a key meant before is
-- captured and handed back at :OrcaReviewClose.
--
-- The rest stay buffer-local, because there they are the honest answer:
-- `comment`/`delete` need a changed file's working-tree line to anchor to,
-- and `open` is the panel's alone — a global <CR> would shadow the one key
-- nobody can spare.
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

-- Open whatever the pointer is on. The cursor is no help here: a click on
-- the panel's 'statusline' (the session's range) fires the map too with
-- the cursor still parked wherever it was, and getmousepos() clamps a
-- click past the last row onto it — after a hide-toggle the window is
-- routinely taller than its rows, so that clamp would toggle the groups
-- back on a click into empty space. Both cases are a no-op instead.
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
    local prev = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, mode, false, true) end)
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

-- The session's global maps, set once at :OrcaReview and undone at
-- :OrcaReviewClose. maparg() reports the *current buffer's* mapping ahead
-- of the global one, so what a key meant before is asked from inside an
-- empty scratch buffer, where nothing is buffer-local — otherwise a review
-- started from a buffer with an LSP map on the same key would hand that
-- map back globally at close.
function Keys:attach_globals()
  local probe = vim.api.nvim_create_buf(false, true)
  local function previous(lhs)
    local ok, prev = pcall(vim.api.nvim_buf_call, probe, function()
      return vim.fn.maparg(lhs, 'n', false, true)
    end)
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
