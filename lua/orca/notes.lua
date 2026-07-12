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

-- Virtual lines rendered under the anchor: the comment text, then orca's
-- resolution once the addressing step has written one back.
local function virt(c)
  local lines = {}
  for _, l in ipairs(vim.split(c.text, '\n', { plain = true })) do
    lines[#lines + 1] = { { '┃ ' .. l, 'OrcaCommentText' } }
  end
  if c.status ~= 'open' then
    local res = ('✔ %s%s'):format(c.status, c.resolution and (' — ' .. c.resolution) or '')
    for _, l in ipairs(vim.split(res, '\n', { plain = true })) do
      lines[#lines + 1] = { { '┃ ' .. l, 'OrcaCommentResolution' } }
    end
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

-- Pull a comment's stored fields up to its extmarks' current positions,
-- re-quoting the anchor line — number and quote must describe the same
-- line whenever the file is written.
local function sync(c)
  if not live(c) then return end
  c.line = mark_line(c.buf, c.mark)
  if c.end_mark then
    local e = mark_line(c.buf, c.end_mark)
    if e then c.end_line = math.max(e, c.line) end
  end
  local l = vim.api.nvim_buf_get_lines(c.buf, c.line - 1, c.line, false)[1]
  if l then c.quoted = l end
end

local function place(c, buf)
  local last = vim.api.nvim_buf_line_count(buf)
  c.buf = buf
  c.mark = vim.api.nvim_buf_set_extmark(buf, NS, math.min(c.line, last) - 1, 0, {
    id = c.mark,
    sign_text = '┃',
    sign_hl_group = 'OrcaCommentSign',
    virt_lines = virt(c),
  })
  if c.end_line and c.end_line > c.line then
    c.end_mark = vim.api.nvim_buf_set_extmark(buf, NS, math.min(c.end_line, last) - 1, 0,
      { id = c.end_mark })
  end
end

local function unplace(c)
  if c.buf and vim.api.nvim_buf_is_valid(c.buf) then
    if c.mark then pcall(vim.api.nvim_buf_del_extmark, c.buf, NS, c.mark) end
    if c.end_mark then pcall(vim.api.nvim_buf_del_extmark, c.buf, NS, c.end_mark) end
  end
  c.buf, c.mark, c.end_mark = nil, nil, nil
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
  }
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

-- Multi-line input in a small acwrite split: :w (or :wq) commits, quitting
-- without writing aborts. Committing empty text is the delete route.
local function input(title, prefill, on_submit)
  if state.input and vim.api.nvim_win_is_valid(state.input) then
    return vim.api.nvim_set_current_win(state.input)
  end
  local from = vim.api.nvim_get_current_win()
  vim.cmd('botright 6new')
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  state.input = win
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, 'orca://comment/' .. title)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, prefill)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modified = false
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
  input(title, prefill, function(lines)
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
  for _, c in ipairs(state.comments) do unplace(c) end
  if state.input and vim.api.nvim_win_is_valid(state.input) then
    pcall(vim.api.nvim_win_close, state.input, true)
  end
  state = nil
end

return M
