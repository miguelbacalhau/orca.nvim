-- :checkhealth orca — answers "why doesn't :OrcaReview work here" without a
-- bug report: plugin reachable, git present and new enough, inside a repo,
-- orca-managed (.orca/ at the repo root), trunk resolvable.

local M = {}

function M.check()
  local h = vim.health
  local start = h.start or h.report_start
  local ok = h.ok or h.report_ok
  local warn = h.warn or h.report_warn
  local err = h.error or h.report_error

  start('orca.nvim')

  if vim.fn.has('nvim-0.9') == 1 then
    ok('Neovim ' .. tostring(vim.version()))
  else
    warn('Neovim < 0.9 — orca.nvim is only exercised on 0.9+')
  end

  if vim.fn.executable('git') == 0 then
    err('git not found on PATH', 'install git ≥ 2.5')
    return
  end
  local git = require('orca.git')
  local version = git.version()
  if not version then
    warn('could not parse `git --version` output')
  else
    local major, minor = version:match('^(%d+)%.(%d+)')
    if tonumber(major) > 2 or (tonumber(major) == 2 and tonumber(minor) >= 5) then
      ok('git ' .. version)
    else
      err('git ' .. version .. ' is too old', 'worktrees need git ≥ 2.5')
    end
  end

  if not git.in_repo() then
    warn(('not inside a git repository (cwd: %s) — :OrcaReview needs one'):format(vim.fn.getcwd()))
    return
  end
  ok('inside a git repository')

  local root = git.repo_root()
  if root and vim.fn.isdirectory(root .. '/.orca') == 1 then
    ok('orca-managed repository — .orca/ at ' .. root)
  else
    err(('no .orca/ at %s — :OrcaReview requires an orca-managed repository')
      :format(root or '<unresolvable repo root>'),
      'run /orca:init in a Claude Code session with the orca plugin')
  end

  local trunk, terr = git.trunk()
  if trunk then
    ok(('trunk resolves to %s — bare :OrcaReview reviews %s...HEAD'):format(trunk, trunk))
  else
    warn(terr or 'trunk not resolvable', 'pass an explicit range: :OrcaReview main...HEAD')
  end
end

return M
