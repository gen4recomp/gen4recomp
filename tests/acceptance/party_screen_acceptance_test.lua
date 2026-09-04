-- Production-composed party-screen contracts. A real field runtime owns the
-- live party: the start menu must offer the party route once a mon is owned,
-- the same screen must reorder through the service exactly once, cancel
-- paths must stay inert, and quit-save must persist the reorder without
-- recording screen state. Only host boundaries (saves, render trap) are
-- faked; maps, scripts, actors, and the mon service stay production.

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
    Assert.equal(game:renderAttempts(), 0, "party acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The same FieldState callbacks LÖVE dispatches in production. No synthetic
-- input behavior of its own.
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

local function grantStarter(game)
  game:setWorldState({ flag = FLAG_GOT_STARTER })
end

local function giveStarterPair(game)
  grantStarter(game)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  Assert.isTrue(
    service:giveMon({ species = "CHIKORITA", level = 5 }),
    "setup gift must enter the party through the production service"
  )
  Assert.isTrue(
    service:giveMon({ species = "CYNDAQUIL", level = 5 }),
    "setup gift must enter the party through the production service"
  )
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

local function closeStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("start menu closes", function(snapshot)
    return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
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
  local status = menuStatus(game)
  for _ = 1, #status.actions + 1 do
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

local function partyOrder(game)
  local service = assert(game.runtime.monService, "field runtime owns the live mon service")
  local order = {}
  for slot = 0, service:partyCount() - 1 do
    order[#order + 1] = service:partyMon(slot).species
  end
  return order
end

-- An empty party offers no usable party route, a first mon enables it, and
-- closing the menu returns to the unchanged field session.
function T.tests.start_menu_offers_party_once_owned_and_returns_to_field()
  withGame(function(game)
    local before = game:snapshot()

    openStartMenu(game)
    local emptyAction = actionById(menuStatus(game), POKEMON_ACTION)
    Assert.isTrue(
      emptyAction == nil or emptyAction.enabled == false,
      "an empty party must not offer a usable party route"
    )
    closeStartMenu(game)
    local closed = game:snapshot()
    Assert.equal(closed.mapId, before.mapId, "closing the menu must keep the same map")
    Assert.equal(closed.player.fieldX, before.player.fieldX, "closing the menu must keep the player position")
    Assert.equal(closed.player.fieldZ, before.player.fieldZ, "closing the menu must keep the player position")

    grantStarter(game)
    local service = assert(game.runtime.monService, "field runtime owns the live mon service")
    Assert.isTrue(service:giveMon({ species = "CHIKORITA", level = 5 }), "setup gift must enter the party")
    openStartMenu(game)
    local action = actionById(menuStatus(game), POKEMON_ACTION)
    local usable = action ~= nil and action.enabled == true
    Assert.isTrue(usable, "an owned party must enable the party action")
  end)
end

-- Confirming the party action launches the party application; closing it
-- without choosing leaves party order and revision untouched.
function T.tests.party_launch_and_inert_close_leave_party_untouched()
  withGame(function(game)
    local state = hostCallbacks(game)
    giveStarterPair(game)
    local service = assert(game.runtime.monService, "field runtime owns the live mon service")
    local revision = service:partyRevision()
    local order = partyOrder(game)

    openStartMenu(game)
    navigateTo(game, state, POKEMON_ACTION)
    confirm(game)
    game:advanceUntil("party application launches through the host fade", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)
    local status = game.runtime.applicationHost:status()
    Assert.equal(status.phase, FieldApplicationHost.PHASES.application, "confirming party must launch its application")
    Assert.equal(status.applicationId, PARTY_APPLICATION, "the launched application must be the party screen")

    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    game:advanceUntil("party screen closes without choosing", function()
      local phase = hostPhase(game)
      return phase == FieldApplicationHost.PHASES.menu or phase == FieldApplicationHost.PHASES.closed
    end, 120)
    Assert.equal(service:partyRevision(), revision, "an inert close must not bump the party revision")
    Assert.deepEqual(partyOrder(game), order, "an inert close must not reorder the party")
  end)
end

-- A reorder through the screen is visible immediately, survives quit-save,
-- and records no screen state in the save bucket.
function T.tests.reordered_party_persists_without_screen_state()
  withGame(function(game)
    giveStarterPair(game)
    local service = assert(game.runtime.monService, "field runtime owns the live mon service")
    service:swapPartyMons(0, 1)
    local order = partyOrder(game)
    Assert.equal(order[1], "CYNDAQUIL", "the swap must move the second mon to the lead immediately")
    Assert.equal(order[2], "CHIKORITA", "the swap must move the lead down immediately")

    local captured = assert(game.runtime:captureGameSave(), "quit-save requires a stable captured game")
    local bucket = assert(captured.mons, "the captured save must carry the mons bucket")
    Assert.equal(#bucket.party.mons, 2, "the captured bucket must carry the reordered pair")
    Assert.equal(bucket.party.mons[1].species, "CYNDAQUIL", "the captured bucket must persist the new lead")
    Assert.isTrue(bucket.view == nil and bucket.selection == nil, "the save bucket must not record screen state")

    game:restart()
    game:waitForFieldEntry()
    Assert.deepEqual(partyOrder(game), order, "reloading must restore the reordered party")
  end)
end

return T
