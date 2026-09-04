-- ROM conformance: the follower-transition effect compiles exactly from the
-- traced field_static_models members (models 129/104, animation 164) and
-- satisfies the strict field-effect cache contract with normalized lifecycle
-- and placement metadata. No substitute model or animation is accepted, and
-- every traced member feeds the generated dependency identity.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEffects = require("romdump.src.config.FieldEffects")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local Nsbta = require("libs.nds.src.nitro.g3d.Nsbta")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local compiledByVersion = {}

local function compileIntact(romFs, versionId)
  if compiledByVersion[versionId] == nil then
    compiledByVersion[versionId] = assert(FieldEntranceIndicatorCompiler.compile(romFs))
  end
  return compiledByVersion[versionId]
end

local function memberBytes(romFs, memberId)
  return assert(assert(romFs:openNarc("field_static_models")):readMember(memberId))
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

local function sortedIds(members)
  local out = {}
  for _, memberId in ipairs(members) do
    out[#out + 1] = memberId
  end
  table.sort(out)
  return out
end

local function declaresPreludeTicks(node, want)
  if type(node) ~= "table" then
    return false
  end
  for key, value in pairs(node) do
    if type(key) == "string" and key:lower():find("prelude", 1, true) and value == want then
      return true
    end
    if declaresPreludeTicks(value, want) then
      return true
    end
  end
  return false
end

local function collectFrameCounts(node, out)
  out = out or {}
  if type(node) ~= "table" then
    return out
  end
  for key, value in pairs(node) do
    if key == "frameCount" and type(value) == "number" then
      out[#out + 1] = value
    else
      collectFrameCounts(value, out)
    end
  end
  return out
end

local function collectAssetPaths(node, out)
  out = out or {}
  if type(node) == "string" then
    if node:sub(-#".g4mesh") == ".g4mesh" or node:sub(-#".png") == ".png" then
      out[#out + 1] = node
    end
    return out
  end
  if type(node) ~= "table" then
    return out
  end
  for _, value in pairs(node) do
    collectAssetPaths(value, out)
  end
  return out
end

local function assertFinitePlacement(offset, where)
  Assert.isTrue(type(offset) == "table", where .. " must carry the normalized placement")
  for _, axis in ipairs({ "x", "y", "z" }) do
    local value = offset[axis]
    Assert.isTrue(
      type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
      where .. " placement " .. axis .. " must be finite"
    )
  end
end

-- A proxy ROM filesystem that serves replacement bytes for selected members
-- of the effect source archive. Every other archive and operation forwards
-- to the real dump, so compilation stays ROM-backed.
local function patchedRomFs(romFs, swaps)
  local inner = assert(romFs:openNarc(FieldEffects.archive.alias))
  local patchedNarc = {
    memberCount = function(_)
      return inner:memberCount()
    end,
    readMember = function(_, memberId)
      if swaps[memberId] ~= nil then
        return swaps[memberId]
      end
      return inner:readMember(memberId)
    end,
  }
  return setmetatable({}, {
    __index = function(_, key)
      if key == "openNarc" then
        return function(_, alias)
          if alias == FieldEffects.archive.alias then
            return patchedNarc
          end
          return romFs:openNarc(alias)
        end
      end
      local value = romFs[key]
      if type(value) == "function" then
        return function(_, ...)
          return value(romFs, ...)
        end
      end
      return value
    end,
  })
end

local function sourceFrameCount(romFs)
  local raw = memberBytes(romFs, 164)
  local decoded = assert(
    Nsbta.decode(raw, { alias = FieldEffects.animationArchive.alias, memberId = 164 }),
    "transition animation member 164 must decode through the Nitro animation stack"
  )
  local animation = assert(decoded.animations[1], "member 164 must carry an animation")
  return assert(animation.resource.numFrame, "member 164 must carry an exact frame count")
end

function T.selection_pins_the_traced_source_members()
  local contractEffects = FieldEffects.effects --[[@as table]]
  local selection = assert(contractEffects.follower_transition, "the transition source selection must exist")
  Assert.equal(FieldEffects.archive.alias, "field_static_models", "the transition reuses the static model archive")
  Assert.equal(
    FieldEffects.animationArchive.alias,
    "field_static_models",
    "the transition animation reuses the static model archive"
  )
  Assert.deepEqual(sortedIds(selection.modelMembers), { 104, 129 }, "transition models")
  Assert.deepEqual(selection.animationMembers, { 164 }, "transition animation")
  assertFinitePlacement(selection.placementOffset, "the transition source selection")
  Assert.isTrue(declaresPreludeTicks(selection, 2), "the transition source selection must declare the two-tick prelude")
end

local function fakeCacheFor(bundle, overrides)
  overrides = overrides or {}
  local index = { schema = bundle.index.schema, effects = {} }
  for kind, entry in pairs(bundle.index.effects) do
    if kind ~= overrides.omitEffect then
      index.effects[kind] = { kind = entry.kind, definition = entry.definition, path = entry.path }
    end
  end
  return {
    read = function(_, path)
      if path == FieldEffectAssetCache.markerPath() then
        return overrides.marker or bundle.marker
      end
      return nil
    end,
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.indexPath() then
        return copy(index)
      end
      for kind, entry in pairs(index.effects) do
        if entry.path == path then
          local definition = copy(assert(bundle.effects[kind]))
          if overrides.dropLifecycle and kind == "follower_transition" then
            definition.lifecycle = nil
          end
          if overrides.dropPlacement and kind == "follower_transition" then
            definition.placementOffset = nil
          end
          return definition
        end
      end
      error("unexpected field-effect cache path " .. path)
    end,
    exists = function(_, path)
      return path ~= overrides.dropPath
    end,
  }
end

function T.compile_yields_the_exact_ready_transition(romFs, versionId)
  local compiled = compileIntact(romFs, versionId)
  local compiledEffects = compiled.effects --[[@as table]]
  local definition = assert(compiledEffects.follower_transition, "the transition must compile from the traced members")
  assertFinitePlacement(definition.placementOffset, "the compiled transition definition")
  Assert.isTrue(definition.placementOffset.y > 0, "the compiled transition must normalize the elevated source offset")
  Assert.isTrue(type(definition.lifecycle) == "table", "the compiled transition must carry lifecycle metadata")
  Assert.isTrue(declaresPreludeTicks(definition, 2), "the compiled transition must preserve the two-tick prelude")
  local expectedFrames = sourceFrameCount(romFs)
  local frameCounts = collectFrameCounts(definition)
  Assert.isTrue(#frameCounts >= 1, "the compiled transition must carry exact animation frame metadata")
  for _, frameCount in ipairs(frameCounts) do
    Assert.equal(frameCount, expectedFrames, "transition frame metadata must come from member 164, not a guess")
  end

  Assert.isTrue(
    FieldEffectAssetCache.isReady(fakeCacheFor(compiled), compiled.marker),
    "the compiled transition bundle must satisfy the strict cache contract"
  )
  Assert.isFalse(
    FieldEffectAssetCache.isReady(fakeCacheFor(compiled, { dropLifecycle = true }), compiled.marker),
    "a transition without lifecycle metadata must not be ready"
  )
  Assert.isFalse(
    FieldEffectAssetCache.isReady(fakeCacheFor(compiled, { dropPlacement = true }), compiled.marker),
    "a transition without placement metadata must not be ready"
  )
  local referenced = collectAssetPaths(definition)
  Assert.isTrue(#referenced >= 1, "the transition must reference generated model artifacts")
  Assert.isFalse(
    FieldEffectAssetCache.isReady(fakeCacheFor(compiled, { dropPath = referenced[1] }), compiled.marker),
    "a transition with a missing referenced artifact must not be ready"
  )
  Assert.isFalse(
    FieldEffectAssetCache.isReady(fakeCacheFor(compiled, { omitEffect = "follower_transition" }), compiled.marker),
    "a cache without the transition definition must not be ready"
  )

  local cacheFs = CacheFs.forVersion(versionId)
  local liveIndex = assert(cacheFs:loadLua(FieldEffectAssetCache.indexPath()), "the live effect index must load")
  local liveEntry = assert(
    liveIndex.effects and liveIndex.effects.follower_transition,
    "the live cache must publish the follower transition"
  )
  Assert.equal(liveEntry.path, FieldEffectAssetCache.definitionPath("follower_transition"))
  local liveDefinition = assert(cacheFs:loadLua(liveEntry.path), "the live transition definition must load")
  Assert.isTrue(type(liveDefinition.lifecycle) == "table", "the live transition must carry lifecycle metadata")
  assertFinitePlacement(liveDefinition.placementOffset, "the live transition definition")
end

function T.source_members_feed_the_dependency_identity(romFs, versionId)
  local intact = compileIntact(romFs, versionId)
  Assert.notNil(intact.effects.follower_transition, "the transition must compile from the traced members")
  local model104 = memberBytes(romFs, 104)
  local model129 = memberBytes(romFs, 129)
  local animation164 = memberBytes(romFs, 164)
  local nameAt = animation164:find("mb_out", 1, true)
  Assert.notNil(nameAt, "transition animation member 164 must carry its source animation name")
  local patchedName = animation164:sub(1, nameAt - 1) .. "n" .. animation164:sub(nameAt + 1)
  local cases = {
    { memberId = 129, bytes = model104, label = "model member 129" },
    { memberId = 104, bytes = model129, label = "model member 104" },
    { memberId = 164, bytes = patchedName, label = "animation member 164" },
  }
  for _, case in ipairs(cases) do
    local rebuilt = assert(
      FieldEntranceIndicatorCompiler.compile(patchedRomFs(romFs, { [case.memberId] = case.bytes })),
      case.label .. " must still compile when swapped"
    )
    Assert.isTrue(
      rebuilt.marker ~= intact.marker,
      case.label .. " must contribute to the generated dependency identity"
    )
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
