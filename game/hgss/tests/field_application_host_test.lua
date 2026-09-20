-- Production-composed application-host ownership contract: the runtime
-- registers the production Trainer Card destination and dispatches Save as
-- an immediate field action while the application host owns the menu.

local Assert = require("tests.support.Assert")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuPolicy = require("libs.hgss.src.ui.StartMenuPolicy")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "start-menu", "application", "transition" },
  },
  tests = {},
}

local function harness()
  return AcceptanceHarness.new({ versions = { AcceptanceHarness.defaultVersion() } })
end

-- Every start-menu unlock flag: a fresh boot leaves them all unset, so the
-- zero-action composition is the precondition of the no-op scenario.
local UNLOCK_FLAGS = {
  FieldScriptSymbols.flagsByName.FLAG_GOT_POKEDEX,
  FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER,
  FieldScriptSymbols.flagsByName.FLAG_GOT_BAG,
  FieldScriptSymbols.flagsByName.FLAG_GOT_POKEGEAR,
  FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD,
  FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON,
  FieldScriptSymbols.flagsByName.FLAG_GOT_OPTIONS_BUTTON,
}

-- The production composition: a fresh field boot with no descriptor options;
-- the real unlock flag makes the production Trainer Card interactive. The
-- boot carries an explicit single-display topology matching the drawable so
-- the runtime installs its resize-tracking provider: later
-- resizePresentation calls (including physical pairs) then measure through
-- the resized topology instead of the context default.
local function bootGame()
  local bootWidth, bootHeight = love.graphics.getDimensions()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      screenTopology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = bootWidth, height = bootHeight },
        touch = false,
        role = "world",
      }),
    },
  })
  game:waitForFieldEntry()
  game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
  return game
end

local function pressMenuEdge(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

local function advanceToPhase(game, phase, maxTicks)
  return game:advanceUntil("host reaches " .. phase, function()
    return game.runtime.applicationHost:status().phase == phase
  end, maxTicks)
end

local function openMenu(game)
  pressMenuEdge(game)
  advanceToPhase(game, "menu", 16)
end

local function confirmAction(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

-- Canonical touch topology for pointer-capable menu tests: the default boot
-- passes no screen topology, so the runtime publishes no placement record
-- and the host has no pointer support until a touch presentation is applied.
local function touchTopology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = true,
  })
end

local function ensureTouchPlacement(game, width, height)
  game.runtime:resizePresentation(width, height, touchTopology(width, height))
end

-- The published plan's interactive body placement: the single record the
-- session draws and inverts through. Read out for test pointing only.
local function readablePlacement(game)
  local menu = assert(game.runtime.applicationHost:status().menu, "the start menu must be open")
  local plan = assert(menu.presentation, "the open menu must publish its presentation plan")
  for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes")) do
    if pane.interactive then
      return assert(pane.placement, "the body pane must carry its placement")
    end
  end
  error("the framed plan must carry an interactive body pane", 0)
end

local function findMenuAction(game, id)
  local menu = assert(game.runtime.applicationHost:status().menu, "the start menu must be open")
  for _, action in ipairs(menu.actions) do
    if action.id == id then
      return action
    end
  end
  error("the start menu does not present action " .. tostring(id))
end

local function hostPointForPosition(game, position)
  local runtime = game.runtime
  local interactive =
    assert(runtime.uiManifest.startMenu.interactive, "the generated manifest must carry the interactive record")
  local record =
    assert(interactive.positions[position], "the generated manifest must carry position " .. tostring(position))
  local rect = record.hitRect
  local centerX = rect.x + rect.width / 2
  local centerY = rect.y + rect.height / 2
  return LayoutGeometry.logicalToHost(readablePlacement(game), centerX, centerY)
end

local function activateActionById(game, id)
  local action = findMenuAction(game, id)
  assert(action.position ~= nil, "the presented action must carry its source position")
  local hostX, hostY = hostPointForPosition(game, action.position)
  game.runtime.input:pointerDown("touch:1", hostX, hostY)
  game.runtime.input:pointerUp("touch:1", hostX, hostY)
  game:step()
end

