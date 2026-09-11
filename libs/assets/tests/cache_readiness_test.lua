-- Strict generated-cache readiness: a completion marker plus a malformed
-- current index/descriptor must never read as ready. Required arrays must be
-- arrays, identity fields must match, and referenced artifacts must be present
-- and loadable. Missing schema fields must not default to empty collections.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local CollisionFixture = require("tests.support.CollisionFixture")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")

local T = {}
local SCRIPT_GENERATION = string.rep("a", 40)

local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

-- Field-actor index and visuals

local AVATAR_STATE_KEYS = {
  "walking",
  "cycling",
  "surfing",
  "rocket",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

local function writeActorIndex(c, spriteIds)
  local states = {}
  local available = 0
  if type(spriteIds) == "table" then
    available = #spriteIds
  end
  for i, name in ipairs(AVATAR_STATE_KEYS) do
    states[name] = available > 0 and spriteIds[((i - 1) % available) + 1] or 0
  end
  local function capability(id, gender)
    local own = {}
    for name, spriteId in pairs(states) do
      own[name] = spriteId
    end
    return { id = id, gender = gender, states = own }
  end
  c:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = spriteIds,
    runtime = {
      avatars = { capability("hero", 0), capability("heroine", 1) },
      variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
    },
  })
  c:write(FieldActorCache.markerPath(), "m")
end

local function validPose()
  return {
    frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } },
    loop = true,
    durationTicks = 1,
  }
end

local function validIdlePose()
  return validPose()
end

local function validDirections()
  return {
    north = { idle = validIdlePose(), walk = validIdlePose() },
    south = { idle = validIdlePose(), walk = validIdlePose() },
    west = { idle = validIdlePose(), walk = validIdlePose() },
    east = { idle = validIdlePose(), walk = validIdlePose() },
  }
end

local function validPolygon()
  return {
    cullMode = "back",
    polygonMode = "modulation",
    polygonId = 1,
    polygonAlpha = 31,
    lightMask = 0,
    translucentDepthWrite = false,
    depthEqual = false,
    fogEnabled = false,
  }
end

local function validVertices()
  return {
    { x = -1, y = 0, z = 0, u = 0, v = 0, nx = 0, ny = 1, nz = 0, r = 255, g = 0, b = 0, a = 255, colorSource = 0 },
    { x = 1, y = 0, z = 0, u = 1, v = 0, nx = 0, ny = 1, nz = 0, r = 0, g = 255, b = 0, colorSource = 1 },
    { x = 1, y = 2, z = 0, u = 1, v = 1, nx = 0, ny = 1, nz = 0, r = 0, g = 0, b = 255, colorSource = 2 },
    { x = -1, y = 2, z = 0, u = 0, v = 1, nx = 0, ny = 1, nz = 0, r = 255, g = 255, b = 255, a = 128, colorSource = 0 },
  }
end

local function validIndices()
  return { 0, 1, 2, 0, 2, 3 }
end

local function validAtlasGeometry()
  return {
    vertices = validVertices(),
    indices = validIndices(),
    anchorTiles = { x = 0, y = 0, z = 0 },
    bounds = { width = 2, height = 2, depth = 0 },
    baseTransform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
  }
end

local function validStaticGeometry()
  return {
    vertices = validVertices(),
    indices = validIndices(),
    anchorTiles = { x = 0, y = 0, z = 0 },
    bounds = { width = 2, height = 2, depth = 0 },
    center = { 0, 1, 0 },
  }
end

local function validAtlasRender(spriteId, frameCount)
  return {
    kind = "atlas",
    image = FieldActorCache.atlasPath(spriteId),
    frameWidth = 32,
    frameHeight = 32,
    frameCount = frameCount or 1,
    alphaClass = "opaque",
    polygon = validPolygon(),
    geometry = validAtlasGeometry(),
  }
end

local function validStaticPart()
  return {
    textured = true,
    alphaClass = "opaque",
    polygon = validPolygon(),
    geometry = validStaticGeometry(),
  }
end

local function validStaticRender(spriteId, frameCount, parts)
  return {
    kind = "staticModel",
    image = FieldActorCache.atlasPath(spriteId),
    frameWidth = 64,
    frameHeight = 64,
    frameCount = frameCount or 1,
    parts = parts or { validStaticPart() },
  }
end

local function writeActorVisual(c, spriteId)
  c:writeLua(FieldActorCache.visualPath(spriteId), {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = validAtlasRender(spriteId, 1),
    idlePresentation = {
      mode = "static",
      cadence = 0,
    },
    directions = validDirections(),
    gestures = {},
  })
  c:write(FieldActorCache.atlasPath(spriteId), "atlas-bytes")
end

local function writeActorVisualWithDirections(c, spriteId, directions, frameCount)
  c:writeLua(FieldActorCache.visualPath(spriteId), {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = validAtlasRender(spriteId, frameCount or 1),
    idlePresentation = {
      mode = "static",
      cadence = 0,
    },
    directions = directions,
    gestures = {},
  })
  c:write(FieldActorCache.atlasPath(spriteId), "atlas-bytes")
end

local function validGesturePose(_)
  return {
    frames = { { frameIndex = 1, ticks = 1 } },
    loop = false,
    durationTicks = 1,
  }
end

local function writeActorVisualWithGestures(c, spriteId, gestures, frameCount)
  c:writeLua(FieldActorCache.visualPath(spriteId), {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = validAtlasRender(spriteId, frameCount or 1),
    idlePresentation = {
      mode = "static",
      cadence = 0,
    },
    directions = validDirections(),
    gestures = gestures,
  })
  c:write(FieldActorCache.atlasPath(spriteId), "atlas-bytes")
end

local function writeStaticModelVisual(c, spriteId, gestures, frameCount)
  c:writeLua(FieldActorCache.visualPath(spriteId), {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = validStaticRender(spriteId, frameCount or 1, nil),
    idlePresentation = {
      mode = "static",
      cadence = 0,
    },
    directions = validDirections(),
    gestures = gestures or {},
  })
  c:write(FieldActorCache.atlasPath(spriteId), "atlas-bytes")
end

function T.actor_index_missing_sprite_ids_is_not_ready()
  local c = cache()
  c:writeLua(FieldActorCache.indexPath(), { schema = FieldActorCache.INDEX_SCHEMA })
  c:write(FieldActorCache.markerPath(), "m")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "spriteIds is required by the current schema")
end

function T.actor_index_with_non_array_sprite_ids_is_not_ready()
  local c = cache()
  writeActorIndex(c, { named = 1 })
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "a hash table is not a spriteIds array")
end

function T.actor_index_without_runtime_config_is_not_ready()
  local c = cache()
  c:writeLua(FieldActorCache.indexPath(), { schema = FieldActorCache.INDEX_SCHEMA, spriteIds = { 0 } })
  c:write(FieldActorCache.markerPath(), "m")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "the runtime avatar/sprite config is required by the schema")
end

function T.actor_index_avatar_without_gender_is_not_ready()
  local c = cache()
  c:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = { 0 },
    runtime = {
      avatars = { { id = "hero", spriteId = 0 } },
      variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
    },
  })
  c:write(FieldActorCache.markerPath(), "m")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "avatar gender is required by the current actor contract")
end

local function avatarStateMap(firstSpriteId)
  local states = {}
  for i, name in ipairs(AVATAR_STATE_KEYS) do
    states[name] = firstSpriteId + i - 1
  end
  return states
end

