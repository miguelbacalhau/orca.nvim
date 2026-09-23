-- Review notes (:help orca-notes): line-anchored comments, extmarks while a
-- session lives, persisted whole to .orca/review-notes/<key>.json. The file
-- is the versioned contract with orca's skills; unknown versions are refused.

local git = require('orca.git')
local notify = require('orca.util').notify

local M = {}

M.VERSION = 1

local NS = vim.api.nvim_create_namespace('orca_notes')
local state = nil

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
  add(('#%d %s'):format(c.id, c.text), 'OrcaCommentText')
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

-- Per-file comment counts, { [path] = n } — the panel's right-aligned [n].
function M.counts()
  local counts = {}
  if state then
    for _, c in ipairs(state.comments) do
      counts[c.file] = (counts[c.file] or 0) + 1
    end
  end
  return counts
end

-- Every comment's current position, { { path, line }, ... }. Lines are
-- extmark-resolved at call time for comments placed in a live buffer, so
-- positions self-heal after edits; unplaced ones report their stored line.
function M.locations()
  local locs = {}
  if state then
    for _, c in ipairs(state.comments) do
      sync(c)
      locs[#locs + 1] = { path = c.file, line = c.line }
    end
  end
  return locs
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
    -- The comment under the float shows spacers, not its text — re-placing
    -- it would collapse the gap the float sits in.
    if c.buf and bufs[c.buf] and live(c) and c ~= state.gap then
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
    on_change = opts.on_change,
    comments = {},
    next_id = 1,
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
  local max_id = 0
  for _, c in ipairs(data.comments or {}) do
    if c.file and c.line and c.text then
      state.comments[#state.comments + 1] = {
        id = tonumber(c.id),
        file = c.file,
        line = c.line,
        end_line = c.end_line,
        text = c.text,
        quoted = c.quoted,
        status = c.status or 'open',
        resolution = c.resolution,
      }
      max_id = math.max(max_id, tonumber(c.id) or 0)
    end
  end
  -- Backfill files from before ids existed. Assignment order is arbitrary
  -- (such files contain no #N references yet), but must not collide with
  -- ids that do exist.
  for _, c in ipairs(state.comments) do
    if not c.id then
      max_id = max_id + 1
      c.id = max_id
    end
  end
  state.next_id = max_id + 1
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
  -- Every mutation funnels through here, so the owner's on_change hook
  -- (the panel's live comment counts) fires exactly once per change.
  local on_change = state.on_change
  for _, c in ipairs(state.comments) do sync(c) end
  if #state.comments == 0 then
    if vim.fn.filereadable(state.path) == 1 then vim.fn.delete(state.path) end
    if on_change then on_change() end
    return
  end
  local out = {}
  for _, c in ipairs(state.comments) do
    out[#out + 1] = {
      id = c.id,
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
  -- Written beside the file and renamed over it: a rename is atomic, so a
  -- write that dies halfway (a full disk, a killed editor) leaves the
  -- previous file whole instead of a truncated one nothing can parse.
  local tmp = state.path .. '.tmp'
  local ok, err = pcall(vim.fn.writefile, { vim.json.encode({
    version = M.VERSION,
    range = state.range,
    head = git.rev(state.head),
    created = state.created,
    updated = now,
    comments = out,
  }) }, tmp)
  if ok then
    local uv = vim.uv or vim.loop
    ok, err = uv.fs_rename(tmp, state.path)
  end
  if not ok then
    vim.fn.delete(tmp)
    notify(('could not write %s: %s'):format(state.path, tostring(err)), vim.log.levels.ERROR)
  end
  if on_change then on_change() end
end

-- N spacer virt_lines: the '┃ ' gutter-bar prefix with no text. While the
-- input float is open they hold the gap the comment's virt_lines normally
-- fill, so the surrounding text does not move.
local function spacers(n)
  local lines = {}
  for _ = 1, n do lines[#lines + 1] = { { '┃ ', 'OrcaCommentText' } } end
  return lines
end

-- Editor-grid position of the first virt_line row under `line` in `win`,
-- past the '┃ ' prefix; nil when scrolled out of view. Not `bufpos`: that is
-- the line's first screen row, wrong for a soft-wrapped anchor.
local function float_pos(win, line)
  if not vim.api.nvim_win_is_valid(win) then return nil end
  local sp = vim.fn.screenpos(win, line, 1)
  if sp.row == 0 then return nil end
  local th = vim.api.nvim_win_text_height(win, { start_row = line - 1, end_row = line - 1 })
  return sp.row - 1 + th.all - th.fill, sp.col - 1 + vim.fn.strdisplaywidth('┃ ')
end

-- The comment editor edits the comment itself, saved as typed. A new comment
-- is a draft — its extmark from the start, but an id and a place in
-- state.comments only with its first words.

local SAVE_DELAY = 500

-- The editor buffer's text, trailing blank lines dropped.
local function editor_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  while #lines > 0 and lines[#lines]:match('^%s*$') do table.remove(lines) end
  return table.concat(lines, '\n')
end

local function save_soon()
  local s = state
  s.save_timer = s.save_timer or (vim.uv or vim.loop).new_timer()
  s.save_timer:start(SAVE_DELAY, 0, vim.schedule_wrap(function()
    if state == s then M.save() end
  end))
end

local function save_now()
  if state.save_timer then state.save_timer:stop() end
  M.save()
end

-- Take the editor's text into its comment. Empty text changes nothing: a
-- draft stays a draft, and an existing comment keeps its last words
-- (emptying is not how a comment is deleted). The comment reopens only on
-- a real change — edited back to what it was, its answer still stands.
-- True when the comment changed.
local function pull(e)
  local c = e.c
  if c.deleted or not vim.api.nvim_buf_is_valid(e.buf) then return false end
  local text = editor_text(e.buf)
  if text == '' or text == c.text then return false end
  if c.draft then
    -- Ids are assigned once and never reused — a deleted comment leaves a
    -- gap, so a stale #N reference in another comment's text dangles
    -- visibly instead of rebinding to a newer comment.
    c.draft = nil
    c.id = state.next_id
    state.next_id = state.next_id + 1
    state.comments[#state.comments + 1] = c
  end
  c.text = text
  if text == e.orig.text then
    c.status, c.resolution = e.orig.status, e.orig.resolution
  else
    c.status, c.resolution = 'open', nil
  end
  return true
end

-- The editor's text into the comment, then onto disk: now, or after
-- SAVE_DELAY while typing. 'modified' is kept off throughout — everything
-- is saved, so :q has nothing to warn about.
local function sync_editor(e, soon)
  if pull(e) then
    -- The split fallback shows the comment's own virt_lines, live.
    if not e.float and live(e.c) then place(e.c, e.c.buf) end
    if soon then
      if state.on_change then state.on_change() end
      save_soon()
    end
  end
  if not soon then save_now() end
  if vim.api.nvim_buf_is_valid(e.buf) then vim.bo[e.buf].modified = false end
end

-- The editor is closing, by whatever route. The comment keeps what was
-- typed; a draft with no words goes, extmark and all; a deleted comment
-- (M.delete while it was open) is already gone and stays gone.
local function finish(e)
  if e.scroll then pcall(vim.api.nvim_del_autocmd, e.scroll) end
  if not state then return end
  state.input, state.editing, state.gap, state.edit = nil, nil, nil, nil
  local c = e.c
  if c.deleted then return end
  sync_editor(e)
  if c.draft then
    if c.buf and vim.api.nvim_buf_is_valid(c.buf) and c.mark then
      pcall(vim.api.nvim_buf_del_extmark, c.buf, NS, c.mark)
    end
    return
  end
  if vim.api.nvim_buf_is_valid(e.buf) and editor_text(e.buf) == '' then
    notify(('comment #%d keeps its text — :OrcaCommentDelete deletes it'):format(c.id))
  elseif c.text ~= e.orig.text then
    notify(('comment #%d saved — %s'):format(c.id, vim.fn.fnamemodify(state.path, ':~')))
  end
  if live(c) then
    sync(c)
    place(c, c.buf)
  end
end

-- The float over the gap: the comment's virt_lines swap for spacers (same
-- extmark, so the gap stays open and the gutter bar keeps running), and
-- float height and spacer count grow in lockstep with the text — the gap
-- breathes while typing.
local function float_open(e, from, row, col)
  local c = e.c
  local win = vim.api.nvim_open_win(e.buf, true, {
    relative = 'editor', row = row, col = col,
    width = wrap_width(c.buf), height = 1,
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
    if not (vim.api.nvim_win_is_valid(win) and live(c)) then return end
    local h = vim.api.nvim_win_text_height(win, {}).all
    vim.api.nvim_win_set_height(win, h)
    sync(c)
    c.mark = set_mark(c.buf, c.mark, c.line, c.end_line, spacers(h))
  end
  state.gap = c
  fit()
  -- Leaving the float is being done with it: everything is already saved,
  -- and a float left open would keep covering the comment's own virt_lines.
  -- Deferred, since a window can't close while it is being left.
  vim.api.nvim_create_autocmd('WinLeave', {
    group = 'orca-notes',
    buffer = e.buf,
    callback = function()
      vim.schedule(function()
        if state and state.edit == e and vim.api.nvim_get_current_win() ~= win then
          M.close_input()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = 'orca-notes',
    buffer = e.buf,
    callback = fit,
  })
  -- relative='editor' does not follow scrolling: recompute while the float
  -- is open; when the anchor scrolls out of view, hide it.
  e.scroll = vim.api.nvim_create_autocmd('WinScrolled', {
    group = 'orca-notes',
    pattern = tostring(from),
    callback = function()
      if not (vim.api.nvim_win_is_valid(win) and live(c)) then return end
      local r, cl = float_pos(from, mark_line(c.buf, c.mark))
      if r then
        vim.api.nvim_win_set_config(win, { relative = 'editor', row = r, col = cl, hide = false })
      else
        vim.api.nvim_win_set_config(win, { hide = true })
      end
    end,
  })
  return win
end

-- Feature gate for the float input: its geometry needs nvim_win_text_height
-- (0.10+); 0.9 keeps the bottom split. Module-visible so the smoke test can
-- force the fallback path on a modern host.
M.float_input = vim.fn.has('nvim-0.10') == 1

-- Open the editor on comment `c` (a draft or a real one, its extmark in
-- place). On 0.10+ it is a borderless float over spacer virt_lines at the
-- anchor — editing looks like typing into the virtual text itself;
-- otherwise a small split at the bottom.
local function input(title, c)
  local from = vim.api.nvim_get_current_win()
  local row, col
  if M.float_input then row, col = float_pos(from, c.line) end
  local win, buf
  if not row then
    -- 0.9, or an anchor with no screen position: the split fallback.
    vim.cmd('botright 6new')
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_get_current_buf()
  else
    buf = vim.api.nvim_create_buf(false, false)
  end
  -- acwrite, so :w is the flush it looks like and :wq closes.
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, 'orca://comment/' .. title)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(c.text, '\n', { plain = true }))
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modified = false
  local e = { c = c, buf = buf, float = row ~= nil,
    orig = { text = c.text, status = c.status, resolution = c.resolution } }
  if row then win = float_open(e, from, row, col) end
  state.input, state.editing = win, c

  local group = 'orca-notes'
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group, buffer = buf,
    callback = function() sync_editor(e, true) end,
  })
  -- Leaving insert mode, :w, and :q (QuitPre runs before the unsaved-
  -- changes check) all write now.
  vim.api.nvim_create_autocmd({ 'InsertLeave', 'BufWriteCmd', 'QuitPre' }, {
    group = group, buffer = buf,
    callback = function() sync_editor(e) end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      -- The split closed from inside (:q, :wq): focus goes back where the
      -- comment was made, not to the panel the split sat under. Deferred,
      -- because the window is still closing, and dropped if another editor
      -- has opened meanwhile. (A float hands focus back to `from` itself.)
      local inside = not e.float and vim.api.nvim_get_current_win() == win and not e.closing
      finish(e)
      if inside then
        vim.schedule(function()
          if state and state.input then return end
          if vim.api.nvim_win_is_valid(from) then pcall(vim.api.nvim_set_current_win, from) end
        end)
      end
    end,
  })
  e.win = win
  state.edit = e
end

-- Close the open editor, if any. What it holds is already the comment's;
-- closing saves it (or drops an empty draft) through the WinClosed route
-- that every other way of closing it takes too.
function M.close_input()
  local e = state and state.edit
  if not (e and state.input and vim.api.nvim_win_is_valid(state.input)) then return end
  e.closing = true
  pcall(vim.api.nvim_win_close, state.input, true)
end

-- Create the comment anchored at [line, line2] of path in buf, or edit the
-- one already covering `line`.
function M.comment(path, buf, line, line2)
  if not state then return end
  if state.blocked then
    return notify(('commenting disabled — %s is %s'):format(state.path, state.blocked),
      vim.log.levels.ERROR)
  end
  if state.input and vim.api.nvim_win_is_valid(state.input) then
    return vim.api.nvim_set_current_win(state.input)
  end
  local c = covering(path, line)
  if c then
    if not (c.buf == buf and live(c)) then
      unplace(c)
      place(c, buf)
    end
  else
    c = {
      draft = true,
      file = path,
      line = line,
      end_line = (line2 and line2 > line) and line2 or nil,
      text = '',
      quoted = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or '',
      status = 'open',
      buf = buf,
    }
    c.mark = set_mark(buf, nil, c.line, c.end_line, spacers(1))
  end
  input(c.draft and ('%s:%d'):format(path, line) or ('#%d %s:%d'):format(c.id, path, c.line), c)
end

-- Take `c` out of the review: off the list, off the screen, and its
-- editor closed if one is open on it. A draft is only ever on screen.
local function remove(c)
  c.deleted = true
  for i, x in ipairs(state.comments) do
    if x == c then
      table.remove(state.comments, i)
      break
    end
  end
  unplace(c)
  if state.editing == c then M.close_input() end
  if not c.draft then M.save() end
end

-- Delete the comment covering `line` of `path`, if any — looked up now, so
-- whatever has changed since an editor opened, it is this one that goes.
function M.delete(path, line)
  if not state or state.blocked then return end
  local c = covering(path, line)
  if not c then return notify('no comment on this line') end
  remove(c)
  notify(('comment #%d deleted — %s:%d'):format(c.id, path, line))
end

-- Delete from inside the editor: the comment it is editing, or the draft
-- it holds. False when the current buffer is not an editor.
function M.delete_editing()
  local e = state and state.edit
  if not (e and vim.api.nvim_get_current_buf() == e.buf) then return false end
  if state.blocked then return true end
  local c = e.c
  -- Typed but not yet pulled in, a draft is still a draft: nothing to save.
  local draft = c.draft
  remove(c)
  notify(draft and 'comment discarded' or ('comment #%d deleted'):format(c.id))
  return true
end

-- The open editor's buffer, or nil.
function M.editor_buf()
  local e = state and state.edit
  return e and vim.api.nvim_buf_is_valid(e.buf) and e.buf or nil
end

-- End the notes layer: the editor closed (which saves what it holds),
-- a final save (anchors as the session last saw them), extmarks cleared.
-- The file persists — that is the point.
function M.stop()
  if not state then return end
  -- The editor first: its close re-places the comment's extmark, which must
  -- happen before the unplace sweep, not after it.
  M.close_input()
  M.save()
  if state.save_timer then
    state.save_timer:stop()
    state.save_timer:close()
  end
  for _, c in ipairs(state.comments) do unplace(c) end
  pcall(vim.api.nvim_del_augroup_by_name, 'orca-notes')
  state = nil
end

return M
