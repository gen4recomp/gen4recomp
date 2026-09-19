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
-- the real unlock flag makes the production Trainer Card interactive.
local function bootGame()
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
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

-- The published placement record carries frame/scale/logical dimensions; the
-- shared logical mapper additionally requires an origin, which is exactly
-- the frame origin on this host. Synthesized here for readout only.
local function readablePlacement(runtime)
  local placement = assert(runtime.startMenuPlacement, "the runtime must publish the start menu placement record")
  return {
    frame = placement.frame,
    origin = placement.origin or { x = placement.frame.x, y = placement.frame.y },
    scale = placement.scale,
    logicalWidth = placement.logicalWidth,
    logicalHeight = placement.logicalHeight,
  }
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
  return LayoutGeometry.logicalToHost(readablePlacement(runtime), centerX, centerY)
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
    -- The capture is held across the resize; the release lands on the same
    -- canonical slot at the new scale and must be discarded by the
    -- cancellation (a press before a resize cannot activate post-resize).
    runtime:resizePresentation(1024, 768, touchTopology(1024, 768))
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

return T