local function completeAvatarSetup()
  local heroStates = avatarStateMap(0)
  local heroineStates = avatarStateMap(20)
  local spriteIds = {}
  for _, states in ipairs({ heroStates, heroineStates }) do
    for _, name in ipairs(AVATAR_STATE_KEYS) do
      spriteIds[#spriteIds + 1] = states[name]
    end
  end
  table.sort(spriteIds)
  local avatars = {
    { id = "hero", gender = 0, states = heroStates },
    { id = "heroine", gender = 1, states = heroineStates },
  }
  return spriteIds, avatars
end

local function writeAvatarStateIndex(c, spriteIds, avatars)
  c:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    spriteIds = spriteIds,
    runtime = {
      avatars = avatars,
      variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
    },
  })
  c:write(FieldActorCache.markerPath(), "m")
end

local function writeVisualsFor(c, spriteIds)
  for _, spriteId in ipairs(spriteIds) do
    writeActorVisual(c, spriteId)
  end
end

function T.actor_index_with_complete_avatar_state_maps_is_ready()
  local c = cache()
  local spriteIds, avatars = completeAvatarSetup()
  writeAvatarStateIndex(c, spriteIds, avatars)
  writeVisualsFor(c, spriteIds)
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "complete gendered state maps must be ready")
end

function T.actor_index_with_malformed_avatar_state_maps_is_not_ready()
  do
    local c = cache()
    local spriteIds, avatars = completeAvatarSetup()
    avatars[1].states.heal = nil
    writeAvatarStateIndex(c, spriteIds, avatars)
    writeVisualsFor(c, spriteIds)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "a missing state must fail readiness")
  end
  do
    local c = cache()
    local spriteIds, avatars = completeAvatarSetup()
    avatars[1].states.extra = avatars[1].states.walking
    writeAvatarStateIndex(c, spriteIds, avatars)
    writeVisualsFor(c, spriteIds)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "an unknown state must fail readiness")
  end
  do
    local c = cache()
    local spriteIds, avatars = completeAvatarSetup()
    avatars[1].states.heal = "0"
    writeAvatarStateIndex(c, spriteIds, avatars)
    writeVisualsFor(c, spriteIds)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "a non-integer state sprite must fail readiness")
  end
  do
    local c = cache()
    local spriteIds, avatars = completeAvatarSetup()
    writeAvatarStateIndex(c, spriteIds, { avatars[1] })
    writeVisualsFor(c, spriteIds)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "a missing gender must fail readiness")
  end
  do
    local c = cache()
    local spriteIds, avatars = completeAvatarSetup()
    writeAvatarStateIndex(c, spriteIds, {
      { id = "hero", gender = 0, states = avatars[1].states },
      { id = "heroine", gender = 0, states = avatars[2].states },
    })
    writeVisualsFor(c, spriteIds)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "a duplicate gender must fail readiness")
  end
  do
    local c = cache()
    local spriteIds, avatars = completeAvatarSetup()
    avatars[1].states.heal = 9999
    writeAvatarStateIndex(c, spriteIds, avatars)
    writeVisualsFor(c, spriteIds)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "a state sprite absent from the index must fail readiness")
  end
end

function T.actor_visual_with_wrong_schema_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  c:writeLua(FieldActorCache.visualPath(0), { schema = "g4-other-v1", spriteId = 0 })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "indexed visual must carry the expected schema")
end

function T.actor_visual_with_wrong_identity_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  c:writeLua(FieldActorCache.visualPath(0), { schema = FieldActorCache.SCHEMA, spriteId = 7 })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "visual file identity must match its index entry")
end

function T.actor_visual_without_idle_presentation_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  c:writeLua(FieldActorCache.visualPath(0), {
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = { kind = "atlas", image = FieldActorCache.atlasPath(0) },
  })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "idle presentation is required by the current actor schema")
end

function T.actor_visual_without_frame_count_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  c:writeLua(FieldActorCache.visualPath(0), {
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = { kind = "atlas", image = FieldActorCache.atlasPath(0), frameCount = nil },
    idlePresentation = {
      mode = "static",
      cadence = 0,
    },
    directions = validDirections(),
  })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "runtime frame count is required by the actor visual contract")
end

function T.actor_visual_with_malformed_idle_presentation_is_not_ready()
  local cases = {
    { mode = "unknown", cadence = 0 },
    { mode = "static", cadence = 1 },
    { mode = "animated", cadence = 0 },
    { mode = "static", cadence = "0" },
  }
  for _, idlePresentation in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    c:writeLua(FieldActorCache.visualPath(0), {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = { kind = "atlas", image = FieldActorCache.atlasPath(0), frameCount = 1 },
      idlePresentation = { mode = idlePresentation.mode, cadence = idlePresentation.cadence },
      directions = validDirections(),
    })
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "malformed idle presentation must fail readiness")
  end
end

function T.actor_visual_with_malformed_idle_display_offset_is_not_ready()
  local c

  -- missing displayOffsetY
  c = cache()
  writeActorIndex(c, { 0 })
  local directions = validDirections()
  directions.south.idle = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 }
  writeActorVisualWithDirections(c, 0, directions, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "idle segment without displayOffsetY must fail")

  -- string displayOffsetY
  c = cache()
  writeActorIndex(c, { 0 })
  directions = validDirections()
  directions.south.idle =
    { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = "0" } }, loop = true, durationTicks = 1 }
  writeActorVisualWithDirections(c, 0, directions, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "string displayOffsetY must fail")

  -- NaN
  c = cache()
  writeActorIndex(c, { 0 })
  c:write(
    FieldActorCache.visualPath(0),
    'return { schema = "'
      .. FieldActorCache.SCHEMA
      .. '", spriteId = 0, render = { kind = "atlas", image = "'
      .. FieldActorCache.atlasPath(0)
      .. '", frameCount = 1 }, idlePresentation = { mode = "static", cadence = 0 }, directions = { north = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 } }, south = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0/0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 } }, west = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 } }, east = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 } } } }'
  )
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "NaN displayOffsetY must fail")

  -- infinite
  c = cache()
  writeActorIndex(c, { 0 })
  c:write(
    FieldActorCache.visualPath(0),
    'return { schema = "'
      .. FieldActorCache.SCHEMA
      .. '", spriteId = 0, render = { kind = "atlas", image = "'
      .. FieldActorCache.atlasPath(0)
      .. '", frameCount = 1 }, idlePresentation = { mode = "static", cadence = 0 }, directions = { north = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 } }, south = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = math.huge } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 } }, west = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 } }, east = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 } } } }'
  )
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "infinite displayOffsetY must fail")

  -- old shape with only frameOffsets and no displayOffsetY on segments
  c = cache()
  writeActorIndex(c, { 0 })
  directions = validDirections()
  directions.south.idle = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 }
  c:writeLua(FieldActorCache.visualPath(0), {
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = { kind = "atlas", image = FieldActorCache.atlasPath(0), frameCount = 1 },
    idlePresentation = { mode = "static", cadence = 0, frameOffsets = { 0 } },
    directions = directions,
  })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "old frameOffsets-only visual must fail")
end

function T.actor_visual_missing_a_facing_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  local directions = validDirections()
  directions.north = nil
  writeActorVisualWithDirections(c, 0, directions, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "a visual missing a required facing must fail")
  Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
end

function T.actor_visual_with_extra_direction_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  local directions = validDirections()
  directions.extra = { idle = validPose(), walk = validPose() }
  writeActorVisualWithDirections(c, 0, directions, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "unknown direction keys must fail")
