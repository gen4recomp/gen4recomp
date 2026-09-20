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
  -- Boot with an explicit single-display topology matching the drawable
  -- so the runtime installs its resize-tracking provider: later
  -- resizePresentation calls (including physical pairs) then measure
  -- through the resized topology instead of the context default.
  local bootWidth, bootHeight = love.graphics.getDimensions()
  local game = AcceptanceHarness.new():boot({
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

-- Patrol across pockets through the supported path until the predicate
-- observes the wanted browse state: climb to the tab strip, move the tab
-- candidate with horizontal input, then commit it with confirm. Confirm keeps
-- tab focus, so reaching the pocket accepts either tab or item focus. Grid
-- edges never change pockets, so reaching another pocket must travel through
-- tab focus.
local function driveUntil(game, state, label, maxSteps, predicate)
  for _ = 1, maxSteps do
    local view = bagView(game)
    local focus = view.focus
    Assert.isTrue(
      focus == "items" or focus == "tabs" or focus == "cancel",
      "the bag status must expose its focus region"
    )
    if predicate() then
      return
    end
    if focus == "tabs" then
      local candidate = view.tabFocusPocket
      Assert.isTrue(type(candidate) == "string" and candidate ~= "", "the bag status must name its focused tab")
      if candidate ~= viewPocket(view) then
        confirm(game)
      else
        tapDirection(game, state, "d")
      end
    elseif focus == "cancel" then
      tapDirection(game, state, "w")
    else
      tapDirection(game, state, "w")
    end
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
    local resizedPlan = assert(resized.presentation, "the bag status must carry its presentation plan")
    local interactivePane
    for _, pane in ipairs(resizedPlan.panes) do
      if pane.interactive then
        interactivePane = pane
      end
    end
    Assert.isTrue(type(interactivePane) == "table", "the bag plan must place its interactive pane")
    local frame = assert(interactivePane.placement, "the interactive pane carries its placement").frame
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

local function pressMenuOnce(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

local function translatedDual()
  return ScreenTopology.dualDisplay({
    id = "main",
    rect = { x = 400, y = 100, width = 256, height = 192 },
    touch = false,
    role = "world",
  }, {
    id = "sub",
    rect = { x = 100, y = 300, width = 256, height = 192 },
    touch = true,
    role = "auxiliary",
  })
end

-- The bag publishes one shared presentation plan beside its semantic
-- snapshot: a stable input key, matched render/input callbacks, ordered
-- panes with complete placements, and logical content.
local function presentationOf(game, what)
  local view = bagView(game)
  local plan = view.presentation
  Assert.isTrue(type(plan) == "table", "the bag publishes its presentation plan " .. what)
  Assert.equal(type(plan.inputKey), "string", "the bag plan names its stable input geometry " .. what)
  Assert.isTrue(type(plan.render) == "function", "the bag plan carries its render callback " .. what)
  Assert.isTrue(type(plan.mapInput) == "function", "the bag plan carries its input callback " .. what)
  Assert.isTrue(type(plan.panes) == "table", "the bag plan orders its panes " .. what)
  return view, plan
end

local function interactivePane(plan, what)
  local found
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      Assert.isNil(found, "the bag plan carries exactly one interactive pane " .. what)
      found = pane
    end
  end
  Assert.isTrue(type(found) == "table", "the bag plan carries its interactive pane " .. what)
  return found
end

local function heroPane(plan, what)
  local found
  for _, pane in ipairs(plan.panes) do
    if not pane.interactive then
      Assert.isNil(found, "the bag plan carries exactly one hero pane " .. what)
      found = pane
    end
  end
  Assert.isTrue(type(found) == "table", "the bag plan carries its hero pane " .. what)
  return found
end

local function frameInside(frame, rect, what)
  Assert.isTrue(
    frame.x >= rect.x
      and frame.y >= rect.y
      and frame.x + frame.width <= rect.x + rect.width
      and frame.y + frame.height <= rect.y + rect.height,
    "the pane frame stays inside its surface " .. what
  )
end

-- Drive from the boot pocket to medicine with POTION selected through
-- directional input only: climb to the tab strip, step the tab candidate
-- to medicine, and commit it.
local function driveToMedicine(game, state)
  for _ = 1, 160 do
    local view = bagView(game)
    if viewPocket(view) == "medicine" and selectedKey(view) == "POTION" then
      return
    end
    local focus = view.focus
    Assert.isTrue(
      focus == "items" or focus == "tabs" or focus == "cancel",
      "the bag status must expose its focus region"
    )
    if focus == "tabs" then
      local candidate = view.tabFocusPocket
      Assert.isTrue(type(candidate) == "string" and candidate ~= "", "the bag status must name its focused tab")
      if candidate == "medicine" then
        confirm(game)
      else
        tapDirection(game, state, "d")
      end
    elseif focus == "cancel" then
      tapDirection(game, state, "w")
    else
      tapDirection(game, state, "w")
    end
  end
  error("bag browse never reaches medicine with POTION selected through directional input", 0)
end

-- Commit the selected item's toss with one quantity step through the
-- composed host: open the action menu, enter the quantity picker, step
-- once, confirm twice, and land back in browsing.
local function tossSelectedWithSingleCopyStep(game, state)
  confirm(game)
  Assert.equal(bagView(game).state, "action_menu", "confirming the composed selection opens the action menu")
  confirm(game)
  Assert.equal(bagView(game).state, "toss_quantity", "confirming toss enters the quantity picker")
  tapDirection(game, state, "d")
  confirm(game)
  Assert.equal(bagView(game).state, "toss_confirm", "confirming a quantity asks for confirmation")
  confirm(game)
  Assert.equal(bagView(game).state, "browsing", "a committed toss returns to browsing")
end

-- The display matrix through the real field factory: native-like shows
-- only the interactive pane with its compact description fallback,
-- wide/tall pair both panes with one shared integer scale, and a
-- translated physical pair maps the hero to the world surface and the
-- interaction to the auxiliary surface. Description and toss
-- confirmation stay reachable in the lower-only composition, and one
-- composed toss mutates exactly once.
function T.tests.bag_display_matrix_uses_a_shared_plan_with_compact_lower_only_information()
  withGame(function(game)
    local state = hostCallbacks(game)
    stockTwoPockets(game)
    grantBag(game)
    openBag(game, state)

    game.runtime:resizePresentation(512, 384, oneDisplay(512, 384, false))
    game:step()
    local view, plan = presentationOf(game, "on the native-like surface")
    Assert.equal(#plan.panes, 1, "the native-like composition shows only its interactive pane")
    Assert.isTrue(plan.panes[1].interactive, "the single native-like pane takes input")
    Assert.isTrue(type(plan.frames) == "table", "the native-like plan carries its static frame list")
    Assert.deepEqual(plan.frames, {}, "exact native coverage leaves no background to decorate")
    Assert.isTrue(type(plan.fadeCoverage) == "table", "the native-like plan owns its transition coverage")
    Assert.equal(#plan.fadeCoverage, 1, "the native-like plan owns its target transition region")
    local content = plan.content
    Assert.isTrue(type(content) == "table", "the native-like plan carries its logical content")
    Assert.equal(content.heroVisible, false, "the native-like plan hides the hero pane")
    Assert.isTrue(type(content.descriptionFallback) == "table", "the lower-only plan keeps its description fallback")
    Assert.isNil(view.layout, "the migrated status carries no stale host layout")

    driveToMedicine(game, state)
    -- Keyboard pocket switching keeps tab focus by preserved controller
    -- semantics, while the info key needs an occupied cell focus: step
    -- once into the grid so the menu key has a described selection.
    tapDirection(game, state, "s")
    Assert.equal(bagView(game).focus, "items", "setup focuses the stocked cell before describing it")
    Assert.equal(selectedKey(bagView(game)), "POTION", "setup keeps the stocked selection")
    pressMenuOnce(game)
    game:step()
    Assert.equal(
      bagView(game).state,
      "description_overlay",
      "the lower-only composition opens the item description through its menu key"
    )
    pressMenuOnce(game)
    game:step()
    Assert.equal(bagView(game).state, "browsing", "the menu key dismisses the description overlay")

    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    local revision = bag:revision()
    tossSelectedWithSingleCopyStep(game, state)
    Assert.equal(bag:quantity("POTION"), 3, "the composed toss removes the picked copies")
    Assert.equal(bag:revision(), revision + 1, "one composed toss mutates exactly once")

    game.runtime:resizePresentation(1280, 720, oneDisplay(1280, 720, false))
    game:step()
    local wideView, wide = presentationOf(game, "on the wide surface")
    Assert.equal(#wide.panes, 2, "the wide composition pairs both panes")
    local wideHero = heroPane(wide, "wide")
    local wideInteractive = interactivePane(wide, "wide")
    local wideHeroPlacement = assert(wideHero.placement, "the wide hero pane carries its placement")
    local wideInteractivePlacement = assert(wideInteractive.placement, "the wide pane carries its placement")
    Assert.equal(
      wideHeroPlacement.pixelScale,
      wideInteractivePlacement.pixelScale,
      "paired wide panes share one integer scale"
    )
    Assert.isTrue(
      wideHeroPlacement.frame.x + wideHeroPlacement.frame.width <= wideInteractivePlacement.frame.x,
      "the wide hero pane sits left of the interaction pane"
    )
    Assert.equal(
      wideInteractivePlacement.frame.x - (wideHeroPlacement.frame.x + wideHeroPlacement.frame.width),
      0,
      "paired wide panes touch with no gap"
    )
    Assert.equal(viewPocket(wideView), "medicine", "the wide composition preserves the pocket")
    Assert.equal(selectedKey(wideView), "POTION", "the wide composition preserves the selected item")

    game.runtime:resizePresentation(600, 1000, oneDisplay(600, 1000, true))
    game:step()
    local _, tall = presentationOf(game, "on the tall surface")
    Assert.equal(#tall.panes, 2, "the tall composition pairs both panes")
    local tallHero = heroPane(tall, "tall")
    local tallInteractive = interactivePane(tall, "tall")
    local tallHeroPlacement = assert(tallHero.placement, "the tall hero pane carries its placement")
    local tallInteractivePlacement = assert(tallInteractive.placement, "the tall pane carries its placement")
    Assert.equal(
      tallHeroPlacement.pixelScale,
      tallInteractivePlacement.pixelScale,
      "paired tall panes share one integer scale"
    )
    Assert.isTrue(
      tallHeroPlacement.frame.y + tallHeroPlacement.frame.height <= tallInteractivePlacement.frame.y,
      "the tall hero pane sits above the interaction pane"
    )
    Assert.equal(
      tallInteractivePlacement.frame.y - (tallHeroPlacement.frame.y + tallHeroPlacement.frame.height),
      0,
      "paired tall panes touch with no gap"
    )
    Assert.equal(viewPocket(bagView(game)), "medicine", "the tall composition preserves the pocket")

    game.runtime:resizePresentation(800, 600, translatedDual())
    game:step()
    local _, dual = presentationOf(game, "on the translated physical pair")
    Assert.equal(#dual.panes, 2, "the physical pair shows both panes")
    local dualHero = heroPane(dual, "dual")
    local dualInteractive = interactivePane(dual, "dual")
    local dualHeroFrame = assert(dualHero.placement, "the dual hero pane carries its placement").frame
    local dualInteractiveFrame = assert(dualInteractive.placement, "the dual pane carries its placement").frame
    frameInside(dualHeroFrame, { x = 400, y = 100, width = 256, height = 192 }, "hero on the world surface")
    frameInside(
      dualInteractiveFrame,
      { x = 100, y = 300, width = 256, height = 192 },
      "interaction on the auxiliary surface"
    )
    Assert.isTrue(type(dual.fadeCoverage) == "table", "the dual plan owns its transition coverage")
    Assert.equal(#dual.fadeCoverage, 2, "the physical pair covers one transition region per surface")

    game.runtime:resizePresentation(640, 480, oneDisplay(640, 480, false))
    game:step()
    Assert.equal(viewPocket(bagView(game)), "medicine", "restoring the topology preserves the pocket")
    pressCancel(game)
    game:advanceUntil("bag closes back to the start menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    closeStartMenu(game)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.closed, "the matrix journey must end back on the field")
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
    local plan = assert(view.presentation, "the bag status must carry its presentation plan")
    local interactive
    for _, pane in ipairs(plan.panes) do
      if pane.interactive then
        interactive = pane
      end
    end
    interactive = assert(interactive, "the bag plan must place its interactive pane")
    local placement = assert(interactive.placement, "the interactive pane must carry its placement")
    local frame = assert(placement.frame, "the interactive placement must expose its host frame")
    local scale = assert(placement.scale, "the interactive placement must expose its scale")
    local manifest = BagCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local cancelGeometry = assert(
      manifest.interactive and manifest.interactive.cancel,
      "the generated manifest must carry its cancel geometry"
    )
    local cancel = assert(cancelGeometry.rect, "the generated manifest must carry its cancel control rectangle")
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
