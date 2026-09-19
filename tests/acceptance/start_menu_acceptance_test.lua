-- Production-composed Start Menu contracts. The real field runtime owns the
-- menu policy, controller, placement, generated manifest, and input mapping;
-- acceptance only supplies host boundaries and semantic input.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "menu", "start-menu", "topology", "integer-scale" },
  },
  tests = {},
}

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function touchDisplay(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = true,
  })
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the Start Menu must own the field tick")
  return assert(status.menu, "the open Start Menu must expose its controller status")
end

local function openMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("Start Menu opens", function()
    return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu
  end, 30)
  return menuStatus(game)
end

local function closeMenu(game)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
  game:advanceUntil("Start Menu closes", function()
    return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed
  end, 30)
end

local function navigate(game, direction)
  local source = "acceptance:start-menu:" .. direction
  game.runtime.input:pressDirection(direction, source)
  game:step()
  game.runtime.input:releaseDirection(source)
  return menuStatus(game)
end

local function withEveryVersion(fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    fn(harness, versionId)
  end)
end

local function withGame(harness, versionId, options, fn)
  local game = harness:boot({
    versionId = versionId,
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      viewportWidth = options.width,
      viewportHeight = options.height,
      screenTopology = options.topology,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "Start Menu acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.production_start_menu_follows_the_ordered_candidate_topology()
  withEveryVersion(function(harness, versionId)
    local options = { width = 256, height = 192, topology = topology(256, 192) }
    withGame(harness, versionId, options, function(game)
      -- A fresh save owns no progression: only the unlock-gated trainer
      -- card, save, and options rows are present, keeping their fixed
      -- retail slots on the right column while the early slots stay holes.
      local status = openMenu(game)
      Assert.equal(status.selectedPosition, 4, "fresh field selection starts at the first present fixed slot")

      local byPosition = {}
      for _, action in ipairs(status.actions) do
        byPosition[action.position] = action
      end
      Assert.isNil(byPosition[0], "the absent pokedex slot remains a hole")
      Assert.isNil(byPosition[1], "the absent pokemon slot remains a hole")
      Assert.isNil(byPosition[2], "the absent bag slot remains a hole")
      Assert.isNil(byPosition[3], "the absent pokegear slot remains a hole")
      Assert.notNil(byPosition[4], "the trainer card keeps its fixed slot")
      Assert.isFalse(byPosition[4].enabled, "the trainer card is visible but disabled")
      Assert.notNil(byPosition[5], "save keeps its fixed slot")
      Assert.notNil(byPosition[6], "options keeps its fixed slot")
      Assert.isNil(byPosition[7], "the special-9 bookkeeping entry is not a visual button")
      Assert.isNil(byPosition[8], "the special-10 bookkeeping entry is not a visual button")

      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
      Assert.equal(menuStatus(game).selectedPosition, 4, "a disabled visible action is not activated")

      Assert.equal(navigate(game, "east").selectedPosition, 4, "right stays on the first visible candidate")
      Assert.equal(navigate(game, "south").selectedPosition, 5, "down selects the next visible candidate")
      Assert.equal(navigate(game, "west").selectedPosition, 5, "left stays when no candidate is visible")
      Assert.equal(navigate(game, "north").selectedPosition, 4, "up selects the previous visible candidate")
      Assert.equal(navigate(game, "south").selectedPosition, 5, "down selects the next visible candidate again")
      Assert.equal(navigate(game, "east").selectedPosition, 5, "right stays when no candidate is visible")
      Assert.equal(navigate(game, "south").selectedPosition, 6, "down selects the last visible candidate")
      Assert.equal(navigate(game, "west").selectedPosition, 6, "left stays when no candidate is visible")

      local hitRect = game.runtime.uiManifest.startMenu.interactive.positions[0].hitRect
      game.runtime.input:pointerMove("acceptance:start-menu:pointer", hitRect.x + 1, hitRect.y + 1)
      game:step()
      Assert.equal(menuStatus(game).selectedPosition, 6, "pointer hover over a position hole changes nothing")
    end)
  end)
end

function T.tests.production_start_menu_follows_the_shared_display_policy()
  local cases = {
    { width = 640, height = 480, windowed = false },
    { width = 1280, height = 720, windowed = true },
    { width = 1920, height = 1080, windowed = true },
    { width = 2560, height = 1440, windowed = true },
    { width = 1080, height = 1920, windowed = true },
  }
  withEveryVersion(function(harness, versionId)
    local first = cases[1]
    withGame(harness, versionId, {
      width = first.width,
      height = first.height,
      topology = topology(first.width, first.height),
    }, function(game)
      for _, size in ipairs(cases) do
        game.runtime:resizePresentation(size.width, size.height, topology(size.width, size.height))
        openMenu(game)
        local menu = menuStatus(game)
        local plan = assert(menu.presentation, "the open menu must publish its presentation plan")
        local body = nil
        for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes")) do
          if pane.interactive then
            body = assert(pane.placement, "the body pane must carry its placement")
          end
        end
        body = assert(body, "the plan must carry an interactive body pane")
        local safe = game.runtime.screenTopology.surfaces[1].safeRect
        local label = size.width .. "x" .. size.height
        Assert.equal(body.logicalWidth, 256, label .. " body keeps canonical logical width")
        Assert.equal(body.logicalHeight, 192, label .. " body keeps canonical logical height")
        Assert.isTrue(
          body.pixelScale ~= nil and body.pixelScale >= 1 and body.pixelScale == math.floor(body.pixelScale),
          label .. " scale is a positive integer"
        )
        local frame = body.frame
        Assert.isTrue(
          frame.x >= safe.x
            and frame.y >= safe.y
            and frame.x + frame.width <= safe.x + safe.width
            and frame.y + frame.height <= safe.y + safe.height,
          label .. " body stays inside the safe rect"
        )
        if size.windowed then
          Assert.notNil(plan.window, label .. " frames the menu in a window")
          Assert.equal(#(plan.coverage or {}), 0, label .. " window owns no fullscreen coverage")
        else
          Assert.isNil(plan.window, label .. " stays a fullscreen native surface")
          Assert.isTrue(#plan.coverage >= 1, label .. " fullscreen owns its target region")
        end
        closeMenu(game)
      end
      -- Application fits follow UI bounds, never the field camera zoom: a
      -- zoom change must not move the published plan.
      game.runtime:resizePresentation(first.width, first.height, topology(first.width, first.height))
      openMenu(game)
      local before = menuStatus(game).presentation.panes[1].placement
      game.runtime.fieldPixelScale:zoomIn()
      game.runtime:applyFieldPixelScaleChange()
      game:step()
      local after = menuStatus(game).presentation.panes[1].placement
      Assert.deepEqual(after.frame, before.frame, "field zoom never moves the menu surface")
      Assert.equal(after.pixelScale, before.pixelScale, "field zoom never rescales the menu surface")
      closeMenu(game)
    end)
  end)
end

-- A wide host frames the menu in a draggable window instead of a gutter
-- panel: the open menu publishes one presentation plan that supplies both
-- drawing and input. Dragging the title strip clamps the whole window to
-- the usable bounds without changing its pixel scale and never launches an
-- action; body pointer input maps through the same plan exactly once; the
-- remembered window position survives close/reopen per configuration.
function T.tests.production_start_menu_window_keeps_scale_clip_and_input_while_dragging()
  withEveryVersion(function(harness, versionId)
    withGame(harness, versionId, { width = 1280, height = 720, topology = touchDisplay(1280, 720) }, function(game)
      local runtime = game.runtime
      local function openPlan()
        local menu = menuStatus(game)
        local plan = assert(menu.presentation, "the open menu must publish its presentation plan")
        return menu, plan
      end
      local function bodyPlacement(plan)
        for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes")) do
          if pane.interactive then
            return assert(pane.placement, "the body pane must carry its placement")
          end
        end
        error("the windowed plan must carry an interactive body pane", 0)
      end
      local function safeRect()
        return runtime.screenTopology.surfaces[1].safeRect
      end
      local function assertOuterInside(plan, label)
        local frame = assert(plan.window, "a wide host must frame the menu in a window").outer.frame
        local safe = safeRect()
        Assert.isTrue(
          frame.x >= safe.x
            and frame.y >= safe.y
            and frame.x + frame.width <= safe.x + safe.width
            and frame.y + frame.height <= safe.y + safe.height,
          label .. ": the whole window stays in the usable bounds"
        )
        return frame
      end
      local function pressAt(x, y)
        runtime.input:pointerDown("acceptance:start-menu:drag", x, y)
        game:step()
        runtime.input:pointerUp("acceptance:start-menu:drag", x, y)
        game:step()
      end

      openMenu(game)
      local menu, plan = openPlan()
      local window = assert(plan.window, "a wide host must frame the menu in a window")
      local grab = assert(window.grabRect, "the window must carry its title-strip grab rectangle")
      local scale = bodyPlacement(plan).pixelScale
      Assert.isTrue(scale ~= nil and scale >= 1, "the windowed body must have an integer pixel scale")
      assertOuterInside(plan, "initial")

      -- Drag the title strip to each edge plus one release outside: the
      -- window follows clamped to the usable bounds, keeps its scale, and
      -- the header never launches an action.
      local grabX, grabY = grab.x + grab.width / 2, grab.y + grab.height / 2
      local selectedBefore = menu.selectedPosition
      local safe = safeRect()
      local targets = {
        { x = safe.x + safe.width / 2, y = safe.y + 2 },
        { x = safe.x + safe.width - 2, y = safe.y + safe.height / 2 },
        { x = safe.x + safe.width / 2, y = safe.y + safe.height - 2 },
        { x = safe.x + 2, y = safe.y + safe.height / 2 },
        { x = safe.x + safe.width + 400, y = safe.y + safe.height + 400 },
      }
      for index, target in ipairs(targets) do
        runtime.input:pointerDown("acceptance:start-menu:drag", grabX, grabY)
        game:step()
        runtime.input:pointerMove("acceptance:start-menu:drag", target.x, target.y)
        game:step()
        runtime.input:pointerUp("acceptance:start-menu:drag", target.x, target.y)
        game:step()
        local _, moved = openPlan()
        assertOuterInside(moved, "drag " .. index)
        Assert.equal(
          bodyPlacement(moved).pixelScale,
          scale,
          "drag " .. index .. ": dragging never changes the pixel scale"
        )
        grab = assert(moved.window, "drag " .. index .. ": the plan keeps its window").grabRect
        grabX, grabY = grab.x + grab.width / 2, grab.y + grab.height / 2
      end
      menu = menuStatus(game)
      Assert.equal(menu.selectedPosition, selectedBefore, "header drags must never launch or move selection")
      -- A header click without movement is still a header press, not an
      -- action activation.
      pressAt(grabX, grabY)
      menu = menuStatus(game)
      Assert.equal(menu.selectedPosition, selectedBefore, "a header click must not launch an action")

      -- Body input maps through the same plan exactly once: move off the
      -- initial slot, then click the disabled trainer-card slot and watch
      -- selection follow the pointer with no activation.
      navigate(game, "south")
      menu = menuStatus(game)
      Assert.equal(menu.selectedPosition, 5, "keyboard navigation must reach the next slot first")
      local _, clicked = openPlan()
      local hostX, hostY = LayoutGeometry.logicalToHost(bodyPlacement(clicked), 126, 38)
      pressAt(hostX, hostY)
      menu = menuStatus(game)
      Assert.equal(menu.selectedPosition, 4, "a body click must map to the visible slot once")
      Assert.equal(
        game.runtime.applicationHost:status().phase,
        FieldApplicationHost.PHASES.menu,
        "clicking a disabled visible action must not leave the menu"
      )

      -- The dragged position survives close/reopen on the same host, while
      -- a tall host starts from its own centred default.
      local _, dragged = openPlan()
      local remembered = assertOuterInside(dragged, "remembered")
      closeMenu(game)
      openMenu(game)
      local _, reopened = openPlan()
      local frame = assertOuterInside(reopened, "reopened")
      Assert.equal(frame.x, remembered.x, "the wide position must survive reopen")
      Assert.equal(frame.y, remembered.y, "the wide position must survive reopen")
      game.runtime:resizePresentation(600, 1000, touchDisplay(600, 1000))
      -- The published plan follows the new measurement on the next tick,
      -- not synchronously with the resize.
      game:step()
      local _, tall = openPlan()
      local tallFrame = assertOuterInside(tall, "tall")
      local tallSafe = safeRect()
      local travelX = tallSafe.width - tallFrame.width
      local travelY = tallSafe.height - tallFrame.height
      if travelX > 0 then
        Assert.isTrue(
          math.abs((tallFrame.x - tallSafe.x) / travelX - 0.5) < 0.05,
          "the tall window keeps its own centred default"
        )
      end
      if travelY > 0 then
        Assert.isTrue(
          math.abs((tallFrame.y - tallSafe.y) / travelY - 0.5) < 0.05,
          "the tall window keeps its own centred default"
        )
      end
      closeMenu(game)
      Assert.equal(game:renderAttempts(), 0, "Start Menu acceptance must stop before GPU rendering")
    end)
  end)
end

return T