end

function T.actor_visual_with_malformed_pose_frames_is_not_ready()
  local cases = {
    { pose = { frames = {}, loop = true, durationTicks = 1 }, label = "empty frames" },
    { pose = { frames = nil, loop = true, durationTicks = 1 }, label = "missing frames" },
    {
      pose = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = "true", durationTicks = 1 },
      label = "non-boolean loop",
    },
    {
      pose = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 0 },
      label = "zero duration",
    },
    {
      pose = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 2 },
      label = "duration mismatch",
    },
    {
      pose = {
        frames = {
          { frameIndex = 1, ticks = 2, displayOffsetY = 0 },
          { frameIndex = 1, ticks = 1, displayOffsetY = 0 },
        },
        loop = true,
        durationTicks = 2,
      },
      label = "sum mismatch",
    },
  }
  for _, case in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    local directions = validDirections()
    directions.south.idle = case.pose
    writeActorVisualWithDirections(c, 0, directions, 1)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), case.label .. " must fail")
  end
end

function T.actor_visual_with_malformed_frame_index_is_not_ready()
  local cases = {
    { frameIndex = 0, label = "zero frameIndex" },
    { frameIndex = 2, label = "out of range frameIndex" },
    { frameIndex = 1.5, label = "fractional frameIndex" },
    { frameIndex = "1", label = "string frameIndex" },
  }
  for _, case in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    local directions = validDirections()
    directions.south.idle =
      { frames = { { frameIndex = case.frameIndex, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }
    writeActorVisualWithDirections(c, 0, directions, 1)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), case.label .. " must fail")
  end
end

function T.actor_visual_with_malformed_ticks_is_not_ready()
  local cases = {
    { ticks = 0, label = "zero ticks" },
    { ticks = 1.5, label = "fractional ticks" },
    { ticks = "1", label = "string ticks" },
    { ticks = nil, label = "missing ticks" },
  }
  for _, case in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    local directions = validDirections()
    local frame = { frameIndex = 1, displayOffsetY = 0 }
    if case.ticks ~= nil then
      frame.ticks = case.ticks
    end
    if case.ticks == nil then
      -- missing ticks case
      directions.south.idle = { frames = { { frameIndex = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }
    else
      directions.south.idle = { frames = { frame }, loop = true, durationTicks = case.ticks == 1 and 1 or 1 }
      -- duration must match ticks or mismatch will also fail; for zero/fractional we keep duration 1 to force ticks invalid
      if case.label == "zero ticks" or case.label == "fractional ticks" or case.label == "string ticks" then
        directions.south.idle.durationTicks = 1
      end
    end
    writeActorVisualWithDirections(c, 0, directions, 1)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), case.label .. " must fail")
  end
end

function T.actor_visual_with_malformed_present_walk_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  local directions = validDirections()
  directions.south.walk = {}
  writeActorVisualWithDirections(c, 0, directions, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "empty walk table must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  directions = validDirections()
  directions.south.walk = { frames = { { frameIndex = 2, ticks = 1 } }, loop = true, durationTicks = 1 }
  writeActorVisualWithDirections(c, 0, directions, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "walk with out-of-range frame must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  directions = validDirections()
  directions.south.walk = { frames = { { frameIndex = 1, ticks = 0 } }, loop = true, durationTicks = 1 }
  writeActorVisualWithDirections(c, 0, directions, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "walk with zero ticks must fail")
end

function T.actor_visual_without_walk_is_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  local directions = validDirections()
  directions.north.walk = nil
  directions.south.walk = nil
  directions.west.walk = nil
  directions.east.walk = nil
  writeActorVisualWithDirections(c, 0, directions, 1)
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "absent walk must remain valid")
  Assert.isTrue(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
end

function T.actor_visual_with_valid_four_facings_is_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisual(c, 0)
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "complete four-facing visual must pass")
  Assert.isTrue(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
end

function T.actor_valid_artifact_is_ready()
  local c = cache()
  writeActorIndex(c, { 0, 29 })
  writeActorVisual(c, 0)
  writeActorVisual(c, 29)
  Assert.isTrue(FieldActorCache.isReady(c, "m"))
end

function T.actor_visual_with_empty_gestures_is_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisual(c, 0)
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "empty gestures must be valid")
  Assert.isTrue(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
end

function T.actor_visual_with_valid_gesture_clip_is_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = { pose = validGesturePose(1), displayOffset = { x = 0, y = 0, z = 1 / 32 } },
  }, 1)
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "valid give clip must pass")
  Assert.isTrue(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
  -- second valid variant
  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    nurse_bow = { pose = validGesturePose(1), displayOffset = { x = 0, y = 0, z = 0 } },
  }, 1)
  Assert.isTrue(FieldActorCache.isReady(c, "m"))
end

function T.actor_visual_missing_gestures_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  c:writeLua(FieldActorCache.visualPath(0), {
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = { kind = "atlas", image = FieldActorCache.atlasPath(0), frameCount = 1 },
    idlePresentation = { mode = "static", cadence = 0 },
    directions = validDirections(),
  })
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "missing gestures must fail")
  Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
end

function T.actor_visual_with_non_table_gestures_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, "nope", 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"))
end

function T.actor_visual_with_unknown_gesture_name_is_not_ready()
  local cases = { "warp_out", "warp_in", "unknown", "nurseBow" }
  for _, name in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    local gestures = {}
    gestures[name] = { pose = validGesturePose(1), displayOffset = { x = 0, y = 0, z = 0 } }
    writeActorVisualWithGestures(c, 0, gestures, 1)
    Assert.isFalse(FieldActorCache.isReady(c, "m"), "unknown gesture " .. name .. " must fail")
    Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
  end
end

function T.actor_visual_with_malformed_gesture_pose_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = { pose = { frames = {}, loop = false, durationTicks = 1 }, displayOffset = { x = 0, y = 0, z = 1 / 32 } },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "empty gesture pose must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = {
      pose = { frames = { { frameIndex = 2, ticks = 1 } }, loop = false, durationTicks = 1 },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "out-of-range gesture frameIndex must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = {
      pose = { frames = { { frameIndex = 1, ticks = 0 } }, loop = false, durationTicks = 1 },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "zero-tick gesture pose must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = {
      pose = { frames = { { frameIndex = 1, ticks = 1 } }, loop = false, durationTicks = 2 },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "duration-mismatch gesture pose must fail")

  c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisualWithGestures(c, 0, {
    give = { displayOffset = { x = 0, y = 0, z = 0 } },
  }, 1)
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "missing gesture pose must fail")
end

