-- Production-composed field Bag inventory actions: obtain through the real
-- generated item-ball routine, browse through Start Menu -> Bag, reorder and
-- toss through the Bag action states, then save, reload, and prove the
-- persisted quantities and order. A second journey proves the two-slot
-- key-item registration lifecycle through the same production composition.
-- Only host boundaries (save-root location, recording audio/event adapters,
-- render trap) stand in for production; maps, scripts, actors, the generated
-- item catalog, and the save composition stay production. No renderer or GPU
-- call may occur on either journey.
--
-- Distinct boundary this file protects: the end-to-end mutate/persist/
-- register journeys (obtain -> browse -> reorder/toss/register -> save ->
-- reload). The generated-routine failure branch lives in the item-script
-- acceptance boot; this file owns the success-path grant plus everything
-- downstream of it.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "bag" },
  },
  tests = {},
}

local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG
local BAG_ACTION = "vanilla.bag"
local BAG_APPLICATION = FieldApplicationIds.BAG

-- Generated Lake of Rage item-ball routine: scr_seq member 938 (the Lake of
-- Rage script bank), script index 16, bound to the map's item-ball object
-- event 12 carrying raw script id 17. It grants native item 23 (one copy of
-- a tossable manual-order medicine item) on the room-available branch and
-- reports the source success result.
local GRANT_MAP = "MAP_LAKE_OF_RAGE"
local GRANT_SCRIPT_ID = "vanilla.hgss.scr_seq.0938.script_016"
local BALL_ACTOR_ID = "map:88:object:12"
local BALL_REMOVAL_FLAG = 652
local GRANTED_KEY = "FULL_RESTORE"
local SECOND_KEY = "POTION"
local SUCCESS_RESULT = 1

local FIRST_REGISTER_KEY = "BICYCLE"
local SECOND_REGISTER_KEY = "OLD_ROD"

local function lakeHarness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        -- Factory coordinates are origin-relative: the Lake of Rage scene
        -- origin sits 512,32 ahead of the generated event frame, so local
        -- (30,15) places the player on the map-space tile (542,47),
        -- directly east of the item ball at (541,47).
        location = { mapSymbol = GRANT_MAP, fieldX = 30, fieldZ = 15, facing = "west" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = BagSave.empty(),
      }
    end,
  })
end

-- The same FieldState callbacks LOVE dispatches in production. No synthetic
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
  error("start menu never focuses the bag action", 0)
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

