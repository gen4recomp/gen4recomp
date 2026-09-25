-- Fresh House 2F actor-lock handoff regression. The shared harness supplies the
-- real generated cache and boots directly into Player House 2F.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "map:63", "map:64" },
    tags = { "field", "hgss", "composition" },
  },
  tests = {},
}

local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"

local function withFreshHouse2F(fn)
  local harness = AcceptanceHarness.new()
  local defaultGameFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultGameFactory(versionId, map)
    game.location.fieldX = 3
    game.location.fieldZ = 4
    return game
  end
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness:boot({
    versionId = versionId,
    map = HOUSE_2F,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "fresh downstairs acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.fresh_player_house_downstairs_step_does_not_fault_actor_lock_handoff()
  withFreshHouse2F(function(game)
    local start = game:waitForFieldReady()
    Assert.equal(start.mapSymbol, HOUSE_2F)

    game:step({ direction = "west" })
    local transition = game:waitForTransition()

    Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
    game:waitForFieldReady()
    Assert.isNil(game.runtime.errorText, "fresh downstairs movement must not fault the actor lock query")
    Assert.equal(game:snapshot().mapSymbol, HOUSE_1F)
  end)
end

function T.tests.production_field_composition_survives_transition_restart_and_teardown()
  local harness = AcceptanceHarness.new()
  local defaultGameFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultGameFactory(versionId, map)
    game.location.fieldX = 3
    game.location.fieldZ = 4
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = HOUSE_2F,
    save = "fresh",
  })

  local ok, err = xpcall(function()
    local start = game:waitForFieldReady()
    Assert.equal(start.mapSymbol, HOUSE_2F)

    game:step({ direction = "west" })
    local transition = game:waitForTransition()
    Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
    local destination = game:waitForFieldReady()
    Assert.equal(destination.mapSymbol, HOUSE_1F)
    Assert.isNil(game.runtime.errorText, "the composed field must remain healthy after the transition")

    local saved = assert(game.runtime:captureGameSave(), "a settled destination must be a save boundary")
    Assert.equal(saved.mapId, game.runtime.runtimeMap.mapId)
    Assert.equal(saved.fieldX, destination.player.fieldX)
    Assert.equal(saved.fieldZ, destination.player.fieldZ)

    game:restart()
    local resumed = game:waitForFieldReady()
    Assert.equal(resumed.mapSymbol, HOUSE_1F)
    Assert.deepEqual(
      { resumed.player.fieldX, resumed.player.fieldZ },
      { destination.player.fieldX, destination.player.fieldZ },
      "recomposing the field must retain the settled player boundary"
    )
    Assert.equal(game.lifecycle.runtimeDisposals, 1, "replacement must dispose the previous runtime once")
    Assert.equal(game:renderAttempts(), 0, "the production-composed journey must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.equal(game.lifecycle.runtimeDisposals, 2, "closing the recomposed field must dispose the live runtime once")
end

return T
