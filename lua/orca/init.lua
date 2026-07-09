-- orca.nvim — branch review inside the user's own Neovim.
--
-- A session is the merge-base diff of <base>...<head>: changed files as a
-- quickfix list, one side-by-side diff pair open at a time. State is
-- module-local and dies with the session; nothing is written anywhere — no
-- files, no git state, no marks beyond the in-memory ✓.

local git = require('orca.git')
local pairview = require('orca.diff')

local M = {}

local AUGROUP = 'orca-review'
local session = nil

local function notify(msg, level)
  vim.notify('orca: ' .. msg, level or vim.log.levels.INFO)
end

-- Buffer-local convenience maps; the :OrcaReview* commands are the public
-- API. Set only in buffers the session owns, removed when it lets go.
local MAPS = {
  { ']f', function() M.next() end, 'orca: next file' },
  { '[f', function() M.prev() end, 'orca: previous file' },
  { '<leader>rm', function() M.mark() end, 'orca: toggle reviewed and advance' },
  { '<leader>rq', function() M.close() end, 'orca: close review' },
}

local function buf_map(buf, lhs, fn, desc)
  vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, desc = desc })
  session.mapped[buf] = session.mapped[buf] or {}
  session.mapped[buf][lhs] = true
end

local function attach_maps(buf)
  for _, m in ipairs(MAPS) do buf_map(buf, m[1], m[2], m[3]) end
end

local function detach_maps(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    for lhs in pairs(session.mapped[buf] or {}) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
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
  buf_map(buf, '<CR>', function() M.open(vim.fn.line('.')) end, "orca: open this file's diff")
end

local function entry_text(e)
  local text = e.status
  if e.status == 'R' or e.status == 'C' then
    text = ('%s %s → %s'):format(e.status, e.old_path, e.path)
  end
  if e.binary then text = text .. ' (binary)' end
  if e.reviewed then text = '✓ ' .. text end
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
  for _, buf in ipairs(pair.bufs) do detach_maps(buf) end
  pairview.close(pair)
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
  }
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

  notify(('%d file%s in %s — <CR> opens a diff, ]f/[f move, <leader>rm marks reviewed')
    :format(#entries, #entries == 1 and '' or 's', session.range))
  M.open(1)
end

-- Open the diff pair for the idx-th changed file.
function M.open(idx)
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  idx = math.max(1, math.min(idx, #session.entries))
  teardown_pair()
  session.index = idx
  local entry = session.entries[idx]

  local pair, err = pairview.open(entry, session.mergebase, session.toplevel, pick_window())
  if not pair then
    refresh_qf()
    return notify(('%s: %s'):format(entry.path, err or 'cannot open'), vim.log.levels.ERROR)
  end
  session.pair = pair
  for _, buf in ipairs(pair.bufs) do attach_maps(buf) end

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

function M.next()
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  if session.index >= #session.entries then
    return notify('already at the last file')
  end
  M.open(session.index + 1)
end

function M.prev()
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  if session.index <= 1 then
    return notify('already at the first file')
  end
  M.open(session.index - 1)
end

-- Toggle reviewed (✓) on the current file. Marking advances to the next
-- unreviewed file (wrapping once); un-marking stays put.
function M.mark()
  if not session then
    return notify('no review session — start one with :OrcaReview', vim.log.levels.WARN)
  end
  if session.index == 0 then
    return notify('no file open — ]f opens the first', vim.log.levels.WARN)
  end
  local entry = session.entries[session.index]
  entry.reviewed = not entry.reviewed
  refresh_qf()
  if not entry.reviewed then return end
  local n = #session.entries
  for step = 1, n do
    local i = ((session.index - 1 + step) % n) + 1
    if not session.entries[i].reviewed then return M.open(i) end
  end
  notify('review complete — every file marked ✓')
end

-- End the session: diff pair torn down, scratch buffers wiped, keymaps
-- removed, augroup cleared. The quickfix list stays — it is the user's.
function M.close()
  if not session then return end
  teardown_pair()
  for buf in pairs(session.mapped) do detach_maps(buf) end
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  session = nil
end

return M
