-- Git plumbing for orca.nvim: trunk and merge-base resolution, the changed-
-- file list, and file-at-revision readers. Pure queries — nothing here writes
-- to the repository or touches editor state.

local M = {}

-- Run git with list-form arguments (no shell involved). Returns the output
-- lines, or nil plus a message.
local function git(args)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, ('git %s failed'):format(table.concat(args, ' '))
  end
  return lines
end

-- Absolute path of the working tree root.
function M.toplevel()
  local out = git({ 'rev-parse', '--show-toplevel' })
  if not out or not out[1] then return nil, 'not inside a git working tree' end
  return out[1]
end

function M.in_repo()
  return git({ 'rev-parse', '--git-dir' }) ~= nil
end

-- The default review base — a default, not discovery; explicit ranges
-- bypass it. Resolved in tiers:
--  1. In a linked worktree, the symbolic HEAD of the *common* git dir — in
--     orca's bare-repo-with-worktrees layout, the bare repo's trunk branch.
--  2. Otherwise HEAD is the branch under review, not a trunk signal (a
--     normal checkout's common dir is its own .git): origin/HEAD names the
--     remote's default branch; prefer its local twin.
--  3. Last resort: the first of main/master/trunk that exists locally.
function M.trunk()
  local gitdir = git({ 'rev-parse', '--git-dir' })
  local common = git({ 'rev-parse', '--git-common-dir' })
  if not (gitdir and gitdir[1] and common and common[1]) then
    return nil, 'not inside a git repository'
  end
  if vim.fn.fnamemodify(gitdir[1], ':p') ~= vim.fn.fnamemodify(common[1], ':p') then
    local ref = git({ '--git-dir=' .. vim.fn.fnamemodify(common[1], ':p'),
      'symbolic-ref', '--quiet', '--short', 'HEAD' })
    if ref and ref[1] and ref[1] ~= '' then return ref[1] end
  end
  local origin = git({ 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD' })
  local name = origin and origin[1] and origin[1]:match('^origin/(.+)$')
  if name then
    if git({ 'rev-parse', '--verify', '--quiet', 'refs/heads/' .. name }) then return name end
    return origin[1]
  end
  for _, cand in ipairs({ 'main', 'master', 'trunk' }) do
    if git({ 'rev-parse', '--verify', '--quiet', 'refs/heads/' .. cand }) then return cand end
  end
  return nil, 'cannot resolve a trunk branch — pass an explicit range: :OrcaReview <base>...<head>'
end

function M.merge_base(base, head)
  local out = git({ 'merge-base', base, head })
  if not out or not out[1] then
    return nil, ('no merge-base for %s and %s'):format(base, head)
  end
  return out[1]
end

-- One entry per file changed between the merge-base and head:
-- { status = 'M'|'A'|'D'|'R'|'C'|'T', path, old_path, binary, reviewed }.
-- `path` is the current name, `old_path` the merge-base name (they differ
-- only for renames/copies); both are relative to the repository root.
function M.changed_files(mergebase, head)
  local status_lines, err = git({ 'diff', '--name-status', '-M', mergebase, head })
  if not status_lines then return nil, err end
  -- Same diff, same options: numstat lists files in the same order, and
  -- marks binary ones with "-<TAB>-" counts. Zip by index to detect them
  -- without re-parsing rename paths.
  local numstat_lines = git({ 'diff', '--numstat', '-M', mergebase, head }) or {}
  local entries = {}
  for i, line in ipairs(status_lines) do
    local fields = vim.split(line, '\t', { plain = true })
    entries[#entries + 1] = {
      status = fields[1]:sub(1, 1),
      old_path = fields[2],
      path = fields[#fields],
      binary = (numstat_lines[i] or ''):match('^%-\t%-\t') ~= nil,
      reviewed = false,
    }
  end
  return entries
end

-- Contents of <path> (repo-root-relative) at <rev>, as a list of lines.
function M.show(rev, path)
  return git({ 'show', rev .. ':' .. path })
end

-- "2.39.5" from `git --version`, or nil.
function M.version()
  local out = git({ '--version' })
  if not out or not out[1] then return nil end
  return out[1]:match('(%d+%.%d+[%.%d]*)')
end

return M
