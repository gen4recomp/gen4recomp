-- Cross-application presentation journeys through true entrypoints. Every
-- migrated interface (Start Menu, Bag, Party, Trainer Card, Starter Choice,
-- Oak naming, Main Menu) must follow the shared display policy when its
-- host configuration changes while it is active: semantic state survives,
-- stale pointer releases never activate moved controls, hidden regions
-- never receive input, and per-case function overrides stay scoped to one
-- application and one case without leaking between instances.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local BagCache = require("libs.assets.src.BagCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local PixelScale = require("libs.ui.src.PixelScale")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RepoFs = require("game.src.RepoFs")
local SaveFs = require("libs.storage.src.SaveFs")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "product", "presentation", "integration", "topology" },
  },
  tests = {},
}

-- Shared host topology builders. Single surfaces use the production world
-- role; pairs use translated world/auxiliary regions so placement must
-- follow actual rectangles rather than origin assumptions.
local function oneDisplay(width, height, touch)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = touch == true,
  })
end

local function differentPair()
  return ScreenTopology.dualDisplay({
    id = "world",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    role = "world",
    touch = false,
  }, {
    id = "aux",
    rect = { x = 520, y = 40, width = 256, height = 192 },
    role = "auxiliary",
    touch = false,
  })
end

-- Field boots measure through an explicit topology matching the drawable so
-- later resizePresentation calls measure through the resized topology.
local function withFieldGame(options, fn)
  local bootWidth, bootHeight = love.graphics.getDimensions()
  local fieldOptions = {
    screenTopology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = bootWidth, height = bootHeight },
      touch = false,
      role = "world",
    }),
  }
  if options.presentationOverrides ~= nil then
    fieldOptions.presentationOverrides = options.presentationOverrides
  end
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = options.map or "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "presentation acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function switchDisplay(game, width, height, topology)
  game.runtime:resizePresentation(width, height, topology or oneDisplay(width, height))
  -- The published plan follows the new measurement on the next tick, not
  -- synchronously with the resize.
  game:step()
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
  error("start menu never focuses " .. id, 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function pressCancel(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function interactivePlacement(plan, what)
  for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes " .. what)) do
    if pane.interactive then
      return assert(pane.placement, "the interactive pane carries its placement " .. what)
    end
  end
  error("the plan carries no interactive pane " .. what, 0)
end

local function assertInside(frame, rect, what)
  Assert.isTrue(
    frame.x >= rect.x
      and frame.y >= rect.y
      and frame.x + frame.width <= rect.x + rect.width
      and frame.y + frame.height <= rect.y + rect.height,
    what .. ": the pane frame stays inside its surface"
  )
end

local function pointerPress(game, source, x, y)
  game.runtime.input:pointerDown(source, x, y)
  game:step()
  game.runtime.input:pointerUp(source, x, y)
  game:step()
end

local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG
local FLAG_GOT_TRAINER_CARD = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD
local BAG_ACTION = "vanilla.bag"
local BAG_APPLICATION = FieldApplicationIds.BAG
local TRAINER_ACTION = "vanilla.trainer_card"
local TRAINER_APPLICATION = "trainer_card"

local function grantBag(game)
  game:setWorldState({ flag = FLAG_GOT_BAG })
end

local function stockBasics(game)
  local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
  Assert.isTrue(bag:add("POTION", 5), "setup stock must enter the bag through the production service")
end

local function openBag(game, state)
  openStartMenu(game)
  local action = actionById(menuStatus(game), BAG_ACTION)
  Assert.isTrue(action ~= nil and action.enabled == true, "the unlocked bag must enable its menu action")
  navigateTo(game, state, BAG_ACTION)
  confirm(game)
  game:advanceUntil("bag application opens over the retained menu", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.application
  end, 120)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.applicationId, BAG_APPLICATION, "the launched application must be the bag")
  return assert(status.application, "the bag application must expose its browse status")
end

local function closeApplication(game)
  pressCancel(game)
  game:advanceUntil("the application closes", function()
    return hostPhase(game) ~= FieldApplicationHost.PHASES.application
  end, 120)
end

local function grantTrainerCard(game)
  game:setWorldState({ flag = FLAG_GOT_TRAINER_CARD })
end

local function openTrainerCard(game, state)
  openStartMenu(game)
  local action = actionById(menuStatus(game), TRAINER_ACTION)
  Assert.isTrue(action ~= nil and action.enabled == true, "the unlocked card must enable its menu action")
  -- The generated focus graph splits the menu into left/right columns
  -- that down-only cycling cannot cross (a remembered left-column cursor
  -- orbits without ever reaching the card), so step into the card's
  -- column first: left reaches the right column, up reaches the card.
  state:keypressed("a")
  game:step()
  state:keyreleased("a")
  state:keypressed("w")
  game:step()
  state:keyreleased("w")
  navigateTo(game, state, TRAINER_ACTION)
  confirm(game)
  game:advanceUntil("trainer card opens over the retained menu", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.application
  end, 120)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.applicationId, TRAINER_APPLICATION, "the launched application must be the trainer card")
  return assert(status.application, "the card application must expose its status")
end

-- A held body press across a configuration switch must cancel instead of
-- activating the control that moves under the pointer; a fresh press
-- afterwards maps through the new plan exactly once.
function T.tests.start_menu_switch_cancels_stale_press_without_state_loss()
  withFieldGame({}, function(game)
    switchDisplay(game, 640, 480)
    openStartMenu(game)
    local before = menuStatus(game)
    local selectedBefore = assert(before.selectedPosition, "menu status must expose its selection")
    local plan = assert(before.presentation, "the open menu must publish its presentation plan")
    local placement = interactivePlacement(plan, "native menu")
    Assert.equal(placement.logicalWidth, 256, "the native body keeps its canonical width")
    Assert.equal(placement.logicalHeight, 192, "the native body keeps its canonical height")

    -- Hold a press on body content, then switch to a wide host before
    -- the release at the identical host coordinates.
    local hostX, hostY = LayoutGeometry.logicalToHost(placement, 126, 38)
    game.runtime.input:pointerDown("integration:stale", hostX, hostY)
    game:step()
    switchDisplay(game, 1280, 720)
    game.runtime.input:pointerUp("integration:stale", hostX, hostY)
    game:step()
    local moved = menuStatus(game)
    Assert.equal(
      moved.selectedPosition,
      selectedBefore,
      "a release after a configuration switch must not activate a moved control"
    )
    local widePlan = assert(moved.presentation, "the menu must publish a plan after the switch")
    local wideFrames = assert(widePlan.frames, "a wide host must frame the menu")
    Assert.equal(#wideFrames, 1, "a wide host frames the menu in one static box")
    local wideBox = assert(wideFrames[1].contentBox, "the static frame carries its content box")
    Assert.equal(wideBox.width, 256, "the framed body keeps its canonical width")
    Assert.equal(wideBox.height, 192, "the framed body keeps its canonical height")
    local widePlacement = interactivePlacement(widePlan, "wide menu")
    Assert.equal(widePlacement.logicalWidth, 256, "the framed body keeps its canonical width")
    Assert.isTrue(
      widePlacement.pixelScale ~= nil
        and widePlacement.pixelScale >= 1
        and widePlacement.pixelScale == math.floor(widePlacement.pixelScale),
      "the framed body keeps an integer pixel scale"
    )
    -- A fresh press after the switch maps through the new plan: hover a
    -- body point and watch selection follow the pointer once.
    local freshX, freshY = LayoutGeometry.logicalToHost(widePlacement, 126, 38)
    game.runtime.input:pointerMove("integration:fresh", freshX, freshY)
    game:step()
    menuStatus(game)
    closeStartMenu(game)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.closed, "closing returns the field to its closed phase")
  end)
