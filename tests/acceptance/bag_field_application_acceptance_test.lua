-- Production-composed field Bag topology contract. A real field runtime
-- owns the live Bag service and cursor: the Start Menu offers the Bag route
-- once the source Bag flag is set and confirming it opens the Bag
-- application through the host fade. This journey proves a structural
-- topology change preserves the semantic selection and that a pointer press
-- held across the change cannot activate a moved target. Browse quantities,
-- cursor memory, and action flows live in the bag actions integration
-- journey; this file keeps the distinct topology/stale-capture boundary.
-- Only host boundaries (saves, render trap) are faked; maps, scripts,
-- actors, the generated item catalog, and the save composition stay
-- production. No renderer or GPU call may occur on the journey.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BagCache = require("libs.assets.src.BagCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "menu", "bag" },
  },
  tests = {},
}

local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG
local BAG_ACTION = "vanilla.bag"
local BAG_APPLICATION = FieldApplicationIds.BAG

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "bag acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
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

-- Stock the live service through the production inventory boundary and prove
-- the stocked items live in two distinct pockets.
local function stockTwoPockets(game)
  local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
  Assert.isTrue(bag:add("POTION", 5), "setup stock must enter the bag through the production service")
  Assert.isTrue(bag:add("POKE_BALL", 3), "setup stock must enter the bag through the production service")
  Assert.isTrue(bag:add("GREAT_BALL", 2), "setup stock must enter the bag through the production service")
  Assert.equal(bag:pocketOf("POTION"), "medicine", "setup medicine must live in the medicine pocket")
  Assert.equal(bag:pocketOf("POKE_BALL"), "balls", "setup balls must live in the balls pocket")
  Assert.equal(bag:pocketOf("GREAT_BALL"), "balls", "setup second ball must live in the balls pocket")
  return bag
end

local function grantBag(game)
  game:setWorldState({ flag = FLAG_GOT_BAG })
end

-- The Bag application's browse status, reached through the production host.
-- Readers stay tolerant of record plumbing while the semantic core (pocket
-- key, per-slot item key plus quantity, selected record or nil) is required.
local function bagView(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(
    status.phase,
    FieldApplicationHost.PHASES.application,
    "the bag application must own the tick while browsing"
  )
  Assert.equal(status.applicationId, BAG_APPLICATION, "the launched application must be the bag")
  local view = assert(status.application, "the bag application must expose its browse status")
  assert(type(view) == "table", "the bag browse status must be a record")
  return view
end

local function viewPocket(view)
  local pocket = view.pocket ~= nil and view.pocket or view.currentPocket
  Assert.isTrue(type(pocket) == "string" and pocket ~= "", "the bag status must name its current pocket")
  return pocket
end

local function viewSelected(view)
  return view.selected
end

local function slotKey(slot)
  assert(type(slot) == "table", "bag slots must be records")
  local key = slot.item or slot.itemKey or slot.key
  assert(type(key) == "string" and key ~= "", "bag slots must carry their item key")
  return key
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

local function tapDirection(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

-- Patrol normal directional input until the predicate observes the wanted
-- browse state. Pocket switching and item selection must both stay reachable
-- through ordinary directions; no shoulder or device-specific key is used.
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

local function oneDisplay(width, height, touch)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = touch,
    role = "world",
  })
end

