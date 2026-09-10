-- Contract tests for suite normalization. The explicit shape is the only
-- shape: a mis-shaped module must be a loud error, not a suite that silently
-- contributes zero tests — the runner has no registry left to notice the
-- difference.

local Assert = require("tests.support.Assert")
local Suite = require("tests.runner.Suite")

local T = {}

local function normalize(mod, defaultLayer)
  return Suite.normalize(mod, "fake.unit.alpha_test", defaultLayer or "unit")
end

-- A bare `name -> function` module is not a legacy shape to normalize: the
-- runner no longer guesses what a module means, so a flat module raises.
function T.flat_module_without_a_tests_table_is_rejected()
  local err = Assert.throws(function()
    normalize({ ["a case"] = function() end, ["b case"] = function() end })
  end)
  Assert.isTrue(tostring(err):find("tests table", 1, true) ~= nil, "names the missing tests table: " .. tostring(err))
end

-- Hooks are plain functions or absent; a non-function hook would be stored and
-- later called as one, surfacing as a confusing runner crash.
function T.non_function_hooks_are_rejected()
  local beforeErr = Assert.throws(function()
    normalize({ beforeAll = "setup", tests = {} })
  end)
  Assert.isTrue(tostring(beforeErr):find("beforeAll", 1, true) ~= nil, "names beforeAll: " .. tostring(beforeErr))

  local afterErr = Assert.throws(function()
    normalize({ afterAll = 1, tests = {} })
  end)
  Assert.isTrue(tostring(afterErr):find("afterAll", 1, true) ~= nil, "names afterAll: " .. tostring(afterErr))
end

-- Capability and tag arrays must be real arrays: `ipairs` alone swallows both
-- holes and extra keys, which would silently drop declarations.
function T.array_metadata_must_be_contiguous_without_extra_keys()
  local extra = Assert.throws(function()
    normalize({ metadata = { capabilities = { "graphics", extra = "x" } }, tests = {} })
  end)
  Assert.isTrue(tostring(extra):find("capabilities", 1, true) ~= nil, "names capabilities: " .. tostring(extra))

  local hole = Assert.throws(function()
    normalize({ metadata = { tags = { "field", nil, "dialogue" } }, tests = {} })
  end)
  Assert.isTrue(tostring(hole):find("tags", 1, true) ~= nil, "names tags: " .. tostring(hole))
end

-- The layer is the discovery root's alone: suites inherit it and cannot
-- declare their own.
function T.suites_inherit_the_root_layer()
  local suite = normalize({
    metadata = { capabilities = { "graphics" }, tags = { "renderer" } },
    beforeAll = function() end,
    tests = { ["compiles a shader"] = function() end },
  }, "graphics")

  Assert.equal(suite.layer, "graphics")
  Assert.deepEqual(suite.capabilities, { "graphics" })
  Assert.deepEqual(suite.tags, { "renderer" })
  Assert.deepEqual(suite.tests, { "compiles a shader" })
  Assert.equal(type(suite.beforeAll), "function")
end

-- A metadata layer would be a second classifier next to the discovery root;
-- it is rejected as an unknown metadata key.
function T.metadata_layer_is_rejected_as_an_unknown_key()
  local err = Assert.throws(function()
    normalize({ metadata = { layer = "graphics" }, tests = { ["a"] = function() end } })
  end)
  Assert.isTrue(tostring(err):find("layer", 1, true) ~= nil, "names the rejected key: " .. tostring(err))
end

-- A module carrying metadata or hooks but no `tests` table would otherwise
-- normalize to an empty legacy suite and report nothing at all.
function T.metadata_without_tests_is_rejected()
  local err = Assert.throws(function()
    normalize({ metadata = {} })
  end)
  Assert.isTrue(tostring(err):find("tests table", 1, true) ~= nil, "names the missing tests table: " .. tostring(err))
end

function T.unknown_suite_and_metadata_keys_are_rejected()
  local suiteKey = Assert.throws(function()
    normalize({ tests = {}, setUp = function() end })
  end)
  Assert.isTrue(tostring(suiteKey):find("setUp", 1, true) ~= nil, "names the unknown key: " .. tostring(suiteKey))

  local metadataKey = Assert.throws(function()
    normalize({ metadata = { layers = "unit" }, tests = {} })
  end)
  Assert.isTrue(
    tostring(metadataKey):find("layers", 1, true) ~= nil,
    "names the unknown metadata key: " .. tostring(metadataKey)
  )
end

function T.non_function_test_entry_is_rejected()
  local err = Assert.throws(function()
    normalize({ tests = { ["not callable"] = "value" } })
  end)
  Assert.isTrue(tostring(err):find("not callable", 1, true) ~= nil, "names the offending test: " .. tostring(err))
end

-- The slow tier is one boolean: omitted and false are fast, true is slow.
function T.slow_defaults_to_fast_and_accepts_true()
  Assert.isFalse(normalize({ tests = {} }).slow, "omitted slow is fast")
  Assert.isFalse(normalize({ metadata = { slow = false }, tests = {} }).slow, "explicit false is fast")
  Assert.isTrue(normalize({ metadata = { slow = true }, tests = {} }).slow, "true is slow")
end

-- Any non-boolean slow value is a normalization failure, never a truthy slow.
function T.non_boolean_slow_is_rejected()
  for _, slow in ipairs({ 1, "true", {}, function() end }) do
    local err = Assert.throws(function()
      normalize({ metadata = { slow = slow }, tests = {} })
    end)
    Assert.isTrue(tostring(err):find("slow", 1, true) ~= nil, "names slow: " .. tostring(err))
  end
end

return { tests = T }