end

-- The Bag keeps its pocket, cursor, and stocked quantities across a
-- topology change; a reflowed release never issues an inventory mutation.
function T.tests.bag_preserves_browse_state_across_topology_change()
  withFieldGame({}, function(game)
    local state = hostCallbacks(game)
    grantBag(game)
    stockBasics(game)
    switchDisplay(game, 640, 480)
    local opened = openBag(game, state)
    local pocketBefore = opened.pocket ~= nil and opened.pocket or opened.currentPocket
    Assert.isTrue(type(pocketBefore) == "string", "the open bag must name its pocket")
    local selectedBefore = opened.selected
    local plan = assert(opened.presentation, "the open bag must publish its presentation plan")
    Assert.equal(#plan.panes, 1, "native-like bag shows only its interaction pane")

    switchDisplay(game, 600, 1000)
    local status = game.runtime.applicationHost:status()
    Assert.equal(status.applicationId, BAG_APPLICATION, "the bag must stay open across the switch")
    local view = assert(status.application, "the bag must expose its status after the switch")
    local pocketAfter = view.pocket ~= nil and view.pocket or view.currentPocket
    Assert.equal(pocketAfter, pocketBefore, "the pocket must survive the topology change")
    Assert.deepEqual(view.selected, selectedBefore, "the cursor must survive the topology change")
    local tallPlan = assert(view.presentation, "the bag must publish a plan after the switch")
    Assert.equal(#tallPlan.panes, 2, "a tall host must pair hero above interaction")
    local heroPane, interactionPane = nil, nil
    for _, pane in ipairs(tallPlan.panes) do
      if pane.interactive then
        interactionPane = pane
      else
        heroPane = pane
      end
    end
    local hero = assert(heroPane, "the tall plan must carry its hero pane")
    local interaction = assert(interactionPane, "the tall plan must carry its interaction pane")
    local heroPlacement = hero.placement
    Assert.equal(
      interaction.placement.pixelScale,
      heroPlacement.pixelScale,
      "paired panes must share one integer pixel scale"
    )

    -- A press on the non-interactive hero pane must not select anything.
    local heroX, heroY = LayoutGeometry.logicalToHost(heroPlacement, 128, 96)
    pointerPress(game, "integration:hero", heroX, heroY)
    local afterHero =
      assert(game.runtime.applicationHost:status().application, "the bag must stay open after a hero press")
    Assert.deepEqual(afterHero.selected, selectedBefore, "hero input must never change the selection")

    closeApplication(game)
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.equal(bag:quantity("POTION"), 5, "reflow and hero presses must issue no inventory mutation")
  end)
end

-- A pointer press held on a Bag cell across a field focus loss must not
-- survive the blur: the stale release activates nothing, and a fresh press
-- after refocus maps through the live session exactly once.
function T.tests.bag_blur_cancels_stale_press_and_fresh_input_recovers()
  withFieldGame({}, function(game)
    local state = hostCallbacks(game)
    grantBag(game)
    stockBasics(game)
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:add("FULL_RESTORE", 3), "setup stocks a second medicine item")
    switchDisplay(game, 640, 480)
    openBag(game, state)
    local function bagView()
      return assert(
        game.runtime.applicationHost:status().application,
        "the bag must stay open through the focus journey"
      )
    end
    local function selectedItem(view)
      local selected = view.selected
      if selected == nil then
        return nil
      end
      assert(type(selected) == "table", "the bag selection must be a record")
      local key = selected.item or selected.itemKey or selected.key
      assert(type(key) == "string" and key ~= "", "the bag selection must name its item")
      return key
    end
    -- Resolve generated tab/cell geometry through the manifest and the
    -- published interactive placement.
    local manifest = BagCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local interactiveManifest = assert(manifest.interactive, "the generated manifest must carry its interactive pane")
    local slots = assert(
      interactiveManifest.itemSlots and interactiveManifest.itemSlots.slots,
      "the generated manifest must carry its item slot geometry"
    )
    local tabs = assert(
      interactiveManifest.pocketTabs and interactiveManifest.pocketTabs.rects,
      "the generated manifest must carry its pocket tab geometry"
    )
    local placement = interactivePlacement(
      assert(bagView().presentation, "the open bag must publish its presentation plan"),
      "open bag"
    )
    local frame = assert(placement.frame, "the interactive placement must expose its host frame")
    local scale = assert(placement.scale, "the interactive placement must expose its scale")
    local function cellCenter(rect)
      return frame.x + (rect.x + rect.width / 2) * scale, frame.y + (rect.y + rect.height / 2) * scale
    end
    -- The stocked medicine lives outside the default items pocket, so
    -- enter medicine through its tab: tabs follow pocket order.
    local medicineEntry = assert(tabs[2], "the manifest must carry a medicine tab")
    local medicineTab = medicineEntry.rect or medicineEntry
    local tabX, tabY = cellCenter(medicineTab)
    pointerPress(game, "focus:medicine", tabX, tabY)
    Assert.equal(bagView().pocket, "medicine", "tapping the medicine tab enters the medicine pocket")
    Assert.equal(selectedItem(bagView()), "POTION", "the medicine pocket starts on the first stocked cell")
    local second = assert(slots[2], "the manifest must carry a second item cell").rect
    local cellX, cellY = cellCenter(second)

    -- Focus the second cell with a complete tap, so the held press below
    -- starts from a known selection.
    pointerPress(game, "focus:second", cellX, cellY)
    Assert.equal(selectedItem(bagView()), "FULL_RESTORE", "tapping the second cell selects its item")

    -- Hold a press on the already-selected cell, then blur and refocus
    -- through the production focus wiring: the field state clears physical
    -- input and asks the live host to cancel its capture.
    local focusState = setmetatable({ runtime = game.runtime }, FieldState)
    game.runtime.input:pointerDown("focus:stale", cellX, cellY)
    game:step()
    focusState:focus(false)
    focusState:focus(true)
    game:step()
    game.runtime.input:pointerUp("focus:stale", cellX, cellY)
    game:step()
    game:step()
    local released = bagView()
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "a stale release must not leave the bag application"
    )
    Assert.equal(released.state, "browsing", "a stale release must not open the action menu")
    Assert.equal(selectedItem(released), "FULL_RESTORE", "a stale release must not move the selection")
    Assert.equal(bag:quantity("POTION"), 5, "the stale gesture must issue no inventory mutation")
    Assert.equal(bag:quantity("FULL_RESTORE"), 3, "the stale gesture must issue no inventory mutation")

    -- A fresh press after refocus maps through the live session: tapping
    -- the selected cell opens the action menu exactly once.
    game.runtime.input:pointerDown("focus:fresh", cellX, cellY)
    game:step()
    game.runtime.input:pointerUp("focus:fresh", cellX, cellY)
    game:step()
    Assert.equal(bagView().state, "action_menu", "a fresh press after refocus must activate through the live session")
    pressCancel(game)
    Assert.equal(bagView().state, "browsing", "cancelling the menu returns to browsing")
    closeApplication(game)
    game:advanceUntil("the start menu returns after the bag closes", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    closeStartMenu(game)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.closed, "the journey ends back on the field")
  end)
