-- orca.nvim — branch review inside the user's own Neovim, the human half
-- of an orca run's review. Orca-managed repositories only: .orca/ must
-- exist at the repo root.
--
-- A session is the merge-base diff of <base>...<head>: changed files in an
-- orca-owned panel (orca/panel.lua — a buffer nothing else can evict, where
-- the quickfix list was shared territory), pinned open for as long as the
-- session lives, with one side-by-side diff pair at a time beside it. The
-- session's navigation keys are global for the same span, so the review
-- answers from outside its own buffers too — a grep result, :help, a file
-- that isn't in the diff. Session state is module-local and dies with it; the
-- one artifact that outlives it is the review-notes file (orca/notes.lua) —
-- line-anchored comments under .orca/review-notes/ that flow back into the
-- orca run.
--
-- What the panel lists is a view over the session's entries, not the
-- entries themselves (orca/filter.lua): named groups — tests by default —
-- fold away behind the panel's summary row, while the entry list stays
-- whole, so a hidden file still opens by :edit, still anchors comments,
-- and still walks with the comment motions.

local git = require('orca.git')
local pairview = require('orca.diff')
local notes = require('orca.notes')
local panel = require('orca.panel')
local filter = require('orca.filter')

local M = {}

local AUGROUP = 'orca-review'
local session = nil

local function notify(msg, level)
  vim.notify('orca: ' .. msg, level or vim.log.levels.INFO)
end

