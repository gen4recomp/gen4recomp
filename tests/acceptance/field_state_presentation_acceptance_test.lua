-- Production-composed FieldState presentation lifecycle characterization.
-- The suite intentionally stops before draw submission: FieldState construction
-- itself owns real LÖVE presentation resources, while the shared acceptance
-- runtime supplies the real generated field/cache state.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldState = require("game.hgss.src.field.FieldState")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "field-core", "map:7" },
    tags = { "field", "presentation", "lifecycle", "last-known-good" },
  },
  tests = {},
}

-- Capture a stable game through the real non-rendering field composition first.
-- FieldState then consumes that production save boundary with presentation
-- enabled; no map, actor, or cache graph is assembled by this test.
local function stableGameRecord()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, record = xpcall(function()
    game:waitForFieldReady()
    return assert(game.runtime:captureGameSave(), "the settled field must expose a save boundary")
  end, debug.traceback)
  local closed, closeError = pcall(function()
    game:close()
  end)
  if not closed then
    error(closeError, 0)
  end
  if not ok then
    error(record, 0)
  end
  return record
end

local function withPresentationState(fn)
  local state
  local ok, err = xpcall(function()
    state = FieldState.new(stableGameRecord(), {})
    fn(state)
  end, debug.traceback)
  local closed, closeError = pcall(function()
    if state then
      state:dispose()
    end
  end)
  if not closed then
    error(closeError, 0)
  end
  if not ok then
    error(err, 0)
  end
end

function T.tests.real_field_state_composes_callbacks_and_releases_on_repeat_dispose()
  withPresentationState(function(state)
    Assert.notNil(state.runtime, "production FieldState construction must publish a live runtime")
    state:update(1 / 60)
    state:resize(640, 480)
    state:dispose()
    state:dispose()
  end)
end

function T.tests.failed_actor_reconciliation_keeps_the_live_state_recoverable()
  withPresentationState(function(state)
    local runtime = assert(state.runtime, "production FieldState runtime is required")
    local playerVisual = assert(runtime.playerVisual, "production player presentation is required")
    local previousSpriteId = assert(playerVisual.spriteId, "production player sprite identity is required")

    -- An unknown generated sprite is the real provider failure boundary. The
    -- valid player presentation remains selected while reconciliation fails;
    -- restoring the prior identity must let the same state continue normally.
    playerVisual.spriteId = previousSpriteId + 1000000
    local err = Assert.throws(function()
      state:update(1 / 60)
    end)
    Assert.isTrue(
      tostring(err):find("not in the compiled actor set", 1, true) ~= nil,
      "the failed reconcile must report the provider's real missing-asset error"
    )
    Assert.isTrue(state.runtime ~= nil, "a failed reconcile must not destroy the live FieldState")

    playerVisual.spriteId = previousSpriteId
    state:update(1 / 60)
    Assert.equal(
      runtime.playerVisual.spriteId,
      previousSpriteId,
      "the previous valid player presentation must remain usable after recovery"
    )
  end)
end

return T
