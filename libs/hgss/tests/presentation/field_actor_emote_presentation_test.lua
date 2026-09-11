-- Field actor emote presentation: proves a decoded semantic emote movement
-- action (e.g. exclamation) surfaces actor-scoped, action-lifetime
-- presentation state through the same production FieldActorManager path
-- locomotion already uses (FieldObjectActor:beginScriptedAction/
-- advanceScriptedAction/commitScriptedAction and
-- FieldActorManager:drawRecords(), the same seam
-- field_actor_walk_in_place_test.lua exercises), never as renderer-owned or
-- global/singleton state.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local FieldActorEmoteRenderer = require("libs.hgss.src.presentation.FieldActorEmoteRenderer")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local POLICY = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } }

local function flatTerrain()
  return TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
end

local function object(overrides)
  local event = {
    index = 0,
    objectEventId = 0,
    spriteId = 99,
    movementType = "stationary",
    type = 0,
    eventFlag = 0,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = 2,
    z = 3,
    y = 0,
  }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function map(objects)
  local result = {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = flatTerrain(),
    fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
  }
  ---@cast result RuntimeFieldMap
  return result
end

local fakeAssets = {
  knows = function()
    return true
  end,
  acquire = function(_, id)
    return { spriteId = id, visual = FieldActorFixture.visual(id) }
  end,
  release = function() end,
}

local function manager(objects, eventState)
  local mgr = FieldActorManager.new({ assets = fakeAssets, policy = POLICY })
  mgr:enterMap(map(objects), eventState or FieldEventState.new())
  return mgr
end

local function drawRecordFor(mgr, actorId)
  for _, record in ipairs(mgr:drawRecords()) do
    if record.actorId == actorId then
      return record
    end
  end
  error("actor " .. actorId .. " has no draw record")
end

-- A minimal one-batch ModelAsset fixture and a recording fake pool, wired
-- exactly like the production GpuAssetPool contract (build/meshFor/imageFor),
-- so the renderer's real quad-placement math runs against the real
-- FieldActorManager draw-record trace instead of a semantic-only fixture.
local IDENTITY_MATRIX = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }

local function fakeExclamationModel(baseTransform)
  return {
    materials = {
      { id = 0, name = "exclamation", texture = "exclamation.png", wrap = { x = "clamp", y = "clamp" } },
    },
    batches = {
      {
        geometry = "exclamation.g4mesh",
        material = 0,
        alphaClass = "cutout",
        cullMode = "none",
        polygonAlpha = 31,
        transformMode = "billboard",
        baseTransform = baseTransform or IDENTITY_MATRIX,
      },
    },
  }
end

local function fakeExclamationDescriptor(baseTransform)
  return {
    schema = "g4-field-emote-v1",
    anchorOffset = { x = 0, y = 2, z = 0.0625 },
    model = fakeExclamationModel(baseTransform),
  }
end

local function fakePool()
  return {
    build = function(_, fn)
      return fn()
    end,
    meshFor = function()
      return { mesh = {}, center = { 0, 2, 0 } }
    end,
    imageFor = function()
      return {}
    end,
  }
end