-- The per-phase disposal matrix: runtime disposal in every application
-- phase releases the modal before the save attempt and closes cleanly. The
-- production Trainer Card destination carries the non-closed phases; the
-- exactly-once controller disposal is the host-unit contract, not this
-- composition's.
function T.tests.runtime_disposal_in_every_application_phase_releases_once()
  local cases = {
    {
      phase = "menu",
      walk = function(game)
        pressMenuEdge(game)
        advanceToPhase(game, "menu", 16)
      end,
    },
    {
      phase = "fading_out",
      walk = function(game)
        openMenu(game)
        confirmAction(game)
        advanceToPhase(game, "fading_out", 8)
      end,
    },
    {
      phase = "application",
      walk = function(game)
        openMenu(game)
        confirmAction(game)
        advanceToPhase(game, "application", 64)
      end,
    },
    {
      phase = "fading_in",
      walk = function(game)
        openMenu(game)
        confirmAction(game)
        advanceToPhase(game, "application", 64)
        game.runtime:pressCancel()
        game:step()
        game.runtime:releaseCancel()
        advanceToPhase(game, "fading_in", 64)
      end,
    },
  }
  for _, case in ipairs(cases) do
    local game = bootGame()
    local ok, err = xpcall(function()
      case.walk(game)
      Assert.equal(game.runtime.applicationHost:status().phase, case.phase, "the journey must reach " .. case.phase)
      game:close()
      Assert.equal(game.lifecycle.saveWrites, 1, case.phase .. " disposal must not checkpoint the field")
    end, debug.traceback)
    if not ok then
      error(err, 0)
    end
    game:close()
  end
end

