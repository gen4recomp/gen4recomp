-- Normalizes a loaded test module into the one suite shape:
--
--   { metadata = { capabilities, tags },
--     beforeAll = f, afterAll = f, tests = { name = function } }
--
-- Every key is validated: metadata is optional but must be a table of known
-- keys, capability/tag arrays must be contiguous with no extra keys, hooks
-- must be functions or absent, and a missing `tests` table is an error. The
-- layer is the discovery root's alone: suites inherit it and a metadata
-- layer is rejected rather than second-guessing the root.

local Suite = {}

local METADATA_KEYS = { capabilities = true, tags = true, slow = true }
local MODULE_KEYS = { metadata = true, beforeAll = true, afterAll = true, tests = true }

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Validates a metadata string array as a contiguous 1..n array: `ipairs`
-- alone would swallow both holes and extra keys, silently dropping
-- declarations.
local function stringArray(value, what, moduleName)
  if value == nil then
    return {}
  end
  assert(type(value) == "table", moduleName .. ": metadata." .. what .. " must be an array")
  local count = 0
  for key in pairs(value) do
    assert(
      type(key) == "number" and key >= 1 and key % 1 == 0,
      moduleName .. ": metadata." .. what .. " must be a contiguous array"
    )
    count = count + 1
  end
  local out = {}
  for index = 1, count do
    local entry = value[index]
    assert(entry ~= nil, moduleName .. ": metadata." .. what .. " must be a contiguous array")
    assert(type(entry) == "string", moduleName .. ": metadata." .. what .. "[" .. index .. "] must be a string")
    out[index] = entry
  end
  return out
end

---@class RunnerSuite
---@field module string
---@field layer string
---@field capabilities string[]
---@field tags string[]
---@field slow boolean
---@field tests string[] sorted test names
---@field fns table<string, fun(context: table)>
---@field beforeAll fun(context: table)|nil
---@field afterAll fun(context: table)|nil

-- Raises when the module violates the suite contract; the caller reports that
-- as a failed result for `moduleName`.
---@param mod table loaded test module
---@param moduleName string
---@param defaultLayer string layer of the discovery root
---@return RunnerSuite
function Suite.normalize(mod, moduleName, defaultLayer)
  assert(type(mod) == "table", moduleName .. ": test module must return a table")
  assert(type(mod.tests) == "table", moduleName .. ": suite needs a tests table")

  for _, key in ipairs(sortedKeys(mod)) do
    assert(MODULE_KEYS[key], moduleName .. ": unknown suite key '" .. key .. "'")
  end
  assert(
    mod.beforeAll == nil or type(mod.beforeAll) == "function",
    moduleName .. ": beforeAll must be a function or nil"
  )
  assert(mod.afterAll == nil or type(mod.afterAll) == "function", moduleName .. ": afterAll must be a function or nil")

  local metadata = mod.metadata or {}
  assert(type(metadata) == "table", moduleName .. ": metadata must be a table")
  for _, key in ipairs(sortedKeys(metadata)) do
    assert(METADATA_KEYS[key], moduleName .. ": unknown metadata key '" .. key .. "'")
  end

  local fns = mod.tests
  local names = sortedKeys(fns)
  for _, name in ipairs(names) do
    assert(type(fns[name]) == "function", moduleName .. ": test '" .. name .. "' must be a function")
  end

  local layer = defaultLayer
  assert(type(layer) == "string", moduleName .. ": discovery root needs a string layer")

  if metadata.slow ~= nil then
    assert(type(metadata.slow) == "boolean", moduleName .. ": metadata.slow must be a boolean")
  end

  return {
    module = moduleName,
    layer = layer,
    capabilities = stringArray(metadata.capabilities, "capabilities", moduleName),
    tags = stringArray(metadata.tags, "tags", moduleName),
    slow = metadata.slow == true,
    tests = names,
    fns = fns,
    beforeAll = mod.beforeAll,
    afterAll = mod.afterAll,
  }
end

return Suite
