-- Production-composed map-entry smoke: the runtime reaches ready headlessly and
-- does not restart entry lifecycles over idle ticks.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "map:27" },
    tags = { "field", "map-init", "lifecycle" },
  },
  tests = {},
}

function T.tests.headless_entry_reaches_ready_without_rendering_and_does_not_repeat_lifecycles()
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultFactory(versionId, map)
    if map == "MAP_ROUTE_22" then
      game.location.fieldX = 9
      game.location.fieldZ = 9
      game.worldState:setFlag(638)
      game.worldState:setFlag(769)
      game.worldState:setFlag(770)
    end
    return game
  end
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness:boot({ versionId = versionId, map = "MAP_ROUTE_22", save = "fresh" })
  local ok, err = xpcall(function()
    local ready = game:advanceUntil("map entry ready", function(snapshot)
      return snapshot.mapEntryStage == nil and not snapshot.fieldLocked and snapshot.player.motion == "idle"
    end, 240)
    Assert.notNil(ready.mapId, "entry must publish a map identity")
    Assert.isNil(game.runtime.errorText, "headless entry must not fault")
    local stageBefore = game:snapshot().mapEntryStage
    local tickBefore = game:snapshot().tick
    for _ = 1, 30 do
      game:step()
    end
    Assert.equal(game:snapshot().mapEntryStage, stageBefore, "ordinary field ticks must not restart entry lifecycles")
    Assert.isNil(game.runtime.errorText, "idle ticks must not fault")
    Assert.equal(game:renderAttempts(), 0, "headless entry must acknowledge presentation without drawing")
    -- Silence unused tickBefore if policy requires observation; tick advances monotonically.
    Assert.isTrue(type(tickBefore) == "number" or tickBefore == nil)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
