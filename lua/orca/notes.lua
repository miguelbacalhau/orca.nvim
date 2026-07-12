-- Review notes for orca.nvim: line-anchored comments that persist to
-- .orca/review-notes/<key>.json and flow back into the orca run — the
-- addressing step converts open comments to findings, fixes them, and
-- writes status/resolution into the same file for the next session to show.
--
-- The session's source of truth is extmarks, so anchors ride buffer edits
-- (fixing nits mid-review is a feature); every mutation rewrites the whole
-- file from their current positions — a crash loses nothing. The file is
-- versioned: it is the plugin↔skill coordination contract (the two ship
-- separately), and either side refuses a version it doesn't know.

local git = require('orca.git')

local M = {}

M.VERSION = 1

local NS = vim.api.nvim_create_namespace('orca_notes')
local state = nil

local function notify(msg, level)
  vim.notify('orca: ' .. msg, level or vim.log.levels.INFO)
end

local function define_hl()
  vim.api.nvim_set_hl(0, 'OrcaCommentSign', { link = 'DiagnosticSignInfo', default = true })
  vim.api.nvim_set_hl(0, 'OrcaCommentText', { link = 'DiagnosticVirtualTextInfo', default = true })
  vim.api.nvim_set_hl(0, 'OrcaCommentResolution', { link = 'DiagnosticVirtualTextHint', default = true })
end

-- <key>.json — the sanitized head branch, or the whole range when head is
-- not a branch (detached HEAD, a sha). Derivable from git state alone, so
-- Tuesday's comments are found on Wednesday with no launch-time handoff,
-- and Claude computes the same key from the deliverable branch.
local function notes_key(head, range)
  return ((git.branch_of(head) or range):gsub('[^%w._-]', '-'))
end

-- The longest prefix of `word` that fits `width` display cells — at least
-- one character, so hard-breaking always makes progress — plus the rest.
local function split_word(word, width)
  local fit = 1
  for i = 2, vim.fn.strchars(word) do
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(word, 0, i)) > width then break end
    fit = i
  end
  return vim.fn.strcharpart(word, 0, fit), vim.fn.strcharpart(word, fit)
end

