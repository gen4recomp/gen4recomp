-- ROM-conformance coverage for the two source selector streams and the
-- normalized field-effect definitions produced from them.

local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEffects = require("romdump.src.config.FieldEffects")
local FieldEffectPatternAnimation = require("romdump.src.digest.field.FieldEffectPatternAnimation")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local RomSuite = require("tests.rom.support.RomSuite")

local SOURCES = {
  { kind = "tall_grass", renderer = 8, modelMember = 126, animationMember = 140 },
  { kind = "very_tall_grass", renderer = 12, modelMember = 122, animationMember = 146 },
  { kind = "trainer_reveal", renderer = 1, modelMember = 124, animationMember = 148 },
}

local function selectorB(bytes, keyCount, index)
  local offset = 4 + keyCount * 3
  return assert(bytes:byte(offset + index + 1), "source selector is truncated")
end

local function cacheFor(bundle)
  return {
    read = function(_, path)
      if path == FieldEffectAssetCache.markerPath() then
        return bundle.marker
      end
      return nil
    end,
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.indexPath() then
        return bundle.index
      end
      local kind = path:match("/([^/]+)%.lua$")
      if kind ~= nil and bundle.effects[kind] ~= nil then
        return bundle.effects[kind]
      end
      if path == FieldEffectAssetCache.definitionPath("follower_transition") then
        return bundle.effects.follower_transition
      end
      error("unexpected field-effect cache path " .. path)
    end,
    exists = function()
      return true
    end,
  }
end

