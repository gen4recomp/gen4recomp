-- Walk-in-place presentation: proves the render-only vertical bob a
-- walk-on-spot action must expose without ever moving the actor's logical
-- coordinates, observed through the same drawRecords() a production renderer
-- consumes (see FieldActorManager:drawRecords).

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local POLICY = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } }
local ACTOR_ID = "map:61:object:0"

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

local function drawnY(mgr)
  for _, record in ipairs(mgr:drawRecords()) do
    if record.actorId == ACTOR_ID then
      return record.world.y
    end
  end
  error("actor " .. ACTOR_ID .. " has no draw record")
end

function T.walk_in_place_keeps_logical_coordinates_and_visibly_bobs_in_presentation_only()
  local mgr = FieldActorManager.new({ assets = fakeAssets, policy = POLICY })
  mgr:enterMap(
    map({
      {
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
      },
    }),
    FieldEventState.new()
  )
  local actor = assert(mgr:getById(ACTOR_ID))
  local baseFieldX, baseFieldZ, baseWorldY =
    actor:getFieldPosition().fieldX, actor:getFieldPosition().fieldZ, assert(actor:getWorldPosition().y)

  mgr:beginScriptedAction(ACTOR_ID, { action = "walk_in_place", direction = "south", speed = "normal" })
  local duration = 8 -- MovementCalibration.WALK_IN_PLACE_TICKS.normal
  local renderYs = {}
  for tick = 1, duration do
    mgr:advanceScriptedAction(ACTOR_ID, tick, duration)
    Assert.equal(actor:getFieldPosition().fieldX, baseFieldX, "walk_in_place must never change logical fieldX")
    Assert.equal(actor:getFieldPosition().fieldZ, baseFieldZ, "walk_in_place must never change logical fieldZ")
    local renderY = drawnY(mgr)
    Assert.equal(drawnY(mgr), renderY, "repeated renders within one fixed tick must be identical")
    renderYs[#renderYs + 1] = renderY
  end
  mgr:commitScriptedAction(ACTOR_ID)

  local distinct = {}
  for _, y in ipairs(renderYs) do
    distinct[y] = true
  end
  local distinctCount = 0
  for _ in pairs(distinct) do
    distinctCount = distinctCount + 1
  end
  Assert.isTrue(distinctCount >= 2, "a full walk-in-place cycle must render at least two distinct Y positions")
  Assert.near(
    renderYs[#renderYs],
    baseWorldY,
    1e-9,
    "the presentation offset returns to the base position at the action boundary"
  )
  Assert.equal(
    actor:getWorldPosition().y,
    baseWorldY,
    "the committed/logical world height never changes for walk_in_place"
  )
end

return { tests = T }
