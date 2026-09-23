require('helpers')

-- virt_lines never wrap on their own (each is one screen line, truncated
-- at the window edge), so the plugin soft-wraps each stored line at
-- placement time to the target window's text width.
orca.review('')
orca.open(idx_of('src/b%.lua'))
local rwin = vim.api.nvim_get_current_win()
local rbuf = vim.api.nvim_get_current_buf()
local function virt_chunks()
  local vout = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do vout[#vout + 1] = vl[1][1] end
  end
  return vout
end
local function text_width()
  local info = vim.fn.getwininfo(rwin)[1]
  return info.width - info.textoff
end

local long = ('soft wrap words '):rep(15) .. 'https://example.com/' .. ('x'):rep(90)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { long })
commit()
local wrapped = virt_chunks()
check(#wrapped > 1, 'long comment wraps into multiple virt_lines, got ' .. #wrapped)
local data = read_notes()
check(data and data.comments[1].text == long, 'stored text stays unwrapped')

-- Resize re-places through the WinResized → scheduled-refit path. Headless
-- runs never see the real event (it fires from the redraw loop, which a
-- UI-less startup script never enters), so fire the autocmd by hand — the
-- handler's no-v:event fallback refits every window in the tab.
vim.cmd('vertical resize 70')
vim.api.nvim_exec_autocmds('WinResized', {})
drain(function() return #virt_chunks() ~= #wrapped end)
local rewrapped = virt_chunks()
check(#rewrapped > 1 and #rewrapped < #wrapped,
  ('wider window rewraps into fewer chunks (%d -> %d)'):format(#wrapped, #rewrapped))
local fits, prefixed = true, true
for _, chunk in ipairs(rewrapped) do
  if vim.fn.strdisplaywidth(chunk) > text_width() then fits = false end
  if chunk:sub(1, #'┃ ') ~= '┃ ' then prefixed = false end
end
check(fits, 'no wrapped chunk exceeds the window text width (' .. text_width() .. ')')
check(prefixed, 'every continuation chunk keeps the ┃ prefix')

-- Refit preserves drift: sync first, then place at the synced line — an
-- anchor that rode an insertion must not snap back to its stored line.
vim.fn.append(0, 'drift line')
vim.cmd('vertical resize 40')
vim.api.nvim_exec_autocmds('WinResized', {})
drain(function() return #virt_chunks() ~= #rewrapped end)
local drifted = vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, {})[1]
check(drifted and drifted[2] == 2, 'resize refit keeps the drifted anchor (row 2), got '
  .. tostring(drifted and drifted[2]))
vim.api.nvim_buf_set_lines(rbuf, 0, 1, false, {})
vim.bo[rbuf].modified = false
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('OrcaCommentDelete')
check(#vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, {}) == 0, 'wrap fixture cleaned up')

-- Ranged comment: ONE extmark spanning line..end_line (no invisible end
-- tracker), and the sign renders on every covered gutter row — the old
-- anchor-only sign left inner range lines bare.
vim.cmd('3,4OrcaComment')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'range text' })
commit()
local ranged_marks = vim.api.nvim_buf_get_extmarks(rbuf, NS, 0, -1, { details = true })
check(#ranged_marks == 1, 'range comment is one ranged extmark, got ' .. #ranged_marks)
check(ranged_marks[1] and ranged_marks[1][4].end_row == 3, 'extmark end_row tracks end_line, got '
  .. tostring(ranged_marks[1] and ranged_marks[1][4].end_row))
vim.cmd('redraw')
local function sign_at(lnum)
  local sp = vim.fn.screenpos(rwin, lnum, 1)
  return sp.row > 0 and vim.fn.screenstring(sp.row, sp.col - 2) or '?'
end
check(sign_at(3) == '┃' and sign_at(4) == '┃',
  ('ranged sign covers every spanned row, got [%s][%s]'):format(sign_at(3), sign_at(4)))
check(sign_at(1) ~= '┃', 'row outside the range shows no sign')

-- The single ranged extmark drifts as one unit: an insertion above moves
-- both ends, read back from details.end_row on the next save.
vim.fn.append(0, 'drift line')
require('orca.notes').save()
data = read_notes()
check(data and data.comments[1].line == 4 and data.comments[1].end_line == 5,
  ('ranged anchor rides an insertion (3-4 -> 4-5), got %s-%s'):format(
    tostring(data and data.comments[1].line), tostring(data and data.comments[1].end_line)))
vim.api.nvim_buf_set_lines(rbuf, 0, 1, false, {})
vim.bo[rbuf].modified = false
orca.close()
vim.fn.delete(notes_path)

finish()
