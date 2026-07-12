-- orca.nvim — branch review inside the user's own Neovim, the human half
-- of an orca run's review. Orca-managed repositories only: .orca/ must
-- exist at the repo root.
--
-- A session is the merge-base diff of <base>...<head>: changed files as a
-- quickfix list, one side-by-side diff pair open at a time. Session state
-- is module-local and dies with the session; the one artifact that
-- outlives it is the review-notes file (orca/notes.lua) — line-anchored
-- comments under .orca/review-notes/ that flow back into the orca run.

local git = require('orca.git')
local pairview = require('orca.diff')
local notes = require('orca.notes')

local M = {}

local AUGROUP = 'orca-review'
local session = nil

local function notify(msg, level)
  vim.notify('orca: ' .. msg, level or vim.log.levels.INFO)
end

-- Buffer-local convenience maps; the :Orca* commands are the public API.
-- Set only in buffers the session owns, removed when it lets go.
-- vim.g.orca_mappings reshapes them: a table overrides per action (false
-- drops one), false wholesale drops them all. Resolved once per session.
-- Every default is a native key upgraded in place — orca never binds a key
-- that doesn't already mean what orca makes it do. comment/delete/close
-- ship unbound (no native key means what they do); the commands and config
-- keys remain.
local DEFAULT_MAPPINGS = {
  next = ']q',
  prev = '[q',
  open = '<CR>', -- quickfix window only
}

local VALID_ACTIONS =
  { next = true, prev = true, comment = true, delete = true, close = true, open = true }

-- List-identity guard: another list can land in the qf window mid-session
-- (:grep, LSP references — usually accidental), and orca's keys must not
-- hijack it. The maps stay asserted either way (the re-assert race
-- machinery is untouched); on a foreign list the mapped function falls
-- through to the stock command, surfacing its errors (E553 at the edges)
-- the way the unmapped key would.
local function foreign_list()
  return session ~= nil and vim.fn.getqflist({ id = 0 }).id ~= session.qfid
end

local function native(cmd)
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.api.nvim_echo({ { err:match('(E%d+:.*)') or err, 'ErrorMsg' } }, true, {})
  end
end

-- Rows are { action, rhs-or-fn, desc [, x-mode rhs] } — comment also maps
-- in visual mode, where the command's range anchors the whole selection.
local ACTIONS = {
  { 'next', function()
    if foreign_list() then return native(vim.v.count1 .. 'cnext') end
    M.next(vim.v.count1)
  end, 'orca: next file' },
  { 'prev', function()
    if foreign_list() then return native(vim.v.count1 .. 'cprevious') end
    M.prev(vim.v.count1)
  end, 'orca: previous file' },
  { 'comment', function() M.comment(vim.fn.line('.'), vim.fn.line('.')) end,
    'orca: comment on this line', ':OrcaComment<CR>' },
  { 'delete', function() M.comment_delete() end, 'orca: delete the comment on this line' },
  { 'close', function() M.close() end, 'orca: close review' },
}

local function resolve_mappings()
  local user = vim.g.orca_mappings
  if user == false then return {} end
  local maps = vim.tbl_extend('force', {}, DEFAULT_MAPPINGS)
  if type(user) == 'table' then
    for action, lhs in pairs(user) do
      if not VALID_ACTIONS[action] then
        notify(('vim.g.orca_mappings: unknown action %q (valid: next, prev, comment, delete, close, open)')
          :format(action), vim.log.levels.WARN)
      elseif lhs == false then
        maps[action] = nil
      else
        maps[action] = lhs
      end
    end
  end
  return maps
end

local function buf_map(buf, lhs, rhs, desc, mode)
  vim.keymap.set(mode or 'n', lhs, rhs, { buffer = buf, nowait = true, desc = desc })
  session.mapped[buf] = session.mapped[buf] or {}
  session.mapped[buf][lhs] = true
end

local function attach_maps(buf)
  for _, a in ipairs(ACTIONS) do
    local lhs = session.maps[a[1]]
    if lhs then
      buf_map(buf, lhs, a[2], a[3])
      if a[4] then buf_map(buf, lhs, a[4], a[3], 'x') end
    end
  end
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

-- Writing a quickfix list re-runs the qf ftplugin, and user configs commonly
-- (re)map <CR> there — a last-writer race our maps must win. Re-asserted
-- after every list write, not just once at session start.
local function attach_qf_maps()
  local buf = session.qfbuf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  attach_maps(buf)
  if session.maps.open then
    buf_map(buf, session.maps.open, function()
      if foreign_list() then return native(vim.fn.line('.') .. 'cc') end
      M.open(vim.fn.line('.'))
    end, "orca: open this file's diff")
  end
end

local function entry_text(e)
  local text = e.status
  if e.status == 'R' or e.status == 'C' then
    text = ('%s %s → %s'):format(e.status, e.old_path, e.path)
  end
  if e.binary then text = text .. ' (binary)' end
  return text
end

local function qf_items()
  local items = {}
  for _, e in ipairs(session.entries) do
    items[#items + 1] = {
      filename = session.toplevel .. '/' .. e.path,
      lnum = 1,
      text = entry_text(e),
    }
  end
  return items
end