function T.actor_visual_with_malformed_gesture_display_offset_is_not_ready()
  local cases = {
    { displayOffset = nil, label = "missing displayOffset" },
    { displayOffset = { x = 0, y = 0 }, label = "missing z" },
    { displayOffset = { x = "0", y = 0, z = 0 }, label = "string x" },
    { displayOffset = { x = 0, y = 0, z = 0 / 0 }, label = "NaN z" },
    { displayOffset = { x = 0, y = math.huge, z = 0 }, label = "infinite y" },
  }
  for _, case in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    if case.displayOffset == nil then
      c:writeLua(FieldActorCache.visualPath(0), {
        schema = FieldActorCache.SCHEMA,
        spriteId = 0,
        render = { kind = "atlas", image = FieldActorCache.atlasPath(0), frameCount = 1 },
        idlePresentation = { mode = "static", cadence = 0 },
        directions = validDirections(),
        gestures = { give = { pose = validGesturePose(1) } },
      })
      c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    elseif case.label == "NaN z" then
      c:write(
        FieldActorCache.visualPath(0),
        'return { schema = "'
          .. FieldActorCache.SCHEMA
          .. '", spriteId = 0, render = { kind = "atlas", image = "'
          .. FieldActorCache.atlasPath(0)
          .. '", frameCount = 1 }, idlePresentation = { mode = "static", cadence = 0 }, directions = { north = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 } }, south = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 } }, west = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 } }, east = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 } } }, gestures = { give = { pose = { frames = { { frameIndex = 1, ticks = 1 } }, loop = false, durationTicks = 1 }, displayOffset = { x = 0, y = 0, z = 0/0 } } } }'
      )
      c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    elseif case.label == "infinite y" then
      c:write(
        FieldActorCache.visualPath(0),
        'return { schema = "'
          .. FieldActorCache.SCHEMA
          .. '", spriteId = 0, render = { kind = "atlas", image = "'
          .. FieldActorCache.atlasPath(0)
          .. '", frameCount = 1 }, idlePresentation = { mode = "static", cadence = 0 }, directions = { north = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 } }, south = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 } }, west = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 } }, east = { idle = { frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 }, walk = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 } } }, gestures = { give = { pose = { frames = { { frameIndex = 1, ticks = 1 } }, loop = false, durationTicks = 1 }, displayOffset = { x = 0, y = math.huge, z = 0 } } } }'
      )
      c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    else
      writeActorVisualWithGestures(c, 0, {
        give = { pose = validGesturePose(1), displayOffset = case.displayOffset },
      }, 1)
    end
    Assert.isFalse(FieldActorCache.isReady(c, "m"), case.label .. " must fail")
  end
end

function T.actor_visual_with_static_model_gestures_empty_is_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeStaticModelVisual(c, 0, {})
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "static-like visual with empty gestures must be ready")
  Assert.isTrue(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
end

function T.actor_visual_with_static_model_gesture_is_not_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeStaticModelVisual(c, 0, {
    give = { pose = validGesturePose(1), displayOffset = { x = 0, y = 0, z = 1 / 32 } },
  })
  Assert.isFalse(FieldActorCache.isReady(c, "m"), "non-empty static gesture must fail")
  Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0))
end

-- Field-message index and banks

local function writeMessageIndex(c, bankIds)
  c:writeLua(FieldMessageCache.indexPath(), {
    schema = FieldMessageCache.INDEX_SCHEMA,
    bankIds = bankIds,
  })
  c:write(FieldMessageCache.markerPath(), "m")
end

function T.message_index_missing_bank_ids_is_not_ready()
  local c = cache()
  c:writeLua(FieldMessageCache.indexPath(), { schema = FieldMessageCache.INDEX_SCHEMA })
  c:write(FieldMessageCache.markerPath(), "m")
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "bankIds is required by the current schema")
end

function T.message_index_with_non_array_bank_ids_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { named = 1 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "a hash table is not a bankIds array")
end

function T.message_index_with_missing_bank_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "an indexed bank file is required")
end

function T.message_bank_with_wrong_identity_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  c:writeLua(FieldMessageCache.bankPath(542), { schema = FieldMessageCache.SCHEMA, bankId = 543 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "bank file identity must match its index entry")
end

function T.message_bank_with_wrong_schema_is_not_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  c:writeLua(FieldMessageCache.bankPath(542), { schema = "g4-other-v1", bankId = 542 })
  Assert.isFalse(FieldMessageCache.isReady(c, "m"), "bank file must carry the expected schema")
end

function T.message_valid_artifact_is_ready()
  local c = cache()
  writeMessageIndex(c, { 542 })
  c:writeLua(FieldMessageCache.bankPath(542), { schema = FieldMessageCache.SCHEMA, bankId = 542 })
  Assert.isTrue(FieldMessageCache.isReady(c, "m"))
end

-- Map scene, model descriptors, and neighbor cells

local function mapScene(mapId)
  return {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = mapId,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {},
    terrainAnimations = { textureSrt = false },
  }
end

local function writeMapScene(c, mapId, scene)
  c:writeLua(MapAssetCache.mapDir(mapId) .. "/scene.lua", scene or mapScene(mapId))
  c:writeLua(MapAssetCache.terrainPath(mapId), { schema = "g4-terrain-surfaces-v1" })
  c:write(MapAssetCache.mapDir(mapId) .. "/dependencies.lua", "return {}\n")
  c:write(MapAssetCache.collisionPath(mapId), CollisionFixture.asset(32, 32))
  c:write(MapAssetCache.mapDir(mapId) .. "/complete", "m")
end

function T.map_scene_missing_materials_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.materials = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "materials is required by the current schema")
end

function T.map_scene_with_non_array_materials_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.materials = { diffuse = 1 }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "a hash table is not a materials array")
end

function T.map_scene_missing_map_batches_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.mapBatches = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "mapBatches is required by the current schema")
end

function T.map_scene_missing_building_instances_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.buildingInstances = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "buildingInstances is required by the current schema")
end

function T.map_scene_missing_neighbors_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.neighbors = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "neighbors is required by the current schema")
end

function T.map_scene_missing_terrain_animations_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.terrainAnimations = nil
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "terrainAnimations is required by the current schema")
end

function T.map_scene_with_non_array_neighbors_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.neighbors = "nope"
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "neighbors must be an array, never a bare value")
end

function T.map_scene_with_wrong_schema_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.schema = "g4-map-scene-v2"
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "scene identity must carry the expected schema")
end

function T.map_scene_with_wrong_map_id_is_not_ready()
  local c = cache()
  local scene = mapScene(99)
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "scene identity must match the probed map")
end

function T.map_batch_without_geometry_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.mapBatches = { { material = 0 } }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "every batch must reference a geometry path")
end

function T.map_scene_with_non_table_batch_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.mapBatches = { 5 }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "a non-table batch element is malformed, not a readable scene")
end

function T.map_neighbor_cell_without_batches_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.neighbors = { { offsetTilesX = 0, offsetTilesY = 0, offsetTilesZ = 32, materials = {} } }
  writeMapScene(c, 61, scene)
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "neighbor cells must carry batches and materials arrays")
end

function T.map_model_descriptor_without_batches_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.buildingInstances = { { modelKey = "indoor:1:abc" } }
  writeMapScene(c, 61, scene)
  c:writeLua(MapAssetCache.modelPath("indoor:1:abc"), { materials = {} })
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "model descriptor batches is required")
end

function T.map_model_descriptor_without_materials_is_not_ready()
  local c = cache()
  local scene = mapScene(61)
  scene.buildingInstances = { { modelKey = "indoor:1:abc" } }
  writeMapScene(c, 61, scene)
  c:writeLua(MapAssetCache.modelPath("indoor:1:abc"), { batches = {} })
  Assert.isFalse(MapAssetCache.isReady(c, 61, "m"), "model descriptor materials is required")
end

function T.map_valid_artifact_is_ready()
  local c = cache()
  writeMapScene(c, 61)
  Assert.isTrue(MapAssetCache.isReady(c, 61, "m"))
end

-- Field-map record collections

