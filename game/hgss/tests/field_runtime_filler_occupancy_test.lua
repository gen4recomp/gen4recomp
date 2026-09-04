-- Dynamic occupancy over physical-only filler must stay in the current
-- logical map: probing a movement candidate on a header-0 cell performs no
-- actor-map lookup for map 0. A residency double that fails on any map-0
-- logical access makes reintroducing raw mapHeaderAt() as an actor-map id a
-- loud failure instead of a silent wrong-map probe.

local Assert = require("tests.support.Assert")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local CURRENT_MAP_ID = 60
local EVERYWHERE_HEADER = 0

local function assets()
  local provider = {
    acquired = 0,
    knows = function()
      return true
    end,
    acquire = function(self, spriteId)
      self.acquired = self.acquired + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId), references = 1 }
    end,
    release = function(self, _)
      self.acquired = self.acquired - 1
    end,
  }
  return provider
end

function T.filler_candidate_keeps_actor_lookup_in_the_current_logical_map()
  local source = {
    mapId = CURRENT_MAP_ID,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    mapSymbol = "source",
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, fieldX, fieldZ)
        return fieldX >= 0 and fieldX < 32 and fieldZ >= 0 and fieldZ < 32
      end,
    },
    terrain = TerrainSurface.new({
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
    }),
    fieldData = { events = { objects = {} } },
    scene = {},
    cameraType = 4,
    release = function() end,
    updateAnimated = function() end,
  } ---@as RuntimeFieldMap
  local coverage = {}
  function coverage:mapHeaderAt(fieldX, fieldZ)
    Assert.equal(fieldX, 1)
    Assert.equal(fieldZ, 0)
    return EVERYWHERE_HEADER
  end
  source.coverage = coverage

  local eventState = FieldEventState.new()
  local assetProvider = assets()
  local actors = FieldActorManager.new({
    assets = assetProvider,
    policy = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } },
  })
  actors:enterMap(source, eventState)

  local residencyCalls = {}
  local residency = {}
  function residency:mapForId(mapId)
    residencyCalls[#residencyCalls + 1] = "mapForId:" .. tostring(mapId)
    error("actor occupancy must not resolve logical map " .. tostring(mapId), 0)
  end
  function residency:mapForPreflight(mapId)
    residencyCalls[#residencyCalls + 1] = "mapForPreflight:" .. tostring(mapId)
    error("actor occupancy must not preflight logical map " .. tostring(mapId), 0)
  end

  local runtime = setmetatable({
    runtimeMap = source,
    actors = actors,
    eventState = eventState,
    residency = residency,
    zoneController = {},
  }, FieldRuntime)

  local lookups = {}
  local originalGetCollisionAt = actors.getCollisionAt
  actors.getCollisionAt = function(self, mapId, candidate)
    lookups[#lookups + 1] = mapId
    return originalGetCollisionAt(self, mapId, candidate)
  end

  local ok, occupant = pcall(function()
    return runtime:_playerOccupantAt({ fieldX = 1, fieldZ = 0, surfaceId = 0 })
  end)
  actors.getCollisionAt = originalGetCollisionAt
  if not ok then
    actors:dispose()
  end
  Assert.isTrue(ok, "a filler occupancy probe must not touch logical map 0: " .. tostring(occupant))
  Assert.isNil(occupant, "an empty filler tile has no occupant")
  Assert.deepEqual(residencyCalls, {}, "no mapForId(0) or mapForPreflight(0) occurs")
  Assert.deepEqual(lookups, { CURRENT_MAP_ID }, "actor collision lookup remains in the current logical map")
  Assert.equal(assetProvider.acquired, 0, "the filler probe acquires no actor visuals")
  actors:dispose()
end

return { metadata = { capabilities = {} }, tests = T }