local function tapDirection(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

-- The Bag application's browse status, reached through the production host.
local function bagView(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(
    status.phase,
    FieldApplicationHost.PHASES.application,
    "the bag application must own the tick while open"
  )
  Assert.equal(status.applicationId, BAG_APPLICATION, "the launched application must be the bag")
  local view = assert(status.application, "the bag application must expose its status")
  assert(type(view) == "table", "the bag status must be a record")
  return view
end

local function viewPocket(view)
  local pocket = view.pocket
  Assert.isTrue(type(pocket) == "string" and pocket ~= "", "the bag status must name its current pocket")
  return pocket
end

local function viewSlots(view)
  local slots = view.visibleSlots
  Assert.isTrue(type(slots) == "table", "the bag status must list its item slots")
  return slots
end

local function viewSelected(view)
  return view.selected
end

local function slotKey(slot)
  assert(type(slot) == "table", "bag slots must be records")
  local key = slot.item
  assert(type(key) == "string" and key ~= "", "bag slots must carry their item key")
  return key
end

local function slotQuantity(slot)
  local quantity = slot.quantity
  assert(type(quantity) == "number" and quantity % 1 == 0 and quantity > 0, "bag slots must carry a quantity")
  return quantity
end

local function selectedKey(view)
  local selected = viewSelected(view)
  if selected == nil then
    return nil
  end
  return slotKey(selected)
end

local function openBag(game, state)
  openStartMenu(game)
  local action = actionById(menuStatus(game), BAG_ACTION)
  Assert.isTrue(
    action ~= nil and action.enabled == true,
    "the unlocked bag must enable its start menu action through policy/capability composition"
  )
  navigateTo(game, state, BAG_ACTION)
  confirm(game)
  game:advanceUntil("bag application launches through the host fade", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.application
  end, 120)
  return bagView(game)
end

local function closeBagToMenu(game)
  pressCancel(game)
  game:advanceUntil("bag closes back to the start menu", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 120)
end

-- Patrol normal directional input until the predicate observes the wanted
-- browse state.
local function driveUntil(game, state, label, maxSteps, predicate)
  local keys = { "d", "s", "a", "w" }
  for step = 1, maxSteps do
    if predicate() then
      return
    end
    tapDirection(game, state, keys[((step - 1) % #keys) + 1])
  end
  error("bag browse never reaches " .. label .. " through directional input", 0)
end

local function pocketOrder(service, pocket)
  local keys = {}
  for _, slot in ipairs(service:pocketItems(pocket)) do
    keys[#keys + 1] = slotKey(slot)
  end
  return keys
end

-- Cursor access reads the production cursor object directly: the contract
-- under test is that the cursor exists at runtime, never enters the save
-- bucket, and restarts at the default pocket.
local function cursorPocket(cursor)
  Assert.notNil(cursor, "field runtime owns the field bag cursor")
  return cursor:currentPocket()
end

-- Confirming the selected item must open the action menu listing the
-- inventory-local actions for that item.
local function openActionMenu(game)
  confirm(game)
  game:step()
  game:step()
  local view = bagView(game)
  Assert.equal(view.state, "action_menu", "confirming an item must open the action menu")
  local actions = assert(view.actions, "the action menu must list its actions")
  Assert.isTrue(#actions >= 2, "the action menu must offer an action plus cancel")
  return view
end

local function actionIds(view)
  local ids = {}
  for _, action in ipairs(assert(view.actions, "the action menu must list its actions")) do
    assert(type(action.id) == "string" and action.id ~= "", "menu actions must carry a semantic id")
    ids[#ids + 1] = action.id
  end
  return ids
end

-- The action menu selection is a zero-based index into the action list.
local function selectedActionId(view)
  local actions = assert(view.actions, "the action menu must list its actions")
  local selection = view.selectedAction
  assert(type(selection) == "number", "the action menu must expose its selection")
  local record = assert(actions[selection + 1], "the selected action must resolve")
  return assert(record.id, "the selected action must carry its id")
end

local function hasAction(view, id)
  for _, candidate in ipairs(actionIds(view)) do
    if candidate == id then
      return true
    end
  end
  return false
end

-- Drive the action menu selection to the wanted semantic action through
-- ordinary vertical input, then confirm it.
local function chooseAction(game, state, id)
  local view = bagView(game)
  Assert.equal(view.state, "action_menu", "choosing an action requires the open action menu")
  local count = #assert(view.actions, "the action menu must list its actions")
  for _ = 1, count + 1 do
    if selectedActionId(bagView(game)) == id then
      confirm(game)
      game:step()
      game:step()
      return bagView(game)
    end
    tapDirection(game, state, "s")
  end
  error("the action menu never selects " .. id, 0)
end

-- Drive the quantity picker to the wanted amount through ordinary horizontal
-- input.
local function setQuantity(game, state, wanted)
  for _ = 1, 2 * 999 + 4 do
    local view = bagView(game)
    Assert.equal(view.state, "toss_quantity", "setting a quantity requires the quantity picker")
    local current = assert(view.quantity, "the quantity picker must expose its amount")
    assert(type(current) == "number", "the quantity picker must expose its amount")
    if current == wanted then
      return view
    elseif current < wanted then
      tapDirection(game, state, "d")
    else
      tapDirection(game, state, "a")
    end
  end
  error("the quantity picker never reaches " .. tostring(wanted), 0)
end

-- Return to plain browsing from any nested action state through bounded
-- cancel presses; every cancel level must preserve the inventory.
local function backToBrowsing(game)
  for _ = 1, 6 do
    local view = bagView(game)
    if view.state == nil or view.state == "browsing" then
      return view
    end
    pressCancel(game)
    game:step()
  end
  error("cancel never returns the bag to browsing", 0)
end

-- Establish the seeded ball precondition through production state: clear
-- the ball's removal flag, let the runtime flush the pending flag change,
-- and require the generated ball object to be live before any interaction.
---@param game AcceptanceGame
local function seedBallVisible(game)
  game.runtime.eventState:clearFlag(BALL_REMOVAL_FLAG)
  game:step()
  game:step()
  Assert.notNil(game.runtime.actors:getById(BALL_ACTOR_ID), "the seeded item ball must be live before interaction")
end

-- Drive the grant routine to its source End while watching for the
-- production dialogue message that carries the buffered item text: the
-- routine must show a message referencing a compiled message resource, not
-- merely mutate the inventory silently.
---@param game AcceptanceGame
---@return { ended: boolean, fault: string|nil, completed: boolean, reason: string|nil, sawMessage: boolean }
local function driveGrantToEnd(game)
  local sawMessage = false
  for _ = 1, 6000 do
    if game.runtime.errorText ~= nil then
      return {
        ended = false,
        fault = tostring(game.runtime.errorText),
        completed = false,
        reason = nil,
        sawMessage = sawMessage,
      }
    end
    for _, record in ipairs(game:recordsNamed("script.ended")) do
      if record.payload.scriptId == GRANT_SCRIPT_ID then
        local completed = record.payload.completed == true
        return {
          ended = true,
          fault = nil,
          completed = completed,
          reason = record.payload.reason,
          sawMessage = sawMessage,
        }
      end
    end
    local snapshot = game:snapshot()
    if snapshot.dialogue.modal or snapshot.fieldLocked then
      local dialogue = snapshot.dialogue
      if
        dialogue.bankId ~= nil
        or dialogue.messageId ~= nil
        or (dialogue.visibleLines ~= nil and #dialogue.visibleLines > 0)
      then
        sawMessage = true
      end
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  return {
    ended = false,
    fault = "the grant routine did not end within the tick bound",
    completed = false,
    reason = nil,
    sawMessage = sawMessage,
  }
end

-- Obtain through the real script flow, browse through the real Bag
-- application, reorder and toss through the Bag action states, save through
-- the production path, reload, and prove the persisted quantities and order
-- while the runtime-only cursor resets.
function T.tests.obtain_browse_mutate_save_reload_round_trip()
  local game = lakeHarness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = GRANT_MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:advanceUntil("field ready for ordinary input", function(snapshot)
      return not snapshot.fieldLocked and not snapshot.dialogue.modal
    end, 480)
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_BAG })

    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.equal(bag:quantity(GRANTED_KEY), 0, "the fresh bag holds no copy before the grant")
    Assert.isTrue(bag:add(SECOND_KEY, 5), "stocking a second manual-order item must succeed")
    Assert.equal(
      bag:pocketOf(SECOND_KEY),
      bag:pocketOf(GRANTED_KEY),
      "both journey items must share one manual-order pocket"
    )
    local revision = bag:revision()

    seedBallVisible(game)
    game:face("west")
    game:pressAction()
    local outcome = driveGrantToEnd(game)
    Assert.isNil(outcome.fault, "the grant routine must run without a runtime fault")
    Assert.isTrue(outcome.ended, "the grant routine must end")
    Assert.isTrue(outcome.completed, "the grant routine must reach its source End: " .. tostring(outcome.reason))
    Assert.isTrue(outcome.sawMessage, "the grant routine must show the buffered item message")
    Assert.equal(
      game.runtime.scripts.worldState:getVar("VAR_SPECIAL_RESULT"),
      SUCCESS_RESULT,
      "the routine must leave the source success result"
    )
    Assert.equal(bag:quantity(GRANTED_KEY), 1, "the grant must add exactly one copy")
    Assert.equal(bag:revision(), revision + 1, "the grant must mutate the live service exactly once")

    local view = openBag(game, state)
    driveUntil(game, state, "the stocked medicine pocket", 160, function()
      return viewPocket(bagView(game)) == bag:pocketOf(GRANTED_KEY)
    end)
    view = bagView(game)
    local shown = {}
    for _, slot in ipairs(viewSlots(view)) do
      if not slot.empty then
        shown[slotKey(slot)] = slotQuantity(slot)
      end
    end
    Assert.equal(shown[GRANTED_KEY], 1, "the browse status must show the granted quantity")
    Assert.equal(shown[SECOND_KEY], 5, "the browse status must show the stocked quantity")
    Assert.deepEqual(
      pocketOrder(bag, bag:pocketOf(GRANTED_KEY)),
      { SECOND_KEY, GRANTED_KEY },
      "the manual pocket must preserve insertion order"
    )

    -- Cursor memory: select the granted item, leave the pocket, return, and
    -- prove the same item is selected again.
    driveUntil(game, state, "the granted item", 60, function()
      return selectedKey(bagView(game)) == GRANTED_KEY
    end)
    driveUntil(game, state, "another pocket", 120, function()
      return viewPocket(bagView(game)) ~= bag:pocketOf(GRANTED_KEY)
    end)
    driveUntil(game, state, "the medicine pocket again", 160, function()
      return viewPocket(bagView(game)) == bag:pocketOf(GRANTED_KEY)
    end)
    Assert.equal(selectedKey(bagView(game)), GRANTED_KEY, "returning must restore the remembered selection")

    -- Cancelling the action menu returns to browsing with no mutation.
    revision = bag:revision()
    openActionMenu(game)
    backToBrowsing(game)
    Assert.equal(bag:revision(), revision, "cancelling the action menu must not mutate the inventory")
    Assert.equal(bag:quantity(SECOND_KEY), 5, "cancelling the action menu must not change quantities")

    -- Manual reorder of the two items through the move state.
    view = openActionMenu(game)
    Assert.isTrue(hasAction(view, "move"), "a manual pocket with two items must offer to move")
    view = chooseAction(game, state, "move")
    Assert.equal(view.state, "move_select", "choosing move must enter target selection")
    tapDirection(game, state, "w")
    confirm(game)
    game:step()
    game:step()
    view = backToBrowsing(game)
    Assert.deepEqual(
      pocketOrder(bag, bag:pocketOf(GRANTED_KEY)),
      { GRANTED_KEY, SECOND_KEY },
      "the open model must reflect the manual reorder"
    )
    Assert.equal(bag:revision(), revision + 1, "the reorder must mutate the live service exactly once")
    Assert.equal(selectedKey(view), GRANTED_KEY, "a successful reorder keeps the moved item selected")
    revision = bag:revision()

    -- Toss a non-zero quantity that leaves at least one copy.
    driveUntil(game, state, "the stocked item", 60, function()
      return selectedKey(bagView(game)) == SECOND_KEY
    end)
    view = openActionMenu(game)
    Assert.isTrue(hasAction(view, "toss"), "a tossable item must offer to toss")
    view = chooseAction(game, state, "toss")
    Assert.equal(view.state, "toss_quantity", "choosing toss must enter the quantity picker")
    setQuantity(game, state, 2)
    confirm(game)
    game:step()
    game:step()
    view = bagView(game)
    Assert.equal(view.state, "toss_confirm", "confirming a quantity must ask for confirmation")
    confirm(game)
    game:step()
    game:step()
    Assert.equal(bag:quantity(SECOND_KEY), 3, "the toss must remove exactly the confirmed quantity")
    Assert.equal(bag:revision(), revision + 1, "the toss must mutate the live service exactly once")
    backToBrowsing(game)

    -- Close Bag -> Start Menu -> field, then save through the production
    -- capture path.
    local before = game:snapshot()
    closeBagToMenu(game)
    Assert.equal(cursorActionId(menuStatus(game)), BAG_ACTION, "closing the bag must remember the bag menu selection")
    closeStartMenu(game)
    local resumed = game:snapshot()
    Assert.equal(resumed.mapId, before.mapId, "closing the menu must keep the same map")
    Assert.isTrue(game.runtime:captureGameSave() ~= nil, "quit-save requires a stable captured game")
    game:save()
    game:restart()
    game:waitForFieldEntry()

    local reloaded = assert(game.runtime.bagService, "continue must restore the live bag service")
    Assert.isTrue(
      game.runtime.eventState:isFlagSet(BALL_REMOVAL_FLAG),
      "map entry must retire the taken ball through its removal flag"
    )
    Assert.isNil(
      game.runtime.actors:getById(BALL_ACTOR_ID),
      "continue must not resurrect the taken ball whose record the save still holds"
    )
    Assert.equal(reloaded:quantity(GRANTED_KEY), 1, "continue must restore the granted quantity")
    Assert.equal(reloaded:quantity(SECOND_KEY), 3, "continue must restore the tossed quantity")
    Assert.deepEqual(
      pocketOrder(reloaded, reloaded:pocketOf(GRANTED_KEY)),
      { GRANTED_KEY, SECOND_KEY },
      "continue must restore the exact manual order"
    )
    Assert.equal(cursorPocket(game.runtime.bagCursor), "items", "continue must reset the field cursor")

    -- Reopen the Bag and prove the persisted model is what browsing shows.
    state = hostCallbacks(game)
    view = openBag(game, state)
    driveUntil(game, state, "the stocked medicine pocket after reload", 160, function()
      return viewPocket(bagView(game)) == reloaded:pocketOf(GRANTED_KEY)
    end)
    view = bagView(game)
    local reopened = {}
    for _, slot in ipairs(viewSlots(view)) do
      if not slot.empty then
        reopened[#reopened + 1] = slotKey(slot)
      end
    end
    Assert.deepEqual(reopened, { GRANTED_KEY, SECOND_KEY }, "reopening must show the persisted order")
    closeBagToMenu(game)
    closeStartMenu(game)

    -- Removed actors must not leak into the save through queued
    -- destruction: reseed the ball live, mark it removed through its
    -- durable source flag while it is still live, save before the sync
    -- boundary runs, reload through the production path, and prove it
    -- stays gone with the bag intact. The generated grant routine leaves
    -- the source flag to the collector, so the harness helper writes the
    -- same durable signal a collecting script would; no step may run
    -- between the flag write and the save.
    seedBallVisible(game)
    game:setActorRemovalFlag(BALL_ACTOR_ID)
    Assert.isTrue(
      game.runtime.eventState:isFlagSet(BALL_REMOVAL_FLAG),
      "the durable removal signal must be visible on the runtime state"
    )
    Assert.isNil(
      game.runtime.actors:captureObjects().actors[BALL_ACTOR_ID],
      "manager capture must omit the flagged ball before queued destruction"
    )
    Assert.notNil(
      game.runtime.actors:getById(BALL_ACTOR_ID),
      "queued removal must not destroy the actor before the sync boundary"
    )
    Assert.isTrue(game.runtime:captureGameSave() ~= nil, "quit-save requires a stable captured game")
    game:save()
    game:restart()
    game:waitForFieldEntry()
    Assert.isNil(game.runtime.actors:getById(BALL_ACTOR_ID), "continue must not resurrect the removed ball")
    local reread = assert(game.runtime.bagService, "continue must restore the live bag service")
    Assert.equal(reread:quantity(GRANTED_KEY), 1, "continue must keep the granted quantity")
    Assert.equal(reread:quantity(SECOND_KEY), 3, "continue must keep the tossed quantity")
    Assert.equal(game:renderAttempts(), 0, "the journey must stop before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

-- Register two owned key items, unregister the first to prove the source
-- slot shift, save and reload to prove persistence, then remove the final
-- copy to prove registration clears.
function T.tests.registration_lifecycle_persists_and_clears()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local state = hostCallbacks(game)
    game:setWorldState({ flag = FLAG_GOT_BAG })

    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(bag:isRegisterable(FIRST_REGISTER_KEY), "setup requires a registerable key item")
    Assert.isTrue(bag:isRegisterable(SECOND_REGISTER_KEY), "setup requires a second registerable key item")
    Assert.isTrue(bag:add(FIRST_REGISTER_KEY, 1), "stocking the first key item must succeed")
    Assert.isTrue(bag:add(SECOND_REGISTER_KEY, 1), "stocking the second key item must succeed")

    local view = openBag(game, state)
    driveUntil(game, state, "the key items pocket", 160, function()
      return viewPocket(bagView(game)) == "key_items"
    end)
    driveUntil(game, state, "the first key item", 60, function()
      return selectedKey(bagView(game)) == FIRST_REGISTER_KEY
    end)

    view = openActionMenu(game)
    Assert.isTrue(hasAction(view, "register"), "an unregistered registerable item must offer to register")
    Assert.isFalse(hasAction(view, "unregister"), "an unregistered item must not offer to unregister")
    chooseAction(game, state, "register")
    backToBrowsing(game)
    Assert.deepEqual(bag:registeredItems(), { FIRST_REGISTER_KEY }, "registering must claim the first slot")

    driveUntil(game, state, "the second key item", 60, function()
      return selectedKey(bagView(game)) == SECOND_REGISTER_KEY
    end)
    view = openActionMenu(game)
    chooseAction(game, state, "register")
    backToBrowsing(game)
    Assert.deepEqual(
      bag:registeredItems(),
      { FIRST_REGISTER_KEY, SECOND_REGISTER_KEY },
      "registering the second item must fill the second slot in order"
    )

    -- The registered second item sits in the right grid column, so one
    -- ordinary west step returns to the first item; a pocket patrol would
    -- walk away instead of stepping left within the row.
    Assert.equal(selectedKey(bagView(game)), SECOND_REGISTER_KEY, "registering keeps the registered item selected")
    tapDirection(game, state, "a")
    Assert.equal(selectedKey(bagView(game)), FIRST_REGISTER_KEY, "one west step returns to the first key item")
    view = openActionMenu(game)
    Assert.isTrue(hasAction(view, "unregister"), "a registered item must offer to unregister")
    Assert.isFalse(hasAction(view, "register"), "a registered item must not offer to register again")
    chooseAction(game, state, "unregister")
    backToBrowsing(game)
    Assert.deepEqual(
      bag:registeredItems(),
      { SECOND_REGISTER_KEY },
      "unregistering the first slot must shift the second forward"
    )

    closeBagToMenu(game)
    closeStartMenu(game)
    Assert.isTrue(game.runtime:captureGameSave() ~= nil, "quit-save requires a stable captured game")
    game:save()
    game:restart()
    game:waitForFieldEntry()

    local reloaded = assert(game.runtime.bagService, "continue must restore the live bag service")
    Assert.deepEqual(
      reloaded:registeredItems(),
      { SECOND_REGISTER_KEY },
      "continue must persist the shifted registration"
    )
    Assert.equal(cursorPocket(game.runtime.bagCursor), "items", "continue must reset the field cursor")
    Assert.isTrue(
      reloaded:take(SECOND_REGISTER_KEY, 1),
      "removing the final copy must succeed through the live service"
    )
    Assert.deepEqual(reloaded:registeredItems(), {}, "removing the final copy must clear registration")

    state = hostCallbacks(game)
    view = openBag(game, state)
    driveUntil(game, state, "the key items pocket after reload", 160, function()
      return viewPocket(bagView(game)) == "key_items"
    end)
    Assert.equal(selectedKey(bagView(game)), FIRST_REGISTER_KEY, "the pocket must show only the remaining key item")
    closeBagToMenu(game)
    closeStartMenu(game)
    Assert.equal(game:renderAttempts(), 0, "the journey must stop before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

return T
