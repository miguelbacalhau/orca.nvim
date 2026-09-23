-- Hidden groups: the panel's view filter. An orca run's diff is often
-- mostly tests, and the look-through before merge wants the source in
-- front of it — so files matching a named group fold away behind one
-- summary row, and the row brings them back.
--
-- Nothing here touches the session's entry list. Hiding is a view over it
-- (orca/init.lua owns session.view), so a hidden file still opens by
-- :edit, still anchors comments, and still reaches the notes file — and it
-- is never hidden silently: the panel always carries the count, and three
-- things pin an entry visible whatever the groups say. A comment on it
-- (you have already said something about this file), being the file the
-- session is currently in, and being the last one left.
--
-- A group is a list of globs, where the '/' decides what gets matched:
--
--   *_test.go     no slash         the basename
--   tests/        trailing slash   a directory, at any depth
--   spec/**/*.rb  slash inside     the whole repo-relative path
--   /tests/       leading slash    anchored at the repository root
--
-- '*' stops at a separator, '**' crosses it, '?' is one non-separator
-- character; '**/' also matches no directory at all. Everything else is
-- literal.

local notify = require('orca.util').notify

local M = {}

-- Shipped defaults. These are load-bearing — a too-greedy glob silently
-- drops real code from every review in every repo — so every directory
-- entry is a literal name and nothing matches on a bare "test" substring.
-- Fixture directories are deliberately absent: fixture data is frequently
-- the thing under review.
M.DEFAULT_GROUPS = {
  tests = {
    'tests/', 'test/', 'spec/', '__tests__/', 'testdata/',
    '*_test.*', '*_spec.*', '*.test.*', '*.spec.*', 'test_*.py', 'conftest.py',
  },
}

-- Glob → Lua pattern fragment. Escaping every non-alphanumeric is always
-- safe (%x is the literal x for any non-alphanumeric x), so the literal
-- branch needs no magic-character table.
local function to_pattern(glob)
  local out, i = {}, 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == '*' then
      if glob:sub(i + 1, i + 1) == '*' then
        out[#out + 1], i = '.*', i + 2
      else
        out[#out + 1], i = '[^/]*', i + 1
      end
    elseif c == '?' then
      out[#out + 1], i = '[^/]', i + 1
    else
      out[#out + 1], i = (c:match('%w') and c or ('%' .. c)), i + 1
    end
  end
  return table.concat(out)
end

local never = function() return false end
local cache = {}

-- Every spelling of `glob` with each '**/' either kept or dropped: '**/'
-- matches zero directories too, and a Lua pattern has no optional group to
-- say so. A trailing '**' has no slash to drop and is left alone.
local function variants(glob)
  local at = glob:find('**/', 1, true)
  if not at then return { glob } end
  local out = {}
  for _, rest in ipairs(variants(glob:sub(at + 3))) do
    out[#out + 1] = glob:sub(1, at + 2) .. rest
    out[#out + 1] = glob:sub(1, at - 1) .. rest
  end
  return out
end

-- One spelling (no '**/' left to vary) → a path predicate.
local function compile(g, anchored, dir)
  if g == '' then
    return never
  elseif dir then
    -- A directory matches as a whole path segment, at the root or at any
    -- depth unless anchored: 'tests/' catches lua/tests/x.lua, '/tests/'
    -- only tests/x.lua.
    local head, nested = '^' .. to_pattern(g) .. '/', '/' .. to_pattern(g) .. '/'
    return function(path)
      if path:find(head) then return true end
      return not anchored and path:find(nested) ~= nil
    end
  elseif anchored or g:find('/') then
    -- A path glob matches the whole path, or (unanchored) any tail of it
    -- starting at a segment boundary.
    local whole, tail = '^' .. to_pattern(g) .. '$', '/' .. to_pattern(g) .. '$'
    return function(path)
      if path:find(whole) then return true end
      return not anchored and path:find(tail) ~= nil
    end
  end
  local base = '^' .. to_pattern(g) .. '$'
  return function(path)
    local name = path:match('[^/]+$')
    return name ~= nil and name:find(base) ~= nil
  end
end

-- One glob → a path predicate, compiled once per session-lifetime.
local function matcher(glob)
  if cache[glob] then return cache[glob] end
  local g = glob
  local anchored = g:sub(1, 1) == '/'
  if anchored then g = g:sub(2) end
  local dir = g:sub(-1) == '/'
  if dir then g = g:sub(1, -2) end
  local preds = {}
  -- '**/b' drops to 'b', a basename glob — which is what an unanchored
  -- '**/b' means anyway.
  for _, v in ipairs(variants(g)) do preds[#preds + 1] = compile(v, anchored, dir) end
  local m = preds[1]
  if #preds > 1 then
    m = function(path)
      for _, p in ipairs(preds) do
        if p(path) then return true end
      end
      return false
    end
  end
  cache[glob] = m
  return m
end

-- The configured groups: the shipped defaults, with vim.g.orca_review_groups
-- replacing a group's list outright (extend by writing the list out — the
-- defaults are in :help orca-hidden) and `false` dropping one. A new key
-- adds a group, and every defined group rides the one toggle.
function M.groups()
  local groups = vim.deepcopy(M.DEFAULT_GROUPS)
  local user = vim.g.orca_review_groups
  if type(user) == 'table' then
    for name, globs in pairs(user) do
      if globs == false then
        groups[name] = nil
      elseif type(globs) == 'table' then
        groups[name] = globs
      else
        notify(('vim.g.orca_review_groups.%s: expected a list of globs or false'):format(name),
          vim.log.levels.WARN)
      end
    end
  elseif user ~= nil then
    notify('vim.g.orca_review_groups: expected a table of { group = { glob, ... } }',
      vim.log.levels.WARN)
  end
  return groups
end

-- A classifier over one config snapshot: entry → group name, or nil for
-- an entry no group claims. Group order is alphabetical, so a file two
-- groups both match reports the same one every time.
function M.classifier(groups)
  groups = groups or M.groups()
  local names = vim.tbl_keys(groups)
  table.sort(names)

  local function group_of(path)
    for _, name in ipairs(names) do
      for _, glob in ipairs(groups[name]) do
        if matcher(glob)(path) then return name end
      end
    end
  end

  return function(entry)
    local group = group_of(entry.path)
    -- A rename out of a group is exactly the change you want in front of
    -- you, so an entry folds away only when both of its names match.
    if group and entry.old_path and entry.old_path ~= entry.path
      and not group_of(entry.old_path) then
      return nil
    end
    return group
  end
end

return M
