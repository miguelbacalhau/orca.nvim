-- Shared by every smoke case (tests/cases/*.lua). run.sh runs each case in
-- its own headless nvim, from inside the feature worktree of a fresh copy of
-- the fixture, with tests/ on package.path; `require('helpers')` makes all
-- of these globals. A case ends with finish(), which reports and exits.

function out(s) io.write(s .. '\n') end
failed = 0
function check(cond, label)
  if cond then out('OK   ' .. label) else failed = failed + 1; out('FAIL ' .. label) end
end
function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'x', false)
end
function drain(cond)
  vim.wait(1000, cond, 10)
end
-- The comment editor saves as you type; :wq is the habit that closes it,
-- and focus goes back to where the comment was made a tick later.
function commit(cmd)
  local ed = vim.api.nvim_get_current_win()
  vim.cmd(cmd or 'wq')
  drain(function() return not vim.api.nvim_win_is_valid(ed) and vim.bo.buftype == '' end)
end

orca = require('orca')
NS = vim.api.nvim_create_namespace('orca_notes')
PNS = vim.api.nvim_create_namespace('orca_panel')

-- Panel introspection: one owned buffer (orca://review), one window at most.
function panel_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == 'orca://review' then
      return b
    end
  end
end
function panel_win()
  local b = panel_buf()
  if not b then return nil end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == b then return w end
  end
end
function panel_lines()
  return vim.api.nvim_buf_get_lines(panel_buf(), 0, -1, false)
end
-- 1-based row of the panel line matching pat (a lua pattern), or nil when
-- no row shows it. Rows are the panel's *view* — with the two test files
-- hidden by default they coincide with entry indices for all six visible
-- files (the hidden pair sorts last), which is what lets the cases keep
-- passing a row to orca.open().
function idx_of(pat)
  for i, l in ipairs(panel_lines()) do
    if l:find(pat) then return i end
  end
end
-- The row carrying the full-line current-file mark.
function panel_cur()
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), PNS, 0, -1, { details = true })) do
    if m[4].line_hl_group == 'OrcaPanelCurrent' then return m[2] + 1 end
  end
end
function status_hl(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), PNS,
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    -- the status letter's mark spans cols 1-2 (after the padding space)
    if m[3] == 1 and m[4].end_col == 2 then return m[4].hl_group end
  end
end
-- The *n comment-count token on a row, or nil.
function count_at(row)
  return panel_lines()[row]:match('%*%d+')
end
-- Is the count token on a row highlighted OrcaPanelCount?
function count_hl_at(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), PNS,
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].hl_group == 'OrcaPanelCount' then return true end
  end
  return false
end
-- The `+n -n` line counts on a row: the right-aligned virt_text, as
-- "<text>|<hl>,...", or nil when the row carries none.
function diffstat_at(row)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(panel_buf(), PNS,
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[4].virt_text and m[4].virt_text_pos == 'right_align' then
      local parts = {}
      for _, c in ipairs(m[4].virt_text) do
        parts[#parts + 1] = ('%s|%s'):format(c[1], c[2] or '')
      end
      return table.concat(parts, ',')
    end
  end
end
function panel_statusline()
  return vim.api.nvim_get_option_value('statusline', { win = panel_win() })
end

-- The repo root (the fixture's, holding .orca/) and this branch's notes file.
root = require('orca.git').repo_root()
notes_path = root .. '/.orca/review-notes/feature.json'
function read_notes()
  if vim.fn.filereadable(notes_path) == 0 then return nil end
  return vim.json.decode(table.concat(vim.fn.readfile(notes_path), '\n'),
    { luanil = { object = true, array = true } })
end

-- Windows in diff mode, in this tab.
function count_diff_wins()
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[w].diff then n = n + 1 end
  end
  return n
end

-- The merge-base side on screen: its window and the path it was cut from.
function left_side()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local n = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
    if n:find('^orca://') and n ~= 'orca://review' then return w, n end
  end
  return nil, ''
end

-- Every notify message fn() produces, joined; errors inside it swallowed.
function notices(fn)
  local got = {}
  local real = vim.notify
  vim.notify = function(m) got[#got + 1] = m end
  pcall(fn)
  vim.notify = real
  return table.concat(got, ' | ')
end

-- Report and exit: non-zero when any check failed.
function finish()
  out(failed == 0 and 'CASE PASS' or ('CASE FAIL (' .. failed .. ')'))
  vim.cmd(failed == 0 and 'qa!' or 'cquit')
end