end

-- The Trainer Card takes the auxiliary fullscreen on a genuine pair with
-- its protected text intact, ignores field zoom, and closes exactly once.
function T.tests.trainer_card_takes_auxiliary_and_closes_once()
  withFieldGame({}, function(game)
    local state = hostCallbacks(game)
    grantTrainerCard(game)
    switchDisplay(game, 640, 480)
    local opened = openTrainerCard(game, state)
    local plan = assert(opened.presentation, "the open card must publish its presentation plan")
    Assert.equal(#plan.panes, 1, "the card shows its single surface")

    game.runtime.fieldPixelScale:zoomIn()
    game.runtime:applyFieldPixelScaleChange()
    game:step()
    local zoomed =
      assert(game.runtime.applicationHost:status().application, "the card must stay open across a zoom change")
    local zoomedPlan = assert(zoomed.presentation, "the card must publish a plan after zoom")
    Assert.deepEqual(
      zoomedPlan.panes[1].placement.frame,
      plan.panes[1].placement.frame,
      "field zoom must not move the card surface"
    )

    local pair = differentPair()
    game.runtime:resizePresentation(800, 600, pair)
    game:step()
    local dual =
      assert(game.runtime.applicationHost:status().application, "the card must stay open across the dual switch")
    local dualPlan = assert(dual.presentation, "the card must publish a plan on the pair")
    local frame = dualPlan.panes[1].placement.frame
    assertInside(frame, { x = 520, y = 40, width = 256, height = 192 }, "dual card")
    Assert.isTrue(
      frame.x >= 520 and frame.x + frame.width <= 776,
      "the dual card must stay inside the auxiliary surface"
    )

    pressCancel(game)
    game:advanceUntil("the card closes back to the menu", function()
      local phase = hostPhase(game)
      return phase == FieldApplicationHost.PHASES.menu or phase == FieldApplicationHost.PHASES.closed
    end, 240)
    Assert.isTrue(
      hostPhase(game) == FieldApplicationHost.PHASES.menu or hostPhase(game) == FieldApplicationHost.PHASES.closed,
      "closing must return through the menu or closed phase exactly once"
    )
  end)
end

-- Elm's Lab starter choice through the genuine scripted route: drive the
-- welcome scene, Elm's dispatcher, and the ball-table trigger, then switch
-- to a native-like host while the blocking choice is open. The compact
-- selector must take over without touching candidates or clocks, and the
-- choice must publish exactly once.
local LAB_MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local LAB_TRIO = { CHIKORITA = true, CYNDAQUIL = true, TOTODILE = true }

local function labHarness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or LAB_MAP, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
end

local function withLabGame(fn)
  local bootWidth, bootHeight = love.graphics.getDimensions()
  local game = labHarness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = LAB_MAP,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      screenTopology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = bootWidth, height = bootHeight },
        touch = false,
        role = "world",
      }),
    },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "starter acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function scriptRecords(game, name)
  local records = {}
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

local function pumpScript(game, ticks, stop, modal)
  for tick = 1, ticks do
    if game.runtime.errorText then
      return { fault = game.runtime.errorText }
    end
    if stop ~= nil and stop() then
      return { stopped = true }
    end
    local snapshot = game:snapshot()
    if snapshot.dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    elseif modal == true and snapshot.fieldLocked and tick % 3 == 0 then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    elseif modal == true and snapshot.fieldLocked and tick % 12 == 0 then
      game:move("right")
    else
      game:step()
    end
  end
  if stop ~= nil and stop() then
    return { stopped = true }
  end
  return { stopped = false }
end

local function labPartyCount(game)
  return game.runtime.monService:partyCount()
end

local function directionToward(fromX, fromZ, toX, toZ)
  if toX > fromX then
    return "east"
  end
  if toX < fromX then
    return "west"
  end
  if toZ > fromZ then
    return "south"
  end
  return "north"
end

local function standNextTo(game, actorId)
  local actors = game:snapshot().actors
  local target = assert(actors[actorId], "actor is not visible: " .. actorId)
  local player = game:snapshot().player
  local neighbors = {
    { fieldX = target.fieldX + 1, fieldZ = target.fieldZ },
    { fieldX = target.fieldX - 1, fieldZ = target.fieldZ },
    { fieldX = target.fieldX, fieldZ = target.fieldZ + 1 },
    { fieldX = target.fieldX, fieldZ = target.fieldZ - 1 },
  }
  local routed = false
  for _, tile in ipairs(neighbors) do
    local ok = pcall(function()
      game:moveTo(tile)
    end)
    if ok then
      local now = game:snapshot()
      local distance = math.abs(now.player.fieldX - target.fieldX) + math.abs(now.player.fieldZ - target.fieldZ)
      if distance == 1 then
        routed = true
        player = now.player
        break
      end
    end
  end
  Assert.isTrue(routed, "production movement must reach a tile adjacent to " .. actorId)
  game:face(directionToward(player.fieldX, player.fieldZ, target.fieldX, target.fieldZ))
