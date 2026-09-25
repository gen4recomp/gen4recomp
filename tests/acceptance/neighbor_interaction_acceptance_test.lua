-- Production-composed interaction smoke scenarios. Detailed neighboring
-- ownership cases live in the resolver and runtime component suites.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "map:60" },
    tags = { "field", "interaction", "collision", "neighbor" },
  },
  tests = {},
}

local function withTown(fn)
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness:boot({ versionId = versionId, map = "MAP_NEW_BARK", save = "fresh" })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "neighbor interaction must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.resident_logical_world_supports_the_real_action_path()
  withTown(function(game)
    local runtime = game.runtime
    local residency = assert(runtime.residency, "production logical residency is required")
    local status = residency:status()
    Assert.isTrue(#status.residentMapIds > 1, "outdoor boot must publish the logical ready footprint")
    local before = status.synchronousLogicalFallbackLoads
    for _, mapId in ipairs(status.residentMapIds) do
      Assert.notNil(residency:mapForId(mapId), "every published logical map must be borrowed by identity")
    end
    game:moveTo({ fieldX = 683, fieldZ = 400 })
    game:face("north")
    local blocked = game:moveUntilBlocked("north")
    Assert.deepEqual(
      { blocked.player.fieldX, blocked.player.fieldZ },
      { 683, 400 },
      "the solid neighboring actor must remain outside the player's committed position"
    )
    game:pressAction()
    local interaction = game:interaction()
    Assert.equal(interaction.kind, "object")
    Assert.isTrue(
      type(interaction.actorId) == "string" and interaction.actorId:match("^map:60:object:%d+$") ~= nil,
      "Action must resolve the resident map's real object identity"
    )
    local actor = assert(game:actor(interaction.actorId), "the interacted object must remain a live actor")
    Assert.equal(
      game:snapshot().occupancy[actor.fieldX .. ":" .. actor.fieldZ],
      interaction.actorId,
      "interaction and the production occupancy view must identify the same actor"
    )
    local occupant = assert(
      runtime.actors:getAt(runtime.runtimeMap.mapId, {
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        surfaceId = actor.surfaceId,
      }),
      "the interacted actor must be present in the committed occupancy index"
    )
    Assert.equal(occupant.actorId, interaction.actorId, "committed occupancy must resolve the interacted actor")
    Assert.equal(
      residency:status().synchronousLogicalFallbackLoads,
      before,
      "Action must not perform a logical preflight load"
    )
  end)
end

return T