-- Soft-wrap one stored line for display: greedy word wrap on display width
-- (multi-byte safe); a single word longer than the width hard-breaks so
-- URLs don't vanish past the window edge. Lines that fit pass verbatim.
local function wrap(line, width)
  if vim.fn.strdisplaywidth(line) <= width then return { line } end
  local chunks, cur = {}, ''
  for word in line:gmatch('%S+') do
    local joined = cur == '' and word or cur .. ' ' .. word
    if vim.fn.strdisplaywidth(joined) <= width then
      cur = joined
    else
      if cur ~= '' then chunks[#chunks + 1] = cur end
      while vim.fn.strdisplaywidth(word) > width do
        chunks[#chunks + 1], word = split_word(word, width)
      end
      cur = word
    end
  end
  if cur ~= '' then chunks[#chunks + 1] = cur end
  if #chunks == 0 then chunks[1] = '' end
  return chunks
end

-- Wrap width for virt_lines placed in `buf`: the showing window's text
-- area minus the '┃ ' prefix. Neovim never wraps virt_lines itself — each
-- is one screen line, silently truncated at the edge — so the plugin wraps
-- at placement time. When no window shows the buffer, assume 78 columns.
local function wrap_width(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  local info = win and vim.fn.getwininfo(win)[1]
  local text_width = info and (info.width - info.textoff) or 78
  return math.max(text_width - vim.fn.strdisplaywidth('┃ '), 1)
end

-- Virtual lines rendered under the anchor: the comment text, then orca's
-- resolution once the addressing step has written one back. Wrapping is
-- display-only, recomputed at every placement — stored text is untouched,
-- and user-authored line breaks stay paragraph breaks (each stored line
-- wraps independently).
local function virt(c, width)
  local lines = {}
  local function add(text, hl)
    for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
      for _, chunk in ipairs(wrap(l, width)) do
        lines[#lines + 1] = { { '┃ ' .. chunk, hl } }
      end
    end
  end
  add(c.text, 'OrcaCommentText')
  if c.status ~= 'open' then
    add(('✔ %s%s'):format(c.status, c.resolution and (' — ' .. c.resolution) or ''),
      'OrcaCommentResolution')
  end
  return lines
end

local function mark_line(buf, id)
  if not id then return nil end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, NS, id, {})
  return pos[1] and (pos[1] + 1) or nil
end

local function live(c)
  return c.buf ~= nil and vim.api.nvim_buf_is_valid(c.buf) and mark_line(c.buf, c.mark) ~= nil
end

-- Pull a comment's stored fields up to its extmark's current position,
-- re-quoting the anchor line — number and quote must describe the same
-- line whenever the file is written. A range comment is one ranged
-- extmark, so its end rides edits too and reads back from details.
local function sync(c)
  if not live(c) then return end
  local pos = vim.api.nvim_buf_get_extmark_by_id(c.buf, NS, c.mark, { details = true })
  c.line = pos[1] + 1
  local end_row = pos[3] and pos[3].end_row
  if end_row then c.end_line = math.max(end_row + 1, c.line) end
  local l = vim.api.nvim_buf_get_lines(c.buf, c.line - 1, c.line, false)[1]
  if l then c.quoted = l end
end

-- The one extmark writer: sign + virt_lines at [line, end_line] of buf,
-- reusing `id` when given. Both the real placement and the edit-time
-- spacer gap go through here, so they cannot disagree on anchoring.
local function set_mark(buf, id, line, end_line, virt_lines)
  local last = vim.api.nvim_buf_line_count(buf)
  local opts = {
    id = id,
    sign_text = '┃',
    sign_hl_group = 'OrcaCommentSign',
    virt_lines = virt_lines,
  }
  if end_line and end_line > line then
    -- Ranged: the sign renders on every spanned line (0.10+ decoration
    -- behavior; on 0.9 it degrades to the anchor line only).
    opts.end_row = math.min(end_line, last) - 1
  end
  return vim.api.nvim_buf_set_extmark(buf, NS, math.min(line, last) - 1, 0, opts)
end

local function place(c, buf)
  c.buf = buf
  c.mark = set_mark(buf, c.mark, c.line, c.end_line, virt(c, wrap_width(buf)))
end

local function unplace(c)
  if c.buf and vim.api.nvim_buf_is_valid(c.buf) and c.mark then
    pcall(vim.api.nvim_buf_del_extmark, c.buf, NS, c.mark)
  end
  c.buf, c.mark = nil, nil
end

-- The comment whose anchored range covers `line` of `path`, plus its index.
local function covering(path, line)
  for i, c in ipairs(state.comments) do
    if c.file == path then
      sync(c)
      if line >= c.line and line <= (c.end_line or c.line) then return c, i end
    end
  end
end

-- Re-place the comments of every buffer shown in `wins` — wrap width
-- follows the window. sync() first, then place() at the synced line with
-- the same extmark id: drifted anchors stay drifted.
function M.refit(wins)
  if not state then return end
  local bufs = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then bufs[vim.api.nvim_win_get_buf(win)] = true end
  end
  for _, c in ipairs(state.comments) do
    -- The comment under edit shows spacers, not its text — re-placing it
    -- would collapse the gap under the open float.
    if c.buf and bufs[c.buf] and live(c) and c ~= state.editing then
      sync(c)
      place(c, c.buf)
    end
  end
end

-- Begin the notes layer for a session, loading any existing file for the
-- same key — multi-sitting reviews and orca's write-back land in one path,
-- so persistence and resolution display are one code path. Returns the
-- number of comments loaded.
function M.start(opts)
  define_hl()
  local dir = opts.root .. '/.orca/review-notes'
  state = {
    dir = dir,
    path = ('%s/%s.json'):format(dir, notes_key(opts.head, opts.range)),
    head = opts.head,
    range = opts.range,
    comments = {},
    resized = {},
  }
  -- Virtual lines wrap to the window width at placement time, so a resize
  -- must re-place. One scheduled refit coalesces the WinResized burst a
  -- mouse drag produces; the augroup is notes-owned because notes
  -- lifecycle equals session lifecycle.
  vim.api.nvim_create_autocmd('WinResized', {
    group = vim.api.nvim_create_augroup('orca-notes', { clear = true }),
    callback = function()
      local s = state
      if not s then return end
      local scheduled = next(s.resized) ~= nil
      -- v:event.windows is absent when fired via nvim_exec_autocmds (the
      -- headless smoke test's route — a UI-less run never sees the real
      -- event); refit every window in the tab then.
      for _, w in ipairs(vim.v.event.windows or vim.api.nvim_tabpage_list_wins(0)) do
        s.resized[w] = true
      end
      if scheduled then return end
      vim.schedule(function()
        if state ~= s then return end
        local wins = vim.tbl_keys(s.resized)
        s.resized = {}
        M.refit(wins)
      end)
    end,
  })
  if vim.fn.filereadable(state.path) == 0 then return 0 end
  local ok, data = pcall(vim.json.decode,
    table.concat(vim.fn.readfile(state.path), '\n'),
    { luanil = { object = true, array = true } })
  if not ok or type(data) ~= 'table' then
    state.blocked = 'not valid JSON'
    notify(state.path .. ' is not valid JSON — commenting disabled so orca.nvim cannot clobber it',
      vim.log.levels.ERROR)
    return 0
  end
  if data.version ~= M.VERSION then
    state.blocked = ('version %s, this orca.nvim speaks %d'):format(tostring(data.version), M.VERSION)
    notify(('%s is version %s, this orca.nvim speaks %d — update the older side; commenting disabled')
      :format(state.path, tostring(data.version), M.VERSION), vim.log.levels.ERROR)
    return 0
  end
  -- A recycled branch name: the file's recorded head is not in this
  -- history. Never discard silently — the file may be the only copy.
  if data.head and not git.is_ancestor(data.head, opts.head) then
    notify(('existing notes (%s) were written on a different lineage — delete %s to start fresh')
      :format(data.range or 'unknown range', state.path), vim.log.levels.WARN)
  end
  state.created = data.created
  for _, c in ipairs(data.comments or {}) do
    if c.file and c.line and c.text then
      state.comments[#state.comments + 1] = {
        file = c.file,
        line = c.line,
        end_line = c.end_line,
        text = c.text,
        quoted = c.quoted,
        status = c.status or 'open',
        resolution = c.resolution,
      }
    end
  end
  return #state.comments
end

-- Show `path`'s comments in `buf` (a pair's working-tree side). Idempotent:
-- a comment already anchored in this buffer keeps its extmark — re-placing
-- would snap it back to the stored line and lose drift.
function M.decorate(buf, path)
  if not state then return end
  for _, c in ipairs(state.comments) do
    if c.file == path and not (c.buf == buf and live(c)) then
      place(c, buf)
    end
  end
end

-- Rewrite the whole file from current extmark positions — always a
-- complete snapshot, never an append. Zero comments deletes it: the file
-- is created lazily on the first comment, and "no comments" and "no file"
-- mean the same thing to the consuming skill.
function M.save()
  if not state or state.blocked then return end
  for _, c in ipairs(state.comments) do sync(c) end
  if #state.comments == 0 then
    if vim.fn.filereadable(state.path) == 1 then vim.fn.delete(state.path) end
    return
  end
  local out = {}
  for _, c in ipairs(state.comments) do
    out[#out + 1] = {
      file = c.file,
      line = c.line,
      end_line = c.end_line,
      text = c.text,
      quoted = c.quoted,
      status = c.status,
      resolution = c.resolution,
    }
  end
  table.sort(out, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    return a.line < b.line
  end)
  local now = os.date('!%Y-%m-%dT%H:%M:%SZ')
  state.created = state.created or now
  vim.fn.mkdir(state.dir, 'p')
  vim.fn.writefile({ vim.json.encode({
    version = M.VERSION,
    range = state.range,
    head = git.rev(state.head),
    created = state.created,
    updated = now,
    comments = out,
  }) }, state.path)
end

-- N spacer virt_lines: the '┃ ' gutter-bar prefix with no text. While the
-- input float is open they hold the gap the comment's virt_lines normally
-- fill, so the surrounding text does not move.
local function spacers(n)
  local lines = {}
  for _ = 1, n do lines[#lines + 1] = { { '┃ ', 'OrcaCommentText' } } end
  return lines
end

-- Editor-grid position for the input float: the first virt_line row under
-- `line` in `win` (the line's own wrapped rows counted via text_height,
-- its virt_lines excluded), col just past the '┃ ' the spacers draw.
-- `bufpos` can't do this — it resolves to the line's *first* screen row,
-- so a soft-wrapped anchor would put the float on its own continuation
-- rows. nil when the anchor is scrolled out of view.
local function float_pos(win, line)
  if not vim.api.nvim_win_is_valid(win) then return nil end
  local sp = vim.fn.screenpos(win, line, 1)
  if sp.row == 0 then return nil end
  local th = vim.api.nvim_win_text_height(win, { start_row = line - 1, end_row = line - 1 })
  return sp.row - 1 + th.all - th.fill, sp.col - 1 + vim.fn.strdisplaywidth('┃ ')
end

-- The float over the gap: swap the anchor's virt_lines for spacers (same
-- extmark id, so the gap stays open and the gutter bar keeps running), or
-- create a temporary mark for a comment that does not exist yet. Float
-- height and spacer count grow in lockstep with the text — the gap
-- breathes while typing. One WinClosed autocmd centralizes restoration,
-- whichever way the window dies (:wq, :q, M.stop()).
local function float_open(buf, from, anchor, row, col)
  local existing = anchor.existing
  local reuse = existing and existing.buf == anchor.buf and live(existing) or false
  local temp -- the temporary extmark a not-yet-committed comment edits over
  local function gap(h)
    local id = set_mark(anchor.buf, reuse and existing.mark or temp,
      anchor.line, anchor.end_line, spacers(h))
    if reuse then existing.mark = id else temp = id end
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', row = row, col = col,
    width = wrap_width(anchor.buf), height = 1,
    -- explicit: 0.11's 'winborder' would otherwise default a border in,
    -- shifting the float off the gap and breaking the in-place illusion
    border = 'none',
    style = 'minimal',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = 'Normal:OrcaCommentText,NormalFloat:OrcaCommentText'
  -- text_height on the float is the exact display height of the text at
  -- this width — no reimplementation of the wrap algorithm.
  local function fit()
    if not vim.api.nvim_win_is_valid(win) then return end
    local h = vim.api.nvim_win_text_height(win, {}).all
    vim.api.nvim_win_set_height(win, h)
    gap(h)
  end
  fit()
  if reuse then state.editing = existing end
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = 'orca-notes',
    buffer = buf,
    callback = fit,
  })
  -- relative='editor' does not follow scrolling: recompute while the float
  -- is open; when the anchor scrolls out of view, hide it.
  local scroll = vim.api.nvim_create_autocmd('WinScrolled', {
    group = 'orca-notes',
    pattern = tostring(from),
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then return end
      local r, c = float_pos(from, anchor.line)
      if r then
        vim.api.nvim_win_set_config(win, { relative = 'editor', row = r, col = c, hide = false })
      else
        vim.api.nvim_win_set_config(win, { hide = true })
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = 'orca-notes',
    pattern = tostring(win),
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_autocmd, scroll)
      if not state then return end
      state.editing = nil
      if state.input == win then state.input = nil end
      if temp then pcall(vim.api.nvim_buf_del_extmark, anchor.buf, NS, temp) end
      if existing then
        -- Restore the real virt_lines — but only if the comment still
        -- exists (committing empty text deleted it). On abort this renders
        -- the unchanged text; after a commit it is idempotent.
        for _, c in ipairs(state.comments) do
          if c == existing then
            sync(c)
            place(c, c.buf and vim.api.nvim_buf_is_valid(c.buf) and c.buf or anchor.buf)
            break
          end
        end
      end
    end,
  })
  return win