local function assertTrainerReveal(compiled, animationNarc)
  local definition = assert(compiled.effects.trainer_reveal)
  local clip = assert(assert(definition.model.animations)[1])
  local payload = assert(clip.compiled)
  assert(payload)
  local raw = assert(animationNarc:readMember(148))
  local decoded = assert(FieldEffectPatternAnimation.decode(raw, {
    alias = FieldEffects.animationArchive.alias,
    memberId = 148,
  }))
  Assert.equal(clip.frameCount, 7, "trainer reveal must be seven frames")
  Assert.equal(definition.lifecycle.mode, "once")
  Assert.equal(definition.lifecycle.frameCount, 7)
  Assert.isNil(definition.lifecycle.holdFrame)
  Assert.notNil(definition.placementOffset, "trainer reveal must carry the normalized source placement")
  Assert.equal(definition.placementOffset.x, 0)
  Assert.equal(definition.placementOffset.y, 0)
  Assert.equal(definition.placementOffset.z, 0.5)
  Assert.isNil(definition.animationSourceSha1)
  Assert.isNil(definition.source)
  Assert.equal(FieldEffects.effects.trainer_reveal.modelMembers[1], 124)
  Assert.equal(FieldEffects.effects.trainer_reveal.animationMembers[1], 148)
  Assert.notNil(
    FieldEffects.effects.trainer_reveal.placementOffset,
    "trainer reveal source selection must carry placement"
  )
  Assert.equal(FieldEffects.effects.trainer_reveal.placementOffset.x, 0)
  Assert.equal(FieldEffects.effects.trainer_reveal.placementOffset.y, 0)
  Assert.equal(FieldEffects.effects.trainer_reveal.placementOffset.z, 0.5)
  -- animation decode sanity
  Assert.isTrue(#decoded.keys >= 1)
end

local function assertSource(compiled, source, animationNarc)
  local definition = assert(compiled.effects[source.kind])
  local clip = assert(assert(definition.model.animations)[1])
  local payload = assert(clip.compiled)
  local target = assert(payload.targets[1])
  local raw = assert(animationNarc:readMember(source.animationMember))
  local decoded = assert(FieldEffectPatternAnimation.decode(raw, {
    alias = FieldEffects.animationArchive.alias,
    memberId = source.animationMember,
  }))

  Assert.equal(#target.keys, #decoded.keys)
  for index, expected in ipairs(decoded.keys) do
    local actual = target.keys[index]
    Assert.equal(actual.frame, expected.frame)
    Assert.equal(actual.texIdx, expected.texIdx)
    Assert.equal(actual.plttIdx, selectorB(raw, #decoded.keys, index - 1))
    Assert.isTrue(actual.texIdx < #payload.textureNames, "source texture selector must be in range")
    Assert.isTrue(actual.plttIdx < #payload.paletteNames, "source palette selector must be in range")
  end
  Assert.equal(clip.source.archive, FieldEffects.animationArchive.alias)
  Assert.equal(clip.source.memberId, source.animationMember)
  Assert.equal(clip.source.sha1, Hashing.sha1hex(raw))
  Assert.equal(FieldEffects.effects[source.kind].renderer, source.renderer)
  Assert.equal(FieldEffects.effects[source.kind].modelMembers[1], source.modelMember)
  Assert.equal(FieldEffects.effects[source.kind].animationMembers[1], source.animationMember)
  Assert.isNil(definition.animationSourceSha1)
  Assert.isNil(definition.source)
  if source.kind == "trainer_reveal" then
    Assert.equal(definition.lifecycle.mode, "once")
    Assert.equal(definition.lifecycle.frameCount, 7)
    Assert.isNil(definition.lifecycle.holdFrame)
    Assert.notNil(definition.placementOffset, "trainer reveal must carry the normalized source placement")
    Assert.equal(definition.placementOffset.x, 0)
    Assert.equal(definition.placementOffset.y, 0)
    Assert.equal(definition.placementOffset.z, 0.5)
  else
    Assert.equal(definition.lifecycle.mode, "hold_until_owner_moves")
    Assert.equal(definition.lifecycle.holdFrame, 12)
    Assert.isNil(definition.lifecycle.frameCount)
    Assert.equal(definition.placementOffset.x, 0)
    Assert.equal(definition.placementOffset.y, 0)
    Assert.equal(definition.placementOffset.z, 0.625)
  end
end

local function assertSurfAttachment(compiled, romFs)
  local selection =
    assert(FieldEffects.effects.surf_attachment, "field-effect source selection must include the surf attachment")
  Assert.equal(selection.modelMembers[1], 86, "surf attachment must select source static-model member 86")

  local staticNarc = assert(romFs:openNarc(FieldEffects.archive.alias))
  local raw = assert(staticNarc:readMember(86), "source surf model member must be readable")
  Assert.isTrue(#raw > 0, "source surf model member must not be empty")

  local definition = assert(compiled.effects.surf_attachment, "compiled bundle must include the surf attachment")
  Assert.equal(definition.model.kind, "static", "surf attachment must compile as a static model")
  ModelAsset.validate(definition.model)
  Assert.isNil(definition.lifecycle, "surf lifecycle belongs to avatar state, not terrain response")
  Assert.isNil(definition.source, "generated surf definition must not carry source provenance")
  Assert.isNil(definition.archive)
  Assert.isNil(definition.memberId)
  Assert.isNil(definition.modelMembers)
  Assert.isNil(definition.callback)

  local presentation = assert(definition.presentation, "surf attachment must carry normalized presentation")
  Assert.equal(presentation.initialPlayerOffset.x, 0)
  Assert.equal(presentation.initialPlayerOffset.y, 4 / 16)
  Assert.equal(presentation.initialPlayerOffset.z, 4 / 16)
  Assert.equal(presentation.oscillator.initialY, 1 / 16)
  Assert.equal(presentation.oscillator.minY, 1 / 16)
  Assert.equal(presentation.oscillator.maxY, 4 / 16)
  Assert.equal(presentation.oscillator.stepY, (1 / 4) / 16)
  Assert.equal(presentation.playerBaseOffset.x, 0)
  Assert.equal(presentation.playerBaseOffset.y, 4 / 16)
  Assert.equal(presentation.playerBaseOffset.z, 4 / 16)
  Assert.equal(presentation.attachmentBaseOffset.x, 0)
  Assert.equal(presentation.attachmentBaseOffset.y, -1 / 16)
  Assert.equal(presentation.attachmentBaseOffset.z, 0)
  Assert.equal(presentation.yawDegrees.north, 180)
  Assert.equal(presentation.yawDegrees.south, 0)
  Assert.equal(presentation.yawDegrees.west, 270)
  Assert.equal(presentation.yawDegrees.east, 90)
  local yawCount = 0
  for _ in pairs(presentation.yawDegrees) do
    yawCount = yawCount + 1
  end
  Assert.equal(yawCount, 4, "surf yaw map must cover exactly the four facings")

  local entry = assert(compiled.index.effects.surf_attachment, "field-effect index must list the surf attachment")
  Assert.equal(entry.kind, "model")
  Assert.equal(entry.definition, "surf_attachment")
  Assert.equal(entry.path, FieldEffectAssetCache.definitionPath("surf_attachment"))
end

local suite = RomSuite.fromFacts({
  ["compiles source field-effect definitions with normalized presentation"] = function(romFs)
    Assert.equal(Contract.fieldEffects.cacheFormat, "field-effect-cache-v8")
    Assert.equal(FieldEffectAssetCache.FORMAT, "field-effect-cache-v8")

    local animationNarc = assert(romFs:openNarc(FieldEffects.animationArchive.alias))
    local compiled = FieldEntranceIndicatorCompiler.compile(romFs)
    for _, source in ipairs(SOURCES) do
      assertSource(compiled, source, animationNarc)
    end
    assertTrainerReveal(compiled, animationNarc)
    assertSurfAttachment(compiled, romFs)

    Assert.isTrue(
      FieldEffectAssetCache.isReady(cacheFor(compiled), compiled.marker),
      "the normalized source bundle must satisfy the strict field-effect cache contract"
    )
  end,
})
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.tags = { "field", "grass", "source" }
return suite