end

function T.tests.starter_choice_switches_to_compact_and_publishes_once()
  withLabGame(function(game)
    game:waitForFieldEntry()
    Assert.equal(labPartyCount(game), 0, "a fresh save starts Elm's Lab with an empty party")

    local baselineStarts = #scriptRecords(game, "script.started")
    game:moveTo({ fieldX = 4, fieldZ = 10 })
    game:advanceUntil("the welcome scene starts", function()
      return #scriptRecords(game, "script.started") > baselineStarts
    end, 60)
    local starts = scriptRecords(game, "script.started")
    local welcomeScriptId = starts[#starts].payload.scriptId
    local welcome = pumpScript(game, 1500, function()
      for _, record in ipairs(scriptRecords(game, "script.ended")) do
        if record.payload.scriptId == welcomeScriptId then
          return record.payload.completed == true
        end
      end
      return false
    end)
    Assert.isNil(welcome.fault, "the welcome scene must run without a runtime fault")
    Assert.isTrue(welcome.stopped, "the welcome scene must conclude before starter choice")

    local ELM_SCRIPT = "vanilla.hgss.scr_seq.0843.script_000"
    local elmActor = nil
    do
      local actorIds = {}
      for actorId in pairs(game:snapshot().actors) do
        if not actorId:find("player", 1, true) then
          actorIds[#actorIds + 1] = actorId
        end
      end
      table.sort(actorIds)
      for _, actorId in ipairs(actorIds) do
        local ok = pcall(standNextTo, game, actorId)
        if ok then
          game:pressAction()
          local interaction = game:interaction()
          if interaction.scriptId == ELM_SCRIPT then
            elmActor = actorId
            break
          end
          local drained = pumpScript(game, 200, function()
            return not game:snapshot().dialogue.modal
          end)
          if drained.fault ~= nil then
            error("runtime fault while driving " .. actorId .. ": " .. tostring(drained.fault))
          end
        end
      end
    end
    Assert.notNil(elmActor, "Elm must start his generated dispatcher script")
    local elmDone = pumpScript(game, 1500, function()
      for _, record in ipairs(scriptRecords(game, "script.ended")) do
        if record.payload.scriptId == ELM_SCRIPT then
          return record.payload.completed == true
        end
      end
      return false
    end)
    Assert.isNil(elmDone.fault, "Elm's dispatcher must run without a runtime fault")
    Assert.isTrue(elmDone.stopped, "Elm's dispatcher must conclude before the table owns the choice")

    local STARTER_SCRIPT = "vanilla.hgss.scr_seq.0843.script_012"
    local triggered = false
    for _, tile in ipairs({
      { fieldX = 8, fieldZ = 5 },
      { fieldX = 7, fieldZ = 4 },
      { fieldX = 9, fieldZ = 4 },
      { fieldX = 8, fieldZ = 3 },
    }) do
      if not triggered then
        local ok = pcall(function()
          game:moveTo(tile)
        end)
        if ok then
          for _, facing in ipairs({ "north", "south", "east", "west" }) do
            if not triggered then
              game:face(facing)
              game:pressAction()
              if game:interaction().scriptId == STARTER_SCRIPT then
                triggered = true
              end
            end
          end
        end
      end
    end
    Assert.isTrue(triggered, "the ball table must start the generated starter script")

    -- Wait for the blocking choice surface, then switch hosts mid-choice:
    -- the compact selector must take over the same open choice.
    game:advanceUntil("the starter choice opens", function()
      local surface = game.runtime.starterChoice
      return surface ~= nil and surface:isActive()
    end, 600)
    switchDisplay(game, 640, 480)
    game:advanceUntil("the compact plan publishes", function()
      local surface = game.runtime.starterChoice
      if surface == nil or not surface:isActive() then
        return false
      end
      local plan = surface:status().presentation
      return plan ~= nil and #plan.panes == 1
    end, 120)
    local choice = game.runtime.starterChoice
    local plan = assert(choice:status().presentation, "the open choice must publish its plan")
    Assert.equal(#plan.panes, 1, "native-like choice shows its single compact selector")
    Assert.equal(plan.inputKey, "starter-compact", "the compact plan names its input geometry")
    local placement = assert(plan.panes[1].placement, "the compact pane carries its placement")
    Assert.equal(placement.logicalWidth, 256, "the compact pane stays canonically wide")
    Assert.equal(placement.logicalHeight, 192, "the compact pane stays canonically tall")

    local chosen = pumpScript(game, 1200, function()
      return labPartyCount(game) == 1
    end, true)
    Assert.isNil(chosen.fault, "the starter script must run without a runtime fault")
    Assert.isTrue(chosen.stopped, "the choice must add exactly one mon to the party")
    local species = game.runtime.monService:partyMon(0).species
    Assert.isTrue(LAB_TRIO[species] == true, "the added mon is one of the three lab candidates")
    pumpScript(game, 120, function()
      return false
    end, true)
    Assert.equal(labPartyCount(game), 1, "the candidate publishes exactly once across the switch")
  end)
end

-- Oak naming through the production intro composition: reach name editing,
-- draft a name, then reflow across a static centered plan. The draft, page,
-- and canonical child geometry must survive; the plan stays frameless and
-- deterministic; an outside press inserts no glyph and dismisses nothing;
-- submission must carry the single confirmed result.
local function oakCandidate(versionId)
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000001"
      end,
    },
    versionId = versionId,
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
  })
end

local function oakCompose(versionId, width, height)
  local audio = FakeAudioOutput.new()
  return OakIntroComposition.compose({
    candidate = oakCandidate(versionId),
    versionId = versionId,
    graphics = love.graphics,
    audioOutput = { audio = audio.audio, sound = audio.sound },
    clock = {
      nowLocal = function()
        return { year = 2026, month = 9, day = 15, hour = 12, minute = 0, second = 0 }
      end,
    },
    randomU32 = function()
      return 0x12345678
    end,
    width = width or 640,
    height = height or 480,
    textInputHost = { setTextInput = function() end },
  })
end

local function oakFinishDialogue(state)
  local messageKey = assert(state:view().messageKey, "Oak selection requires an active dialogue")
  for _ = 1, 20000 do
    if state:view().messageKey ~= messageKey then
      return
    end
    local status = state.dialogueController:status()
    if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
      state:keypressed("return")
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not reach its semantic completion boundary: " .. messageKey)
end

local function oakAdvanceUntil(state, messageKey)
  for _ = 1, 20000 do
    if state:view().messageKey == messageKey then
      return
    end
    if state.dialogueController:isModal() then
      oakFinishDialogue(state)
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not open: " .. messageKey)
end