function T.emote_presentation_follows_the_action_lifetime_independent_of_draw_count_and_never_moves_the_actor()
  local ACTOR_ID = "map:61:object:0"
  local mgr = manager({ object({ objectEventId = 0, x = 2, z = 3 }) })
  local actor = assert(mgr:getById(ACTOR_ID))
  local baseFieldX, baseFieldZ = actor:getFieldPosition().fieldX, actor:getFieldPosition().fieldZ
  local baseWorldX, baseWorldY, baseWorldZ =
    actor:getWorldPosition().x, actor:getWorldPosition().y, actor:getWorldPosition().z

  Assert.isNil(drawRecordFor(mgr, ACTOR_ID).activeEmoteKind, "no emote is active before the action begins")

  local renderer = FieldActorEmoteRenderer.new({ exclamation = fakeExclamationDescriptor() }, fakePool())
  Assert.equal(#renderer:drawItems(mgr:drawRecords()), 0, "the renderer draws nothing before the action begins")

  mgr:beginScriptedAction(ACTOR_ID, { action = "emote", name = "exclamation" })
  local duration = MovementCalibration.EMOTE_TICKS
  for tick = 1, duration do
    mgr:advanceScriptedAction(ACTOR_ID, tick, duration)
    -- Rendering the same fixed tick any number of times must not move or
    -- extend the effect: the movement action clock is the sole authority,
    -- never the number of draw calls.
    for _ = 1, 3 do
      local record = drawRecordFor(mgr, ACTOR_ID)
      Assert.equal(record.activeEmoteKind, "exclamation", "exclamation must be active for tick " .. tick)
    end
    Assert.equal(actor:getFieldPosition().fieldX, baseFieldX, "an emote must never change logical fieldX")
    Assert.equal(actor:getFieldPosition().fieldZ, baseFieldZ, "an emote must never change logical fieldZ")
    Assert.equal(actor:getWorldPosition().x, baseWorldX, "an emote must never change logical worldX")
    Assert.equal(actor:getWorldPosition().y, baseWorldY, "an emote must never change logical worldY")
    Assert.equal(actor:getWorldPosition().z, baseWorldZ, "an emote must never change logical worldZ")

    -- The renderer's actual draw trace: exactly one quad, anchored above the
    -- acting actor's current draw-world position by the generated offset.
    local items = renderer:drawItems(mgr:drawRecords())
    Assert.equal(#items, 1, "exactly one emote quad draws while the action is active")
    Assert.equal(items[1].actorId, ACTOR_ID, "the emote quad is attributed to the acting actor")
    Assert.equal(items[1].transform[13], baseWorldX, "the emote quad tracks the actor's world x")
    Assert.near(items[1].transform[14], baseWorldY + 2, 1e-9, "the emote quad is above the actor's world y")
    Assert.near(items[1].transform[15], baseWorldZ + 0.0625, 1e-9, "the emote quad uses the actor's world z anchor")
    Assert.notNil(items[1].billboardCenter, "a billboard batch must carry a camera-independent center")
    Assert.notNil(items[1].billboardScale, "a billboard batch must carry a camera-independent scale")
  end
  mgr:commitScriptedAction(ACTOR_ID)

  Assert.isNil(drawRecordFor(mgr, ACTOR_ID).activeEmoteKind, "the indicator must be gone once the action completes")
  Assert.equal(#renderer:drawItems(mgr:drawRecords()), 0, "the renderer draws nothing once the action completes")
end

-- The compiled model's batch is marked billboard (the source's Nitro BB
-- opcode) with a captured base transform; the renderer must fold that base
-- transform's own translation/scale into the final placement rather than
-- discarding it, exactly like the static-building billboard path
-- (ModelInstance:drawItems / BillboardTransform).
function T.a_billboard_batch_folds_its_captured_base_transform_into_the_final_placement()
  local ACTOR_ID = "map:61:object:0"
  local mgr = manager({ object({ objectEventId = 0, x = 2, z = 3 }) })
  local actor = assert(mgr:getById(ACTOR_ID))

  -- A base transform that is not identity: translated +2 up (source vertical
  -- offset), scaled 1.5x on x, 2x on y.
  local baseTransform = {
    1.5,
    0,
    0,
    0,
    0,
    2,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    2,
    0,
    1,
  }
  local renderer = FieldActorEmoteRenderer.new({ exclamation = fakeExclamationDescriptor(baseTransform) }, fakePool())

  mgr:beginScriptedAction(ACTOR_ID, { action = "emote", name = "exclamation" })
  mgr:advanceScriptedAction(ACTOR_ID, 1, MovementCalibration.EMOTE_TICKS)

  local items = renderer:drawItems(mgr:drawRecords())
  Assert.equal(#items, 1)
  Assert.near(items[1].billboardCenter[1], actor:getWorldPosition().x, 1e-9, "billboard center x tracks the actor")
  Assert.near(
    items[1].billboardCenter[2],
    actor:getWorldPosition().y + 4,
    1e-9,
    "billboard center y includes anchor and base offsets"
  )
  Assert.near(
    items[1].billboardCenter[3],
    actor:getWorldPosition().z + 0.0625,
    1e-9,
    "billboard center z includes the generated anchor"
  )
  Assert.near(items[1].billboardScale[1], 1.5, 1e-9, "billboard scale x comes from the base transform")
  Assert.near(items[1].billboardScale[2], 2, 1e-9, "billboard scale y comes from the base transform")

  mgr:commitScriptedAction(ACTOR_ID)
end

function T.emote_anchor_uses_each_current_draw_world_once()
  local renderer = FieldActorEmoteRenderer.new({ exclamation = fakeExclamationDescriptor() }, fakePool())
  local items = renderer:drawItems({
    {
      actorId = "actor:a",
      activeEmoteKind = "exclamation",
      world = { x = 10, y = 20.25, z = -3 },
      presentationOffset = { x = 7, y = 11, z = 13 },
    },
    {
      actorId = "actor:b",
      activeEmoteKind = "exclamation",
      world = { x = -4, y = 1.5, z = 8 },
    },
    {
      actorId = "actor:none",
      activeEmoteKind = nil,
      world = { x = 0, y = 0, z = 0 },
    },
    {
      actorId = "actor:unsupported",
      activeEmoteKind = "question",
      world = { x = 0, y = 0, z = 0 },
    },
  })

  Assert.equal(#items, 2, "only active compiled emotes produce draw items")
  Assert.equal(items[1].actorId, "actor:a")
  Assert.equal(items[1].transform[13], 10)
  Assert.near(items[1].transform[14], 22.25, 1e-9)
  Assert.near(items[1].transform[15], -2.9375, 1e-9)
  Assert.equal(items[2].actorId, "actor:b")
  Assert.equal(items[2].transform[13], -4)
  Assert.near(items[2].transform[14], 3.5, 1e-9)
  Assert.near(items[2].transform[15], 8.0625, 1e-9)
end

function T.emote_state_is_per_actor_and_clears_on_removal_without_leaking_to_a_recreated_actor()
  local eventState = FieldEventState.new()
  local mgr = manager({
    object({ objectEventId = 0, eventFlag = 0, x = 2, z = 3 }),
    object({ objectEventId = 1, eventFlag = 401, x = 5, z = 3 }),
  }, eventState)
  local A, B = "map:61:object:0", "map:61:object:1"

  mgr:beginScriptedAction(A, { action = "emote", name = "exclamation" })
  mgr:beginScriptedAction(B, { action = "emote", name = "question" })
  mgr:advanceScriptedAction(A, 1, MovementCalibration.EMOTE_TICKS)
  mgr:advanceScriptedAction(B, 1, MovementCalibration.EMOTE_TICKS)

  Assert.equal(drawRecordFor(mgr, A).activeEmoteKind, "exclamation", "actor A shows only its own emote")
  Assert.equal(drawRecordFor(mgr, B).activeEmoteKind, "question", "actor B shows only its own emote")

  -- Removing B mid-emote (a flag-driven disappearance, exactly like the
  -- friend/Marill hide flags) must drop its effect within that same
  -- lifecycle boundary and must never bleed into A's independent state.
  eventState:setFlag(401)
  mgr:step(1)
  Assert.isNil(mgr:getById(B), "actor B must be gone once its flag is set")
  Assert.equal(drawRecordFor(mgr, A).activeEmoteKind, "exclamation", "the unaffected actor keeps its own emote")

  -- A later actor instance reusing B's local object id must never inherit
  -- the removed instance's stale emote.
  eventState:clearFlag(401)
  mgr:step(2)
  local recreated = assert(mgr:getById(B), "actor B must be recreated once its flag clears")
  Assert.isNil(recreated.activeEmoteKind, "a recreated actor must start with no active emote")
  Assert.isNil(drawRecordFor(mgr, B).activeEmoteKind, "the recreated actor's draw record carries no stale emote")

  mgr:commitScriptedAction(A)
end

return { tests = T }