end

-- Feature gate for the float input: its geometry needs nvim_win_text_height
-- (0.10+); 0.9 keeps the bottom split. Module-visible so the smoke test can
-- force the fallback path on a modern host.
M.float_input = vim.fn.has('nvim-0.10') == 1

-- Multi-line input in an acwrite scratch buffer: :w (or :wq) commits,
-- quitting without writing aborts. Committing empty text is the delete
-- route. On 0.10+ the buffer shows in a borderless float over spacer
-- virt_lines at the anchor — editing looks like typing into the virtual
-- text itself; otherwise it is a small split at the bottom.
local function input(title, prefill, anchor, on_submit)
  if state.input and vim.api.nvim_win_is_valid(state.input) then
    return vim.api.nvim_set_current_win(state.input)
  end
  local from = vim.api.nvim_get_current_win()
  local row, col
  if M.float_input then row, col = float_pos(from, anchor.line) end
  local win, buf
  if not row then
    -- 0.9, or an anchor with no screen position: the split fallback.
    vim.cmd('botright 6new')
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_get_current_buf()
  else
    buf = vim.api.nvim_create_buf(false, false)
  end
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, 'orca://comment/' .. title)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, prefill)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modified = false
  if row then win = float_open(buf, from, anchor, row, col) end
  state.input = win
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.bo[buf].modified = false
      -- Deferred: on :wq the quit still owns this window, and closing it
      -- mid-command would pull it out from under the command. Focus goes
      -- back where the comment was made, not wherever the close dumps it.
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
        if vim.api.nvim_win_is_valid(from) then vim.api.nvim_set_current_win(from) end
      end)
      on_submit(lines)
    end,
  })
