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
local keymaps = require('orca.keymaps')
local notify = require('orca.util').notify

local M = {}

local AUGROUP = 'orca-review'
local session = nil

-- `fn`, refusing politely when no session is running — the one guard
-- every entry point that needs a session shares.
local function with_session(fn)
  return function(...)
    if not session then
      notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
      return
    end
    return fn(...)
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

-- Recompute the panel's view (filter.view) from session state. A view that
-- had to show everything, because the groups claimed every file, turns
-- hiding off for the session: the toggle then reads as what is on screen.
local function recompute_view(counts)
  local view = filter.view(session.entries, session.index, counts or notes.counts(),
    session.hidden, session.classify)
  if view.blocked then session.hidden = false end
  session.view = view
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
  session.keys:attach_panel(buf)
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

-- Hand the pair on screen back: its maps detached. Clearing `session.pair`
-- is the caller's — M.open lets go of the record here and then offers it to
-- pairview.open as the one to take over. Where the next pair goes is not
-- decided here: `session.last_win` is set by the open that built this one,
-- and a jump names its own window.
local function release_pair(pair)
  for _, buf in ipairs(pair.bufs) do session.keys:detach(buf) end
end

local function teardown_pair()
  local pair = session.pair
  if not pair then return end
  session.pair = nil
  local was = session.navigating
  session.navigating = true
  pcall(function()
    release_pair(pair)
    pairview.close(pair)
  end)
  session.navigating = was
end