local function writeFieldRecord(c, mapId, events, audioPolicy, schema)
  audioPolicy = audioPolicy
    or {
      music = { day = "SEQ_X", night = "SEQ_X", flagOverrides = {}, traversalOverrides = {} },
      soundplates = {},
    }
  c:writeLua(FieldMapDataCache.fieldPath(mapId), {
    schema = schema or FieldMapDataCache.FIELD_SCHEMA,
    mapId = mapId,
    mapSymbol = "test",
    transitionEnvironment = "outdoors",
    events = events,
    music = audioPolicy.music,
    soundplates = audioPolicy.soundplates,
    initScripts = {},
  })
  c:writeLua(FieldMapDataCache.dependenciesPath(mapId), { cacheFormat = FieldMapDataCache.FORMAT })
  c:write(FieldMapDataCache.markerPath(mapId), "m")
end

local function writeCurrentFieldRecord(c, mapId, transitionEnvironment)
  writeFieldRecord(
    c,
    mapId,
    { background = {}, objects = {}, warps = {}, coordinates = {} },
    nil,
    FieldMapDataCache.FIELD_SCHEMA
  )
  local field = assert(c:loadLua(FieldMapDataCache.fieldPath(mapId)))
  field.transitionEnvironment = transitionEnvironment
  c:writeLua(FieldMapDataCache.fieldPath(mapId), field)
end

local function writeFieldObjectRecord(c, object)
  writeFieldRecord(c, 60, {
    background = {},
    objects = { object },
    warps = {},
    coordinates = {},
  })
end

function T.current_field_data_requires_a_valid_transition_environment()
  for _, environment in ipairs({ "cave", "outdoors", "building" }) do
    local c = cache()
    writeCurrentFieldRecord(c, 60, environment)
    Assert.isTrue(FieldMapDataCache.isReady(c, 60, "m"), environment)
  end

  for _, case in ipairs({ { value = nil }, { value = "unknown" } }) do
    local c = cache()
    writeCurrentFieldRecord(c, 60, case.value)
    Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "invalid transition environment")
  end
end

function T.field_data_missing_events_is_not_ready()
  local c = cache()
  writeFieldRecord(c, 60, nil)
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "events is required by the current schema")
end

function T.field_data_with_partial_events_is_not_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {} })
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "all four event collections are required")
end

function T.field_data_with_non_array_event_collection_is_not_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = "x", coordinates = {} })
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "each event collection must be an array")
end

function T.field_data_rejects_objects_without_semantic_movement_types()
  local cases = {
    { movement = nil, xRange = 0, yRange = 0 },
    { movement = 3, xRange = 0, yRange = 0 },
    { movement = 3, movementType = "wander_around", xRange = 0, yRange = 0 },
    { movementType = "3", xRange = 0, yRange = 0 },
    { movementType = "unknown", xRange = 0, yRange = 0 },
  }
  for _, object in ipairs(cases) do
    local c = cache()
    writeFieldObjectRecord(c, object)
    Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "object movement type must be a known semantic string")
  end
end

function T.field_data_with_semantic_object_movement_type_is_ready()
  local c = cache()
  writeFieldObjectRecord(c, { movementType = "stationary", xRange = 0, yRange = 0 })
  Assert.isTrue(FieldMapDataCache.isReady(c, 60, "m"))
end

function T.field_data_accepts_canonical_object_movement_ranges()
  local cases = {
    { xRange = -1, yRange = -1 },
    { xRange = 0, yRange = 0 },
    { xRange = 3, yRange = 7 },
    { xRange = -1, yRange = 5 },
    { xRange = 8, yRange = -1 },
  }
  for _, ranges in ipairs(cases) do
    local c = cache()
    writeFieldObjectRecord(c, {
      movementType = "stationary",
      xRange = ranges.xRange,
      yRange = ranges.yRange,
    })
    Assert.isTrue(
      FieldMapDataCache.isReady(c, 60, "m"),
      string.format("canonical ranges %d/%d remain valid", ranges.xRange, ranges.yRange)
    )
  end
end

function T.field_data_rejects_invalid_object_movement_ranges_on_each_axis()
  local cases = {
    { name = "missing", value = nil },
    { name = "below sentinel", value = -2 },
    { name = "fractional", value = 1.5 },
    { name = "NaN", expression = "0 / 0" },
    { name = "positive infinity", expression = "1 / 0" },
    { name = "negative infinity", expression = "-1 / 0" },
    { name = "string", value = "1" },
    { name = "boolean", value = true },
    { name = "table", value = {} },
  }
  for _, axis in ipairs({ "xRange", "yRange" }) do
    for _, case in ipairs(cases) do
      local object = { movementType = "stationary", xRange = 0, yRange = 0 }
      object[axis] = case.value
      local c = cache()
      if case.expression == nil then
        writeFieldObjectRecord(c, object)
      else
        writeFieldObjectRecord(c, { movementType = "stationary", xRange = 0, yRange = 0 })
        local path = FieldMapDataCache.fieldPath(60)
        local source = assert(c:read(path))
        local replacement = axis .. " = " .. case.expression
        local malformed, replacements = source:gsub(axis .. " = 0", replacement, 1)
        Assert.equal(replacements, 1, "test fixture must replace the selected range")
        c:write(path, malformed)
      end
      Assert.isFalse(
        FieldMapDataCache.isReady(c, 60, "m"),
        string.format("invalid %s range on %s must not be ready", case.name, axis)
      )
    end
  end
end

function T.field_data_rejects_any_object_with_an_invalid_movement_range()
  local c = cache()
  writeFieldRecord(c, 60, {
    background = {},
    objects = {
      { movementType = "stationary", xRange = 0, yRange = 0 },
      { movementType = "stationary", xRange = -2, yRange = 0 },
    },
    warps = {},
    coordinates = {},
  })
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"))
end

function T.field_data_valid_artifact_is_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = {}, coordinates = {} })
  Assert.isTrue(FieldMapDataCache.isReady(c, 60, "m"))
end

function T.field_data_rejects_malformed_init_descriptor_union()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = {}, coordinates = {} })
  local field = assert(c:loadLua(FieldMapDataCache.fieldPath(60)))
  field.initScripts = { { type = "on_resume", scriptId = "vanilla.hgss.scr_seq.0001.script_000", extra = true } }
  c:writeLua(FieldMapDataCache.fieldPath(60), field)
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"))
end

function T.field_data_rejects_legacy_numeric_script_targets()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = {}, coordinates = {} })
  local field = assert(c:loadLua(FieldMapDataCache.fieldPath(60)))
  field.initScripts = { { type = "on_frame_eq", rules = { { variableId = 1, equals = 2, scriptIndex = 0 } } } }
  c:writeLua(FieldMapDataCache.fieldPath(60), field)
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"))
end

-- The generated field schema is current-schema-only: a record that is valid in
-- every other respect but carries the superseded schema identity is stale
-- generated data and must never read as ready (rebuilding the derived cache is
-- the only migration; no compatibility reader exists).
function T.field_data_with_the_superseded_schema_is_not_ready()
  local c = cache()
  writeFieldRecord(c, 60, { background = {}, objects = {}, warps = {}, coordinates = {} }, nil, "g4-field-map-v8")
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "a stale v8 field record is not current data")
end

function T.field_data_missing_audio_policy_is_not_ready()
  local c = cache()
  local events = { background = {}, objects = {}, warps = {}, coordinates = {} }
  writeFieldRecord(c, 60, events, { soundplates = {} })
  Assert.isFalse(FieldMapDataCache.isReady(c, 60, "m"), "the music record is required by the current schema")
  writeFieldRecord(
    c,
    61,
    events,
    { music = { day = "SEQ_X", night = "SEQ_X", flagOverrides = {}, traversalOverrides = {} } }
  )
  Assert.isFalse(FieldMapDataCache.isReady(c, 61, "m"), "the soundplates array is required by the current schema")
