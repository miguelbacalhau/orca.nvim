-- orca.nvim's review session: the merge-base diff of <base>...<head>, one
-- diff pair at a time beside a pinned panel (orca/panel.lua). Session state
-- is module-local and dies with the session; the notes file (orca/notes.lua)
-- is what outlives it. Design notes: :help orca.

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

-- Is the panel pinned open for the session? Yes unless
-- vim.g.orca_panel_pinned = false (:help vim.g.orca_panel_pinned).
local function resolve_pinned()
  local v = vim.g.orca_panel_pinned
  if v == nil then return true end
  return v and true or false
end

-- Do sessions start with the groups folded away? Yes unless
-- vim.g.orca_review_hidden = false. Resolved once per session.
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

-- Put the pinned panel back without taking focus. Split from an ordinary
-- window (a float may be current), and through nvim_win_call, which fires
-- no WinEnter/BufEnter for the navigation follower to act on.
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
-- is the caller's; where the next pair goes is not decided here.
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

-- Can a pair's right side go in window `w`? Never a float, the panel (by
-- id: its buffer is nofile like a scratch side) or a quickfix window.
local function usable(w)
  return w and vim.api.nvim_win_is_valid(w)
    and vim.api.nvim_win_get_config(w).relative == ''
    and w ~= panel.win()
    and vim.bo[vim.api.nvim_win_get_buf(w)].buftype ~= 'quickfix'
end

-- The previous pair's window, else the current or first usable one, else
-- a fresh split.
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

-- BufEnter: the pair follows navigation. Entering a changed file opens its
-- pair around the landed window; a foreign buffer in a pair window collapses
-- the pair, since 'diff' is window-local and would carry over to it.
local function follow_navigation()
  if not session or session.navigating then return end
  -- Pickers preview into floats; entering one must not collapse anything.
  if vim.api.nvim_win_get_config(0).relative ~= '' then return end
  local buf = vim.api.nvim_get_current_buf()
  -- The panel's own BufEnter fires mid-open, before its window is known:
  -- reasserting here would build a second panel.
  if buf == panel.buf() then return end
  -- A buffer landing in the panel's window closes no window, so WinClosed
  -- misses it.
  ensure_panel()
  local pair = session.pair
  if pair then
    for _, owned in ipairs({ pair.bufs, pair.scratch }) do
      if vim.tbl_contains(owned, buf) then return end
    end
  end

  local idx = entry_of(buf)
  if idx then
    -- Already current: a no-op, or a binary file's plain :edit would loop
    -- open → BufEnter → open.
    if idx == session.index and pair then return end
    -- The pair goes where the jump landed. Taken over in place, it opens
    -- now: nothing splits, and deferring would draw a frame of the new file
    -- against the old merge base.
    local win = vim.api.nvim_get_current_win()
    if pairview.reusable(pair, session.entries[idx], win) then
      return M.open(idx, win)
    end
    -- Otherwise deferred: this may be mid-:close, and splitting then is
    -- illegal (E242).
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

-- Everything a session needs from git, resolved without touching a running
-- one. `range` is '<base>...<head>', '<base>' (head HEAD) or empty (trunk).
-- Returns a plan, or nil plus a message and its level.
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

  -- The pinned panel comes back when its window closes. Deferred (E242),
  -- and only for this session, so the closing one can't resurrect it.
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

  -- Earlier comments and orca's resolutions load here; every notes save
  -- refreshes the panel's counts.
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
  -- Hiding is never silent: the count and the way back are in this line.
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

  -- The pair on screen is taken over when the entry can use it, else torn
  -- down first. All of it is protected, teardown included: navigating must
  -- come back down whatever throws, or the follower stays off for good.
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

-- Move count files forward/back through the panel's rows (hidden files are
-- skipped). An overshooting count clamps; at the edge, a message.
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

-- The hidden-groups toggle, behind the summary row's <CR> and the `hidden`
-- action. No command, by design: :help orca-hidden.
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

-- The focus ladder behind :OrcaReviewPanel: not there → open and focus;
-- unfocused → focus; focused → back to the diff (or, unpinned, close).
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

-- Review-wide comment walk: file order, then line, crossing files through
-- M.open. Lines are extmark-resolved, so they follow edits.
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

-- The anchor for :OrcaComment: the current buffer must be the working-tree
-- side of a changed text file — not a merge-base scratch, a deleted file
-- or a binary one.
local comment_target = with_session(function()
  local buf = vim.api.nvim_get_current_buf()
  local _, entry = entry_of(buf)
  if not entry or entry.binary then
    notify('comments anchor to the working-tree side of a changed text file', vim.log.levels.WARN)
    return
  end
  return entry.path, buf
end)

-- Create the comment on line1..line2 of the current buffer, or edit the one
-- already covering line1.
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

-- End the session. Everything it made goes, and every key it took goes
-- back; the notes file stays.
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