-- The changed file `buf` is the working-tree buffer of: its index and entry,
-- or nil for anything else — scratch sides, the panel, the comment editor,
-- files outside the review.
local function entry_of(buf)
  if vim.bo[buf].buftype ~= '' then return nil end
  local prefix = session.toplevel .. '/'
  local name = vim.api.nvim_buf_get_name(buf)
  if name:sub(1, #prefix) ~= prefix then return nil end
  local idx = session.by_path[name:sub(#prefix + 1)]
  return idx, idx and session.entries[idx]
end

-- The window the next diff pair's right side goes into: the previous
-- pair's, else the current or first ordinary window, else a fresh split.
-- Never the panel (by id — its buffer is nofile like the pair's scratch
-- side) and never a quickfix window (a foreign :grep list may be open
-- mid-session, and its window must stay the user's).
local function usable(w)
  return w and vim.api.nvim_win_is_valid(w)
    and vim.api.nvim_win_get_config(w).relative == ''
    and w ~= panel.win()
    and vim.bo[vim.api.nvim_win_get_buf(w)].buftype ~= 'quickfix'
end

local function pick_window()
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

  local idx = entry_of(buf)
  if idx then
    -- Re-entering the file whose pair is already current must be a no-op:
    -- a binary "pair" is a plain :edit of the very buffer just entered,
    -- and reopening it here would loop open → BufEnter → open.
    if idx == session.index and pair then return end
    -- The pair goes where the jump landed. A window that is not the pair's
    -- own right side cannot be taken over, so the old pair comes down and
    -- the new one is built around this window.
    local win = vim.api.nvim_get_current_win()
    -- A pair the entered file can take over rebuilds right now, in this
    -- BufEnter: nothing splits, so none of the reasons to wait apply, and
    -- waiting is visible — the deferred rebuild lets the screen draw the new
    -- file beside the *previous* file's merge base first, one frame of a
    -- diff against the wrong side.
    if pairview.reusable(pair, session.entries[idx], win) then
      return M.open(idx, win)
    end
    -- Otherwise deferred one tick: this BufEnter may be firing mid-:close
    -- (focus falling back into a changed file's window), and the pair's
    -- split is illegal while another window is closing (E242).
    local s = session
    vim.schedule(function()
      if session ~= s then return end
      if idx == session.index and session.pair then return end
      M.open(idx, win)
    end)
  elseif pair then
    local cur = vim.api.nvim_get_current_win()
    if cur == pair.right_win or cur == pair.left_win then teardown_pair() end
  end
end

-- Everything a session needs from git, resolved without touching the one
-- that may be running: a range that goes nowhere must leave the review on
-- screen alone. `range` is '<base>...<head>', a bare '<base>' (head
-- defaults to HEAD), or empty for <trunk>...HEAD. Returns a plan, or nil
-- plus a message and its level.
local function resolve(range)
  local ERROR = vim.log.levels.ERROR
  local base, head
  if range and range ~= '' then
    if range:find('...', 1, true) then
      base, head = range:match('^(.-)%.%.%.(.*)$')
    elseif range:find('..', 1, true) then
      return nil, ('%s is a two-dot range — use %s: a review is the merge-base diff')
        :format(range, (range:gsub('%.%.', '...', 1))), ERROR
    end
    if not base or base == '' then base, head = range, '' end
    if head == '' then head = 'HEAD' end
  else
    local trunk, err = git.trunk()
    if not trunk then return nil, err, ERROR end
    base, head = trunk, 'HEAD'
  end

  local toplevel, terr = git.toplevel()
  if not toplevel then return nil, terr, ERROR end

  -- Orca-only gate: the plugin is the human half of orca's review, not a
  -- general diff tool. .orca/ lives at the repo root — the parent of the
  -- common git dir, the same rule the orca skills use.
  local root, rerr = git.repo_root()
  if not root then return nil, rerr, ERROR end
  if vim.fn.isdirectory(root .. '/.orca') == 0 then
    return nil, ('no .orca/ at %s — orca.nvim reviews orca-managed repositories; run /orca:init first')
      :format(root), ERROR
  end

  -- The queries below ask this repository, not a running session's.
  local prev_root = git.root
  git.root = toplevel
  local function fail(msg, level)
    git.root = prev_root
    return nil, msg, level or ERROR
  end
  -- The right side of every pair is the working tree, so a head that is
  -- not the checked-out commit would show other content than it names, and
  -- file its comments under its key regardless.
  local head_sha = git.rev(head)
  if not head_sha then return fail(('%s is not a commit here'):format(head)) end
  if head_sha ~= git.rev('HEAD') then
    local branch = git.branch_of(head)
    local wt = branch and git.worktree_of(branch)
    return fail(('%s is not checked out here — a review\'s right side is the working tree; %s')
      :format(head, wt and ('review it from its worktree, ' .. wt) or 'check it out first'))
  end
  local mergebase, mberr = git.merge_base(base, head)
  if not mergebase then return fail(mberr) end
  local entries, derr = git.changed_files(mergebase, head)
  if not entries then return fail(derr) end
  if #entries == 0 then
    return fail(('nothing to review — %s...%s has no changes'):format(base, head),
      vim.log.levels.INFO)
  end
  git.root = prev_root
  return { base = base, head = head, toplevel = toplevel, root = root,
    mergebase = mergebase, entries = entries }
end

-- Start (or restart) a review session. A running session is closed only
-- once the new one is known to be good.
function M.review(range)
  local plan, err, level = resolve(range)
  if not plan then return notify(err, level) end
  if session then M.close() end
  local base, head, toplevel, root = plan.base, plan.head, plan.toplevel, plan.root
  local mergebase, entries = plan.mergebase, plan.entries
  -- From here on every git query asks this repository, whatever the cwd
  -- does next.
  git.root = toplevel

  session = {
    entries = entries,
    index = 0,
    hidden = resolve_hidden(),
    -- The group config, read once: a bad one warns at session start, not
    -- on every refresh after it.
    classify = filter.classifier(),
    pinned = resolve_pinned(),
    mergebase = mergebase,
    toplevel = toplevel,
    range = base .. '...' .. head,
    by_path = {},
    -- Looked up through M when a key fires, as the maps always have.
    keys = keymaps.new({
      next = function(n) M.next(n) end,
      prev = function(n) M.prev(n) end,
      comment = function(l1, l2) M.comment(l1, l2) end,
      delete = function() M.comment_delete() end,
      comment_next = function() M.comment_next() end,
      comment_prev = function() M.comment_prev() end,
      panel = function() M.panel() end,
      hidden = function() M.toggle_hidden() end,
      close = function() M.close() end,
      open_row = function(row) M.open_row(row) end,
    }),
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
  session.keys:attach_globals()

  local k = session.keys
  local hints = {}
  local open_key, next_key = k:key_of('open'), k:key_of('next')
  local prev_key = k:key_of('prev')
  if open_key then hints[#hints + 1] = open_key .. ' opens a diff' end
  if next_key and prev_key then
    hints[#hints + 1] = ('%s/%s move'):format(next_key, prev_key)
  else
    -- Unbound by default; naming the commands keeps them discoverable.
    hints[#hints + 1] = (next_key or prev_key or ':OrcaReviewNext') .. ' moves'
  end
  hints[#hints + 1] = (k:key_of('comment') or ':OrcaComment') .. ' comments a line'
  -- Hiding is never silent: when a group folded anything away, the count
  -- and the way back are in the line that opens the session, whether or
  -- not the `hidden` action is bound to a key.
  local view = session.view
  if view.n > 0 then
    hints[#hints + 1] = ('%s %s'):format(k:key_of('hidden') or '<CR> on the … row',
      view.hidden and 'shows them' or ('hides ' .. view.n))
  end
  notify(('%d file%s in %s%s%s%s'):format(#entries, #entries == 1 and '' or 's', session.range,
    (view.hidden and view.n > 0) and (', %d hidden'):format(view.n) or '',
    loaded > 0 and (', %d comment%s loaded'):format(loaded, loaded == 1 and '' or 's') or '',
    #hints > 0 and (' — ' .. table.concat(hints, ', ')) or ''))
  if view.blocked then
    notify(('every file in %s is in a hidden group — showing all %d')
      :format(session.range, #entries))
  end
  M.open(view.rows[1])
end

-- Open the diff pair for the idx-th changed file, with its right side in
-- `win` when that is given and usable, else wherever pick_window() says.
M.open = with_session(function(idx, win)
  -- An open comment editor hangs in the pair about to be taken down. What
  -- it holds is already the comment's, so it just closes.
  notes.close_input()
  idx = math.max(1, math.min(idx, #session.entries))
  session.navigating = true
  session.index = idx
  local entry = session.entries[idx]

  -- The pair on screen is handed to the new one rather than torn down, when
  -- the entry can take it over: swapping its two buffers is what keeps the
  -- layout from reflowing — and the working-tree file from being re-read —
  -- every time a jump lands in a changed file. A pair the new entry cannot
  -- use (the user took one of its windows, or this entry is binary and wants
  -- no split) comes down the old way first. All of it is protected, the
  -- teardown included: session.navigating must come back down whatever
  -- throws, or the navigation follower stays off for good.
  local ok, pair, err = pcall(function()
    local old = session.pair
    session.pair = nil
    if old then release_pair(old) end
    if not usable(win) then win = pick_window() end
    if old and not pairview.reusable(old, entry, win) then
      pairview.close(old)
      old = nil
    end
    return pairview.open(entry, session.mergebase, session.toplevel, win, old)
  end)
  session.navigating = false
  if not ok then pair, err = nil, pair end
  if not pair then
    refresh_panel()
    return notify(('%s: %s'):format(entry.path, err or 'cannot open'), vim.log.levels.ERROR)
  end
  session.pair = pair
  session.last_win = pair.right_win
  for _, buf in ipairs(pair.bufs) do session.keys:attach(buf) end
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
end)

-- Open the file on panel row `row`. The panel's rows are the view's, so
-- row and entry index part ways the moment a group folds something away;
-- the row past the last file is the summary row, whose <CR> toggles.
M.open_row = with_session(function(row)
  local idx = session.view.rows[row]
  if idx then return M.open(idx) end
  M.toggle_hidden()
end)

-- Move count files forward/back (default 1) through the panel's view:
-- what the groups folded away is not something the walk stops on. At the
-- edge, a polite message; a count that would overshoot clamps to the edge
-- instead of erroring.
local walk = with_session(function(dir, count)
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
end)

function M.next(count) walk(1, count) end
function M.prev(count) walk(-1, count) end

-- The hidden-groups toggle: <CR> on the panel's summary row, the `hidden`
-- mapping action, and this function for anyone driving orca from their own
-- keymap layer. There is no command — like `open`, this is an action on
-- the panel, and the row is always there to carry it.
M.toggle_hidden = with_session(function()
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
end)

-- The panel's focus ladder — one function behind both :OrcaReviewPanel and
-- the `panel` mapping action: not there → open and focus; there but
-- unfocused → focus; focused → back to the diff. That last rung used to
-- close the window, which a pinned panel has no use for: with the panel
-- always on screen the round trip is what the key is for, and pressing it
-- twice leaves you where you started. vim.g.orca_panel_pinned = false puts
-- the close back.
M.panel = with_session(function()
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
end)

-- Review-wide comment walk. Comments are orca's own extmarks — nothing
-- native can find them — so orca walks them itself: file order (the
-- session's), then line, crossing files through M.open. Lines come from
-- notes.locations(), extmark-resolved, so positions self-heal after edits.
local comment_walk = with_session(function(dir)
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
  local here = entry_of(vim.api.nvim_get_current_buf())
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
end)

function M.comment_next() comment_walk(1) end
function M.comment_prev() comment_walk(-1) end

-- The anchor for :OrcaComment — the current buffer must be the working-
-- tree (right) side of a changed text file. The left side is a base-
-- version scratch ("this deletion was wrong" has no working-tree anchor —
-- v1 punts), and deleted/binary entries have no commentable right side.
local comment_target = with_session(function()
  local buf = vim.api.nvim_get_current_buf()
  local _, entry = entry_of(buf)
  if not entry or entry.binary then
    notify('comments anchor to the working-tree side of a changed text file', vim.log.levels.WARN)
    return
  end
  return entry.path, buf
end)

-- Create or edit the review comment on the given line(s) of the current
-- buffer: normal mode anchors the cursor line, a visual range the whole
-- selection; on an already-commented line the existing comment opens for
-- editing. The editor is the comment — what you type is saved as you type.
function M.comment(line1, line2)
  local path, buf = comment_target()
  if not path then return end
  notes.comment(path, buf, line1, line2)
  -- Deleting what you are writing should not mean leaving it first.
  local ebuf = notes.editor_buf()
  if ebuf then session.keys:attach_editor(ebuf) end
end

-- Delete the comment under the cursor — or, from inside the editor, the
-- one being edited.
function M.comment_delete()
  if session and notes.delete_editing() then return end
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
  session.keys:release()
  panel.teardown()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  git.root = nil
  session = nil
end

-- Optional sugar over vim.g.orca_mappings (what lazy.nvim's `opts` calls).
-- The global stays the single source of truth; nothing requires setup().
function M.setup(opts)
  if opts and opts.mappings ~= nil then vim.g.orca_mappings = opts.mappings end
end

return M