end

-- Script index and emitted resources

local function writeGenerationIndex(c, generation, marker, resources)
  c:write(ScriptCache.generationMarkerPath(generation), marker)
  c:writeLua(ScriptCache.generationIndexPath(generation), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = generation,
    marker = marker,
    resources = resources,
  })
end

local function writeScriptIndex(c, resources)
  c:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = "m",
  })
  c:write(ScriptCache.markerPath(), "m")
  writeGenerationIndex(c, SCRIPT_GENERATION, "m", resources)
end

local function writeGenerationResource(c, generation, member, id, kind)
  c:write(
    ScriptCache.scriptPath(generation, member, id),
    string.format('return { kind = "%s", id = "%s" }\n', kind or "field_script", id)
  )
end

function T.script_generation_readiness_does_not_require_active_selection()
  local c = cache()
  writeGenerationIndex(c, SCRIPT_GENERATION, "m", { { id = "a.b", member = 1, scriptIndex = 0 } })
  writeGenerationResource(c, SCRIPT_GENERATION, 1, "a.b")

  Assert.isTrue(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"))
  Assert.isFalse(ScriptCache.isReady(c, "m"), "an inactive generation is not active-ready")
end

function T.script_generation_with_wrong_marker_is_not_ready()
  local c = cache()
  writeGenerationIndex(c, SCRIPT_GENERATION, "m", {})
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "other"))
end

function T.script_generation_with_missing_or_malformed_index_is_not_ready()
  local c = cache()
  c:write(ScriptCache.generationMarkerPath(SCRIPT_GENERATION), "m")
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"))

  c = cache()
  c:write(ScriptCache.generationMarkerPath(SCRIPT_GENERATION), "m")
  c:writeLua(ScriptCache.generationIndexPath(SCRIPT_GENERATION), { schema = "wrong" })
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"))
end

function T.script_generation_with_missing_marker_is_not_ready()
  local c = cache()
  c:writeLua(ScriptCache.generationIndexPath(SCRIPT_GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = "m",
    resources = {},
  })
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"))
end

function T.script_generation_with_missing_or_malformed_resource_is_not_ready()
  local c = cache()
  local resources = { { id = "a.b", member = 1, scriptIndex = 0 } }
  writeGenerationIndex(c, SCRIPT_GENERATION, "m", resources)
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"))

  writeGenerationResource(c, SCRIPT_GENERATION, 1, "a.b", "other")
  Assert.isFalse(ScriptCache.isGenerationReady(c, SCRIPT_GENERATION, "m"))
end

function T.script_index_missing_resources_is_not_ready()
  local c = cache()
  c:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = SCRIPT_GENERATION,
    marker = "m",
  })
  c:write(ScriptCache.markerPath(), "m")
  c:write(ScriptCache.generationMarkerPath(SCRIPT_GENERATION), "m")
  c:writeLua(ScriptCache.generationIndexPath(SCRIPT_GENERATION), { schema = ScriptCache.INDEX_SCHEMA })
  Assert.isFalse(ScriptCache.isReady(c, "m"), "resources is required by the current schema")
end

function T.script_index_with_non_array_resources_is_not_ready()
  local c = cache()
  writeScriptIndex(c, { named = 1 })
  Assert.isFalse(ScriptCache.isReady(c, "m"), "a hash table is not a resources array")
end

function T.script_resource_with_mismatched_id_is_not_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0 } })
  c:write(ScriptCache.scriptPath(SCRIPT_GENERATION, 1, "a.b"), 'return { kind = "field_script", id = "c.d" }\n')
  Assert.isFalse(ScriptCache.isReady(c, "m"), "emitted script identity must match its index entry")
end

function T.script_resource_with_wrong_kind_is_not_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0 } })
  c:write(ScriptCache.scriptPath(SCRIPT_GENERATION, 1, "a.b"), 'return { kind = "other", id = "a.b" }\n')
  Assert.isFalse(ScriptCache.isReady(c, "m"), "emitted script must be a field_script resource")
end

function T.script_resource_that_does_not_parse_is_not_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0 } })
  c:write(ScriptCache.scriptPath(SCRIPT_GENERATION, 1, "a.b"), "not lua at all")
  Assert.isFalse(ScriptCache.isReady(c, "m"), "an unparsable resource cannot be ready")
end

function T.script_valid_artifact_is_ready()
  local c = cache()
  writeScriptIndex(c, { { id = "a.b", member = 1, scriptIndex = 0 } })
  c:write(
    ScriptCache.scriptPath(SCRIPT_GENERATION, 1, "a.b"),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "a.b", steps = { S.stop() } }\n'
  )
  Assert.isTrue(ScriptCache.isReady(c, "m"))
end

function T.actor_valid_atlas_and_static_renders_are_ready()
  local c = cache()
  writeActorIndex(c, { 0 })
  writeActorVisual(c, 0)
  local visual = c:loadLua(FieldActorCache.visualPath(0))
  Assert.isTrue(FieldActorCache.isValidVisual(visual, 0))
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "valid atlas with geometry/polygon/dimensions must be ready")

  c = cache()
  writeActorIndex(c, { 1 })
  writeStaticModelVisual(c, 1, {})
  visual = c:loadLua(FieldActorCache.visualPath(1))
  Assert.isTrue(FieldActorCache.isValidVisual(visual, 1))
  Assert.isTrue(FieldActorCache.isReady(c, "m"), "valid static with parts/geometry/polygon must be ready")

  -- direct validation of helpers without cache
  Assert.isTrue(FieldActorCache.isValidVisual({
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = validAtlasRender(0, 2),
    idlePresentation = { mode = "static", cadence = 0 },
    directions = validDirections(),
    gestures = {},
  }, 0))
  Assert.isTrue(FieldActorCache.isValidVisual({
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = validStaticRender(0, 1, { validStaticPart(), validStaticPart() }),
    idlePresentation = { mode = "static", cadence = 0 },
    directions = validDirections(),
    gestures = {},
  }, 0))
end

function T.actor_visual_with_unknown_render_kind_is_not_ready()
  local cases = {
    { kind = "unknown", label = "unknown kind" },
    { kind = nil, label = "missing kind" },
    { kind = "ATLAS", label = "wrong case" },
    { kind = 1, label = "numeric kind" },
  }
  for _, case in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validAtlasRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    visual.render.kind = case.kind
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), case.label .. " must fail")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), case.label .. " must fail readiness")
  end
end

