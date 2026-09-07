-- ROM-conformance test: field-actor graphics/resources plus one runtime terrain
-- projection composition against a real HGSS dump. Runs only in the ROM-gated
-- layer and never checks in a decoded commercial asset.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorDefinitionProvider = require("libs.hgss.src.actors.FieldActorDefinitionProvider")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local FieldActorGraphics = require("romdump.src.digest.actor.FieldActorGraphics")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local FieldActorCacheWriter = require("romdump.src.digest.actor.FieldActorCacheWriter")
local ZoneEvents = require("romdump.src.digest.map.ZoneEvents")
local manifest = require("romdump.src.config.FieldActors")

local T = {}

-- The source-correlation set: the player graphics plus every class the two
-- target maps place. mapModelId is the actor's own NSBTX member; descriptor is
-- the visual selector in packed bits 10-15.
local EXPECTED = {
  { spriteId = 0, mapModelId = 69, packed = 0x1C60, descriptor = 7, label = "hero" },
  { spriteId = 97, mapModelId = 70, packed = 0x1C60, descriptor = 7, label = "heroine" },
  { spriteId = 29, mapModelId = 25, packed = 0x0000, descriptor = 0, label = "aide" },
  { spriteId = 34, mapModelId = 37, packed = 0x0000, descriptor = 0, label = "policeman" },
  { spriteId = 99, mapModelId = 54, packed = 0x0000, descriptor = 0, label = "professor" },
  { spriteId = 148, mapModelId = 58, packed = 0x0000, descriptor = 0, label = "rival" },
  { spriteId = 325, mapModelId = 123, packed = 0x0000, descriptor = 0, label = "woman 1" },
  { spriteId = 328, mapModelId = 126, packed = 0x0000, descriptor = 0, label = "man 1" },
  { spriteId = 332, mapModelId = 130, packed = 0x0000, descriptor = 0, label = "big man" },
  { spriteId = 365, mapModelId = 159, packed = 0x0000, descriptor = 0, label = "mother" },
  { spriteId = 1032, mapModelId = 483, packed = 0x4E27, descriptor = 19, label = "static Marill" },
}

local function decodeTable(romFs)
  local bytes, info = romFs:readOverlay(manifest.overlay.cpu, manifest.overlay.overlayId)
  Assert.notNil(bytes, "overlay 1 must be readable from the dump")
  return assert(FieldActorGraphics.decode(bytes, { ramAddress = info.ramAddress }, manifest)), info
end

function T.graphics_table_matches_the_source_derived_invariants(romFs)
  local decoded, info = decodeTable(romFs)
  Assert.equal(decoded.recordCount, manifest.tables.graphics.expectedRecordCount)
  Assert.equal(decoded.terminatorOffset, manifest.tables.graphics.expectedTerminatorOffset)
  Assert.equal(decoded.tableOffset, manifest.tables.graphics.address - info.ramAddress)
  Assert.equal(decoded.spanBytes, 5412)
end

function T.every_target_sprite_resolves_to_its_source_bundle(romFs)
  local decoded = decodeTable(romFs)
  for _, expected in ipairs(EXPECTED) do
    local resolved = assert(
      FieldActorGraphics.resolve(decoded, expected.spriteId),
      expected.label .. " must be present in the graphics table"
    )
    Assert.equal(resolved.record.mapModelId, expected.mapModelId, expected.label .. " NSBTX member")
    Assert.equal(resolved.record.packed, expected.packed, expected.label .. " packed word")
    Assert.equal(resolved.record.visualDescriptor, expected.descriptor, expected.label .. " visual descriptor")
    -- Every target class shares the same billboard model member.
    Assert.equal(resolved.descriptor.modelMemberId, 266, expected.label .. " shared model")
  end
end

function T.the_variable_friend_sprite_is_absent_by_design(romFs)
  local decoded = decodeTable(romFs)
  local record, err = FieldActorGraphics.resolve(decoded, manifest.variableSpriteRange.first)
  Assert.isNil(record, "SPRITE_VAR_1 resolves through a field variable, not the table")
  Assert.equal(assert(err).code, "FIELD_ACTOR_SPRITE_ABSENT")
end