local function oakAdvanceUntilPhase(state, phase)
  for _ = 1, 200 do
    if state:view().phase == phase then
      return
    end
    if state.dialogueController:isModal() then
      oakFinishDialogue(state)
    else
      state:tick(1)
    end
  end
  error("Oak did not reach phase " .. phase)
end

local function oakDriveToNameEdit(state)
  oakAdvanceUntil(state, "profile.gender_question")
  oakFinishDialogue(state)
  oakAdvanceUntilPhase(state, "gender_select")
  state:keypressed("return")
  oakFinishDialogue(state)
  state:keypressed("return")
  oakFinishDialogue(state)
  oakAdvanceUntilPhase(state, "name_edit")
end

local function withOakComposed(width, height, fn)
  local state = oakCompose(AcceptanceHarness.defaultVersion(), width, height)
  local ok, err = xpcall(fn, debug.traceback, state)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.tests.oak_naming_draft_survives_static_reflow_without_glyphs()
  withOakComposed(640, 480, function(state)
    oakDriveToNameEdit(state)
    state:textinput("GOLD")
    Assert.equal(state:view().name, "GOLD", "the typed draft must reach the profile")
    local plan = assert(state:view().namingPresentation, "name editing must publish its naming plan")
    Assert.equal(#plan.panes, 1, "naming resolves to one canonical pane")
    Assert.equal(plan.panes[1].placement.logicalWidth, 256, "the naming pane stays canonical")

    state:resize(1280, 720)
    local reflowed = state:view()
    Assert.equal(reflowed.name, "GOLD", "the draft must survive the reflow")
    local reflowedPlan = assert(reflowed.namingPresentation, "name editing must publish a plan after reflow")
    Assert.equal(#reflowedPlan.panes, 1, "reflow keeps one canonical naming pane")
    Assert.equal(reflowedPlan.panes[1].placement.logicalWidth, 256, "reflow never shrinks the child")
    Assert.deepEqual(
      assert(reflowedPlan.frames, "naming publishes its frame list"),
      {},
      "naming stays frameless on a wide host"
    )
    local paneFrame = assert(reflowedPlan.panes[1].placement, "the naming pane carries its placement").frame
    -- A second identical reflow must resolve the same static geometry:
    -- no remembered position may shift the pane.
    state:resize(1280, 720)
    local restated = assert(state:view().namingPresentation, "name editing must publish a plan after reflow")
    Assert.deepEqual(
      assert(restated.panes[1].placement, "the naming pane carries its placement").frame,
      paneFrame,
      "an identical reflow resolves identical static geometry"
    )
    -- An outside press inserts no glyph and dismisses nothing: naming
    -- never maps outside input to content or to dismissal.
    local probeX, probeY = 8, 8
    if
      probeX >= paneFrame.x
      and probeX < paneFrame.x + paneFrame.width
      and probeY >= paneFrame.y
      and probeY < paneFrame.y + paneFrame.height
    then
      probeX, probeY = 1272, 712
    end
    Assert.isFalse(
      probeX >= paneFrame.x
        and probeX < paneFrame.x + paneFrame.width
        and probeY >= paneFrame.y
        and probeY < paneFrame.y + paneFrame.height,
      "the probe must fall outside the naming pane"
    )
    state:mousepressed(probeX, probeY, 1)
    state:mousereleased(probeX, probeY, 1)
    Assert.equal(state:view().name, "GOLD", "an outside press must never insert a glyph")
    Assert.equal(state:view().phase, "name_edit", "an outside press must never leave name editing")

    state:gamepadpressed(nil, "start")
    state:tick(26)
    Assert.equal(state:view().phase, "name_confirm", "submission must reach confirmation once")
    Assert.equal(state:view().name, "GOLD", "confirmation must carry the single drafted name")
  end)
end

-- Main Menu save-management scaffolding: isolated save roots, production
-- catalog validation, and a render trap so acceptance stays headless.
local menuNamespaceSerial = 0
local menuTemplateRecord = nil

local function isolatedBackend(namespace)
  local fs = love.filesystem
  local function map(path)
    return namespace .. "/" .. path:gsub("^saves/", "")
  end
  return {
    write = function(_, path, data)
      return fs.write(map(path), data)
    end,
    read = function(_, path)
      return fs.read(map(path))
    end,
    getInfo = function(_, path)
      return fs.getInfo(map(path))
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(map(path))
    end,
    remove = function(_, path)
      return fs.remove(map(path))
    end,
    replace = function(_, sourcePath, destinationPath)
      return os.rename(
        fs.getSaveDirectory() .. "/" .. map(sourcePath),
        fs.getSaveDirectory() .. "/" .. map(destinationPath)
      )
    end,
  }
end

local function removeTree(path)
  local fs = love.filesystem
  local info = fs.getInfo(path)
  if info == nil then
    return
  end
  if info.type == "directory" then
    for _, child in ipairs(fs.getDirectoryItems(path)) do
      removeTree(path .. "/" .. child)
    end
  end
  assert(fs.remove(path), "acceptance cleanup must remove " .. path)
end

local function menuRenderTrap(fn)
  local names = { "newShader", "newCanvas", "newImage", "newMesh", "newQuad", "draw" }
  local originals = {}
  local attempts = 0
  for _, name in ipairs(names) do
    originals[name] = love.graphics[name]
    love.graphics[name] = function()
      attempts = attempts + 1
      error("Main Menu acceptance attempted love.graphics." .. name, 2)
    end
  end
  local ok, result = xpcall(fn, debug.traceback)
  for name, original in pairs(originals) do
    love.graphics[name] = original
  end
  if not ok then
    error(result, 0)
  end
  Assert.equal(attempts, 0, "Main Menu acceptance must stop before GPU rendering")
  return result
end

local function freshRecord(versionId)
  local game = AcceptanceHarness.new():boot({
    versionId = versionId,
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, result = xpcall(function()
    game:waitForFieldReady()
    return assert(game.runtime:captureGameSave(), "fresh production runtime must provide a save record")
  end, debug.traceback)
  local closeOk, closeError = pcall(function()
    game:close()
  end)
  if not closeOk then
    error(closeError, 0)
  end
  if not ok then
    error(result, 0)
  end
  return result
end

local function copyRecord(record, saveId, name, playTimeSeconds)
  local copy = {}
  for key, value in pairs(record) do
    copy[key] = value
  end
  copy.saveId = saveId
  copy.playTimeSeconds = playTimeSeconds
  local playerData = {}
  for key, value in pairs(record.playerData) do
    playerData[key] = value
  end
  local profile = {}
  for key, value in pairs(record.playerData.profile) do
    profile[key] = value
  end
  profile.name = name
  playerData.profile = profile
  copy.playerData = playerData
  return copy
end

local function seedRecords(saveFs, count)
  local store = GameSaveStore.new(saveFs)
  local saveIds = {}
  for index = 1, count do
    local saveId = store:reserve()
    saveIds[index] = saveId
    store:publishFirst(copyRecord(menuTemplateRecord, saveId, "PLAYER" .. index, index * 60))
  end
  return saveIds
end

local function withMenu(count, width, height, fn)
  local versionId = AcceptanceHarness.defaultVersion()
  if menuTemplateRecord == nil then
    menuTemplateRecord = freshRecord(versionId)
  end
  menuNamespaceSerial = menuNamespaceSerial + 1
  local namespace = "acceptance/main-menu-matrix/" .. menuNamespaceSerial
  local backend = isolatedBackend(namespace)
  local saveFs = SaveFs.global(backend)
  local saveIds = seedRecords(saveFs, count)
  local results = {}
  local validation = GameSaveValidation.new({
    overrideFs = RepoFs.new(love.filesystem.getSourceBaseDirectory()),
  })
  local store = GameSaveStore.new(saveFs, {
    recordValidate = function(record)
      return validation:validate(record)
    end,
  })
  local menuText = FieldTextRenderer.new({ cacheFs = CacheFs.forVersion(versionId) })
  local menuRenderer = MainMenuRenderer.new({
    text = menuText,
    cacheFs = CacheFs.forVersion(versionId),
    versionId = versionId,
  })
  local menu = MainMenuState.new({
    saveStore = store,
    readyVersions = { versionId },
    onResult = function(result)
      results[#results + 1] = result
    end,
    width = width,
    height = height,
    renderer = menuRenderer,
  })
  local ok, err = xpcall(function()
    menuRenderTrap(function()
      fn(menu, saveIds, results)
    end)
  end, debug.traceback)
  local disposeOk, disposeError = pcall(function()
    menu:dispose()
  end)
  removeTree(namespace)
  if not ok then
    error(err, 0)
  end
  if not disposeOk then
    error(disposeError, 0)
  end
end

local function menuView(menu)
  return assert(menu:view(), "Main Menu must publish a production view")
end

local function menuPress(menu, logicalX, logicalY)
  local published = menuView(menu)
  local placement = assert(published.presentation.panes[1].placement, "pointer input needs the published placement")
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
  menu:mousepressed(hostX, hostY, 1)
  menu:mousereleased(hostX, hostY, 1)
end

-- The responsive startup menu keeps its logical geometry, focus, and
-- scroll across a host resize; presses on clipped-away cards cannot
-- launch or delete anything.
function T.tests.main_menu_resize_keeps_focus_scroll_and_hit_safety()
  withMenu(6, 640, 480, function(menu, _, results)
    local before = menuView(menu)
    local layout = assert(before.layout, "the menu must publish its logical layout")
    Assert.isNil(layout.uiScale, "the logical layout must carry no presentation scale")
    menu:keypressed("down")
    menu:keypressed("down")
    local focused = menuView(menu).focusedId
    Assert.isTrue(focused ~= nil, "keyboard navigation must focus a card before resize")

    menu:resize(1280, 720)
    menu:mousemoved(640, 360, 0, 0, false)
    local after = menuView(menu)
    Assert.equal(after.focusedId, focused, "the focused card must survive the resize")
    Assert.isNil(after.layout.uiScale, "the resized layout must carry no presentation scale")
    local resizedPlacement =
      assert(after.presentation.panes[1].placement, "the resized menu must publish its placement")
    Assert.isTrue(
      resizedPlacement.logicalWidth >= before.presentation.panes[1].placement.logicalWidth,
      "a larger host must not shrink the logical viewport"
    )

    -- A press far outside every card rectangle cannot commit an action.
    menuPress(menu, -40, -40)
    Assert.equal(#results, 0, "an off-content press must not route any result")
    menu:keypressed("escape")
    Assert.isTrue(#results <= 1, "reflow must not duplicate route results")
  end)
end

-- A per-case function override replaces the whole render/input pair for
-- exactly one application and one case: the custom mapper drives the real
-- controller, other cases keep their defaults, and a second instance
-- without overrides is unaffected.
function T.tests.start_menu_wide_override_replaces_pair_without_leaking()
  local customRenders = 0
  local customMaps = 0
  local function customWide(context, view)
    local fallback = StartMenuInterface.framed(context, view)
    local body = nil
    for _, pane in ipairs(assert(fallback.panes, "the default wide plan carries its panes")) do
      if pane.interactive then
        body = pane
      end
    end
    assert(body, "the default wide plan carries its body pane")
    return {
      panes = { body },
      content = fallback.content,
      inputKey = "start-menu-custom",
      render = function()
        customRenders = customRenders + 1
      end,
      mapInput = function(event, _, _)
        customMaps = customMaps + 1
        if event.type == "pointer_down" and event.outside ~= true then
          return { type = "navigate", direction = "down" }
        end
        return nil
      end,
      frames = fallback.frames,
    }
  end

  withFieldGame({ presentationOverrides = { start_menu = { wide = customWide } } }, function(game)
    switchDisplay(game, 1280, 720)
    openStartMenu(game)
    local menu = menuStatus(game)
    local widePlan = assert(menu.presentation, "the overridden menu must publish its plan")
    Assert.equal(widePlan.inputKey, "start-menu-custom", "the wide case must use the override pair")

    -- The custom mapper turns a body press into a downward navigation on
    -- the real controller.
    local placement = interactivePlacement(widePlan, "custom wide")
    local hostX, hostY = LayoutGeometry.logicalToHost(placement, 126, 38)
    pointerPress(game, "integration:custom", hostX, hostY)
    local after = menuStatus(game)
    Assert.isTrue(customMaps > 0, "the custom mapper must execute on body input")
    Assert.equal(
      after.selectedPosition,
      5,
      "the custom downward navigation must move the fresh cursor from slot 4 to slot 5"
    )
    closeStartMenu(game)

    -- Other cases keep their defaults on the same instance.
    switchDisplay(game, 640, 480)
    openStartMenu(game)
    local nativePlan = assert(menuStatus(game).presentation, "native-like must publish its plan")
    Assert.isTrue(nativePlan.inputKey ~= "start-menu-custom", "the override must not leak into the native-like case")
    closeStartMenu(game)
  end)

  withFieldGame({}, function(game)
    switchDisplay(game, 1280, 720)
    openStartMenu(game)
    local defaultPlan = assert(menuStatus(game).presentation, "the default instance must publish its plan")
    Assert.isTrue(defaultPlan.inputKey ~= "start-menu-custom", "the override must not leak into a second instance")
    closeStartMenu(game)
  end)
  Assert.equal(customRenders, 0, "acceptance must never execute render callbacks headlessly")
end

-- Unknown override case keys fail at composition; the failure never
-- publishes a partial interface.
function T.tests.unknown_override_case_key_fails_without_publication()
  local ok, err = pcall(function()
    return StartMenuInterface.withOverrides({
      wide = StartMenuInterface.framed,
      bogus = StartMenuInterface.framed,
    })
  end)
  Assert.isFalse(ok, "an unknown override case key must fail")
  Assert.isTrue(type(err) == "string" and #err > 0, "the failure must carry a diagnostic")
end

-- Frame borders and non-interactive panes are application interior: a press
-- there changes nothing, and a press fully outside all panes and frames is
-- reported without coordinates for the leaf outside policy.
local function hostRectContains(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

-- Geometry-only interior: every visible pane clip plus every published
-- outer frame clip. Fade coverage is transition metadata, never a hit
-- region, so it stays out of this probe by construction.
local function planOwnsPoint(plan, x, y)
  for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes for hit probing")) do
    local clip = assert(pane.placement, "every pane carries its placement").clipRect
    if clip ~= nil and hostRectContains(clip, x, y) then
      return true
    end
  end
  for _, frame in ipairs(plan.frames or {}) do
    local clip = assert(frame.placement, "every frame carries its placement").clipRect
    if clip ~= nil and hostRectContains(clip, x, y) then
      return true
    end
  end
  return false
end

local function outsidePoint(plan, width, height)
  local candidates = {
    { 8, 8 },
    { width - 8, 8 },
    { 8, height - 8 },
    { width - 8, height - 8 },
    { width / 2, 8 },
    { 8, height / 2 },
  }
  for _, candidate in ipairs(candidates) do
    if not planOwnsPoint(plan, candidate[1], candidate[2]) then
      return candidate[1], candidate[2]
    end
  end
  error("the framed plan leaves no outside margin on this host", 0)
end

-- Two host pixels inside the outer frame origin: within the left/top
-- border for any integer scale >= 1, hence application interior that must
-- never dismiss.
local function frameBorderPoint(plan)
  local frameRecord = assert((plan.frames or {})[1], "the plan must publish an outer frame")
  local outer = assert(frameRecord.placement, "the frame carries its placement").frame
  return outer.x + 2, outer.y + 2
end

local function downOnly(game, source, x, y)
  game.runtime.input:pointerDown(source, x, y)
  game:step()
end

local function upOnly(game, source, x, y)
  game.runtime.input:pointerUp(source, x, y)
  game:step()
end

-- A press on the decorative frame border is application interior: it
-- moves nothing and closes nothing, while a true outside press on the
-- next tick dismisses the menu through the normal host lifecycle without
-- opening anything else.
function T.tests.outside_press_dismisses_the_start_menu_while_frame_press_stays_inside()
  withFieldGame({}, function(game)
    switchDisplay(game, 1280, 720)
    openStartMenu(game)
    local menu = menuStatus(game)
    local selectedBefore = assert(menu.selectedPosition, "menu status must expose its selection")
    local plan = assert(menu.presentation, "the menu must publish its plan")
    Assert.isTrue(#(plan.frames or {}) >= 1, "the wide menu must publish its outer frame")
    local borderX, borderY = frameBorderPoint(plan)
    Assert.isTrue(planOwnsPoint(plan, borderX, borderY), "the border probe must hit the frame clip")
    downOnly(game, "integration:frame", borderX, borderY)
    local held = menuStatus(game)
    Assert.equal(held.selectedPosition, selectedBefore, "a frame press must not move selection")
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.menu, "a frame press must not leave the menu")
    upOnly(game, "integration:frame", borderX, borderY)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.menu, "the frame release must not leave the menu")
    local outsideX, outsideY = outsidePoint(plan, 1280, 720)
    downOnly(game, "integration:outside", outsideX, outsideY)
    game:advanceUntil("an outside press dismisses the menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.closed
    end, 120)
    upOnly(game, "integration:outside", outsideX, outsideY)
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.closed,
      "dismissal returns to the field without opening anything else"
    )
  end)
end

-- Ordinary Cancel unwinds one nested Bag level while the bag stays open;
-- an outside press from the same nested state closes the bag at once.
function T.tests.bag_nested_cancel_unwinds_while_outside_press_closes()
  withFieldGame({}, function(game)
    local state = hostCallbacks(game)
    grantBag(game)
    stockBasics(game)
    switchDisplay(game, 1280, 720)
    local opened = openBag(game, state)
    Assert.equal(opened.state, "browsing", "the bag opens in top-level browsing")
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    local targetPocket = bag:pocketOf("POTION")
    local function bagApp()
      return assert(game.runtime.applicationHost:status().application, "the bag must stay open")
    end
    for _ = 1, 160 do
      local view = bagApp()
      local pocket = view.pocket ~= nil and view.pocket or view.currentPocket
      if pocket == targetPocket then
        break
      end
      if view.focus == "tabs" then
        if view.tabFocusPocket ~= pocket then
          confirm(game)
        else
          state:keypressed("d")
          game:step()
          state:keyreleased("d")
        end
      else
        state:keypressed("w")
        game:step()
        state:keyreleased("w")
      end
    end
    local stocked = bagApp()
    local stockedPocket = stocked.pocket ~= nil and stocked.pocket or stocked.currentPocket
    Assert.equal(stockedPocket, targetPocket, "setup must reach the stocked pocket")
    local function selectedItemKey(view)
      local selected = view.selected
      if selected == nil then
        return nil
      end
      assert(type(selected) == "table", "the bag selection must be a record")
      return selected.item or selected.itemKey or selected.key
    end
    Assert.equal(selectedItemKey(stocked), "POTION", "the stocked pocket starts on its first item")
    if stocked.focus ~= "items" then
      state:keypressed("s")
      game:step()
      state:keyreleased("s")
    end
    local entered = bagApp()
    Assert.equal(entered.focus, "items", "setup must hand interaction to the item grid")
    local function confirmItem()
      confirm(game)
      game:step()
    end
    confirmItem()
    local nested = assert(game.runtime.applicationHost:status().application, "the bag must stay open after confirm")
    Assert.equal(nested.state, "action_menu", "confirming an item opens the nested action menu")
    pressCancel(game)
    game:step()
    local unwound = assert(game.runtime.applicationHost:status().application, "ordinary cancel must keep the bag open")
    Assert.equal(unwound.state, "browsing", "ordinary cancel unwinds one level without closing")
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "ordinary cancel stays inside the application"
    )
    confirmItem()
    local rentered =
      assert(game.runtime.applicationHost:status().application, "the bag must stay open after the second confirm")
    Assert.equal(rentered.state, "action_menu", "the second confirm reopens the nested action menu")
    local plan = assert(rentered.presentation, "the nested bag must publish its plan")
    local outsideX, outsideY = outsidePoint(plan, 1280, 720)
    downOnly(game, "integration:outside", outsideX, outsideY)
    game:advanceUntil("an outside press closes the nested bag", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.menu, "dismissal returns to the menu")
    upOnly(game, "integration:outside", outsideX, outsideY)
    Assert.equal(bag:quantity("POTION"), 5, "dismissal must issue no inventory mutation")
  end)
end

-- A true outside press dismisses the Trainer Card through the normal host
-- lifecycle: the framed card closes without any nested cancel step.
function T.tests.trainer_card_outside_press_dismisses_through_the_host()
  withFieldGame({}, function(game)
    local state = hostCallbacks(game)
    grantTrainerCard(game)
    switchDisplay(game, 1280, 720)
    local opened = openTrainerCard(game, state)
    local plan = assert(opened.presentation, "the open card must publish its presentation plan")
    Assert.isTrue(#(plan.frames or {}) >= 1, "the wide card must publish its outer frame")
    local outsideX, outsideY = outsidePoint(plan, 1280, 720)
    downOnly(game, "integration:outside", outsideX, outsideY)
    game:advanceUntil("an outside press dismisses the card", function()
      local phase = hostPhase(game)
      return phase == FieldApplicationHost.PHASES.menu or phase == FieldApplicationHost.PHASES.closed
    end, 120)
    upOnly(game, "integration:outside", outsideX, outsideY)
    Assert.isTrue(
      hostPhase(game) == FieldApplicationHost.PHASES.menu or hostPhase(game) == FieldApplicationHost.PHASES.closed,
      "dismissal returns through the menu or closed phase without opening anything else"
    )
  end)
end

-- The shared numeric matrix in one place: native-like band entry at error
-- 12, hysteresis retention through 14, exact integer fits, DPI
-- equivalence, and translated origins. Fast suites in each owning layer
-- prove the same policies per module; this test pins the integrated
-- boundary values every consumer relies on.
function T.tests.shared_numeric_matrix_pins_band_scale_and_dpi_boundaries()
  local cases = {
    { width = 256, height = 192, configuration = "nativeLike" },
    { width = 320, height = 240, configuration = "nativeLike" },
    { width = 512, height = 384, configuration = "nativeLike" },
    { width = 640, height = 480, configuration = "nativeLike" },
    { width = 640, height = 456, configuration = "nativeLike" },
    { width = 750, height = 560, configuration = "nativeLike" },
    { width = 740, height = 548, configuration = "nativeLike" },
    { width = 1280, height = 720, configuration = "wide" },
    { width = 1920, height = 1080, configuration = "wide" },
    { width = 390, height = 844, configuration = "tall" },
    { width = 512, height = 512, configuration = "tall" },
    { width = 240, height = 180, configuration = "nativeLike" },
  }
  for _, host in ipairs(cases) do
    local label = host.width .. "x" .. host.height
    local measured = {
      width = host.width,
      height = host.height,
      topology = oneDisplay(host.width, host.height),
      pixelRatio = 1,
      signature = "matrix:" .. label,
    }
    Assert.equal(
      ApplicationLayout.classify(measured),
      host.configuration,
      label .. " must classify to its matrix configuration"
    )
  end

  -- Exact band edges from the locked relative-error rule: error 12 enters,
  -- error 14 retains, anything above 14 leaves.
  local function classifiedAt(width, height, previous)
    return ApplicationLayout.classify({
      width = width,
      height = height,
      topology = oneDisplay(width, height),
      pixelRatio = 1,
      signature = "band:" .. width .. "x" .. height,
    }, previous)
  end
  Assert.equal(classifiedAt(280, 192), "nativeLike", "error exactly 12 must enter native-like")
  Assert.equal(classifiedAt(284, 192), "wide", "error 14 must not enter native-like fresh")
  Assert.equal(classifiedAt(284, 192, "nativeLike"), "nativeLike", "error 14 must retain a native-like session")
  Assert.equal(classifiedAt(285, 192, "nativeLike"), "wide", "error above 14 must leave native-like")
  Assert.equal(classifiedAt(280, 192, "wide"), "nativeLike", "error 12 must re-enter native-like from wide")

  -- Integer fitting: the 256x192 surface on representative hosts.
  local fits = {
    { width = 640, height = 480, scale = 2, crop = 0 },
    { width = 750, height = 560, scale = 3, crop = 3 },
    { width = 740, height = 548, scale = 2, crop = 0 },
  }
  for _, fit in ipairs(fits) do
    local label = fit.width .. "x" .. fit.height
    local placement = assert(
      PixelScale.placeFixed({ x = 0, y = 0, width = fit.width, height = fit.height }, 256, 192),
      label .. " must place its surface"
    )
    Assert.equal(placement.pixelScale, fit.scale, label .. " must fit at its integer scale")
    Assert.equal(placement.crop.left, fit.crop, label .. " must crop its left edge by budget")
    Assert.equal(placement.crop.right, fit.crop, label .. " must crop its right edge by budget")
    -- Cropped input inverts the full origin, never the clip origin: the
    -- first visible point maps to the first visible logical pixel.
    local visible = assert(placement.visibleLogicalRect, label .. " names its visible area")
    local hx = placement.clipRect.x
    local hy = placement.clipRect.y
    local inverted = { LayoutGeometry.hostToLogical(placement, hx, hy) }
    local lx, ly = inverted[1], inverted[2]
    Assert.notNil(lx, label .. " clip inverts to visible logic")
    Assert.notNil(ly, label .. " clip inverts to visible logic")
    Assert.equal(lx, visible.x, label .. " clip maps to its visible logical origin")
    Assert.equal(ly, visible.y, label .. " clip maps to its visible logical origin")
  end

  -- DPI equivalence: the same physical bounds at ratio 2 match ratio 1.
  local one = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 750, height = 560 }, 256, 192, { pixelRatio = 1 }))
  local two = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 375, height = 280 }, 256, 192, { pixelRatio = 2 }))
  Assert.equal(two.pixelScale, one.pixelScale, "equal physical bounds must choose equal pixel scales")
  Assert.equal(two.crop.left, one.crop.left, "equal physical bounds must crop equally")
end

return T