function T.actor_visual_with_malformed_atlas_render_is_not_ready()
  local function mutateAtlas(mutator, label)
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validAtlasRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    mutator(visual.render)
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0), label .. " must fail")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), label .. " must fail readiness")
  end

  mutateAtlas(function(r)
    r.frameWidth = nil
  end, "missing frameWidth")
  mutateAtlas(function(r)
    r.frameHeight = nil
  end, "missing frameHeight")
  mutateAtlas(function(r)
    r.frameWidth = 0
  end, "zero frameWidth")
  mutateAtlas(function(r)
    r.frameHeight = -1
  end, "negative frameHeight")
  mutateAtlas(function(r)
    r.frameWidth = "32"
  end, "string frameWidth")
  mutateAtlas(function(r)
    r.frameCount = 0
  end, "zero frameCount")
  mutateAtlas(function(r)
    r.image = "assets/generated/field/actors/0001.png"
  end, "wrong image path")
  mutateAtlas(function(r)
    r.image = nil
  end, "missing image")
  mutateAtlas(function(r)
    r.alphaClass = "translucent"
  end, "atlas translucent alphaClass")
  mutateAtlas(function(r)
    r.alphaClass = "mixed"
  end, "atlas mixed alphaClass")
  mutateAtlas(function(r)
    r.alphaClass = nil
  end, "missing atlas alphaClass")
  mutateAtlas(function(r)
    r.alphaClass = "unknown"
  end, "unknown atlas alphaClass")
  mutateAtlas(function(r)
    r.polygon = nil
  end, "missing polygon")
  mutateAtlas(function(r)
    r.geometry = nil
  end, "missing geometry")
  mutateAtlas(function(r)
    r.geometry.baseTransform = nil
  end, "missing baseTransform")
  mutateAtlas(function(r)
    r.geometry.baseTransform = { 1, 0, 0 }
  end, "short baseTransform")
  mutateAtlas(function(r)
    r.geometry.baseTransform = "nope"
  end, "string baseTransform")
  -- NaN / infinite baseTransform cannot be serialized via writeLua; test directly
  do
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validAtlasRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    visual.render.geometry.baseTransform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 / 0 }
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), "NaN baseTransform must fail")
    visual.render.geometry.baseTransform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, math.huge }
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), "infinite baseTransform must fail")
  end
end

function T.actor_visual_with_malformed_static_render_is_not_ready()
  local function mutateStatic(mutator, label)
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validStaticRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    mutator(visual.render)
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0), label .. " must fail")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), label .. " must fail readiness")
  end

  mutateStatic(function(r)
    r.frameCount = 2
  end, "static frameCount 2")
  mutateStatic(function(r)
    r.frameCount = 0
  end, "static frameCount 0")
  mutateStatic(function(r)
    r.parts = nil
  end, "missing parts")
  mutateStatic(function(r)
    r.parts = {}
  end, "empty parts")
  mutateStatic(function(r)
    r.parts = { named = 1 }
  end, "hash parts")
  mutateStatic(function(r)
    r.frameWidth = nil
  end, "static missing frameWidth")
  mutateStatic(function(r)
    r.frameHeight = nil
  end, "static missing frameHeight")
  mutateStatic(function(r)
    r.image = nil
  end, "static missing image")
end

function T.actor_visual_with_malformed_static_part_is_not_ready()
  local function mutatePart(mutator, label)
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validStaticRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    mutator(visual.render.parts[1])
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0), label .. " must fail")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), label .. " must fail readiness")
  end

  mutatePart(function(p)
    p.textured = nil
  end, "missing textured")
  mutatePart(function(p)
    p.textured = "true"
  end, "string textured")
  mutatePart(function(p)
    p.alphaClass = "unknown"
  end, "unknown part alphaClass")
  mutatePart(function(p)
    p.alphaClass = nil
  end, "missing part alphaClass")
  mutatePart(function(p)
    p.polygon = nil
  end, "missing part polygon")
  mutatePart(function(p)
    p.geometry = nil
  end, "missing part geometry")
  local c = cache()
  writeActorIndex(c, { 0 })
  local visual = {
    schema = FieldActorCache.SCHEMA,
    spriteId = 0,
    render = validStaticRender(
      0,
      1,
      { { textured = true, alphaClass = "cutout", polygon = validPolygon(), geometry = validStaticGeometry() } }
    ),
    idlePresentation = { mode = "static", cadence = 0 },
    directions = validDirections(),
    gestures = {},
  }
  c:writeLua(FieldActorCache.visualPath(0), visual)
  c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
  Assert.isTrue(
    FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0),
    "cutout static part must be valid"
  )
end

function T.actor_visual_with_malformed_geometry_is_not_ready()
  ---@param isAtlas boolean
  ---@param label string
  ---@param mutator fun(geometry: table<string, unknown>, visual: table<string, unknown>)
  local function mutateGeometry(isAtlas, mutator, label)
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = isAtlas and validAtlasRender(0, 1) or validStaticRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    local geom = isAtlas and visual.render.geometry or visual.render.parts[1].geometry
    mutator(geom, visual)
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0), label .. " must fail")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), label .. " must fail readiness")
  end

  mutateGeometry(true, function(g)
    g.vertices = nil
  end, "atlas missing vertices")
  mutateGeometry(true, function(g)
    g.vertices = {}
  end, "atlas empty vertices")
  mutateGeometry(true, function(g)
    g.vertices = { named = 1 }
  end, "atlas hash vertices")
  mutateGeometry(true, function(g)
    g.vertices[1].r = 256
  end, "atlas vertex r out of range")
  mutateGeometry(true, function(g)
    g.vertices[1].r = -1
  end, "atlas vertex r negative")
  mutateGeometry(true, function(g)
    g.vertices[1].r = 1.5
  end, "atlas vertex r fractional")
  mutateGeometry(true, function(g)
    g.vertices[1].a = 512
  end, "atlas vertex a out of range")
  mutateGeometry(true, function(g)
    g.vertices[1].colorSource = 3
  end, "atlas vertex colorSource out of range")
  mutateGeometry(true, function(g)
    g.vertices[1].colorSource = "0"
  end, "atlas vertex colorSource string")
  mutateGeometry(true, function(g)
    g.indices = nil
  end, "atlas missing indices")
  mutateGeometry(true, function(g)
    g.indices = {}
  end, "atlas empty indices")
  mutateGeometry(true, function(g)
    g.indices[1] = 99
  end, "atlas index out of range")
  mutateGeometry(true, function(g)
    g.indices[1] = -1
  end, "atlas negative index")
  mutateGeometry(true, function(g)
    g.indices[1] = 1.5
  end, "atlas fractional index")
  mutateGeometry(true, function(g)
    g.indices[1] = "0"
  end, "atlas string index")
  mutateGeometry(true, function(g)
    g.anchorTiles = nil
  end, "atlas missing anchorTiles")
  mutateGeometry(true, function(g)
    g.anchorTiles = { x = 0, y = 0 }
  end, "atlas anchor missing z")
  mutateGeometry(true, function(g)
    g.anchorTiles = { x = "0", y = 0, z = 0 }
  end, "atlas anchor string x")
  mutateGeometry(true, function(g)
    g.bounds = nil
  end, "atlas missing bounds")
  mutateGeometry(true, function(g)
    g.bounds = { width = -1, height = 1, depth = 0 }
  end, "atlas negative bounds width")
  mutateGeometry(true, function(g)
    g.bounds = { width = "1", height = 1, depth = 0 }
  end, "atlas string bounds")
  mutateGeometry(true, function(g)
    g.center = { 0, 0 }
  end, "atlas bad center length")
  mutateGeometry(false, function(g)
    g.vertices = nil
  end, "static missing vertices")
  mutateGeometry(false, function(g)
    g.indices = { 0, 99 }
  end, "static index out of range")
  mutateGeometry(false, function(g)
    g.bounds = { width = 1, height = 1, depth = -1 }
  end, "static negative depth")
  do
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validAtlasRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    visual.render.geometry.vertices[1].x = 0 / 0
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), "atlas NaN vertex x must fail")
    visual.render.geometry.vertices[1].x = math.huge
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), "atlas infinite vertex x must fail")
    visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validAtlasRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    visual.render.geometry.anchorTiles = { x = 0 / 0, y = 0, z = 0 }
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), "atlas anchor NaN must fail")
    visual.render.geometry.anchorTiles = { x = 0, y = 0, z = 0 }
    visual.render.geometry.bounds = { width = 0 / 0, height = 1, depth = 0 }
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), "atlas NaN bounds must fail")
    visual.render.geometry.bounds = { width = 2, height = 2, depth = 0 }
    visual.render.geometry.center = { 0, 0, 0 / 0 }
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), "atlas NaN center must fail")
  end