-- The zero-action production composition: with no unlock flag set the
-- runtime's start-menu composition returns no interactive actions, so the
-- Source-present entries appear in the menu even when no implementations are
-- registered. The menu opens with disabled entries. Confirming a disabled
-- entry is a no-op; unlocking a destination with an implementation makes it
-- enabled and interactive. This test proves the production flag -> policy ->
-- menu-with-disabled-entries composition path.
function T.tests.zero_interactive_actions_make_the_menu_edge_a_noop_and_the_field_continues()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  game:waitForFieldEntry()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    local world = runtime.scripts.worldState

    -- The fixture precondition: a fresh boot seeds only scenario object
    -- flags, so every menu unlock flag starts unset.
    for _, flag in ipairs(UNLOCK_FLAGS) do
      Assert.equal(world:isFlagSet(flag), false, "the fresh boot must leave every menu unlock flag unset")
    end

    -- With no implementations available, the menu opens with source-present
    -- entries, all disabled. The host acquires the modal input lifetime and
    -- the menu surface appears.
    pressMenuEdge(game)
    local status = runtime.applicationHost:status()
    Assert.notNil(status.menu, "the menu must open with source-present entries")
    Assert.equal(status.menu.open, true, "the menu must be in open state")
    Assert.equal(runtime.errorText, nil, "opening the menu must not fail the runtime")
    Assert.equal(runtime.input.uiActive, true, "opening the menu must acquire the modal input lifetime")

    -- All menu entries are disabled, so confirming a selection is a no-op.
    -- The menu stays open. Pressing the menu key again to close it.
    runtime:pressAction()
    game:step()
    runtime:releaseAction()
    game:step()
    Assert.equal(runtime.applicationHost:status().menu.open, true, "confirming a disabled entry keeps menu open")

    -- Close the menu by pressing cancel.
    runtime:pressCancel()
    game:step()
    runtime:releaseCancel()
    advanceToPhase(game, "closed", 16)

    -- Unlock the trainer card and open the menu again: now it has an enabled
    -- action. The menu should reach the menu phase successfully.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local actions = runtime.applicationHost:status().menu.actions
    local enabledCount = 0
    local trainerCardFound = false
    for _, action in ipairs(actions) do
      if action.enabled then
        enabledCount = enabledCount + 1
      end
      if action.id == "vanilla.trainer_card" then
        trainerCardFound = true
        Assert.equal(action.enabled, true, "the trainer card action must be enabled")
      end
    end
    Assert.equal(enabledCount, 1, "the unlocked trainer card must be the only enabled interactive destination")
    Assert.equal(trainerCardFound, true, "the menu must include the trainer card action")
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.notNil(runtime:captureGameSave(), "closing the menu must restore the capturable boundary")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The production destination catalogue contains child applications only;
-- Save is dispatched separately as a field action.
function T.tests.the_runtime_registers_production_destinations_only()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = { saveStore = false },
  })
  game:waitForFieldEntry()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    Assert.equal(
      runtime.applications:has("trainer_card"),
      true,
      "the production runtime must register the trainer card itself"
    )
    Assert.equal(runtime.applications:has("save"), false, "Save must not be a child application")
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local actions = game.runtime.applicationHost:status().menu.actions
    local enabledActions = {}
    for _, action in ipairs(actions) do
      if action.enabled then
        enabledActions[#enabledActions + 1] = action
      end
    end
    local saveEnabled = false
    for _, action in ipairs(enabledActions) do
      saveEnabled = saveEnabled or action.id == "vanilla.save"
    end
    Assert.equal(saveEnabled, false, "Save must remain unavailable without its concrete handler")
    Assert.equal(
      enabledActions[1].id,
      "vanilla.trainer_card",
      "the trainer card stays the only enabled interactive action"
    )
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.equal(runtime:captureGameSave() ~= nil, true, "closing the menu must restore the capturable field boundary")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.manual_save_publishes_then_updates_through_the_menu_host()
  local game = bootGame()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
    ensureTouchPlacement(game, 256, 192)
    openMenu(game)
    activateActionById(game, "vanilla.save")
    Assert.equal(runtime.applicationHost:status().phase, "closed")
    Assert.equal(runtime.savePublished, true)
    ---@type { list: fun(self: table): table[] }
    local saveStore = assert(runtime.saveStore)
    Assert.equal(#saveStore:list(), 1, "the first manual save must publish exactly one reserved record")
    local first = assert(saveStore:list()[1])
    Assert.isTrue(first.saveId:find("^save%-", 1) ~= nil)
    local firstWrites = game.lifecycle.saveWrites

    openMenu(game)
    activateActionById(game, "vanilla.save")
    Assert.equal(#saveStore:list(), 1, "a later save must update the reserved identity, not add a logical record")
    Assert.equal(saveStore:list()[1].saveId, first.saveId, "the update must retain the same reserved save identity")
    Assert.isTrue(game.lifecycle.saveWrites > firstWrites, "a real update must issue a backend write")

    game:failNextSave()
    openMenu(game)
    activateActionById(game, "vanilla.save")
    Assert.equal(
      runtime.applicationHost:status().phase,
      "failed",
      "the injected write failure must surface as the production error boundary, not be swallowed"
    )
    Assert.notNil(runtime.applicationHost:error(), "the surfaced failure must carry the underlying save error")
    Assert.equal(#saveStore:list(), 1, "a failed write must not leave a duplicate or ghost logical record behind")
    Assert.equal(saveStore:list()[1].saveId, first.saveId, "a failed write must not change the published identity")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- A resize recomputes the shared placement and cancels an active menu
-- pointer capture, so a press held across the layout change cannot activate
-- a different post-resize slot. The production runtime exposes the resize
-- path; the capture cancellation is observed through the activation result
-- (without it, the same-slot release would launch the destination).
function T.tests.resize_cancels_an_active_menu_pointer_capture()
  local game = bootGame()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    ensureTouchPlacement(game, 256, 192)
    openMenu(game)
    local menu = assert(runtime.applicationHost:status().menu, "the start menu must be open")
    local target = nil ---@type table<string, unknown>?
    for _, action in ipairs(menu.actions) do
      if action.enabled then
        target = action
        break
      end
    end
    local chosen = assert(target, "the open menu must present an enabled action")
    local chosenPosition =
      assert((chosen --[[@as table<string, unknown>]]).position, "the action must carry its position")
    local preX, preY = hostPointForPosition(game, chosenPosition --[[@as integer]])
    runtime.input:pointerDown("touch:1", preX, preY)
    game:step()
    -- The capture is held across the resize. The published plan follows
    -- on the next tick (not synchronously), so one step re-resolves through
    -- the new measurement and discards the held press; the release then
    -- lands on the same canonical slot at the new scale and must be
    -- discarded by the cancellation (a press before a resize cannot
    -- activate post-resize).
    runtime:resizePresentation(1024, 768, touchTopology(1024, 768))
    game:step()
    local postX, postY = hostPointForPosition(game, chosenPosition --[[@as integer]])
    runtime.input:pointerUp("touch:1", postX, postY)
    game:step()
    Assert.equal(game.runtime.applicationHost:status().phase, "menu", "the menu must stay open")
    -- A fresh press after the resize lands on the same slot and activates.
    runtime.input:pointerDown("touch:1", postX, postY)
    runtime.input:pointerUp("touch:1", postX, postY)
    game:step()
    Assert.equal(
      game.runtime.applicationHost:status().phase,
      "fading_out",
      "the fresh press after the resize must activate the slot"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Normal visual composition admits exactly the icon-backed visual actions.
-- Retail gates every slot on its draw predicate with the context-to-icon
-- mapping (the cancel sentinel and the bookkeeping specials carry no icon
-- slot), so the visual menu holds the seven normal entries while the source
-- policy keeps its sentinel facts independently. An icon-backed disabled
-- entry stays visible and confirms as a no-op through the real pointer path.
function T.tests.normal_menu_presents_only_icon_backed_visual_actions()
  local game = bootGame()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    for _, flag in ipairs(UNLOCK_FLAGS) do
      game:setWorldState({ flag = flag })
    end
    ensureTouchPlacement(game, 256, 192)
    openMenu(game)
    local menu = assert(runtime.applicationHost:status().menu, "the start menu must be open")
    local presentedIds = {}
    for _, action in ipairs(menu.actions) do
      presentedIds[action.id] = true
    end
    Assert.keySet(
      presentedIds,
      "vanilla.bag,vanilla.options,vanilla.pokedex,vanilla.pokegear,vanilla.pokemon,vanilla.save,vanilla.trainer_card",
      "the normal visual menu holds exactly the seven icon-backed entries"
    )
    local facts = {
      hasPokedex = true,
      hasStarter = true,
      bagUnlocked = true,
      hasPokegear = true,
      trainerCardUnlocked = true,
      saveUnlocked = true,
      optionsUnlocked = true,
    }
    local policyIds = {}
    for _, entry in ipairs(StartMenuPolicy.actions(facts)) do
      policyIds[entry.id] = true
    end
    Assert.isTrue(policyIds["vanilla.running_shoes"], "the source policy retains the running-shoes sentinel")
    Assert.isTrue(policyIds["vanilla.special_9"], "the source policy retains the special-9 sentinel")
    Assert.isTrue(policyIds["vanilla.special_10"], "the source policy retains the special-10 sentinel")
    Assert.isTrue(
      presentedIds["vanilla.running_shoes"] == nil,
      "the cancel sentinel has no icon slot and is not a visual button"
    )
    Assert.isTrue(
      presentedIds["vanilla.special_9"] == nil,
      "the special-9 bookkeeping entry is not a visual button: vanilla.special_9"
    )
    Assert.isTrue(presentedIds["vanilla.special_10"] == nil, "the special-10 bookkeeping entry is not visual")
    local disabled = nil ---@type table<string, unknown>?
    for _, action in ipairs(menu.actions) do
      local candidate = action --[[@as table<string, unknown>]]
      if candidate["enabled"] == false then
        disabled = candidate
        break
      end
    end
    local target = assert(disabled, "the open menu must present an icon-backed disabled action")
    local targetId = assert((target --[[@as { id: string }]]).id, "the disabled action must carry its id")
    local targetPosition =
      assert((target --[[@as { position: integer }]]).position, "the disabled action must carry its position")
    local hostX, hostY = hostPointForPosition(game, targetPosition)
    runtime.input:pointerDown("touch:1", hostX, hostY)
    runtime.input:pointerUp("touch:1", hostX, hostY)
    game:step()
    Assert.equal(
      runtime.applicationHost:status().phase,
      "menu",
      "confirming the disabled entry " .. tostring(targetId) .. " keeps the menu open"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Presentation changes must not change application lifetime: one modal input
-- lifetime spans menu, child, and return; both fades keep their twelve-tick
-- cadence; the modal never leaks ticks into world simulation; the published
-- plan owns drawing and input together, with transition fade coverage on a
-- native host and an empty fade coverage on a static framed host that leaves
-- the paused world visible outside itself.
function T.tests.menu_child_return_keeps_one_lifetime_twelve_tick_fades_and_plan_coverage()
  local game = bootGame()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    local input = runtime.input
    local begun, cleared = 0, 0
    local beginUi = input.beginUi
    local clearUi = input.clearUi
    input.beginUi = function(self, tick)
      begun = begun + 1
      return beginUi(self, tick)
    end
    input.clearUi = function(self)
      cleared = cleared + 1
      return clearUi(self)
    end
    local function phase()
      return runtime.applicationHost:status().phase
    end
    local function stepTo(next, cap, label)
      local ticks = 0
      while phase() ~= next and ticks < cap do
        game:step()
        ticks = ticks + 1
      end
      Assert.equal(phase(), next, label)
      return ticks
    end

    ensureTouchPlacement(game, 640, 480)
    openMenu(game)
    Assert.equal(begun, 1, "opening the menu must begin the modal input lifetime once")
    local hostStatus = runtime.applicationHost:status()
    local plan = assert(hostStatus.menu.presentation, "the open menu must publish its presentation plan")
    Assert.isTrue(
      #(assert(plan.fadeCoverage, "the native plan names its transition region")) >= 1,
      "a fullscreen native plan must own its transition region"
    )
    local session = assert(runtime.session, "the field session must exist")
    local playerX, playerZ = session.player.fieldX, session.player.fieldZ
    local edge = "modality-probe:south"
    runtime.input:pressDirection("south", edge)
    game:step()
    runtime.input:releaseDirection(edge)
    game:step()
    Assert.equal(session.player.fieldX, playerX, "modal ticks must not move the player")
    Assert.equal(session.player.fieldZ, playerZ, "modal ticks must not move the player")
    Assert.equal(
      runtime.applicationHost:status().menu.selectedPosition,
      5,
      "the kept navigation must still drive the modal"
    )
    edge = "modality-probe:north"
    runtime.input:pressDirection("north", edge)
    game:step()
    runtime.input:releaseDirection(edge)
    game:step()

    activateActionById(game, "vanilla.trainer_card")
    Assert.equal(phase(), "fading_out", "launching a destination must start the fade-out")
    Assert.equal(stepTo("application", 16, "the fade-out must reach the child"), 12, "the fade-out keeps twelve ticks")
    Assert.equal(begun, 1, "the child must not begin a second input lifetime")
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    Assert.equal(phase(), "fading_in", "closing the child must start the fade-in")
    Assert.equal(stepTo("menu", 16, "the fade-in must return to the menu"), 12, "the fade-in keeps twelve ticks")
    Assert.equal(
      runtime.applicationHost:status().menu.selectedPosition,
      4,
      "the return must remember the launched selection"
    )
    Assert.equal(begun, 1, "the return must not begin a second input lifetime")
    Assert.equal(cleared, 0, "the return must not release the input lifetime early")
    pressMenuEdge(game)
    stepTo("closed", 16, "the menu must close")
    Assert.equal(cleared, 1, "closing the menu must release the input lifetime once")

    ensureTouchPlacement(game, 1280, 720)
    openMenu(game)
    local wide = runtime.applicationHost:status()
    local widePlan = assert(wide.menu.presentation, "the wide host must publish its presentation plan")
    Assert.equal(#assert(widePlan.frames, "a wide host must frame the menu"), 1, "one static box frames the menu")
    Assert.equal(#(widePlan.fadeCoverage or {}), 0, "a static frame owns no transition region")
    pressMenuEdge(game)
    stepTo("closed", 16, "the framed menu must close")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The Trainer Card follows the shared interface policy instead of the
-- field camera: on a wide host it owns one source-sized content pane in a
-- static framed box with no position memory, a field viewport refit keeps
-- its logical content and input geometry stable, a physical pair hosts it
-- on the auxiliary surface without a frame, and closing reports exactly
-- one result.
function T.tests.trainer_card_follows_interface_policy_not_camera_zoom()
  local game = bootGame()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    local function openCard()
      -- The menu persists across a child close (the host returns to
      -- the menu phase), while the menu edge toggles: pressing it while
      -- the menu is already open would close it, so only open the menu
      -- from outside it. Both paths launch the card from an open menu.
      if runtime.applicationHost:status().phase ~= "menu" then
        openMenu(game)
      end
      activateActionById(game, "vanilla.trainer_card")
      local ticks = 0
      while runtime.applicationHost:status().phase ~= "application" and ticks < 24 do
        game:step()
        ticks = ticks + 1
      end
      Assert.equal(runtime.applicationHost:status().phase, "application", "the card must open as a child application")
      return assert(runtime.applicationHost:status().application, "the open card must expose its status")
    end
    local function closeCard()
      game.runtime:pressCancel()
      game:step()
      game.runtime:releaseCancel()
      Assert.equal(runtime.applicationHost:status().phase, "fading_in", "closing the card must start the fade-in")
      local ticks = 0
      while runtime.applicationHost:status().phase ~= "menu" and ticks < 16 do
        game:step()
        ticks = ticks + 1
      end
      Assert.equal(runtime.applicationHost:status().phase, "menu", "the close must return to the menu")
    end
    ensureTouchPlacement(game, 1280, 720)
    local plan = assert(openCard().presentation, "the open card must publish its presentation plan")
    Assert.equal(type(plan.inputKey), "string", "the card plan must name its input geometry")
    local contentKey = plan.inputKey
    Assert.equal(#plan.panes, 1, "the wide card shows one content pane")
    local placement = assert(plan.panes[1].placement, "the content pane must carry its placement")
    Assert.equal(placement.logicalWidth, 256, "the card content stays source-sized")
    Assert.equal(placement.logicalHeight, 192, "the card content stays source-sized")
    local frame =
      assert(assert(plan.frames, "the wide card must own its static frame")[1], "one outer frame decorates the card")
    local outerBefore = { x = frame.placement.frame.x, y = frame.placement.frame.y }
    -- A press on the decorative frame border is application interior: it
    -- moves nothing and closes nothing.
    local startX, startY = frame.placement.frame.x + 4, frame.placement.frame.y + 4
    runtime.input:pointerDown("touch:1", startX, startY)
    game:step()
    runtime.input:pointerMove("touch:1", startX + 120, startY + 60)
    game:step()
    runtime.input:pointerUp("touch:1", startX + 120, startY + 60)
    game:step()
    local settled = assert(
      runtime.applicationHost:status().application.presentation,
      "the card must keep its plan after the frame press"
    )
    Assert.equal(runtime.applicationHost:status().phase, "application", "a frame press must not close the card")
    local settledOuter = assert(settled.frames, "the card must stay framed after the press")[1].placement.frame
    Assert.deepEqual(
      { x = settledOuter.x, y = settledOuter.y },
      { x = outerBefore.x, y = outerBefore.y },
      "static frames never move: the frame press changes no geometry"
    )
    closeCard()
    local reopened = assert(openCard().presentation, "the reopened card must publish its plan")
    local reopenedOuter = assert(reopened.frames, "the reopened card must own its frame")[1].placement.frame
    Assert.deepEqual(
      { x = reopenedOuter.x, y = reopenedOuter.y },
      { x = outerBefore.x, y = outerBefore.y },
      "no position memory survives the reopen: the frame recenters deterministically"
    )
    -- a field viewport refit (which drives field zoom on the old path)
    -- keeps the card's logical content and input geometry stable
    game.runtime:resizePresentation(1280, 600, touchTopology(1280, 600))
    game:step()
    local refit =
      assert(runtime.applicationHost:status().application.presentation, "the card must keep its plan across the refit")
    Assert.equal(refit.inputKey, contentKey, "the refit must not change the input geometry")
    Assert.equal(#refit.panes, 1, "the refit keeps one content pane")
    Assert.equal(
      assert(refit.panes[1].placement, "the refit pane must carry its placement").logicalWidth,
      256,
      "the refit keeps source-sized content"
    )
    -- a physical pair hosts the card on the auxiliary surface with no outer frame
    game.runtime:resizePresentation(
      800,
      600,
      ScreenTopology.dualDisplay({
        id = "main",
        rect = { x = 400, y = 100, width = 256, height = 192 },
        touch = true,
        role = "world",
      }, {
        id = "sub",
        rect = { x = 100, y = 300, width = 256, height = 192 },
        touch = false,
        role = "auxiliary",
      })
    )
    game:step()
    local dual =
      assert(runtime.applicationHost:status().application.presentation, "the card must keep its plan on the pair")
    Assert.deepEqual(dual.frames, {}, "the auxiliary card needs no frame")
    local dualFrame = assert(dual.panes[1].placement, "the dual pane must carry its placement").frame
    Assert.isTrue(
      dualFrame.x >= 100
        and dualFrame.y >= 300
        and dualFrame.x + dualFrame.width <= 356
        and dualFrame.y + dualFrame.height <= 492,
      "the pair hosts the card on the auxiliary surface"
    )
    -- closing reports exactly once: the return reaches the menu and the
    -- card opens again cleanly
    closeCard()
    openCard()
    closeCard()
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
