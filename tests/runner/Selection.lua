-- Pure selection rules: which suites and tests a run executes, and which
-- declared capability (if any) is unavailable.
--
-- A filter is matched literally against the fully qualified `module :: test`
-- name, so a module name, a test name, or any substring spanning both
-- selects. Lua pattern metacharacters have no special meaning.

local Selection = {}

Selection.QUALIFIER = " :: "

---@param moduleName string
---@param testName string
---@return string fully qualified test name used for filtering and reporting
function Selection.qualify(moduleName, testName)
  return moduleName .. Selection.QUALIFIER .. testName
end

---@param qualified string
---@param filter string|nil nil selects every test
---@return boolean
function Selection.matchesFilter(qualified, filter)
  if filter == nil then
    return true
  end
  return qualified:find(filter, 1, true) ~= nil
end

-- The first declared capability that is unavailable, or nil when the suite can
-- run. Order follows the declaration so the reported reason is stable.
---@param capabilities string[]
---@param available table<string, boolean>
---@return string|nil
function Selection.missingCapability(capabilities, available)
  for _, name in ipairs(capabilities) do
    if available[name] ~= true then
      return name
    end
  end
  return nil
end

-- Exact membership of one tag in the suite's normalized tags.
---@param suite RunnerSuite
---@param tag string
---@return boolean
local function hasTag(suite, tag)
  for _, declared in ipairs(suite.tags) do
    if declared == tag then
      return true
    end
  end
  return false
end

-- The selected test names of one suite, in the suite's (sorted) order, plus
-- the count hidden solely by the slow gate. Selectors compose conjunctively:
-- a tag mismatch rejects the suite before filtering, then the literal filter
-- picks names, then slow eligibility hides the matches unless enabled.
---@param suite RunnerSuite
---@param options { filter: string|nil, tag: string|nil, slow: boolean|nil }|nil
---@return string[] selected, integer excludedSlow
function Selection.tests(suite, options)
  options = options or {}
  assert(type(options) == "table", "Selection.tests needs an options table")
  if options.tag ~= nil and not hasTag(suite, options.tag) then
    return {}, 0
  end
  local matched = {}
  for _, name in ipairs(suite.tests) do
    if Selection.matchesFilter(Selection.qualify(suite.module, name), options.filter) then
      matched[#matched + 1] = name
    end
  end
  if suite.slow == true and options.slow ~= true then
    return {}, #matched
  end
  return matched, 0
end

return Selection