end

function T.actor_visual_with_malformed_polygon_is_not_ready()
  local function mutatePolygon(mutator, label)
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validAtlasRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    mutator(visual.render.polygon)
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0), label .. " must fail")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), label .. " must fail readiness")
    -- also ensure static part polygon fails
    local c2 = cache()
    writeActorIndex(c2, { 0 })
    local visual2 = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = validStaticRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    mutator(visual2.render.parts[1].polygon)
    c2:writeLua(FieldActorCache.visualPath(0), visual2)
    c2:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(
      FieldActorCache.isValidVisual(c2:loadLua(FieldActorCache.visualPath(0)), 0),
      label .. " static must fail"
    )
  end

  mutatePolygon(function(p)
    p.cullMode = "invalid"
  end, "invalid cullMode")
  mutatePolygon(function(p)
    p.polygonMode = "invalid"
  end, "invalid polygonMode")
  mutatePolygon(function(p)
    p.polygonId = 64
  end, "polygonId out of range")
  mutatePolygon(function(p)
    p.polygonId = -1
  end, "polygonId negative")
  mutatePolygon(function(p)
    p.polygonId = 1.5
  end, "polygonId fractional")
  mutatePolygon(function(p)
    p.polygonAlpha = 32
  end, "polygonAlpha out of range")
  mutatePolygon(function(p)
    p.lightMask = 16
  end, "lightMask out of range")
  mutatePolygon(function(p)
    p.translucentDepthWrite = true
  end, "translucentDepthWrite true unsupported")
  mutatePolygon(function(p)
    p.depthEqual = true
  end, "depthEqual true unsupported")
  mutatePolygon(function(p)
    p.fogEnabled = "true"
  end, "fogEnabled not boolean")
  mutatePolygon(function(p)
    p.cullMode = nil
  end, "missing cullMode")
end

function T.actor_geometry_with_non_triangle_indices_is_not_ready()
  local function assertNonTriangle(isAtlas, label)
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = isAtlas and validAtlasRender(0, 1) or validStaticRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    local geom = isAtlas and visual.render.geometry or visual.render.parts[1].geometry
    geom.indices = { 0, 1, 2, 0 }
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0), label .. " must fail")
    Assert.isFalse(FieldActorCache.isReady(c, "m"), label .. " must fail readiness")
    -- also direct helper check without cache
    local direct = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = isAtlas and validAtlasRender(0, 1) or validStaticRender(0, 1),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    local directGeom = isAtlas and direct.render.geometry or direct.render.parts[1].geometry
    directGeom.indices = { 0, 1, 2, 0 }
    Assert.isFalse(FieldActorCache.isValidVisual(direct, 0), label .. " direct must fail")
  end

  assertNonTriangle(true, "atlas non-triangle indices")
  assertNonTriangle(false, "static non-triangle indices")
end

function T.actor_visual_with_incompatible_alpha_class_is_not_ready()
  local cases = {
    {
      label = "atlas opaque with polygonAlpha 30",
      make = function()
        local r = validAtlasRender(0, 1)
        r.alphaClass = "opaque"
        r.polygon.polygonAlpha = 30
        return r
      end,
      kind = "atlas",
    },
    {
      label = "static textured opaque with polygonAlpha 30",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "opaque"
        p.polygon.polygonAlpha = 30
        p.textured = true
        return validStaticRender(0, 1, { p })
      end,
      kind = "static",
    },
    {
      label = "static wireframe with polygonAlpha 31",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "wireframe"
        p.polygon.polygonAlpha = 31
        p.polygon.polygonMode = "modulation"
        return validStaticRender(0, 1, { p })
      end,
      kind = "static",
    },
    {
      label = "static textured cutout with polygonAlpha 31 decal",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "cutout"
        p.polygon.polygonAlpha = 31
        p.polygon.polygonMode = "decal"
        p.textured = true
        return validStaticRender(0, 1, { p })
      end,
      kind = "static",
    },
    {
      label = "static untextured cutout with polygonAlpha 31 modulation",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "cutout"
        p.polygon.polygonAlpha = 31
        p.polygon.polygonMode = "modulation"
        p.textured = false
        return validStaticRender(0, 1, { p })
      end,
      kind = "static",
    },
  }

  for _, case in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = case.make(),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isFalse(
      FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0),
      case.label .. " must fail"
    )
    Assert.isFalse(FieldActorCache.isReady(c, "m"), case.label .. " must fail readiness")
    Assert.isFalse(FieldActorCache.isValidVisual(visual, 0), case.label .. " direct must fail")
  end
end

function T.actor_visual_with_compatible_alpha_class_remains_valid()
  local cases = {
    {
      label = "static translucent with polygonAlpha 30",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "translucent"
        p.polygon.polygonAlpha = 30
        return validStaticRender(0, 1, { p })
      end,
    },
    {
      label = "static wireframe with polygonAlpha 0",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "wireframe"
        p.polygon.polygonAlpha = 0
        return validStaticRender(0, 1, { p })
      end,
    },
    {
      label = "textured static cutout with polygonAlpha 31 modulation",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "cutout"
        p.polygon.polygonAlpha = 31
        p.polygon.polygonMode = "modulation"
        p.textured = true
        return validStaticRender(0, 1, { p })
      end,
    },
    {
      label = "opaque atlas with polygonAlpha 31 modulation",
      make = function()
        local r = validAtlasRender(0, 1)
        r.alphaClass = "opaque"
        r.polygon.polygonAlpha = 31
        r.polygon.polygonMode = "modulation"
        return r
      end,
    },
    {
      label = "cutout atlas with polygonAlpha 31 modulation",
      make = function()
        local r = validAtlasRender(0, 1)
        r.alphaClass = "cutout"
        r.polygon.polygonAlpha = 31
        r.polygon.polygonMode = "modulation"
        return r
      end,
    },
    {
      label = "static opaque decal with polygonAlpha 31",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "opaque"
        p.polygon.polygonAlpha = 31
        p.polygon.polygonMode = "decal"
        return validStaticRender(0, 1, { p })
      end,
    },
    {
      label = "static mixed with polygonAlpha 31 modulation textured",
      make = function()
        local p = validStaticPart()
        p.alphaClass = "mixed"
        p.polygon.polygonAlpha = 31
        p.polygon.polygonMode = "modulation"
        p.textured = true
        return validStaticRender(0, 1, { p })
      end,
    },
  }

  for _, case in ipairs(cases) do
    local c = cache()
    writeActorIndex(c, { 0 })
    local visual = {
      schema = FieldActorCache.SCHEMA,
      spriteId = 0,
      render = case.make(),
      idlePresentation = { mode = "static", cadence = 0 },
      directions = validDirections(),
      gestures = {},
    }
    c:writeLua(FieldActorCache.visualPath(0), visual)
    c:write(FieldActorCache.atlasPath(0), "atlas-bytes")
    Assert.isTrue(
      FieldActorCache.isValidVisual(c:loadLua(FieldActorCache.visualPath(0)), 0),
      case.label .. " must pass"
    )
    Assert.isTrue(FieldActorCache.isReady(c, "m"), case.label .. " must pass readiness")
  end
end

return { tests = T }