end

-- Create the comment anchored at [line, line2] of path in buf, or edit the
-- one already covering `line`. Editing re-opens it: changed text means the
-- previous resolution no longer answers it.
function M.comment(path, buf, line, line2)
  if not state then return end
  if state.blocked then
    return notify(('commenting disabled — %s is %s'):format(state.path, state.blocked),
      vim.log.levels.ERROR)
  end
  local existing, idx = covering(path, line)
  local prefill = existing and vim.split(existing.text, '\n', { plain = true }) or {}
  local title = ('%s:%d'):format(path, existing and existing.line or line)
  -- The anchor drives the float presentation: where the gap opens, and
  -- which extmark holds it (existing's own, or a temporary one).
  local anchor = {
    buf = buf,
    line = existing and existing.line or line,
    end_line = existing and existing.end_line
      or ((line2 and line2 > line) and line2 or nil),
    existing = existing,
  }
  input(title, prefill, anchor, function(lines)
    if not state then return end
    while #lines > 0 and lines[#lines]:match('^%s*$') do table.remove(lines) end
    if #lines == 0 then
      if existing then
        unplace(existing)
        table.remove(state.comments, idx)
        M.save()
        notify('comment deleted — ' .. title)
      end
      return
    end
    local text = table.concat(lines, '\n')
    if existing then
      existing.text = text
      existing.status = 'open'
      existing.resolution = nil
      if existing.buf ~= buf then unplace(existing) end
      sync(existing)
      place(existing, buf)
    else
      local c = {
        file = path,
        line = line,
        end_line = (line2 and line2 > line) and line2 or nil,
        text = text,
        quoted = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or '',
        status = 'open',
      }
      state.comments[#state.comments + 1] = c
      place(c, buf)
    end
    M.save()
    notify('comment saved — ' .. vim.fn.fnamemodify(state.path, ':~'))
  end)
end

-- Delete the comment covering `line` of `path`, if any.
function M.delete(path, line)
  if not state or state.blocked then return end
  local existing, idx = covering(path, line)
  if not existing then return notify('no comment on this line') end
  unplace(existing)
  table.remove(state.comments, idx)
  M.save()
  notify(('comment deleted — %s:%d'):format(path, line))
end

-- End the notes layer: final save (anchors as the session last saw them),
-- extmarks cleared, any open input abandoned. The file persists — that is
-- the point.
function M.stop()
  if not state then return end
  M.save()
  -- Close the input first: a float's WinClosed restoration re-places
  -- extmarks, which must happen before the unplace sweep, not after it.
  if state.input and vim.api.nvim_win_is_valid(state.input) then
    pcall(vim.api.nvim_win_close, state.input, true)
  end
  for _, c in ipairs(state.comments) do unplace(c) end
  pcall(vim.api.nvim_del_augroup_by_name, 'orca-notes')
  state = nil
end

return M
