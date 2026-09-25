-- Production-composed warp-entrance field effect smoke.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "map:60", "map:62" },
    tags = { "field", "warp-entrance", "indicator", "asset-readiness" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local LAB_2F = "MAP_NEW_BARK_ELMS_LAB_2F"

local function withGame(map, fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the indicator contract must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function recordsNamed(game, name)
  local records = {}
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

local function entranceCell(game, behavior)
  local map = game.runtime.runtimeMap
  local origin = assert(map.coordinateOrigin, "the production map must expose a coordinate origin")
  for _, warp in ipairs(map.fieldData.events.warps) do
    local localX, localZ = warp.x - origin.x, warp.z - origin.z
    if map.collision:containsLocal(localX, localZ) then
      local cell = map.collision:getLocal(localX, localZ)
      if cell.behavior == behavior then
        return { fieldX = warp.x, fieldZ = warp.z }
      end
    end
  end
  return nil
end

local function enterLab2F(game)
  OpeningLifecycle.settleNewBarkFriendScene(game)
  FieldMovement.activate(game, { fieldX = 688, fieldZ = 392 }, "north")
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, LAB_2F)
end

local function indicatorStatus(game)
  local indicator = game.runtime.fieldEntranceIndicator
  Assert.notNil(indicator, "the production field runtime must expose the directional entrance indicator state")
  local status = indicator:status()
  Assert.notNil(status, "the production indicator must expose a presentation-neutral status")
  return status
end

T.tests["east entrance indicator tracks facing and canonical asset is composed"] = function()
  withGame(TOWN, function(game)
    enterLab2F(game)
    local asset = game.runtime.fieldEntranceIndicatorAsset
    Assert.notNil(asset, "production boot must resolve the ROM-derived entrance-effect asset")
    Assert.equal(asset.model.key, "field-effect:warp-entrance")
    Assert.notNil(asset.model.batches, "the readiness contract must expose model batches")
    Assert.notNil(asset.model.materials, "the readiness contract must expose model materials")
    Assert.equal(#recordsNamed(game, "asset.fallback_draw"), 0, "the effect must not use a synthetic fallback")

    local cell = assert(
      entranceCell(game, MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST),
      "Elm Lab 2F must expose the east entrance tile"
    )
    game:moveTo(cell)
    game.runtime.player.facing = "east"
    game:step()
    local east = indicatorStatus(game)
    Assert.isTrue(east.visible, "the east entrance indicator must be visible while facing east")
    Assert.equal(east.direction, "east")
  end)
end

return T
