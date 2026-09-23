require('helpers')

-- '**/' is zero or more directories. It used to compile to '.*/', which
-- demands at least one, so spec/**/*.rb passed over spec/a_spec.rb.
local filter = require('orca.filter')
local function claims(glob, path)
  return filter.classifier({ g = { glob } })({ path = path }) == 'g'
end
check(claims('spec/**/*.rb', 'spec/a_spec.rb') and claims('spec/**/*.rb', 'spec/x/a_spec.rb')
  and claims('spec/**/*.rb', 'spec/x/y/a_spec.rb'),
  "spec/**/*.rb claims spec files at any depth, the top one included")
check(not claims('spec/**/*.rb', 'lib/spec.rb') and not claims('spec/**/*.rb', 'spec/a_spec.lua'),
  'and nothing outside spec/')
check(claims('/**/gen.go', 'gen.go') and claims('/**/gen.go', 'a/gen.go')
  and claims('a/**/b/**/c', 'a/b/c') and claims('a/**/b/**/c', 'a/x/b/y/c')
  and not claims('a/**/b/**/c', 'a/x/c'),
  "every '**/' may match nothing, anchored or not")
check(claims('gen/**', 'gen/x/y.go') and not claims('gen/**', 'gen'),
  "a trailing '**' is unchanged")

-- ==================== the hidden view, directly ====================

-- filter.view is a pure function of the entries and the session's state,
-- so its rules are checked here without a session: what is claimed, what
-- pins a claimed entry visible, and the all-claimed fallback.
local ents = {
  { path = 'src/a.lua' }, { path = 'tests/a_spec.lua' }, { path = 'tests/b_spec.lua' },
  { path = 'src/b_test.lua' },
}
local cls = filter.classifier({ tests = { 'tests/', '*_test.*' } })
local v = filter.view(ents, 1, {}, true, cls)
check(table.concat(v.rows, ',') == '1' and v.n == 3 and v.groups.tests == 3 and v.hidden and not v.blocked,
  'view: grouped entries fold away and are counted, got rows ' .. table.concat(v.rows, ','))
v = filter.view(ents, 3, { ['tests/a_spec.lua'] = 2 }, true, cls)
check(table.concat(v.rows, ',') == '1,2,3' and v.n == 1,
  'view: a commented entry and the current one are pinned visible, got rows ' .. table.concat(v.rows, ','))
v = filter.view(ents, 1, {}, false, cls)
check(#v.rows == 4 and v.n == 3 and not v.hidden, 'view: shown, every entry takes a row and n still counts')
v = filter.view({ ents[2], ents[3] }, 0, {}, true, cls)
check(v.blocked and not v.hidden and table.concat(v.rows, ',') == '1,2',
  'view: when every entry is claimed, all show, hiding is off, and blocked says why')

finish()