-- Convenience maps; the :Orca* commands are the public API. The session's
-- navigation verbs are mapped globally for as long as it lives (see
-- GLOBAL_ACTIONS below) and the line-anchored ones only in the buffers it
-- owns; both go away when it lets go.
-- vim.g.orca_mappings reshapes them: a table overrides per action (a
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
local ACTIONS = {
  { 'next', function() M.next(vim.v.count1) end, 'orca: next file' },
  { 'prev', function() M.prev(vim.v.count1) end, 'orca: previous file' },
  { 'comment', function() M.comment(vim.fn.line('.'), vim.fn.line('.')) end,
    'orca: comment on this line', ':OrcaComment<CR>' },
  { 'delete', function() M.comment_delete() end, 'orca: delete the comment on this line' },
  { 'comment_next', function() M.comment_next() end, 'orca: next comment' },
  { 'comment_prev', function() M.comment_prev() end, 'orca: previous comment' },
  { 'panel', function() M.panel() end, 'orca: focus the review panel, or go back' },
  { 'hidden', function() M.toggle_hidden() end, 'orca: show or hide the grouped files' },
  { 'close', function() M.close() end, 'orca: close review' },
}

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

-- The key an action is announced by: the first one bound, which is the
-- keyboard one — "<2-LeftMouse> opens a diff" is not a hint anybody needs.
local function key_of(maps, action)
  local keys = maps[action]
  return keys and keys[1]
end

local function buf_map(buf, lhs, rhs, desc, mode)
  vim.keymap.set(mode or 'n', lhs, rhs, { buffer = buf, nowait = true, desc = desc })
  session.mapped[buf] = session.mapped[buf] or {}
  session.mapped[buf][lhs] = true
end

local function attach_maps(buf)
  for _, a in ipairs(ACTIONS) do
    if not GLOBAL_ACTIONS[a[1]] then
      for _, lhs in ipairs(session.maps[a[1]] or {}) do
        buf_map(buf, lhs, a[2], a[3])
        if a[4] then buf_map(buf, lhs, a[4], a[3], 'x') end
      end
    end
  end
end

-- The session's global maps, set once at :OrcaReview and undone at
-- :OrcaReviewClose. maparg() reports the *current buffer's* mapping ahead
-- of the global one, so what a key meant before is asked from inside an
-- empty scratch buffer, where nothing is buffer-local — otherwise a review
-- started from a buffer with an LSP map on the same key would hand that
-- map back globally at close.
local function attach_globals()
  local probe = vim.api.nvim_create_buf(false, true)
  local function previous(lhs)
    local ok, prev = pcall(vim.api.nvim_buf_call, probe, function()
      return vim.fn.maparg(lhs, 'n', false, true)
    end)
    if ok and type(prev) == 'table' and next(prev) ~= nil then return prev end
    return false
  end
  for _, a in ipairs(ACTIONS) do
    if GLOBAL_ACTIONS[a[1]] then
      for _, lhs in ipairs(session.maps[a[1]] or {}) do
        if session.globals[lhs] == nil then session.globals[lhs] = previous(lhs) end
        vim.keymap.set('n', lhs, a[2], { desc = a[3] })
      end
    end
  end
  pcall(vim.api.nvim_buf_delete, probe, { force = true })
end

-- Hand every taken key back exactly as it was found: restored when it meant
-- something, deleted when it meant nothing.
local function detach_globals()
  for lhs, prev in pairs(session.globals) do
    pcall(vim.keymap.del, 'n', lhs)
    if prev then pcall(vim.fn.mapset, 'n', 0, prev) end
  end
  session.globals = {}
end

local function detach_maps(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    for lhs in pairs(session.mapped[buf] or {}) do
      for _, mode in ipairs({ 'n', 'x' }) do
        pcall(vim.keymap.del, mode, lhs, { buffer = buf })
      end
    end
  end
  session.mapped[buf] = nil
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
local function open_click()
  local win = panel.win()
  local pos = vim.fn.getmousepos()
  if not win or pos.winid ~= win or pos.line < 1 then return end
  -- The panel never wraps, folds, or carries virtual lines, so the row
  -- under the pointer is exactly topline + winrow - 1.
  local top = vim.api.nvim_win_call(win, function() return vim.fn.line('w0') end)
  if top + pos.winrow - 1 > vim.api.nvim_buf_line_count(panel.buf()) then return end
  M.open_row(pos.line)
end

-- The panel buffer is orca's alone — no ftplugin re-runs, no last-writer
-- mapping race, no list identity to check. Maps are set once per buffer
-- (the buffer outlives its window, so reopening needs no re-assert).
local function attach_panel_maps(buf)
  attach_maps(buf)
  for _, lhs in ipairs(session.maps.open or {}) do
    if is_pointer(lhs) then
      buf_map(buf, lhs, open_click, "orca: open the clicked file's diff")
    else
      buf_map(buf, lhs, function() M.open_row(vim.fn.line('.')) end,
        "orca: open this file's diff")
    end
  end
end

-- Is the panel pinned open for the session? It is: the panel is the
-- review's map — what is left, what you have already said something about,
-- where you are in the walk — and a review that has lost it is one
-- navigating blind, with nothing on screen saying so. So closing its window
-- no longer hides it; the window comes straight back, and the way out is
-- ending the session. vim.g.orca_panel_pinned = false restores the old
-- closable panel for anyone who wants the rows back as screen space.
local function resolve_pinned()
  local v = vim.g.orca_panel_pinned
  if v == nil then return true end
  return v and true or false
end

-- Do sessions start with the groups folded away? They do: an orca run's
-- diff is usually mostly tests, and the look-through before merge wants
-- the source in front of it. vim.g.orca_review_hidden = false opts out.
-- Resolved once per session, like the mappings.
local function resolve_hidden()
  local v = vim.g.orca_review_hidden
  if v == nil then return true end
  return v and true or false
end

-- The panel's view over session.entries: which entries it shows, in
-- order, and what the groups claim. Three things pin an entry visible
-- whatever its group says — a comment on it (you have already said
-- something about this file), being the file the session is currently in
-- (you are looking at it), and being the last one left. That last one is
-- the only place the default overrides itself: hiding every file would
-- open a review with nothing in it, so an all-tests branch shows
-- everything and says so.
local function recompute_view(counts)
  counts = counts or notes.counts()
  local classify = filter.classifier()
  local rows, groups, n = {}, {}, 0
  for i, e in ipairs(session.entries) do
    local group
    if i ~= session.index and (counts[e.path] or 0) == 0 then group = classify(e) end
    if group then
      groups[group] = (groups[group] or 0) + 1
      n = n + 1
    end
    if not (group and session.hidden) then rows[#rows + 1] = i end
  end
  local blocked = session.hidden and #rows == 0
  if blocked then
    session.hidden = false
    rows = {}
    for i = 1, #session.entries do rows[i] = i end
  end
  session.view = { rows = rows, groups = groups, n = n, hidden = session.hidden,
    blocked = blocked }
  return blocked
end

local function refresh_panel()
  if not session then return end
  local counts = notes.counts()
  recompute_view(counts)
  panel.refresh(session.entries, session.index, counts, session.view)
end

-- Open (or focus) the panel window, re-rendered from session state.
local function show_panel()
  local counts = notes.counts()
  recompute_view(counts)
  local buf = panel.open(session.entries, session.index, counts, session.view,
    'OrcaReview ' .. session.range)
  attach_panel_maps(buf)
end

-- Put the pinned panel back, without taking focus from wherever the user
-- is: a panel returning is something you notice at the edge of the screen,
-- not with your cursor. The split is made from an ordinary window —
-- :split from a float is a different operation, and a picker preview is a
-- perfectly ordinary place to be standing when :only takes the panel out.
-- nvim_win_call rather than a pair of nvim_set_current_win calls: it fires
-- no WinEnter/BufEnter for the detour, so the navigation follower never
-- sees a window the user never visited.
local function ensure_panel()
  if not session or not session.pinned or panel.win() then return end
  local cur = vim.api.nvim_get_current_win()
  local from = cur
  if vim.api.nvim_win_get_config(from).relative ~= '' then
    from = nil
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative == '' then
        from = w
        break
      end
    end
    if not from then return end
  end
  local was = session.navigating
  session.navigating = true
  pcall(vim.api.nvim_win_call, from, show_panel)
  session.navigating = was
  if vim.api.nvim_win_is_valid(cur) and vim.api.nvim_get_current_win() ~= cur then
    pcall(vim.api.nvim_set_current_win, cur)
  end
end

-- Hand the pair on screen back: its maps detached and `session.last_win`
-- left pointing at the window it held, so the next pair lands where this one
-- was. Clearing `session.pair` is the caller's — M.open lets go of the
-- record here and then offers it to pairview.open as the one to take over.
local function release_pair(pair)
  session.last_win = pair.right_win
  for _, buf in ipairs(pair.bufs) do detach_maps(buf) end
end

local function teardown_pair()
  local pair = session.pair
  if not pair then return end
  session.pair = nil
  local was = session.navigating
  session.navigating = true
  release_pair(pair)
  pairview.close(pair)
  session.navigating = was
end

-- The window the next diff pair's right side goes into: the previous
-- pair's, else the current or first ordinary window, else a fresh split.
-- Never the panel (by id — its buffer is nofile like the pair's scratch
-- side) and never a quickfix window (a foreign :grep list may be open
-- mid-session, and its window must stay the user's).
local function pick_window()
  local function usable(w)
    return w and vim.api.nvim_win_is_valid(w)
      and vim.api.nvim_win_get_config(w).relative == ''
      and w ~= panel.win()
      and vim.bo[vim.api.nvim_win_get_buf(w)].buftype ~= 'quickfix'
  end
  if usable(session.last_win) then return session.last_win end
  local cur = vim.api.nvim_get_current_win()
  if usable(cur) then return cur end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(w) then return w end
  end
  vim.cmd('topleft new')
  return vim.api.nvim_get_current_win()
end

-- While the session lives, the diff pair follows navigation: entering a
-- changed file by any route (picker, gd, :edit) opens its pair around the
-- window the user landed in; a foreign buffer landing in a pair window
-- collapses the pair. The collapse is load-bearing, not polish — 'diff' and
-- 'scrollbind' are window-local, so the wandered-to buffer would otherwise
-- inherit diff mode against the previous file's still-open scratch. The
-- session itself survives a collapse.
local function follow_navigation()
  if not session or session.navigating then return end
  -- Pickers preview into floats; entering one must not collapse anything.
  if vim.api.nvim_win_get_config(0).relative ~= '' then return end
  local buf = vim.api.nvim_get_current_buf()
  -- Entering the panel's own buffer is the panel arriving, not leaving —
  -- and it fires mid-open, before the window is recorded, so reasserting
  -- here would build a second panel on top of the first.
  if buf == panel.buf() then return end
  -- A foreign buffer landing in the panel's window takes the panel away
  -- without ever closing a window, so WinClosed alone would miss it. The
  -- check is two API calls on a hook that already runs on every BufEnter.
  ensure_panel()
  local pair = session.pair
  if pair then
    for _, owned in ipairs({ pair.bufs, pair.scratch }) do
      if vim.tbl_contains(owned, buf) then return end
    end
  end

  local idx
  local prefix = session.toplevel .. '/'
  local name = vim.api.nvim_buf_get_name(buf)
  if name:sub(1, #prefix) == prefix then
    idx = session.by_path[name:sub(#prefix + 1)]
  end

  if idx then
    -- Re-entering the file whose pair is already current must be a no-op:
    -- a binary "pair" is a plain :edit of the very buffer just entered,
    -- and reopening it here would loop open → BufEnter → open.
    if idx == session.index and pair then return end
    session.last_win = vim.api.nvim_get_current_win()
    -- A pair the entered file can take over rebuilds right now, in this
    -- BufEnter: nothing splits, so none of the reasons to wait apply, and
    -- waiting is visible — the deferred rebuild lets the screen draw the new
    -- file beside the *previous* file's merge base first, one frame of a
    -- diff against the wrong side.
    if pairview.reusable(pair, session.entries[idx], session.last_win) then
      return M.open(idx)
    end
    -- Otherwise deferred one tick: this BufEnter may be firing mid-:close
    -- (focus falling back into a changed file's window), and the pair's
    -- split is illegal while another window is closing (E242).
    local s = session
    vim.schedule(function()
      if session ~= s then return end
      if idx == session.index and session.pair then return end
      M.open(idx)
    end)
  elseif pair then
    local cur = vim.api.nvim_get_current_win()
    if cur == pair.right_win or cur == pair.left_win then teardown_pair() end
  end
end

-- Start (or restart) a review session. `range` is '<base>...<head>', a bare
-- '<base>' (head defaults to HEAD), or empty for <trunk>...HEAD.
function M.review(range)
  if session then M.close() end

  local base, head
  if range and range ~= '' then
    base, head = range:match('^(.-)%.%.%.(.*)$')
    if not base or base == '' then base, head = range, '' end
    if head == '' then head = 'HEAD' end
  else
    local trunk, err = git.trunk()
    if not trunk then return notify(err, vim.log.levels.ERROR) end
    base, head = trunk, 'HEAD'
  end

  local toplevel, terr = git.toplevel()
  if not toplevel then return notify(terr, vim.log.levels.ERROR) end

  -- Orca-only gate: the plugin is the human half of orca's review, not a
  -- general diff tool. .orca/ lives at the repo root — the parent of the
  -- common git dir, the same rule the orca skills use.
  local root, rerr = git.repo_root()
  if not root then return notify(rerr, vim.log.levels.ERROR) end
  if vim.fn.isdirectory(root .. '/.orca') == 0 then
    return notify(('no .orca/ at %s — orca.nvim reviews orca-managed repositories; run /orca:init first')
      :format(root), vim.log.levels.ERROR)
  end

  local mergebase, mberr = git.merge_base(base, head)
  if not mergebase then return notify(mberr, vim.log.levels.ERROR) end
  local entries, derr = git.changed_files(mergebase, head)
  if not entries then return notify(derr, vim.log.levels.ERROR) end
  if #entries == 0 then
    return notify(('nothing to review — %s...%s has no changes'):format(base, head))
  end

  session = {
    entries = entries,
    index = 0,
    hidden = resolve_hidden(),
    pinned = resolve_pinned(),
    mergebase = mergebase,
    toplevel = toplevel,
    range = base .. '...' .. head,
    mapped = {},
    by_path = {},
    maps = resolve_mappings(),
    globals = {},
  }
  for i, e in ipairs(entries) do session.by_path[e.path] = i end
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  -- One session-wide hook covers every navigation route. nested, so the
  -- :edit it triggers still fires filetype/LSP autocmds; re-entrancy is cut
  -- by session.navigating instead.
  vim.api.nvim_create_autocmd('BufEnter', {
    group = AUGROUP,
    nested = true,
    callback = follow_navigation,
  })

  -- The pinned panel's other half: a window closing under it — :q, CTRL-W_c,
  -- :only, a window-management plugin tidying up — puts it straight back.
  -- Deferred one tick because splitting while another window is closing is
  -- illegal (E242), and guarded on the session still being this one, so the
  -- close that ends the session never resurrects what it just destroyed.
  vim.api.nvim_create_autocmd('WinClosed', {
    group = AUGROUP,
    callback = function(args)
      local s = session
      if not s or not s.pinned or tonumber(args.match) ~= panel.win() then return end
      vim.schedule(function()
        if session == s then ensure_panel() end
      end)
    end,
  })

  -- The notes layer: existing comments for this branch load here, so
  -- multi-sitting reviews and orca's resolutions show up immediately.
  -- Every notes save refreshes the panel, keeping comment counts live.
  local loaded = notes.start({ root = root, toplevel = toplevel, range = session.range,
    head = head, on_change = refresh_panel })

  show_panel()
  attach_globals()

  local m = session.maps
  local hints = {}
  local open_key, next_key = key_of(m, 'open'), key_of(m, 'next')
  local prev_key = key_of(m, 'prev')
  if open_key then hints[#hints + 1] = open_key .. ' opens a diff' end
  if next_key and prev_key then
    hints[#hints + 1] = ('%s/%s move'):format(next_key, prev_key)
  else
    -- Unbound by default; naming the commands keeps them discoverable.
    hints[#hints + 1] = (next_key or prev_key or ':OrcaReviewNext') .. ' moves'
  end
  hints[#hints + 1] = (key_of(m, 'comment') or ':OrcaComment') .. ' comments a line'
  -- Hiding is never silent: when a group folded anything away, the count
  -- and the way back are in the line that opens the session, whether or
  -- not the `hidden` action is bound to a key.
  local view = session.view
  if view.n > 0 then
    hints[#hints + 1] = ('%s %s them'):format(key_of(m, 'hidden') or '<CR> on the … row',
      view.hidden and 'shows' or ('hides ' .. view.n))
  end
  notify(('%d file%s in %s%s%s%s'):format(#entries, #entries == 1 and '' or 's', session.range,
    view.hidden and (', %d hidden'):format(view.n) or '',
    loaded > 0 and (', %d comment%s loaded'):format(loaded, loaded == 1 and '' or 's') or '',
    #hints > 0 and (' — ' .. table.concat(hints, ', ')) or ''))
  if view.blocked then
    notify(('every file in %s is in a hidden group — showing all %d')
      :format(session.range, #entries))
  end
  M.open(view.rows[1])
end

-- An open comment editor and the file under it are one thing: the editor
-- hangs in an extmark gap in that file's buffer, at a screen position that
-- window's scroll decides, and the pair it floats over is about to be torn
-- down. So every file change resolves it first — a leftover editor over the
-- next file is a window with no gap under it, still holding the slot the
-- next :OrcaComment wants. An editor nobody typed into just gets out of the
-- way; one holding unwritten words keeps the keystroke, which goes to
-- revealing it instead: nobody presses "next file" meaning "throw that
-- away". Returns true when the caller must stand down.
local function editor_holds_the_keystroke()
  if not notes.input_pending() then
    notes.close_input()
    return false
  end
  notes.focus_input()
  notify('the comment is unwritten — :w commits it, :q throws it away',
    vim.log.levels.WARN)
  return true
end

-- Open the diff pair for the idx-th changed file.
function M.open(idx)
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  if editor_holds_the_keystroke() then return end
  idx = math.max(1, math.min(idx, #session.entries))
  session.navigating = true
  session.index = idx
  local entry = session.entries[idx]

  -- The pair on screen is handed to the new one rather than torn down, when
  -- the entry can take it over: swapping its two buffers is what keeps the
  -- layout from reflowing — and the working-tree file from being re-read —
  -- every time a jump lands in a changed file. A pair the new entry cannot
  -- use (the user took one of its windows, or this entry is binary and wants
  -- no split) comes down the old way first.
  local old = session.pair
  session.pair = nil
  if old then release_pair(old) end
  local win = pick_window()
  if old and not pairview.reusable(old, entry, win) then
    pairview.close(old)
    old = nil
  end

  local ok, pair, err = pcall(pairview.open, entry, session.mergebase, session.toplevel, win, old)
  session.navigating = false
  if not ok then pair, err = nil, pair end
  if not pair then
    refresh_panel()
    return notify(('%s: %s'):format(entry.path, err or 'cannot open'), vim.log.levels.ERROR)
  end
  session.pair = pair
  for _, buf in ipairs(pair.bufs) do attach_maps(buf) end
  -- Anchor this file's comments in the working-tree side (deleted files
  -- have none — their right side is a scratch).
  if not entry.binary and entry.status ~= 'D' then
    notes.decorate(pair.bufs[#pair.bufs], entry.path)
  end

  -- If a scratch side goes away by any route (teardown, :bwipeout, window
  -- juggling), diff mode must not outlive it on the survivor.
  for _, sbuf in ipairs(pair.scratch) do
    vim.api.nvim_create_autocmd('BufWipeout', {
      group = AUGROUP,
      buffer = sbuf,
      callback = function() pairview.diffoff(pair) end,
    })
  end

  refresh_panel()
  if entry.binary then notify(entry.path .. ' is binary — opened without a diff') end
end

-- Open the file on panel row `row`. The panel's rows are the view's, so
-- row and entry index part ways the moment a group folds something away;
-- the row past the last file is the summary row, whose <CR> toggles.
function M.open_row(row)
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  local idx = session.view.rows[row]
  if idx then return M.open(idx) end
  M.toggle_hidden()
end

-- Move count files forward/back (default 1) through the panel's view:
-- what the groups folded away is not something the walk stops on. At the
-- edge, a polite message; a count that would overshoot clamps to the edge
-- instead of erroring.
local function walk(dir, count)
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  local rows = session.view.rows
  local pos
  for r, i in ipairs(rows) do
    if i == session.index then
      pos = r
      break
    end
  end
  -- No position yet (nothing opened) — start at the near end.
  if not pos then return M.open(rows[dir > 0 and 1 or #rows]) end
  if dir > 0 and pos >= #rows then return notify('already at the last file') end
  if dir < 0 and pos <= 1 then return notify('already at the first file') end
  M.open(rows[math.max(1, math.min(pos + dir * (count or 1), #rows))])
end

function M.next(count) walk(1, count) end
function M.prev(count) walk(-1, count) end

-- The hidden-groups toggle: <CR> on the panel's summary row, the `hidden`
-- mapping action, and this function for anyone driving orca from their own
-- keymap layer. There is no command — like `open`, this is an action on
-- the panel, and the row is always there to carry it.
function M.toggle_hidden()
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  session.hidden = not session.hidden
  refresh_panel()
  local view = session.view
  if view.blocked then
    return notify(('every file in %s is in a hidden group — showing all %d')
      :format(session.range, #session.entries))
  end
  if view.n == 0 then return notify('no files match the hidden groups in this review') end
  notify(view.hidden and ('%d file%s hidden'):format(view.n, view.n == 1 and '' or 's')
    or ('showing all %d files'):format(#session.entries))
end

-- The panel's focus ladder — one function behind both :OrcaReviewPanel and
-- the `panel` mapping action: not there → open and focus; there but
-- unfocused → focus; focused → back to the diff. That last rung used to
-- close the window, which a pinned panel has no use for: with the panel
-- always on screen the round trip is what the key is for, and pressing it
-- twice leaves you where you started. vim.g.orca_panel_pinned = false puts
-- the close back.
function M.panel()
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  local win = panel.win()
  if not win then
    show_panel()
  elseif vim.api.nvim_get_current_win() ~= win then
    vim.api.nvim_set_current_win(win)
  elseif not session.pinned then
    panel.close()
  else
    -- Back to the file under review: the pair's working-tree side, else
    -- whatever ordinary window pick_window() would put the next pair in.
    local back = session.pair and session.pair.right_win
    if not (back and vim.api.nvim_win_is_valid(back)) then back = pick_window() end
    pcall(vim.api.nvim_set_current_win, back)
  end
end

-- Review-wide comment walk. Comments are orca's own extmarks — nothing
-- native can find them — so orca walks them itself: file order (the
-- session's), then line, crossing files through M.open. Lines come from
-- notes.locations(), extmark-resolved, so positions self-heal after edits.
local function comment_walk(dir)
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  -- Checked here too, not just in M.open: this walk moves the cursor after
  -- the file change, and a refused change must not leave it doing that.
  if editor_holds_the_keystroke() then return end
  local locs = {}
  for _, l in ipairs(notes.locations()) do
    l.fidx = session.by_path[l.path]
    if l.fidx then locs[#locs + 1] = l end
  end
  if #locs == 0 then return notify('no comments in this review') end
  table.sort(locs, function(a, b)
    if a.fidx ~= b.fidx then return a.fidx < b.fidx end
    return a.line < b.line
  end)

  -- Current position: the cursor when it sits in a reviewed file's
  -- working-tree buffer; from anywhere else (the panel, a scratch side),
  -- the current file's near boundary, so the walk enters it naturally.
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local prefix = session.toplevel .. '/'
  local here = vim.bo[buf].buftype == '' and name:sub(1, #prefix) == prefix
    and session.by_path[name:sub(#prefix + 1)] or nil
  local cidx = here or session.index
  local cline = here and vim.fn.line('.') or (dir > 0 and 0 or math.huge)

  local target
  if dir > 0 then
    for _, l in ipairs(locs) do
      if l.fidx > cidx or (l.fidx == cidx and l.line > cline) then
        target = l
        break
      end
    end
  else
    for i = #locs, 1, -1 do
      if locs[i].fidx < cidx or (locs[i].fidx == cidx and locs[i].line < cline) then
        target = locs[i]
        break
      end
    end
  end
  if not target then
    return notify(dir > 0 and 'already at the last comment' or 'already at the first comment')
  end

  if target.fidx ~= here then M.open(target.fidx) end
  pcall(vim.api.nvim_win_set_cursor, 0,
    { math.min(target.line, vim.api.nvim_buf_line_count(0)), 0 })
end

function M.comment_next() comment_walk(1) end
function M.comment_prev() comment_walk(-1) end

-- The anchor for :OrcaComment — the current buffer must be the working-
-- tree (right) side of a changed text file. The left side is a base-
-- version scratch ("this deletion was wrong" has no working-tree anchor —
-- v1 punts), and deleted/binary entries have no commentable right side.
local function comment_target()
  if not session then
    notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local prefix = session.toplevel .. '/'
  local idx = name:sub(1, #prefix) == prefix and session.by_path[name:sub(#prefix + 1)]
  local entry = idx and session.entries[idx]
  if not entry or entry.binary or vim.bo[buf].buftype ~= '' then
    notify('comments anchor to the working-tree side of a changed text file', vim.log.levels.WARN)
    return
  end
  return entry.path, buf
end

-- Create or edit the review comment on the given line(s) of the current
-- buffer: normal mode anchors the cursor line, a visual range the whole
-- selection; on an already-commented line the existing comment opens for
-- editing. Input is a small scratch split — :w commits, quitting without
-- writing aborts, committing empty text deletes.
function M.comment(line1, line2)
  local path, buf = comment_target()
  if path then notes.comment(path, buf, line1, line2) end
end

-- Delete the comment under the cursor.
function M.comment_delete()
  local path = comment_target()
  if path then notes.delete(path, vim.fn.line('.')) end
end

-- End the session: notes saved and their extmarks cleared, diff pair torn
-- down, panel destroyed, scratch buffers wiped, keymaps removed (the
-- session's global ones handed back to whatever they meant before), augroup
-- cleared. The one survivor is the notes file — persisting is its job.
function M.close()
  if not session then return end
  -- First, so that nothing in the teardown below — a window closing, a
  -- buffer being wiped — trips the pin and builds the panel back up.
  session.pinned = false
  notes.stop()
  teardown_pair()
  for buf in pairs(session.mapped) do detach_maps(buf) end
  detach_globals()
  panel.teardown()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  session = nil
end

-- Optional sugar over vim.g.orca_mappings (what lazy.nvim's `opts` calls).
-- The global stays the single source of truth; nothing requires setup().
function M.setup(opts)
  if opts and opts.mappings ~= nil then vim.g.orca_mappings = opts.mappings end
end

return M