-- A structural topology change while the Bag is open preserves the semantic
-- pocket/item selection, and a pointer press held across the change cannot
-- activate the target that moved under the pointer.
function T.tests.bag_topology_change_preserves_selection_and_stale_capture()
  withGame(function(game)
    local state = hostCallbacks(game)
    stockTwoPockets(game)
    grantBag(game)

    openBag(game, state)

    -- Reach a non-first pocket with a selected item through directional
    -- input only.
    driveUntil(game, state, "a non-first pocket with a selection", 160, function()
      local current = bagView(game)
      return viewPocket(current) ~= "items" and selectedKey(current) ~= nil
    end)
    local pocketBefore = viewPocket(bagView(game))
    local selectionBefore = selectedKey(bagView(game))
    Assert.notNil(selectionBefore, "the topology journey requires a selected item")

    -- Structurally change the topology without GPU work and step once: the
    -- same semantic item in the same pocket must remain selected.
    game.runtime:resizePresentation(390, 844, oneDisplay(390, 844, true))
    game:step()
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "a topology change must keep the bag application open"
    )
    local resized = bagView(game)
    Assert.equal(viewPocket(resized), pocketBefore, "a topology change must preserve the pocket")
    Assert.equal(selectedKey(resized), selectionBefore, "a topology change must preserve the selected item")

    -- Stale capture: press inside the interactive pane, change the topology
    -- again, then release at the identical host coordinates. The release
    -- must not activate the target that moved under the pointer.
    local layout = resized.layout
    Assert.isTrue(type(layout) == "table", "the bag status must carry its resolved layout")
    local interactive = layout.interactive
    Assert.isTrue(type(interactive) == "table", "the bag layout must place its interactive pane")
    local frame = interactive.frame
    Assert.isTrue(
      type(frame) == "table" and type(frame.width) == "number" and type(frame.height) == "number",
      "the interactive placement must expose its host frame"
    )
    local pressX = frame.x + frame.width / 2
    local pressY = frame.y + frame.height / 2
    game.runtime.input:pointerDown("touch:0", pressX, pressY)
    game:step()
    local pressedPocket = viewPocket(bagView(game))
    local pressedSelection = selectedKey(bagView(game))
    game.runtime:resizePresentation(960, 540, oneDisplay(960, 540, false))
    game:step()
    game.runtime.input:pointerUp("touch:0", pressX, pressY)
    game:step()
    game:step()
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "a stale pointer release must not leave the bag application"
    )
    local released = bagView(game)
    Assert.equal(viewPocket(released), pressedPocket, "a stale pointer release must not change the pocket")
    Assert.equal(selectedKey(released), pressedSelection, "a stale pointer release must not activate the moved target")

    -- Restore the boot geometry and leave through the production cancel
    -- path so teardown starts from the field.
    game.runtime:resizePresentation(640, 480, oneDisplay(640, 480, false))
    game:step()
    Assert.equal(viewPocket(bagView(game)), pressedPocket, "restoring the topology must preserve the pocket")
    pressCancel(game)
    game:advanceUntil("bag closes back to the start menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    closeStartMenu(game)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.closed, "the topology journey must end back on the field")
  end)
end

-- Raw host-coordinate Cancel activation through the production host: a
-- pointer press and release on separate fixed ticks over the generated
-- Cancel affordance closes the Bag back to the Start Menu. The unit
-- coverage proves the capture survives equivalent fallback topologies; this
-- journey proves the composed host maps the same placement from real
-- pointer input through the session into the live Bag controller.
function T.tests.bag_cancel_pointer_closes_through_the_host()
  withGame(function(game)
    local state = hostCallbacks(game)
    stockTwoPockets(game)
    grantBag(game)
    openBag(game, state)

    local view = bagView(game)
    local layout = assert(view.layout, "the bag status must carry its resolved layout")
    local interactive = assert(layout.interactive, "the bag layout must place its interactive pane")
    local frame = assert(interactive.frame, "the interactive placement must expose its host frame")
    local scale = assert(interactive.scale, "the interactive placement must expose its scale")
    local manifest = BagCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local cancel = assert(
      manifest.interactive and manifest.interactive.cancel,
      "the generated manifest must carry its cancel rectangle"
    )
    local hostX = frame.x + (cancel.x + cancel.width / 2) * scale
    local hostY = frame.y + (cancel.y + cancel.height / 2) * scale

    game.runtime.input:pointerDown("touch:0", hostX, hostY)
    game:step()
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "the press tick must keep the bag application open"
    )
    game.runtime.input:pointerUp("touch:0", hostX, hostY)
    game:step()
    game:advanceUntil("cancel pointer closes the bag to the start menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    closeStartMenu(game)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.closed, "the pointer journey must end back on the field")
  end)
end

return T
