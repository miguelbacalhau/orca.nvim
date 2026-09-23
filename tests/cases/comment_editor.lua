require('helpers')

-- The float needs nvim_win_text_height (0.10+). On 0.9 the editor is always
-- the split, so the float's own checks are skipped there, and the contract
-- below runs through the split alone.
local has_float = require('orca.notes').float_input

if has_float then
  -- Editing happens in a borderless float over spacer virt_lines: the gap
  -- under the anchor stays open (spacers keep the ┃ prefix), float and gap
  -- grow with the text, and closing the float restores the real virt_lines
  -- whichever way it dies.
  orca.review('')
  orca.open(idx_of('src/b%.lua'))
  local fsrc_win = vim.api.nvim_get_current_win()
  local fsrc_buf = vim.api.nvim_get_current_buf()
  local function first_mark()
    return vim.api.nvim_buf_get_extmarks(fsrc_buf, NS, 0, -1, { details = true })[1]
  end

  -- New comment: the input is a float, and the comment's own extmark holds
  -- the sign + gap from the start.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('OrcaComment')
  local fwin = vim.api.nvim_get_current_win()
  local fbuf = vim.api.nvim_get_current_buf()
  check(vim.api.nvim_win_get_config(fwin).relative == 'editor',
    'comment input opens as an editor-relative float')
  check(first_mark() ~= nil, 'the draft\'s extmark holds the gap for a new comment')
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'float seed' })
  commit()
  check(not vim.api.nvim_win_is_valid(fwin), 'float closes on :wq')
  check(#vim.api.nvim_buf_get_extmarks(fsrc_buf, NS, 0, -1, {}) == 1,
    'one mark: the draft\'s became the comment\'s')
  local data = read_notes()
  check(data and data.comments[1].text == 'float seed', 'the float\'s text is in the JSON')

  -- Edit: the existing mark swaps its virt_lines for prefix-only spacers,
  -- count = the float's text height.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('OrcaComment')
  fwin = vim.api.nvim_get_current_win()
  fbuf = vim.api.nvim_get_current_buf()
  check(table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), '\n') == 'float seed',
    'edit float prefills the existing text')
  local spacer_ok = true
  for _, vl in ipairs(first_mark()[4].virt_lines or {}) do
    if vl[1][1] ~= '┃ ' then spacer_ok = false end
  end
  check(spacer_ok, 'edit-time virt_lines are prefix-only spacers')
  check(#first_mark()[4].virt_lines == vim.api.nvim_win_get_height(fwin),
    'spacer count equals the float height')

  -- Growth: more text -> taller float and more spacers, in lockstep.
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'grown alpha', 'beta', 'gamma', 'delta' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = fbuf })
  check(vim.api.nvim_win_get_height(fwin) == 4,
    'float grows to the text height, got ' .. vim.api.nvim_win_get_height(fwin))
  check(#first_mark()[4].virt_lines == 4,
    'spacer count grows in lockstep, got ' .. #first_mark()[4].virt_lines)

  -- Closing puts the real virt_lines back, with the text as it now stands.
  commit()
  local restored = {}
  for _, vl in ipairs(first_mark()[4].virt_lines or {}) do restored[#restored + 1] = vl[1][1] end
  check(table.concat(restored, '\n'):find('gamma', 1, true) ~= nil,
    'closing restores real virt_lines with the edited text')

  -- Leaving the float for the file is being done with it. It used to stay
  -- open over the gap, so the comment kept showing as the float's bare
  -- text, never as its rendered virt_lines with the #N in front.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('OrcaComment')
  fwin = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'left behind' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
  vim.cmd('wincmd p')
  drain(function() return not vim.api.nvim_win_is_valid(fwin) end)
  check(not vim.api.nvim_win_is_valid(fwin) and vim.api.nvim_get_current_win() == fsrc_win,
    'leaving the float closes it, and the cursor stays where it went')
  check(first_mark()[4].virt_lines[1][1][1] == '┃ #1 left behind',
    'and the comment shows rendered, number and all, got '
      .. tostring(first_mark()[4].virt_lines[1][1][1]))

  -- Session close with a float open: float gone, no dangling autocmds.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('OrcaComment')
  fwin = vim.api.nvim_get_current_win()
  orca.close()
  check(not vim.api.nvim_win_is_valid(fwin), 'session close takes the open float with it')
  check(#vim.api.nvim_buf_get_extmarks(fsrc_buf, NS, 0, -1, {}) == 0,
    'no extmarks survive close with a float open')
  -- (builtin matchparen owns a '*' WinScrolled; the float's autocmds are the
  -- window-id-patterned ones)
  local dangling = 0
  for _, a in ipairs(vim.api.nvim_get_autocmds({ event = { 'WinScrolled', 'WinClosed' } })) do
    if tostring(a.pattern):match('^%d+$') then dangling = dangling + 1 end
  end
  check(dangling == 0, 'no dangling float autocmds after close, got ' .. dangling)
  vim.fn.delete(notes_path)
else
  out('SKIP the float editor needs 0.10+')
end

-- The editor is the comment, not a transaction on it. What is typed is the
-- comment's as it is typed and on disk moments later; there is nothing to
-- commit and nothing to lose. The same contract holds for the float and for
-- the 0.9 split fallback, so it runs through both.
local function editor_contract(label)
  vim.fn.writefile({ vim.json.encode({ version = 1, range = 'main...HEAD', comments = {
    { id = 1, file = 'src/b.lua', line = 2, text = 'seeded', quoted = 'line2 CHANGED',
      status = 'addressed', resolution = 'done' },
    { id = 2, file = 'src/b.lua', line = 3, text = 'second', quoted = 'line3', status = 'open' },
  } }) }, notes_path)
  vim.cmd('silent! only')
  orca.review('')
  local bi = idx_of('src/b%.lua')
  orca.open(bi)
  local src_win, src_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local function type_in(lines)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
  end
  local function by_id(id)
    for _, c in ipairs((read_notes() or {}).comments or {}) do
      if c.id == id then return c end
    end
    return {}
  end
  local function edit_at(line)
    vim.api.nvim_set_current_win(src_win)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    vim.cmd('OrcaComment')
    return vim.api.nvim_get_current_win()
  end

  -- Typing persists without :w — a crash mid-sentence, which never closes
  -- anything, finds the words already on disk.
  local ed = edit_at(4)
  check(vim.api.nvim_win_get_config(ed).relative == (label == 'float' and 'editor' or ''),
    label .. ': the editor opens as a ' .. label)
  type_in({ 'typed live' })
  check(count_at(bi) == '*3', label .. ': a draft with words is a comment — the panel counts it')
  drain(function() return by_id(3).text == 'typed live' end)
  check(vim.api.nvim_win_is_valid(ed) and by_id(3).text == 'typed live',
    label .. ': typed text reaches the file with the editor still open, no :w')
  type_in({ 'typed live', 'more' })
  vim.api.nvim_exec_autocmds('InsertLeave', { buffer = 0 })
  check(by_id(3).text == 'typed live\nmore', label .. ': leaving insert mode writes at once')
  check(not vim.bo.modified, label .. ': and nothing is ever unsaved, so :q has nothing to refuse')
  commit('quit')

  -- :w is done — saved and closed, as it always was here — and q in normal
  -- mode closes too. Saving alone used to leave you stuck in the editor.
  ed = edit_at(4)
  type_in({ 'typed live', 'more', 'still more' })
  vim.cmd('write')
  drain(function() return not vim.api.nvim_win_is_valid(ed) end)
  check(not vim.api.nvim_win_is_valid(ed) and by_id(3).text == 'typed live\nmore\nstill more',
    label .. ': :w saves and closes the editor')
  ed = edit_at(4)
  keys('q')
  drain(function() return not vim.api.nvim_win_is_valid(ed) end)
  check(not vim.api.nvim_win_is_valid(ed), label .. ': q in normal mode closes it')
  drain(function() return vim.api.nvim_get_current_win() == src_win end)
  check(vim.api.nvim_get_current_win() == src_win, label .. ': and the cursor is back in the file')

  -- A draft closed with no words never existed: no mark, no comment, and no
  -- id used up.
  ed = edit_at(1)
  commit('quit')
  check(#vim.api.nvim_buf_get_extmarks(src_buf, NS, 0, -1, {}) == 3,
    label .. ': an empty draft leaves no mark behind')
  edit_at(1)
  type_in({ 'fourth' })
  commit()
  check(by_id(4).text == 'fourth', label .. ': and uses up no id — the next comment is #4')

  -- Opening a resolved comment is not editing it.
  edit_at(2)
  commit('quit')
  check(by_id(1).status == 'addressed' and by_id(1).resolution == 'done',
    label .. ': reopening a resolved comment without editing keeps it resolved')
  -- A real change reopens it; changing it back puts the answer back.
  edit_at(2)
  type_in({ 'seeded, reworded' })
  vim.api.nvim_exec_autocmds('InsertLeave', { buffer = 0 })
  check(by_id(1).status == 'open' and by_id(1).resolution == nil,
    label .. ': changed text reopens it')
  type_in({ 'seeded' })
  vim.api.nvim_exec_autocmds('InsertLeave', { buffer = 0 })
  check(by_id(1).status == 'addressed' and by_id(1).resolution == 'done',
    label .. ': edited back, it is resolved again')
  commit('quit')

  -- Emptying a comment is not how it is deleted: it keeps its last words.
  edit_at(3)
  type_in({ '' })
  commit('quit')
  check(by_id(2).text == 'second', label .. ': emptying a comment reverts it on close')

  -- A file change mid-sentence closes the editor and keeps the sentence.
  ed = edit_at(3)
  type_in({ 'second, amended' })
  orca.next()
  check(not vim.api.nvim_win_is_valid(ed), label .. ': the next-file key closes the editor')
  check(by_id(2).text == 'second, amended', label .. ': and the text typed so far is kept')
  check(panel_cur() == bi + 1, label .. ': and the walk goes through')
  -- Nothing of it is left holding the slot: the next :OrcaComment is the
  -- new file's.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd('OrcaComment')
  check(vim.api.nvim_buf_get_name(0):find('orca://comment/src/caf') ~= nil,
    label .. ': the next comment belongs to the new file, got ' .. vim.api.nvim_buf_get_name(0))
  commit('quit')
  orca.open(bi)
  src_win = vim.api.nvim_get_current_win()

  -- Deleting the comment under edit, from its file: the editor closes with
  -- it, and nothing else goes. The editor used to remember the comment's
  -- list position when it opened and delete by it when emptied, so the
  -- same steps with the list shifted underneath took out a neighbour.
  ed = edit_at(2)
  vim.api.nvim_set_current_win(src_win)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('OrcaCommentDelete')
  check(not vim.api.nvim_win_is_valid(ed), label .. ': deleting the comment under edit closes its editor')
  local ids = {}
  for _, c in ipairs(read_notes().comments) do ids[#ids + 1] = c.id end
  table.sort(ids)
  check(table.concat(ids, ',') == '2,3,4',
    label .. ': and deletes exactly that comment, got ' .. table.concat(ids, ','))
  orca.close()
  vim.fn.delete(notes_path)
end

-- Deleting from inside the editor, by the `delete` key when one is bound
-- and by :OrcaCommentDelete when not: the comment being edited goes, or
-- the draft is discarded, and the editor closes either way. It used to
-- mean leaving the editor for the file first.
local function delete_inside(label, key)
  vim.g.orca_mappings = key and { delete = key } or nil
  vim.fn.writefile({ vim.json.encode({ version = 1, range = 'main...HEAD', comments = {
    { id = 1, file = 'src/b.lua', line = 2, text = 'doomed', quoted = 'line2 CHANGED', status = 'open' },
  } }) }, notes_path)
  vim.cmd('silent! only')
  orca.review('')
  orca.open(idx_of('src/b%.lua'))
  local src_win, src_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local how = key and 'the delete key' or ':OrcaCommentDelete'
  local function del()
    if key then keys(key:gsub('<leader>', '\\')) else vim.cmd('OrcaCommentDelete') end
  end
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('OrcaComment')
  local ed = vim.api.nvim_get_current_win()
  if key then
    check(vim.fn.maparg(key, 'n', false, true).desc == 'orca: delete this comment',
      label .. ': the delete key is mapped in the editor')
  end
  del()
  check(not vim.api.nvim_win_is_valid(ed) and vim.fn.filereadable(notes_path) == 0,
    ('%s: %s inside the editor deletes the comment and closes it'):format(label, how))
  vim.api.nvim_set_current_win(src_win)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd('OrcaComment')
  ed = vim.api.nvim_get_current_win()
  del()
  check(not vim.api.nvim_win_is_valid(ed) and #vim.api.nvim_buf_get_extmarks(src_buf, NS, 0, -1, {}) == 0
    and vim.fn.filereadable(notes_path) == 0,
    ('%s: %s inside a draft discards it'):format(label, how))
  orca.close()
  vim.g.orca_mappings = nil
end

if has_float then
  editor_contract('float')
  delete_inside('float', nil)
  delete_inside('float', '<leader>x')
end
require('orca.notes').float_input = false
editor_contract('split')
delete_inside('split', nil)
delete_inside('split', '<leader>x')
require('orca.notes').float_input = has_float

finish()
