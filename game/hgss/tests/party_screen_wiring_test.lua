-- Production party-screen composition contract: the runtime registers
-- the pokemon application itself, the start menu enables the vanilla
-- pokemon action only once a mon is owned, confirming it launches the
-- party screen, a switch through the screen reorders the live party
-- exactly once, and closing returns to the unchanged field session. Only
-- host boundaries (saves, render trap) are faked; maps, scripts, actors,
-- and the mon service stay production.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "menu", "party" },
  },
  tests = {},
}

local FLAG_GOT_STARTER = FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER
local POKEMON_ACTION = "vanilla.pokemon"
local PARTY_APPLICATION = "pokemon"

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "party wiring must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function hostCallbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function hostPhase(game)
  return game.runtime.applicationHost:status().phase
end

local function openStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  return game:advanceUntil("start menu becomes modal", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 120)
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the start menu must own the tick")
  return assert(status.menu, "the menu phase must expose the controller status")
end

local function actionById(status, id)
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.id == id then
      return action
    end
  end
  return nil
end

local function cursorActionId(status)
  local position = assert(status.cursorSlotId, "menu status must expose the cursor slot") - 2
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.position == position then
      return action.id
    end
  end
  error("start menu cursor does not resolve to a visible action", 0)
end

local function navigateTo(game, state, id)
  for _ = 1, #menuStatus(game).actions + 1 do
    if cursorActionId(menuStatus(game)) == id then
      return
    end
    state:keypressed("s")
    game:step()
    state:keyreleased("s")
  end
  error("start menu never focuses the party action", 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function cancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function advanceToPhase(game, phase, message)
  game:advanceUntil(message or ("host reaches " .. phase), function()
    return hostPhase(game) == phase
  end, 180)
end

local function givePair(game)
  game:setWorldState({ flag = FLAG_GOT_STARTER })
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  Assert.isTrue(service:giveMon({ species = "CHIKORITA", level = 5 }), "setup gift must enter the party")
  Assert.isTrue(service:giveMon({ species = "CYNDAQUIL", level = 5 }), "setup gift must enter the party")
end

local function partyOrder(game)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  local order = {}
  for slot = 0, service:partyCount() - 1 do
    order[#order + 1] = service:partyMon(slot).species
  end
  return order
end

-- The runtime registers the party application itself; the action stays
-- unusable while the party is empty and enables once a mon is owned.
function T.tests.production_registers_the_party_application_and_gates_the_action()
  withGame(function(game)
    Assert.isTrue(
      game.runtime.applications:has(PARTY_APPLICATION),
      "the production runtime registers the party application itself"
    )
    openStartMenu(game)
    local emptyAction = actionById(menuStatus(game), POKEMON_ACTION)
    Assert.isTrue(emptyAction == nil or emptyAction.enabled == false, "an empty party offers no usable party route")
    cancel(game)
    advanceToPhase(game, FieldApplicationHost.PHASES.closed, "the start menu closes")
    -- The starter flag alone still offers no route: only an owned mon does.
    game:setWorldState({ flag = FLAG_GOT_STARTER })
    openStartMenu(game)
    local flaggedAction = actionById(menuStatus(game), POKEMON_ACTION)
    Assert.isTrue(
      flaggedAction ~= nil and flaggedAction.enabled == false,
      "the starter flag without a mon leaves the party action disabled"
    )
    cancel(game)
    advanceToPhase(game, FieldApplicationHost.PHASES.closed, "the start menu closes")
    givePair(game)
    openStartMenu(game)
    local action = actionById(menuStatus(game), POKEMON_ACTION)
    Assert.isTrue(action ~= nil and action.enabled == true, "an owned party enables the party action")
  end)
end

-- A switch through the screen reorders once through the service, then
-- closing returns to the same field session without rebuilding runtime.
function T.tests.switch_through_the_screen_reorders_once_and_returns_to_field()
  withGame(function(game)
    local state = hostCallbacks(game)
    givePair(game)
    local before = game:snapshot()
    local service = assert(game.runtime.monService, "field runtime owns the live mon service")
    local revision = service:partyRevision()

    openStartMenu(game)
    navigateTo(game, state, POKEMON_ACTION)
    confirm(game)
    advanceToPhase(game, FieldApplicationHost.PHASES.application, "confirming party launches its application")
    local status = game.runtime.applicationHost:status()
    Assert.equal(status.applicationId, PARTY_APPLICATION)

    -- Slot 0 is under the cursor: confirm opens the action choice,
    -- confirm again starts the switch, down moves to slot 1, confirm swaps.
    confirm(game)
    confirm(game)
    state:keypressed("s")
    game:step()
    state:keyreleased("s")
    confirm(game)
    Assert.equal(service:partyRevision(), revision + 1, "the screen switch bumps the revision exactly once")
    Assert.deepEqual(
      partyOrder(game),
      { "CYNDAQUIL", "CHIKORITA" },
      "the switch reorders the live party through the service"
    )

    cancel(game)
    advanceToPhase(game, FieldApplicationHost.PHASES.menu, "closing the screen returns to the start menu")
    cancel(game)
    advanceToPhase(game, FieldApplicationHost.PHASES.closed, "closing the menu returns to the field")
    local after = game:snapshot()
    Assert.equal(after.mapId, before.mapId, "the round trip keeps the same map")
    Assert.equal(after.player.fieldX, before.player.fieldX, "the round trip keeps the player position")
    Assert.equal(after.player.fieldZ, before.player.fieldZ, "the round trip keeps the player position")
    Assert.deepEqual(partyOrder(game), { "CYNDAQUIL", "CHIKORITA" }, "the reorder survives the return")
  end)
end

return T