local function refresh_qf()
  vim.fn.setqflist({}, 'r', {
    id = session.qfid,
    title = 'OrcaReview ' .. session.range,
    items = qf_items(),
  })
  if session.index > 0 then
    vim.fn.setqflist({}, 'a', { id = session.qfid, idx = session.index })
  end
  attach_qf_maps()
end

local function teardown_pair()
  local pair = session.pair
  if not pair then return end
  session.pair = nil
  session.last_win = pair.right_win
  local was = session.navigating
  session.navigating = true
  for _, buf in ipairs(pair.bufs) do detach_maps(buf) end
  pairview.close(pair)
  session.navigating = was
end

-- The window the next diff pair's right side goes into: the previous pair's,
-- else the current or first ordinary window, else a fresh split.
local function pick_window()
  local function usable(w)
    return w and vim.api.nvim_win_is_valid(w)
      and vim.api.nvim_win_get_config(w).relative == ''
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
  if buf == session.qfbuf then return end
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
    -- Deferred one tick: this BufEnter may be firing mid-:close (focus
    -- falling back into a changed file's window), and the pair's split is
    -- illegal while another window is closing (E242).
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
    mergebase = mergebase,
    toplevel = toplevel,
    range = base .. '...' .. head,
    mapped = {},
    by_path = {},
    maps = resolve_mappings(),
  }
  for i, e in ipairs(entries) do session.by_path[e.path] = i end
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.fn.setqflist({}, ' ', { title = 'OrcaReview ' .. session.range, items = qf_items() })
  session.qfid = vim.fn.getqflist({ id = 0 }).id
  vim.cmd('botright copen')
  session.qfbuf = vim.api.nvim_get_current_buf()
  attach_qf_maps()
  -- User configs and plugins re-map <CR> in qf buffers on these events (the
  -- ftplugin pattern; mini.jump2d's <CR> revert). Session autocmds register
  -- later than theirs, so re-asserting here wins every same-event race.
  vim.api.nvim_create_autocmd({ 'BufEnter', 'FileType' }, {
    group = AUGROUP,
    buffer = session.qfbuf,
    callback = function() attach_qf_maps() end,
  })
  -- One session-wide hook covers every navigation route. nested, so the
  -- :edit it triggers still fires filetype/LSP autocmds; re-entrancy is cut
  -- by session.navigating instead.
  vim.api.nvim_create_autocmd('BufEnter', {
    group = AUGROUP,
    nested = true,
    callback = follow_navigation,
  })

  -- The notes layer: existing comments for this branch load here, so
  -- multi-sitting reviews and orca's resolutions show up immediately.
  local loaded = notes.start({ root = root, toplevel = toplevel, range = session.range, head = head })

  local m = session.maps
  local hints = {}
  if m.open then hints[#hints + 1] = m.open .. ' opens a diff' end
  if m.next and m.prev then
    hints[#hints + 1] = ('%s/%s move'):format(m.next, m.prev)
  elseif m.next or m.prev then
    hints[#hints + 1] = (m.next or m.prev) .. ' moves'
  end
  -- Unbound by default; naming the command keeps commenting discoverable.
  hints[#hints + 1] = (m.comment or ':OrcaComment') .. ' comments a line'
  notify(('%d file%s in %s%s%s'):format(#entries, #entries == 1 and '' or 's', session.range,
    loaded > 0 and (', %d comment%s loaded'):format(loaded, loaded == 1 and '' or 's') or '',
    #hints > 0 and (' — ' .. table.concat(hints, ', ')) or ''))
  M.open(1)
end

-- Open the diff pair for the idx-th changed file.
function M.open(idx)
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  idx = math.max(1, math.min(idx, #session.entries))
  session.navigating = true
  teardown_pair()
  session.index = idx
  local entry = session.entries[idx]

  local ok, pair, err = pcall(pairview.open, entry, session.mergebase, session.toplevel, pick_window())
  session.navigating = false
  if not ok then pair, err = nil, pair end
  if not pair then
    refresh_qf()
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
      callback = function()
        for _, key in ipairs({ 'left_win', 'right_win' }) do
          local w = pair[key]
          if w and vim.api.nvim_win_is_valid(w) then
            vim.api.nvim_win_call(w, function() vim.cmd('diffoff') end)
          end
        end
      end,
    })
  end

  refresh_qf()
  if entry.binary then notify(entry.path .. ' is binary — opened without a diff') end
end

-- Move count files forward/back (default 1), honoring the native count
-- contract of ]q/[q. At the edge, a polite message; a count that would
-- overshoot clamps to the edge (in M.open) instead of erroring.
function M.next(count)
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  if session.index >= #session.entries then
    return notify('already at the last file')
  end
  M.open(session.index + (count or 1))
end

function M.prev(count)
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  if session.index <= 1 then
    return notify('already at the first file')
  end
  M.open(session.index - (count or 1))
end

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
-- down, scratch buffers wiped, keymaps removed, augroup cleared. The
-- quickfix list stays — it is the user's.
function M.close()
  if not session then return end
  notes.stop()
  teardown_pair()
  for buf in pairs(session.mapped) do detach_maps(buf) end
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  session = nil
end

-- Optional sugar over vim.g.orca_mappings (what lazy.nvim's `opts` calls).
-- The global stays the single source of truth; nothing requires setup().
function M.setup(opts)
  if opts and opts.mappings ~= nil then vim.g.orca_mappings = opts.mappings end
end

return M
