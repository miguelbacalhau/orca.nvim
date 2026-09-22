-- The review panel: the session's changed-file list in a buffer orca owns.
-- The quickfix list it replaces was shared territory — any :grep or LSP
-- reference push evicted the review from the display — while nothing
-- external writes into an orca-owned buffer, so the list survives
-- everything short of :OrcaReviewClose. Owning the buffer also buys what
-- the qf `text` column capped out on: highlighted status letters, a
-- full-line current-file mark, per-file comment counts, and each file's
-- `+n -n` line counts held against the window's right edge.
--
-- One scratch buffer (orca://review), one window at most. The window is a
-- bottom strip — the qf window's exact footprint, so diff pairs keep full
-- width. Closing the window only hides the view; the buffer (and the
-- session behind it) survive for :OrcaReviewPanel to bring back. Only
-- teardown(), at session close, destroys anything.
--
-- What the panel shows is a *view* over the session's entries (see
-- orca/filter.lua): rows carry entry indices, and the last row — the one
-- row that is not a file — reports what the hidden groups folded away and
-- toggles them back. The count is always on screen, so a review never
-- omits anything quietly.

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
  vim.api.nvim_set_hl(0, 'OrcaPanelHidden', { link = 'Comment', default = true })
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

-- The `+n -n` line counts for one entry, as virt_text chunks. Both sides
-- always show, `+0` and `-0` included: a file that only grows reads as
-- `+100 -0`, and the zero is the statement — the eye scanning the column
-- never has to work out whether a blank means nothing or means nothing
-- shown. Only a binary file, where git counts no lines at all, returns
-- nil and leaves the margin empty. Widths come from the widest token on
-- show, so the two columns stack down the panel instead of ragging.
local function diffstat(e, aw, dw)
  if not (e.added or e.deleted) then return nil end
  local function pad(tok, w) return (' '):rep(w - #tok) .. tok end
  return {
    { pad(('+%d'):format(e.added or 0), aw), 'OrcaPanelAdded' },
    { ' ' },
    { pad(('-%d'):format(e.deleted or 0), dw), 'OrcaPanelRemoved' },
    -- A breath of padding off the window edge, mirroring the row's own.
    { ' ' },
  }
end

-- The group breakdown, "tests" for one group and "4 tests, 2 generated"
-- for several — the shape that stays readable either way.
local function breakdown(view)
  local names = vim.tbl_keys(view.groups)
  table.sort(names)
  if #names == 1 then return names[1] end
  local parts = {}
  for _, g in ipairs(names) do parts[#parts + 1] = ('%d %s'):format(view.groups[g], g) end
  return table.concat(parts, ', ')
end

-- The summary row, present whenever a group claims anything at all. It
-- states what is missing and what <CR> on it will do — in both states, so
-- the toggle is discoverable from the panel alone and the hidden set is
-- never a thing you have to already know about.
function M.summary(view)
  if view.hidden then
    return ('%d file%s hidden (%s) — <CR> shows'):format(
      view.n, view.n == 1 and '' or 's', breakdown(view))
  end
  return ('showing everything — <CR> hides %d (%s)'):format(view.n, breakdown(view))
end

-- The row showing entry `index`, or nil when the view folded it away.
local function row_of(view, index)
  for r, i in ipairs(view.rows) do
    if i == index then return r end
  end
end

-- How tall the panel wants to be: its rows, the summary one included.
local function height(view)
  return #view.rows + (view.n > 0 and 1 or 0)
end

-- Re-render everything: lines, status-letter highlights, the current-file
-- line mark, the [n] comment counts, and the summary row. Cheap enough (a
-- screenful of short lines) that partial updates are not worth their
-- bookkeeping.
local function render(entries, index, counts, view)
  local buf = state.buf
  -- The count columns start at 2 — the width of `+0`, which every
  -- non-binary row carries — and grow to the widest number on show.
  local max, aw, dw = 0, 2, 2
  for _, i in ipairs(view.rows) do
    local e = entries[i]
    max = math.max(max, counts and counts[e.path] or 0)
    if e.added then aw = math.max(aw, #('+%d'):format(e.added)) end
    if e.deleted then dw = math.max(dw, #('-%d'):format(e.deleted)) end
  end
  -- The count column sizes to the widest *n on show.
  local width = max > 0 and #('*%d'):format(max) or 0
  local lines = {}
  for r, i in ipairs(view.rows) do
    lines[r] = entry_line(entries[i], counts and counts[entries[i].path] or 0, width)
  end
  local summary = view.n > 0 and (#lines + 1) or nil
  if summary then lines[summary] = (' … %s'):format(M.summary(view)) end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for r, i in ipairs(view.rows) do
    local e = entries[i]
    vim.api.nvim_buf_set_extmark(buf, NS, r - 1, 1, {
      end_col = 2,
      hl_group = STATUS_HL[e.status] or 'OrcaPanelChanged',
    })
    local n = counts and counts[e.path]
    if n and n > 0 then
      -- ` X *n` — the token starts after space+letter+space (col 3).
      vim.api.nvim_buf_set_extmark(buf, NS, r - 1, 3, {
        end_col = 3 + #('*%d'):format(n),
        hl_group = 'OrcaPanelCount',
      })
    end
    -- The line counts ride the window's right edge as virt_text rather
    -- than buffer text: the panel is as wide as the window, which the
    -- user resizes, and right_align re-places them on every redraw for
    -- free. In a panel narrow enough for a name to reach them they cover
    -- its tail — the full-width bottom strip makes that rare, and the
    -- alternative is a name that pushes the counts off the screen.
    local stat = diffstat(e, aw, dw)
    if stat then
      vim.api.nvim_buf_set_extmark(buf, NS, r - 1, 0, {
        virt_text = stat,
        virt_text_pos = 'right_align',
        hl_mode = 'combine',
      })
    end
  end
  if summary then
    vim.api.nvim_buf_set_extmark(buf, NS, summary - 1, 0, { line_hl_group = 'OrcaPanelHidden' })
  end
  local cur = row_of(view, index)
  if cur then
    vim.api.nvim_buf_set_extmark(buf, NS, cur - 1, 0, {
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
function M.open(entries, index, counts, view, title)
  define_hl()
  local buf = ensure_buf()
  local win = M.win()
  if not win then
    -- noautocmd: :split briefly shows the current buffer in the new
    -- window, and a BufEnter for it would ripple through the session's
    -- navigation follower.
    vim.cmd(('noautocmd botright %dsplit'):format(math.max(1, math.min(height(view), 10))))
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
  render(entries, index, counts, view)
  local cur = row_of(view, index)
  if cur then pcall(vim.api.nvim_win_set_cursor, win, { cur, 0 }) end
  return buf
end

-- Re-render from session state; when the panel window is not focused, park
-- its cursor on the current row too, so entering the panel always lands on
-- the current file (the qf `idx` behavior, kept).
function M.refresh(entries, index, counts, view)
  if not M.buf() then return end
  render(entries, index, counts, view)
  local win = M.win()
  local cur = row_of(view, index)
  if win and win ~= vim.api.nvim_get_current_win() and cur then
    pcall(vim.api.nvim_win_set_cursor, win, { cur, 0 })
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
