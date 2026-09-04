-- Committed player anchors: one movement revision per committed tile step,
-- never for interpolation ticks, turns, or blocked input. The following
-- controller replays these anchors, so phantom revisions would walk the
-- partner into walls.

local Assert = require("tests.support.Assert")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local function terrain()
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

local function playerAt(fieldX, fieldZ, facing)
  local map = {
    mapId = 61,
    mapSymbol = "test-map",
    mapSection = "test-section",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = {},
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function(_, x, z)
        return x == 0 and z == 1
      end,
      getLocal = function(_, x, z)
        return { blocked = x == 0 and z == 1, behavior = 0 }
      end,
    },
    terrain = terrain(),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
  return FieldPlayer.new({
    currentMap = map,
    fieldX = fieldX or 5,
    fieldZ = fieldZ or 5,
    surfaceId = 0,
    facing = facing or "south",
  })
end

local function settle(player)
  for _ = 1, 16 do
    if player.motion == "idle" then
      return
    end
    player:updateFixed({})
  end
  Assert.equal(player.motion, "idle", "the step must settle within its duration")
end

function T.committed_steps_bump_the_revision_once_each()
  local player = playerAt(5, 5, "south")
  Assert.equal(player:movementRevision(), 0, "a fresh player has committed nothing")
  local first = player:committedAnchor()
  Assert.equal(first.fieldX, 5, "the anchor starts on the player tile")
  Assert.equal(first.fieldZ, 5, "the anchor starts on the player tile")
  Assert.equal(first.facing, "south", "the anchor carries the player facing")
  Assert.equal(first.mapId, 61, "the anchor carries the map identity")
  Assert.isTrue(first.surfaceId ~= nil, "the anchor carries a surface identity")
  Assert.isTrue(first.worldY ~= nil, "the anchor carries a height")

  Assert.isTrue(player:tryStep("south"), "the south step must commit")
  settle(player)
  Assert.equal(player:movementRevision(), 1, "one committed tile is one revision")
  local second = player:committedAnchor()
  Assert.equal(second.fieldX, 5, "the anchor follows the commit")
  Assert.equal(second.fieldZ, 6, "the anchor follows the commit")

  Assert.isTrue(player:tryStep("south"), "the second step must commit")
  settle(player)
  Assert.equal(player:movementRevision(), 2, "each committed tile bumps once")
end

function T.interpolation_turns_and_blocked_input_bump_nothing()
  local player = playerAt(5, 5, "south")
  Assert.isTrue(player:tryStep("south"), "the step must start")
  Assert.equal(player:movementRevision(), 0, "starting a step commits nothing")
  player:updateFixed({})
  player:updateFixed({})
  Assert.equal(player:movementRevision(), 0, "interpolation ticks commit nothing")
  settle(player)
  Assert.equal(player:movementRevision(), 1, "only the commit bumps")

  -- A turn in place faces north without moving.
  player:updateFixed({ pressedDirection = "north" })
  settle(player)
  Assert.equal(player:movementRevision(), 1, "turning in place commits no tile")
  Assert.equal(player:committedAnchor().facing, "north", "the anchor still tracks facing")

  -- West from (5,6) is open; walk back then face the wall tile at local
  -- (0,1)... instead probe a directly blocked step: teleport-free check via
  -- a second player facing the blocked cell.
  local blocked = playerAt(1, 1, "west")
  Assert.isFalse(blocked:tryStep("west"), "the wall step must not start")
  Assert.equal(blocked:movementRevision(), 0, "blocked input commits nothing")
end

function T.scripted_commits_carry_their_own_traversal_kind()
  local player = playerAt(5, 5, "south")
  player:beginScriptedAction({ action = "walk", direction = "south", speed = "normal" })
  for _ = 1, 8 do
    player:advanceScriptedAction(1, 8)
  end
  player:commitScriptedAction()
  Assert.equal(player:movementRevision(), 1, "a scripted tile commit bumps once")
  Assert.equal(player:committedAnchor().traversalKind, "scripted", "scripted commits are marked")
  Assert.equal(player:committedAnchor().fieldZ, 6, "the anchor follows the scripted commit")
end

return { tests = T }
