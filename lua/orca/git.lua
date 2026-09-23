-- Git plumbing for orca.nvim: trunk and merge-base resolution, the changed-
-- file list, and file-at-revision readers. Pure queries — nothing here writes
-- to the repository or touches editor state.

local M = {}

-- Run git with list-form arguments (no shell involved) and return its exit
-- code, stdout and stderr, kept apart: git writes warnings to stderr on a
-- successful run (a skipped rename detection, say), and those are not
-- output. vim.system is 0.10+; 0.9 gets the same from a buffered job, whose
-- data lists carry NUL bytes as "\n" inside an item.
local function run(cmd)
  if vim.system then
    local r = vim.system(cmd, { text = true }):wait()
    return r.code, r.stdout or '', r.stderr or ''
  end
  local out, err = { '' }, { '' }
  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) out = data end,
    on_stderr = function(_, data) err = data end,
  })
  if job <= 0 then return -1, '', 'cannot run git' end
  local code = vim.fn.jobwait({ job })[1]
  for i, item in ipairs(out) do out[i] = item:gsub('\n', '\0') end
  return code, table.concat(out, '\n'), table.concat(err, '\n')
end

-- git's stdout, or nil plus a message carrying its stderr.
local function git_raw(args)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  local code, stdout, stderr = run(cmd)
  if code ~= 0 then
    local why = vim.trim(stderr):match('[^\n]*')
    return nil, ('git %s failed%s'):format(table.concat(args, ' '),
      why ~= '' and (': ' .. why) or '')
  end
  return stdout
end

-- git's stdout as lines, or nil plus a message.
local function git(args)
  local stdout, err = git_raw(args)
  if not stdout then return nil, err end
  local lines = vim.split(stdout, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
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

-- Absolute repo root as orca defines it: the parent of the *common* git
-- dir — the exact rule the orca skills use. In orca's bare-with-worktrees
-- layout that is the directory holding .bare and every worktree; in a
-- plain checkout, the toplevel.
function M.repo_root()
  local out = git({ 'rev-parse', '--path-format=absolute', '--git-common-dir' })
  if not out or not out[1] then
    -- --path-format needs git ≥ 2.31; older gits emit a cwd-relative path.
    out = git({ 'rev-parse', '--git-common-dir' })
  end
  if not out or not out[1] then return nil, 'not inside a git repository' end
  return vim.fn.fnamemodify(out[1], ':p:h:h')
end

-- The local branch <rev> names, or nil: HEAD resolves through its symbolic
-- ref, anything else only if it is a local branch name verbatim (detached
-- HEAD, shas and remote refs all return nil).
function M.branch_of(rev)
  if rev == 'HEAD' then
    local out = git({ 'symbolic-ref', '--quiet', '--short', 'HEAD' })
    return out and out[1]
  end
  if git({ 'rev-parse', '--verify', '--quiet', 'refs/heads/' .. rev }) then return rev end
  return nil
end

-- The commit sha <rev> points at, or nil.
function M.rev(rev)
  local out = git({ 'rev-parse', '--verify', '--quiet', rev .. '^{commit}' })
  return out and out[1]
end

-- Is <a> an ancestor of <b>? False too when <a> is not a commit here at
-- all (a recycled branch whose old tip was pruned).
function M.is_ancestor(a, b)
  return git({ 'merge-base', '--is-ancestor', a, b }) ~= nil
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
-- { status = 'M'|'A'|'D'|'R'|'C'|'T', path, old_path, binary, added, deleted }.
-- `path` is the current name, `old_path` the merge-base name (they differ
-- only for renames/copies); both are relative to the repository root.
-- `added`/`deleted` are the file's line counts, nil for a binary file (git
-- counts no lines there).
function M.changed_files(mergebase, head)
  local status_lines, err = git({ 'diff', '--name-status', '-M', mergebase, head })
  if not status_lines then return nil, err end
  -- Same diff, same options: numstat lists files in the same order, and
  -- carries their line counts — "-<TAB>-" for a binary one. Zip by index,
  -- so neither rename paths nor quoted names need re-parsing here.
  local numstat_lines = git({ 'diff', '--numstat', '-M', mergebase, head }) or {}
  local entries = {}
  for i, line in ipairs(status_lines) do
    local fields = vim.split(line, '\t', { plain = true })
    local added, deleted = (numstat_lines[i] or ''):match('^(%S+)\t(%S+)\t')
    entries[#entries + 1] = {
      status = fields[1]:sub(1, 1),
      old_path = fields[2],
      path = fields[#fields],
      binary = added == '-',
      -- tonumber('-') is nil, so a binary file simply has no counts.
      added = tonumber(added),
      deleted = tonumber(deleted),
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