function T.player_and_ordinary_timelines_differ_as_the_source_says(romFs)
  local decoded = decodeTable(romFs)
  local hero = assert(FieldActorGraphics.resolve(decoded, 0))
  local aide = assert(FieldActorGraphics.resolve(decoded, 29))
  local marill = assert(FieldActorGraphics.resolve(decoded, 1032))
  Assert.equal(hero.descriptor.timelineMemberId, 281)
  Assert.equal(aide.descriptor.timelineMemberId, 280)
  Assert.equal(marill.descriptor.timelineMemberId, 292)
  Assert.equal(#hero.descriptor.ranges, 8, "the player descriptor carries a second directional set")
  Assert.equal(#aide.descriptor.ranges, 4)
  Assert.equal(#marill.descriptor.ranges, 4)
end

function T.compiled_visuals_cover_the_target_maps(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  local compiled = {}
  for _, spriteId in ipairs(bundle.index.spriteIds) do
    compiled[spriteId] = true
  end
  for _, expected in ipairs(EXPECTED) do
    Assert.isTrue(compiled[expected.spriteId], expected.label .. " must be compiled")
  end
  local previous
  for _, spriteId in ipairs(bundle.index.variableSprites) do
    Assert.isTrue(
      spriteId >= manifest.variableSpriteRange.first and spriteId <= manifest.variableSpriteRange.last,
      "deferred sprite IDs stay inside the variable range"
    )
    Assert.isTrue(not previous or spriteId > previous, "deferred sprite IDs are sorted and unique")
    previous = spriteId
  end
  Assert.equal(bundle.index.variableSprites[1], manifest.variableSpriteRange.first)
  Assert.isNil(manifest.gestureSpriteIds, "state visuals are the only avatar selection source")
  for _, avatar in ipairs(manifest.avatars) do
    local generated
    for _, candidate in ipairs(bundle.index.runtime.avatars) do
      if candidate.id == avatar.id then
        generated = candidate
        break
      end
    end
    Assert.notNil(generated, avatar.id .. " must be present in the runtime avatar catalog")
    generated = assert(generated)
    Assert.equal(generated.gender, avatar.gender, avatar.id .. " gender metadata")
    Assert.isTrue(compiled[generated.states.walking], avatar.id .. " default visual must be compiled")
  end

  local aide = bundle.visuals[29]
  Assert.equal(aide.render.frameWidth, 32)
  Assert.equal(aide.render.frameHeight, 32)
  Assert.equal(aide.render.billboardMode, "cameraFacingFull")
  Assert.isFalse(aide.render.mirrorEastWest)
  -- Four directions, each a four-frame loop of four ticks.
  for _, direction in ipairs(manifest.directionOrder) do
    local walk = aide.directions[direction].walk
    Assert.equal(#walk.frames, 4, direction .. " walk frame count")
    Assert.equal(walk.durationTicks, 16, direction .. " walk duration")
    Assert.equal(walk.frames[1].ticks, 4)
  end
  -- East is never a mirror of west: the two use different source texture slots.
  Assert.isTrue(
    aide.frames[aide.directions.west.walk.frames[1].frameIndex].textureSlot
      ~= aide.frames[aide.directions.east.walk.frames[1].frameIndex].textureSlot
  )
end

function T.compiled_visuals_normalize_source_actor_families(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  local ordinary = bundle.visuals[29]
  local familyModes = {
    [84] = "static", -- family 1
    [335] = "static", -- family 12
    [425] = "static", -- family 13
    [183] = "static", -- family 15
    [1043] = "static", -- family 16
    [1032] = "static", -- family 17
    [262] = "static", -- family 18
  }
  local follower = bundle.visuals[1032]

  Assert.deepEqual(ordinary.idlePresentation, {
    mode = "static",
    cadence = 0,
  })
  for spriteId, mode in pairs(familyModes) do
    Assert.equal(bundle.visuals[spriteId].idlePresentation.mode, mode)
  end
  Assert.equal(follower.idlePresentation.mode, "static")
  Assert.equal(follower.idlePresentation.cadence, 0)
  Assert.equal(follower.directions.south.idle.durationTicks, 1)
  for _, direction in ipairs(manifest.directionOrder) do
    for _, segment in ipairs(ordinary.directions[direction].idle.frames) do
      Assert.equal(segment.displayOffsetY, 0, "static idle segment offset must be 0")
    end
  end
  for _, visual in pairs(bundle.visuals) do
    Assert.isNil(visual.actorFamily, "raw actor family must not cross the generated asset boundary")
  end
end

function T.field_pokemon_idle_is_a_single_stationary_frame_while_walk_keeps_its_loop(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  for _, spriteId in ipairs({ 1032, 1043 }) do
    local visual = assert(bundle.visuals[spriteId], "field pokemon visual " .. spriteId .. " must be compiled")
    Assert.equal(visual.idlePresentation.mode, "static", "field pokemon idle must be stationary")
    Assert.equal(visual.idlePresentation.cadence, 0, "stationary idle carries no frame clock")
    for _, direction in ipairs(manifest.directionOrder) do
      local set = assert(visual.directions[direction], direction .. " pose set is required")
      local idle = assert(set.idle, direction .. " idle pose is required")
      local walk = assert(set.walk, direction .. " walk pose is required")
      Assert.equal(idle.durationTicks, 1, direction .. " idle holds one tick")
      Assert.equal(#idle.frames, 1, direction .. " idle holds one frame")
      Assert.equal(idle.frames[1].ticks, 1)
      Assert.equal(idle.frames[1].displayOffsetY, 0, direction .. " idle carries no display offset")
      Assert.isTrue(idle.loop, direction .. " idle loops its single frame")
      Assert.isTrue(walk.durationTicks > 1 and #walk.frames > 1, direction .. " walk keeps multi-frame locomotion")
      Assert.equal(
        idle.frames[1].frameIndex,
        walk.frames[1].frameIndex,
        direction .. " idle holds the neutral walk frame"
      )
    end
  end
end

-- The render facts every target class must inherit from the shared model member:
-- one bottom-centered quad two tiles on a side, drawn single-sided in modulation
-- mode at full polygon alpha under polygon id 0, lit from the field profile
-- through its own normal. This is the answer to how actor polygons take part in
-- edge marking, read from the ROM rather than assumed.
function T.the_shared_model_supplies_one_lit_cutout_quad(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  for _, expected in ipairs(EXPECTED) do
    local render = bundle.visuals[expected.spriteId].render
    local geometry, polygon = render.geometry, render.polygon
    Assert.equal(geometry.modelName, "mmdl_m32x32", expected.label .. " model")
    Assert.equal(#geometry.vertices, 4, expected.label .. " quad vertices")
    Assert.equal(#geometry.indices, 6)
    Assert.equal(geometry.bounds.width, 2, expected.label .. " quad width in tiles")
    Assert.equal(geometry.bounds.height, 2)
    Assert.equal(geometry.bounds.depth, 0)
    Assert.equal(geometry.anchorTiles.x, 0)
    Assert.equal(geometry.anchorTiles.y, 0)
    Assert.equal(geometry.anchorTiles.z, manifest.placement.modelOffset.z / 16)
    Assert.equal(render.alphaClass, "cutout", expected.label .. " alpha class")
    Assert.equal(polygon.polygonAlpha, 31)
    Assert.equal(polygon.polygonMode, "modulation")
    Assert.equal(polygon.polygonId, 0)
    Assert.equal(polygon.cullMode, "back")
    Assert.equal(polygon.lightMask, 1)
    for _, vertex in ipairs(geometry.vertices) do
      Assert.equal(vertex.colorSource, 1, expected.label .. " vertex is normal-lit")
      Assert.isTrue(vertex.u == 0 or vertex.u == 1, "UVs span exactly one atlas frame")
    end
  end
end

function T.marill_keeps_its_uneven_south_loop(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  local south = bundle.visuals[1032].directions.south.walk
  Assert.equal(south.durationTicks, 20)
  Assert.deepEqual({ south.frames[1].ticks, south.frames[2].ticks, south.frames[3].ticks }, { 5, 10, 5 })
  Assert.equal(south.frames[1].frameIndex, south.frames[3].frameIndex, "the loop returns to its first slot")
end

function T.compiled_visuals_publish_semantic_gesture_clips(romFs)
  local decoded = decodeTable(romFs)
  local nurse = assert(FieldActorGraphics.resolve(decoded, 335), "nurse 335 must be present")
  Assert.equal(nurse.record.actorFamily, 12, "nurse actorFamily")
  Assert.equal(nurse.record.visualDescriptor, 5, "nurse descriptor")
  Assert.equal(#nurse.descriptor.ranges, 5, "nurse descriptor has five ranges")
  Assert.deepEqual(
    { nurse.descriptor.ranges[5].startFrame, nurse.descriptor.ranges[5].endFrame, nurse.descriptor.ranges[5].endMode },
    { 64, 68, 1 },
    "nurse fifth range is 64..68 one-shot"
  )

  local banzaiMale = assert(FieldActorGraphics.resolve(decoded, 200), "BANZAI male 200 must be present")
  local banzaiFemale = assert(FieldActorGraphics.resolve(decoded, 201), "BANZAI female 201 must be present")
  for _, resolved in ipairs({ banzaiMale, banzaiFemale }) do
    Assert.equal(resolved.record.actorFamily, 10, "BANZAI actorFamily")
    Assert.equal(resolved.record.visualDescriptor, 13, "BANZAI descriptor")
    Assert.equal(#resolved.descriptor.ranges, 2, "BANZAI descriptor has two ranges")
    Assert.deepEqual({
      resolved.descriptor.ranges[1].startFrame,
      resolved.descriptor.ranges[1].endFrame,
      resolved.descriptor.ranges[1].endMode,
    }, { 0, 20, 1 }, "BANZAI range 1 is 0..20 one-shot")
    Assert.deepEqual({
      resolved.descriptor.ranges[2].startFrame,
      resolved.descriptor.ranges[2].endFrame,
      resolved.descriptor.ranges[2].endMode,
    }, { 21, 41, 1 }, "BANZAI range 2 is 21..41 one-shot")
  end

  local bundle = assert(FieldActorCompiler.compile(romFs))
  local has200, has201 = false, false
  for _, id in ipairs(bundle.index.spriteIds) do
    if id == 200 then
      has200 = true
    end
    if id == 201 then
      has201 = true
    end
  end
  Assert.isTrue(has200, "selectedSpriteIds must include 200")
  Assert.isTrue(has201, "selectedSpriteIds must include 201")
  -- sorted
  local prev
  for _, id in ipairs(bundle.index.spriteIds) do
    if prev then
      Assert.isTrue(id > prev, "selectedSpriteIds must be sorted")
    end
    prev = id
  end

  for _, spriteId in ipairs(bundle.index.spriteIds) do
    local visual = assert(bundle.visuals[spriteId], "visual must exist")
    Assert.equal(type(visual.gestures), "table", "every visual must carry gestures table")
    Assert.isNil(visual.gestures.warp_out, "warp_out must not be a gesture clip")
    Assert.isNil(visual.gestures.warp_in, "warp_in must not be a gesture clip")
  end

  local nurseVisual = assert(bundle.visuals[335], "nurse visual 335 must be compiled")
  Assert.notNil(nurseVisual.gestures.nurse_bow, "nurse_bow must be present")
  Assert.isNil(nurseVisual.gestures.give, "nurse must not have give")
  Assert.isNil(nurseVisual.gestures.receive, "nurse must not have receive")
  local nurseBow = nurseVisual.gestures.nurse_bow
  Assert.equal(type(nurseBow.pose), "table", "nurse_bow pose")
  Assert.deepEqual(nurseBow.displayOffset, { x = 0, y = 0, z = 0 }, "nurse_bow offset is zero")
  Assert.isTrue(nurseBow.pose.durationTicks > 0, "nurse_bow pose has duration")
  -- frame indices within atlas
  for _, seg in ipairs(nurseBow.pose.frames) do
    Assert.isTrue(seg.frameIndex >= 1 and seg.frameIndex <= nurseVisual.render.frameCount, "nurse_bow frame in range")
  end
  Assert.isNil(nurseBow.actorFamily, "no source family leaked")
  Assert.isNil(nurseBow.visualDescriptor, "no descriptor leaked")
  Assert.isNil(nurseBow.rangeIndex, "no range index leaked")

  for _, spriteId in ipairs({ 200, 201 }) do
    local visual = assert(bundle.visuals[spriteId], "BANZAI visual " .. spriteId .. " must be compiled")
    Assert.notNil(visual.gestures.give, "give must be present for " .. spriteId)
    Assert.notNil(visual.gestures.receive, "receive must be present for " .. spriteId)
    Assert.isNil(visual.gestures.nurse_bow, "BANZAI must not have nurse_bow")
    for _, name in ipairs({ "give", "receive" }) do
      local gesture = visual.gestures[name]
      Assert.equal(type(gesture.pose), "table")
      Assert.deepEqual(gesture.displayOffset, { x = 0, y = 0, z = 1 / 32 }, name .. " offset is 1/32")
      for _, seg in ipairs(gesture.pose.frames) do
        Assert.isTrue(seg.frameIndex >= 1 and seg.frameIndex <= visual.render.frameCount, name .. " frame in range")
      end
      Assert.isNil(gesture.actorFamily)
      Assert.isNil(gesture.visualDescriptor)
    end
  end

  -- ordinary sprite must have empty gestures
  local aide = assert(bundle.visuals[29], "aide 29 must be compiled")
  Assert.equal(type(aide.gestures), "table")
  local count = 0
  for _ in pairs(aide.gestures) do
    count = count + 1
  end
  Assert.equal(count, 0, "ordinary sprite gestures must be empty")

  -- static model still carries empty gestures
  local marill = assert(bundle.visuals[1032], "static Marill 1032 must be compiled")
  Assert.equal(type(marill.gestures), "table")
  count = 0
  for _ in pairs(marill.gestures) do
    count = count + 1
  end
  Assert.equal(count, 0)
end

function T.compiled_bundle_publishes_complete_gendered_avatar_state_capability(romFs)
  local maleStates = {
    walking = 0,
    cycling = 21,
    surfing = 178,
    rocket = 258,
    watering = 180,
    fishing = 188,
    poketch = 196,
    saving = 198,
    heal = 200,
    ladder = 248,
    rocket_heal = 260,
    pokeathlon = 407,
    apricorn_shake = 423,
    rocket_saving = 297,
  }
  local femaleStates = {
    walking = 97,
    cycling = 98,
    surfing = 179,
    rocket = 259,
    watering = 181,
    fishing = 189,
    poketch = 197,
    saving = 199,
    heal = 201,
    ladder = 249,
    rocket_heal = 261,
    pokeathlon = 408,
    apricorn_shake = 424,
    rocket_saving = 298,
  }
  local expectedKeySet =
    "apricorn_shake,cycling,fishing,heal,ladder,pokeathlon,poketch,rocket,rocket_heal,rocket_saving,saving,surfing,walking,watering"

  local bundle = assert(FieldActorCompiler.compile(romFs))
  local runtime = assert(bundle.index.runtime, "the generated index must carry a runtime avatar capability")
  local avatars = assert(runtime.avatars, "the runtime capability must list playable avatars")
  Assert.equal(#avatars, 2, "the capability covers both genders")
  local byGender = {}
  for _, avatar in ipairs(avatars) do
    Assert.keySet(avatar, "gender,id,states", "avatar records carry only semantic identity")
    Assert.isTrue(type(avatar.id) == "string" and avatar.id ~= "", "avatar id is required")
    byGender[avatar.gender] = avatar
  end
  local male = assert(byGender[0], "the male capability must be present")
  local female = assert(byGender[1], "the female capability must be present")
  Assert.keySet(assert(male.states), expectedKeySet, "male states cover every visual state")
  Assert.keySet(assert(female.states), expectedKeySet, "female states cover every visual state")
  Assert.deepEqual(male.states, maleStates, "male state visuals")
  Assert.deepEqual(female.states, femaleStates, "female state visuals")

  local indexed = {}
  local previous
  for _, spriteId in ipairs(bundle.index.spriteIds) do
    indexed[spriteId] = true
    Assert.isTrue(previous == nil or spriteId > previous, "selected sprite IDs stay sorted")
    previous = spriteId
  end
  for _, states in ipairs({ maleStates, femaleStates }) do
    for state, spriteId in pairs(states) do
      Assert.isTrue(indexed[spriteId] == true, state .. " visual " .. spriteId .. " must be selected")
      Assert.notNil(bundle.visuals[spriteId], state .. " visual " .. spriteId .. " must be compiled")
    end
  end
  Assert.isTrue(indexed[200] == true, "heal male visual is selected through the state map")
  Assert.isTrue(indexed[201] == true, "heal female visual is selected through the state map")
  Assert.notNil(bundle.visuals[200], "heal male visual is compiled")
  Assert.notNil(bundle.visuals[201], "heal female visual is compiled")
end

function T.compilation_is_deterministic_and_writes_a_ready_cache(romFs, version)
  local first = assert(FieldActorCompiler.compile(romFs))
  local second = assert(FieldActorCompiler.compile(romFs))
  Assert.equal(first.marker, second.marker)

  local cache = CacheFs.forVersion(version, FakeCache.new())
  Assert.equal(FieldActorCacheWriter.write(cache, first), first.marker)
  Assert.isTrue(FieldActorCache.isReady(cache, first.marker))

  local other = CacheFs.forVersion(version, FakeCache.new())
  FieldActorCacheWriter.write(other, second)
  for _, spriteId in ipairs(first.index.spriteIds) do
    Assert.equal(
      cache:read(FieldActorCache.atlasPath(spriteId)),
      other:read(FieldActorCache.atlasPath(spriteId)),
      "atlas bytes are reproducible"
    )
    Assert.equal(
      cache:read(FieldActorCache.visualPath(spriteId)),
      other:read(FieldActorCache.visualPath(spriteId)),
      "visual bytes are reproducible"
    )
  end
end

function T.nonzero_object_event_y_reaches_runtime_surface_projection(romFs, version)
  local symbol = "MAP_MAHOGANY_SOUVENIR_SHOP"
  local resolved = assert(MapResolver.resolve(romFs, symbol))
  local runtimeMap = RomRuntimeMap.compile(romFs, symbol)
  ---@cast runtimeMap RuntimeFieldMap
  local field = runtimeMap.fieldData
  local eventMember = assert(romFs:openNarc("zone_events")):readMember(assert(resolved.map.eventMemberId))
  local raw = assert(ZoneEvents.decode(eventMember, { mapId = runtimeMap.mapId }))
  local rawByObjectEventId = {}
  for _, event in ipairs(raw.objectEvents) do
    rawByObjectEventId[event.objectEventId] = event
  end

  local cache = CacheFs.forVersion(version)
  local actorIndex = assert(FieldActorCache.loadIndex(cache))
  local assets = FieldActorDefinitionProvider.new(cache)
  local candidate
  for _, event in ipairs(field.events.objects) do
    local source = rawByObjectEventId[event.objectEventId]
    if source and event.y ~= 0 and event.eventFlag == 0 and assets:knows(event.spriteId) then
      local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, event.x, event.z)
      local options = {
        localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      }
      local surfaces = runtimeMap.terrain:candidatesAt(options.localX, options.localZ)
      if #surfaces > 0 then
        local normalizedY = source.y / (16 * 4096)
        local expected = SurfaceResolver.new(runtimeMap.terrain):resolve({
          localX = options.localX,
          localZ = options.localZ,
          currentY = normalizedY,
        })
        candidate = { event = event, source = source, expected = expected }
        break
      end
    end
  end
  Assert.notNil(candidate, "the map must provide a nonzero-Y object with a known actor and terrain surface")
  local selected = assert(candidate)
  Assert.equal(selected.event.y, selected.source.y, "generated object event preserves raw source Y")
  Assert.isTrue(selected.event.y ~= 0, "fixture uses a nonzero source Y")

  local manager = FieldActorManager.new({ assets = assets, policy = actorIndex.runtime })
  manager:enterMap(runtimeMap, FieldEventState.new())
  local actor = assert(manager:getById("map:" .. runtimeMap.mapId .. ":object:" .. selected.event.objectEventId))
  Assert.equal(actor.sourceEvent.y, selected.source.y, "live actor retains the raw source Y")
  Assert.equal(actor.surfaceId, selected.expected.surfaceId, "runtime selects the retail-height surface")
  Assert.equal(actor.worldY, selected.expected.worldY, "runtime samples the selected terrain height")
  Assert.isTrue(actor.worldY ~= actor.sourceEvent.y, "runtime world Y is not a raw source value")
  manager:dispose()
  assets:dispose()
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
