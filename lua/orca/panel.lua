-- The review panel: the session's changed-file list in a buffer orca owns.
-- The quickfix list it replaces was shared territory — any :grep or LSP
-- reference push evicted the review from the display — while nothing
-- external writes into an orca-owned buffer, so the list survives
-- everything short of :OrcaReviewClose. Owning the buffer also buys what
-- the qf `text` column capped out on: highlighted status letters, a
-- full-line current-file mark, per-file comment counts as virt_text.
--
-- One scratch buffer (orca://review), one window at most. The window is a
-- bottom strip — the qf window's exact footprint, so diff pairs keep full
-- width. Closing the window only hides the view; the buffer (and the
-- session behind it) survive for :OrcaReviewPanel to bring back. Only
-- teardown(), at session close, destroys anything.

local M = {}

local NS = vim.api.nvim_create_namespace('orca_panel')
local state = { buf = nil, win = nil }

local STATUS_HL = {
  A = 'OrcaPanelAdded',
  D = 'OrcaPanelRemoved',
  R = 'OrcaPanelRenamed',
  C = 'OrcaPanelRenamed',
}

local function define_hl()
  -- Added/Removed/Changed are builtin groups on 0.10+; on 0.9 the links
  -- resolve to nothing and the letters render plainly. All overridable.
  vim.api.nvim_set_hl(0, 'OrcaPanelAdded', { link = 'Added', default = true })
  vim.api.nvim_set_hl(0, 'OrcaPanelRemoved', { link = 'Removed', default = true })
  vim.api.nvim_set_hl(0, 'OrcaPanelChanged', { link = 'Changed', default = true })
  vim.api.nvim_set_hl(0, 'OrcaPanelRenamed', { link = 'Changed', default = true })
  vim.api.nvim_set_hl(0, 'OrcaPanelCurrent', { link = 'CursorLine', default = true })
  vim.api.nvim_set_hl(0, 'OrcaPanelCount', { fg = '#c678dd', ctermfg = 176, default = true })
end

-- One row: ` <status> *n <name>`. The *n comment count sits between the
-- status letter and the name; its column is reserved (spaces) on rows
-- without comments so names stay aligned, and omitted entirely when the
-- review has none. Leading space: a breath of padding off the window edge.
local function entry_line(e, count, width)
  local name = e.path
  if e.status == 'R' or e.status == 'C' then
    name = ('%s → %s'):format(e.old_path, e.path)
  end
  if e.binary then name = name .. ' (binary)' end
  local counts_col = ' '
  if width > 0 then
    counts_col = (' %-' .. width .. 's'):format(count > 0 and ('*%d'):format(count) or '')
  end
  return (' %s%s %s'):format(e.status, counts_col, name)
end

-- Re-render everything: lines, status-letter highlights, the current-file
-- line mark, and the [n] comment counts. Cheap enough (a screenful of
-- short lines) that partial updates are not worth their bookkeeping.
local function render(entries, index, counts)
  local buf = state.buf
  local max = 0
  for _, e in ipairs(entries) do
    max = math.max(max, counts and counts[e.path] or 0)
  end
  -- The count column sizes to the widest *n in the session.
  local width = max > 0 and #('*%d'):format(max) or 0
  local lines = {}
  for i, e in ipairs(entries) do
    lines[i] = entry_line(e, counts and counts[e.path] or 0, width)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, e in ipairs(entries) do
    vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 1, {
      end_col = 2,
      hl_group = STATUS_HL[e.status] or 'OrcaPanelChanged',
    })
    local n = counts and counts[e.path]
    if n and n > 0 then
      -- ` X *n` — the token starts after space+letter+space (col 3).
      vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 3, {
        end_col = 3 + #('*%d'):format(n),
        hl_group = 'OrcaPanelCount',
      })
    end
  end
  if index and index >= 1 and index <= #entries then
    vim.api.nvim_buf_set_extmark(buf, NS, index - 1, 0, {
      line_hl_group = 'OrcaPanelCurrent',
    })
  end
end

function M.buf()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf) and state.buf or nil
end

-- The window currently showing the panel, if any. The user may have closed
-- it (:q, a window-management plugin) or put another buffer in it; both
-- count as hidden.
function M.win()
  local w = state.win
  if w and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == state.buf then
    return w
  end
  return nil
end

local function ensure_buf()
  if M.buf() then return state.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, 'orca://review')
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide' -- closing the window must not kill the list
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'orca-panel'
  state.buf = buf
  return buf
end

-- Create (or focus) the panel window and render. Returns the panel buffer
-- — new or reused; the caller re-asserts its maps either way, and setting
-- a map twice is idempotent.
function M.open(entries, index, counts, title)
  define_hl()
  local buf = ensure_buf()
  local win = M.win()
  if not win then
    -- noautocmd: :split briefly shows the current buffer in the new
    -- window, and a BufEnter for it would ripple through the session's
    -- navigation follower.
    vim.cmd(('noautocmd botright %dsplit'):format(math.max(1, math.min(#entries, 10))))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    for opt, val in pairs({
      number = false, relativenumber = false, wrap = false, spell = false,
      list = false, signcolumn = 'no', foldcolumn = '0', cursorline = false,
      winfixheight = true,
      statusline = title and title:gsub('%%', '%%%%') or '',
    }) do
      -- scope='local': without it this is :set, and the panel's looks
      -- would leak into the global defaults every new window inherits.
      vim.api.nvim_set_option_value(opt, val, { win = win, scope = 'local' })
    end
    state.win = win
  else
    vim.api.nvim_set_current_win(win)
  end
  render(entries, index, counts)
  if index and index >= 1 and index <= #entries then
    pcall(vim.api.nvim_win_set_cursor, win, { index, 0 })
  end
  return buf
end

-- Re-render from session state; when the panel window is not focused, park
-- its cursor on the current row too, so entering the panel always lands on
-- the current file (the qf `idx` behavior, kept).
function M.refresh(entries, index, counts)
  if not M.buf() then return end
  render(entries, index, counts)
  local win = M.win()
  if win and win ~= vim.api.nvim_get_current_win()
    and index and index >= 1 and index <= #entries then
    pcall(vim.api.nvim_win_set_cursor, win, { index, 0 })
  end
end

-- Hide the window; the buffer (and the session behind it) survive.
function M.close()
  local win = M.win()
  if win then pcall(vim.api.nvim_win_close, win, false) end
end

-- Session close: destroy everything.
function M.teardown()
  M.close()
  if M.buf() then pcall(vim.api.nvim_buf_delete, state.buf, { force = true }) end
  state.buf, state.win = nil, nil
end

return M
