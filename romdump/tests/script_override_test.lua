-- Script composition contracts : production uses generated vanilla resources,
-- ordinary map intents derive their ids from source identity, explicit
-- test-owned overrides retain precedence, and unsupported generated nodes
-- remain scheduler faults.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local Bindings = require("libs.hgss.src.script.Bindings")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local FakeServices = require("tests.support.script.FakeServices")
local RepoFs = require("game.src.RepoFs")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local S = require("gen4.script")

local T = {
  metadata = { tags = { "script", "composition", "vanilla" } },
  tests = {},
}
local GENERATION = string.rep("a", 40)

local PRODUCTION_IDS = {
  "demo.signpost",
  "elms_lab.elm",
  "vanilla.hgss.scr_seq.0842.script_017",
}

local function productionFs()
  return RepoFs.new(love.filesystem.getSourceBaseDirectory())
end

local function generatedResource(id)
  return S.script({ api = 1, id = id, steps = { S.stop() } })
end

local function scriptText(id, step)
  return string.format(
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = %q, steps = { %s } }\n',
    id,
    step
  )
end

local function cacheWithScripts(files)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(ScriptCache.markerPath(), "synthetic-script-cache")
  local resources = {}
  for id in pairs(files) do
    resources[#resources + 1] = { id = id }
  end
  table.sort(resources, function(a, b)
    return a.id < b.id
  end)
  for index, entry in ipairs(resources) do
    entry.member = 0
    entry.scriptIndex = index - 1
  end
  cache:write(ScriptCache.generationMarkerPath(GENERATION), "synthetic-script-cache")
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = "synthetic-script-cache",
  })
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = "synthetic-script-cache",
    resources = resources,
  })
  for id, content in pairs(files) do
    cache:write(ScriptCache.scriptPath(GENERATION, 0, id), content)
  end
  return cache
end

local function overrideFs(files)
  local ids = {}
  for id in pairs(files) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local manifest = "return {"
  for _, id in ipairs(ids) do
    manifest = manifest .. string.format(" %q,", id)
  end
  manifest = manifest .. " }\n"
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return manifest
      end
      local id = path:match("^data/scripts/overrides/(.+)%.lua$")
      return id and files[id] or nil
    end,
  }
end

function T.tests.production_registry_uses_generated_resources()
  local registry = Registry.new()
  for _, id in ipairs(PRODUCTION_IDS) do
    registry:installBase(id, generatedResource(id), "generated")
  end

  local installed = ScriptLoader.installOverrides(registry, productionFs())
  Assert.equal(#installed, 0, "production must not install checked-in script overrides")
  for _, id in ipairs(PRODUCTION_IDS) do
    local resource = assert(registry:base(id))
    Assert.isFalse(resource.metadata ~= nil and resource.metadata.override == true)
  end
end

function T.tests.map_intents_match_the_compiler_canonical_id()
  local expected = "vanilla.hgss.scr_seq.0842.script_001"
  Assert.equal(ScriptCompiler.publicId(842, 1), expected)

  local bindings = Bindings.new()
  local intent = {
    kind = "object",
    mapId = 60,
    scriptBankId = 842,
    scriptId = 2,
    playerFacing = "north",
    object = { actorId = "map:60:object:1", objectEventId = 1, spriteId = 1 },
  }
  local hit = assert(bindings:resolveIntent(intent, intent.playerFacing), "map intent must resolve mechanically")
  Assert.equal(hit.scriptId, expected)
  Assert.equal(hit.trigger.scriptId, expected)
end

function T.tests.zero_raw_script_id_resolves_to_the_inert_interaction()
  local bindings = Bindings.new()
  local intent = {
    kind = "background",
    mapId = 60,
    scriptBankId = 842,
    scriptId = 0,
    playerFacing = "north",
    background = { eventIndex = 0, type = 1, direction = 4 },
  }
  local resolved = assert(bindings:resolveIntent(intent, intent.playerFacing))
  Assert.equal(resolved.scriptId, "runtime.inert_interaction")
end

function T.tests.synthetic_override_keeps_explicit_precedence()
  local id = "test.generated.script"
  local generated = cacheWithScripts({
    [id] = scriptText(id, "S.stop()"),
  })
  local withoutOverride = ScriptLoader.buildRegistry(generated, overrideFs({}))
  Assert.equal(assert(withoutOverride:base(id)).steps[1].op, "stop")

  local withOverride = ScriptLoader.buildRegistry(
    generated,
    overrideFs({
      [id] = scriptText(id, "S.yieldTick()"),
    })
  )
  Assert.equal(assert(withOverride:base(id)).steps[1].op, "yield_tick")
end

function T.tests.generated_unsupported_node_is_a_scheduler_fault()
  local id = "vanilla.hgss.scr_seq.0842.script_016"
  local cache = cacheWithScripts({
    [id] = scriptText(id, 'S.unsupported({ command = 999, originalName = "SyntheticUnsupported" })'),
  })
  local registry = ScriptLoader.buildRegistry(cache, productionFs())
  local composition = Composition.new(registry)
  local services = FakeServices.new()
  services.signpost = {
    setSourceAppearance = function() end,
    setCommand = function() end,
    isCommandIdle = function()
      return true
    end,
  }
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = TaskRegistry.new(),
    resolveComposition = function(scriptId)
      return composition:effective(scriptId)
    end,
  })
  local composed = assert(composition:effective(id))
  local instanceId = scheduler:createForeground(composed, nil, 100)
  scheduler:step(100, nil)

  local fault = assert(services.events:eventFor("script.error", instanceId))
  Assert.equal(fault.code, "SCRIPT_UNSUPPORTED_REACHABLE")
  Assert.equal(fault.context.scriptId, id)
  Assert.isNil(scheduler:foregroundEnvironmentId(), "unsupported execution must release foreground ownership")
  Assert.equal(#scheduler:instances(), 0, "faulted root must be cleaned up")
  Assert.equal(#scheduler:tasks(), 0, "unsupported execution must not leave tasks behind")
end

return T
