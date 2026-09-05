-- Interaction facing physical-only filler: pressing Action toward a
-- reachable header-0 EVERYWHERE cell must resolve the interaction in the
-- current logical map. It must not call mapForId(0) or mapForPreflight(0),
-- and a tile with no event remains a clean miss rather than an assertion.
--
-- Placement: Cherrygrove's west-edge tile (512,397) faces filler cell
-- (15,12) across a reachable surface. New Bark's own filler-adjacent rows
-- are fully blocked, the east crossing out of New Bark is untraversable,
-- Route 29 has no walkable filler adjacency, and Route 27's filler-adjacent
-- row sits in a region unreachable on foot -- this is the only live
-- filler-adjacent tile found in the SoulSilver corpus window. The boot uses
-- a local spawn on that tile because the harness default spawn belongs to
-- New Bark.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "interaction", "zone" },
  },
  tests = {},
}

local PLAYER_X = 512
local PLAYER_Z = 397
local EXPECTED_MAP_ID = 67

function T.tests.action_facing_filler_stays_in_the_current_logical_map()
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = {
          mapSymbol = map or "MAP_CHERRYGROVE",
          fieldX = 0,
          fieldZ = 13,
          facing = "south",
        },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
      }
    end,
  })
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness:boot({ versionId = versionId, map = "MAP_CHERRYGROVE", save = "fresh" })
  local ok, err = xpcall(function()
    -- Settle map entry so the current map owns a live actor entry: the
    -- occupancy assertion below requires live current-map lookup.
    game:waitForFieldEntry()
    local runtime = game.runtime
    local snapshot = game:snapshot()
    Assert.equal(snapshot.player.fieldX, PLAYER_X)
    Assert.equal(snapshot.player.fieldZ, PLAYER_Z)
    Assert.equal(snapshot.mapId, EXPECTED_MAP_ID)

    local coverage = assert(runtime.runtimeMap.coverage, "outdoor boot owns physical coverage")
    local facingHeader = coverage:mapHeaderAt(PLAYER_X - 1, PLAYER_Z)
    Assert.equal(facingHeader, 0, "the faced tile is raw EVERYWHERE filler")

    local residency = assert(runtime.residency, "production logical residency is required")
    local residencyCalls = {}
    local originalForId = residency.mapForId
    local originalPreflight = residency.mapForPreflight
    function residency:mapForId(mapId)
      residencyCalls[#residencyCalls + 1] = "mapForId:" .. tostring(mapId)
      return originalForId(self, mapId)
    end
    function residency:mapForPreflight(mapId)
      residencyCalls[#residencyCalls + 1] = "mapForPreflight:" .. tostring(mapId)
      return originalPreflight(self, mapId)
    end
    local actorLookups = {}
    local actors = assert(runtime.actors, "production actor manager is required")
    local originalGetAt = actors.getAt
    actors.getAt = function(self, mapId, candidate)
      actorLookups[#actorLookups + 1] = mapId
      return originalGetAt(self, mapId, candidate)
    end

    game:face("west")
    local zoneBefore = runtime.lastZoneChange
    local actionCalls = #residencyCalls
    local okAction, actionErr = pcall(function()
      game:pressAction()
    end)
    actors.getAt = originalGetAt
    residency.mapForId = originalForId
    residency.mapForPreflight = originalPreflight
    Assert.isTrue(
      okAction,
      "Action facing reachable filler must not raise a logical-map lookup: " .. tostring(actionErr)
    )

    for index = actionCalls + 1, #residencyCalls do
      Assert.isFalse(
        residencyCalls[index] == "mapForId:0" or residencyCalls[index] == "mapForPreflight:0",
        "Action facing filler must not look up logical map 0, saw: " .. residencyCalls[index]
      )
    end
    Assert.isTrue(#actorLookups > 0, "the interaction lookup still consults actor occupancy")
    for _, mapId in ipairs(actorLookups) do
      Assert.equal(mapId, EXPECTED_MAP_ID, "the filler interaction is owned by the current logical map")
    end
    local interaction = game:interaction()
    Assert.isNil(interaction.kind, "a filler tile with no event is a clean miss, not an assertion")
    local after = game:snapshot()
    Assert.equal(after.mapId, EXPECTED_MAP_ID, "facing filler changes no zone")
    Assert.equal(runtime.lastZoneChange, zoneBefore, "no zone-change callback fires for filler")
    Assert.equal(game:renderAttempts(), 0, "filler interaction stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
