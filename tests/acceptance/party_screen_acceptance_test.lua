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
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

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
  local position = assert(status.selectedPosition, "menu status must expose the selected position")
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

local function wideTopology()
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    role = "world",
    touch = true,
  })
end

local function nativeTopology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function withWideGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      viewportWidth = 1280,
      viewportHeight = 720,
      screenTopology = wideTopology(),
    },
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

local function partyView(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(
    status.phase,
    FieldApplicationHost.PHASES.application,
    "the party application must own the tick while browsing"
  )
  Assert.equal(status.applicationId, PARTY_APPLICATION, "the launched application must be the party screen")
  return assert(status.application, "the party application must expose its browse status")
end

local function pressKey(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

local function pressCancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
  game:step()
end

local function tapAt(game, x, y)
  game.runtime.input:pointerDown("acceptance:party:pointer", x, y)
  game:step()
  game.runtime.input:pointerUp("acceptance:party:pointer", x, y)
  game:step()
end

local function interactivePlacement(plan)
  for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes")) do
    if pane.interactive then
      return assert(pane.placement, "the interactive pane must carry its placement")
    end
  end
  error("the party plan must carry one interactive pane", 0)
end

local function hostPoint(placement, logicalX, logicalY)
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
  assert(hostX ~= nil and hostY ~= nil, "the tapped logical point must be visible")
  return hostX, hostY
end

-- One static framed journey through the compact grid: keyboard navigation
-- follows the visible two-column neighbors onto cancel and back, a body
-- tap selects through the same plan, the outer frame never moves between
-- equivalent resolves, a keyboard switch reorders exactly once, a
-- native-like reflow preserves the selection, and cancel closes back to
-- the field.
function T.tests.party_grid_static_frame_and_reflow_journey_preserves_semantics()
  withWideGame(function(game)
    local state = hostCallbacks(game)
    giveStarterPair(game)
    local service = assert(game.runtime.monService, "field runtime owns the live mon service")
    local revision = service:partyRevision()

    openStartMenu(game)
    navigateTo(game, state, POKEMON_ACTION)
    confirm(game)
    game:advanceUntil("party application launches through the host fade", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.application
    end, 120)

    local view = partyView(game)
    local plan = assert(view.presentation, "the open party must publish its presentation plan")
    Assert.equal(#plan.panes, 1, "the party plan carries its single content pane")
    Assert.isTrue(type(plan.inputKey) == "string", "the party plan names its input geometry")
    local inputKey = plan.inputKey
    local placement = interactivePlacement(plan)
    local frames = assert(plan.frames, "a wide host must frame the party")
    Assert.equal(#frames, 1, "a wide host frames the party in one static box")
    local pixelScale = placement.pixelScale
    Assert.isTrue(
      type(pixelScale) == "number" and pixelScale >= 1 and pixelScale % 1 == 0,
      "the framed body keeps an integral pixel scale"
    )
    Assert.equal(view.cursorNode, 0, "the remembered selection opens on the lead slot")

    -- Keyboard navigation follows the visible grid: down skips the empty
    -- middle and bottom rows onto cancel, up returns through the column.
    pressKey(game, state, "s")
    Assert.equal(partyView(game).cursorNode, "cancel", "down from the lead reaches cancel")
    pressKey(game, state, "w")
    Assert.equal(partyView(game).cursorNode, 0, "up from cancel returns to the lead")
    pressKey(game, state, "d")
    Assert.equal(partyView(game).cursorNode, 1, "right moves within the top row")
    pressKey(game, state, "a")
    Assert.equal(partyView(game).cursorNode, 0, "left moves within the top row")

    -- A body tap on the second card selects through the same plan and
    -- opens the action choice, dismissed back to browsing.
    local tapX, tapY = hostPoint(interactivePlacement(partyView(game).presentation), 191, 30)
    tapAt(game, tapX, tapY)
    Assert.equal(partyView(game).cursorNode, 1, "a tap on the second card selects it")
    Assert.equal(partyView(game).action, "action_choice", "a tap opens the action choice")
    pressCancel(game)
    Assert.equal(partyView(game).action, "browsing", "cancel dismisses the action choice")

    -- The outer frame never moves between equivalent resolves: rereading
    -- the live plan after a tick resolves the identical static box with
    -- no selection, scale, or order side effects.
    local outerBefore = assert(partyView(game).presentation.frames, "the plan keeps its frame")[1].placement.frame
    game:step()
    local restated = partyView(game)
    local outerAfter = assert(restated.presentation.frames, "the plan keeps its frame")[1].placement.frame
    Assert.deepEqual(
      { x = outerAfter.x, y = outerAfter.y },
      { x = outerBefore.x, y = outerBefore.y },
      "an equivalent resolve never moves the static frame"
    )
    Assert.equal(restated.cursorNode, 1, "a static re-resolve never moves the selection")
    Assert.equal(
      interactivePlacement(restated.presentation).pixelScale,
      pixelScale,
      "a static re-resolve never changes the pixel scale"
    )
    Assert.equal(service:partyRevision(), revision, "a static re-resolve never swaps")
    local safe = game.runtime.screenTopology.surfaces[1].safeRect
    Assert.isTrue(
      outerAfter.x >= safe.x
        and outerAfter.y >= safe.y
        and outerAfter.x + outerAfter.width <= safe.x + safe.width
        and outerAfter.y + outerAfter.height <= safe.y + safe.height,
      "the static frame stays in the usable bounds"
    )

    -- A keyboard switch reorders the live party exactly once: choice,
    -- switch start, step right, confirm.
    pressKey(game, state, "a")
    Assert.equal(partyView(game).cursorNode, 0, "left returns to the lead before the switch")
    confirm(game)
    Assert.equal(partyView(game).action, "action_choice", "confirm opens the action choice")
    confirm(game)
    Assert.equal(partyView(game).action, "switch_destination", "confirm starts the switch")
    pressKey(game, state, "d")
    Assert.equal(partyView(game).cursorNode, 1, "right selects the switch destination")
    confirm(game)
    Assert.equal(service:partyRevision(), revision + 1, "the screen switch bumps the revision exactly once")
    Assert.deepEqual(
      partyOrder(game),
      { "CYNDAQUIL", "CHIKORITA" },
      "the switch reorders the live party through the service"
    )
    Assert.equal(partyView(game).cursorNode, 1, "the switch lands on the destination slot")

    -- A native-like reflow preserves the active selection and order
    -- while the underfilled plan keeps its static frame.
    game.runtime:resizePresentation(640, 480, nativeTopology(640, 480))
    game:step()
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "a reflow must keep the party application open"
    )
    local reflowed = partyView(game)
    Assert.equal(reflowed.cursorNode, 1, "a reflow preserves the active selection")
    Assert.deepEqual(partyOrder(game), { "CYNDAQUIL", "CHIKORITA" }, "a reflow preserves the party order")
    Assert.equal(
      #assert(reflowed.presentation.frames, "the underfilled native party keeps its static frame"),
      1,
      "the native-like plan keeps its one outer frame"
    )
    Assert.equal(reflowed.presentation.inputKey, inputKey, "a reflow keeps the input geometry")

    -- Down onto cancel and confirm closes back through the menu to the
    -- unchanged field session with the reorder intact.
    pressKey(game, state, "s")
    Assert.equal(partyView(game).cursorNode, "cancel", "down reaches cancel before closing")
    confirm(game)
    game:advanceUntil("party screen closes without choosing", function()
      local phase = hostPhase(game)
      return phase == FieldApplicationHost.PHASES.menu or phase == FieldApplicationHost.PHASES.closed
    end, 120)
    closeStartMenu(game)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.closed, "the journey ends back on the field")
    Assert.deepEqual(partyOrder(game), { "CYNDAQUIL", "CHIKORITA" }, "closing preserves the switched order")
  end)
end

return T
