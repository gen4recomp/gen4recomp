-- Runtime generation-pinning contract: a registry keeps the active selection
-- observed at construction even when a later generation is activated.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local ScriptLoader = require("libs.script.src.ScriptLoader")

local T = {}

local SCRIPT_ID = "vanilla.test.generation_pin"
local LEGACY_DIR = "data/generated/script"
local ACTIVE_DIR = LEGACY_DIR .. "/active"
local GENERATIONS_DIR = LEGACY_DIR .. "/generations"
local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)

local function scriptText(generation)
  return string.format(
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = %q, metadata = { generation = %q }, steps = { S.stop() } }\n',
    SCRIPT_ID,
    generation
  )
end

local function writeSelection(cache, generation, marker)
  local generationDir = GENERATIONS_DIR .. "/" .. generation
  local index = {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = generation,
    marker = marker,
    resources = { { id = SCRIPT_ID, member = 0, scriptIndex = 0 } },
  }
  cache:writeLua(ACTIVE_DIR .. "/index.lua", {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = generation,
    marker = marker,
  })
  cache:write(ACTIVE_DIR .. "/complete", marker)
  cache:writeLua(generationDir .. "/index.lua", index)
  cache:write(generationDir .. "/complete", marker)
  cache:write(generationDir .. "/members/0000/scripts/" .. SCRIPT_ID .. ".lua", scriptText(generation))

  -- Keep the old mutable paths populated only as a fixture for the pre-pin
  -- behavior. A pinned loader must not consult them after construction.
  cache:write(LEGACY_DIR .. "/complete", marker)
  cache:writeLua(LEGACY_DIR .. "/index.lua", { schema = ScriptCache.INDEX_SCHEMA, resources = { { id = SCRIPT_ID } } })
  cache:write(LEGACY_DIR .. "/scripts/" .. SCRIPT_ID .. ".lua", scriptText(generation))
end

local function overrideFs()
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return "return {}\n"
      end
      return nil
    end,
  }
end

function T.registry_pins_the_generation_seen_before_activation()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeSelection(cache, GENERATION_A, "marker-a")

  local oldRegistry = ScriptLoader.buildRegistry(cache, overrideFs(), nil, { lazy = true })
  writeSelection(cache, GENERATION_B, "marker-b")

  local oldResource = assert(oldRegistry:base(SCRIPT_ID))
  Assert.equal(oldResource.metadata.generation, GENERATION_A, "a running registry must remain pinned to generation A")

  local newRegistry = ScriptLoader.buildRegistry(cache, overrideFs(), nil, { lazy = true })
  local newResource = assert(newRegistry:base(SCRIPT_ID))
  Assert.equal(newResource.metadata.generation, GENERATION_B, "a later registry observes generation B")
  Assert.isTrue(
    oldRegistry:fingerprint() ~= newRegistry:fingerprint(),
    "generation activation changes the registry fingerprint"
  )
end

return { tests = T }
