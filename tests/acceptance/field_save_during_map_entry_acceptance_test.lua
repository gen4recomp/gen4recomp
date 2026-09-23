-- Production-composed save eligibility at the transient map-entry boundary.

local Assert = require("tests.support.Assert")
local GameSave = require("libs.hgss.src.save.GameSave")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "save", "map-entry" },
  },
  tests = {},
}

function T.tests.active_map_entry_rejects_save_until_the_field_entry_settles()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_NEW_BARK",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    Assert.isTrue(runtime.session.mapEntryController:isActive(), "fresh field entry is active at boot")
    local entryStage = runtime.session.mapEntryStage
    local timelineLength = #game.timeline

    local rejected, reason = runtime:captureGameSave()
    Assert.isNil(rejected, "an active map entry cannot produce a field save")
    Assert.isTrue(type(reason) == "string" and reason ~= "", "rejection explains the unstable save boundary")
    Assert.equal(runtime.session.mapEntryStage, entryStage, "save eligibility does not advance field entry")
    Assert.equal(#game.timeline, timelineLength, "save eligibility does not run a field tick")

    game:waitForFieldEntry()
    Assert.isFalse(runtime.session.mapEntryController:isActive(), "field entry reaches its settled state")
    local captured, captureReason = runtime:captureGameSave()
    Assert.notNil(captured, "settled field entry permits capture: " .. tostring(captureReason))
    Assert.notNil(GameSave.validate(captured), "settled capture is a valid game save")
    Assert.equal(game:renderAttempts(), 0, "save acceptance stops before GPU rendering")
  end, debug.traceback)
  local closeOk, closeErr = pcall(function()
    game:close()
  end)
  if ok and not closeOk then
    ok, err = false, closeErr
  end
  if not ok then
    error(err, 0)
  end
end

return T
