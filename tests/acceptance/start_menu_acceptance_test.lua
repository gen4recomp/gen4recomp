-- Production-composed Start Menu contracts. The real field runtime owns the
-- menu policy, controller, placement, generated manifest, and input mapping;
-- acceptance only supplies host boundaries and semantic input.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
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
      local status = openMenu(game)
      Assert.equal(status.selectedPosition, 0, "fresh field selection starts at source display position zero")

      local byPosition = {}
      for _, action in ipairs(status.actions) do
        byPosition[action.position] = action
      end
      Assert.notNil(byPosition[0], "the first source action is visible")
      Assert.isFalse(byPosition[0].enabled, "the first source action is visible but disabled")
      Assert.notNil(byPosition[1], "the next source row action is visible")
      Assert.notNil(byPosition[2], "the second source row action is visible")
      Assert.isNil(byPosition[7], "the special-9 bookkeeping entry is not a visual button")
      Assert.isNil(byPosition[8], "the special-10 bookkeeping entry is not a visual button")
      Assert.isNil(byPosition[4], "an absent source position remains a hole")

      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
      Assert.equal(menuStatus(game).selectedPosition, 0, "a disabled visible action is not activated")

      Assert.equal(navigate(game, "east").selectedPosition, 0, "right stays on the first visible candidate")
      Assert.equal(navigate(game, "south").selectedPosition, 1, "down selects the first visible candidate")
      Assert.equal(navigate(game, "west").selectedPosition, 1, "left stays on the first visible candidate")
      Assert.equal(navigate(game, "north").selectedPosition, 0, "up selects the first visible candidate")
      Assert.equal(navigate(game, "south").selectedPosition, 1, "down selects the first visible candidate again")
      Assert.equal(navigate(game, "east").selectedPosition, 1, "right stays when no candidate is visible")
      Assert.equal(navigate(game, "south").selectedPosition, 2, "down selects the first visible candidate")
      Assert.equal(navigate(game, "west").selectedPosition, 2, "left stays when no candidate is visible")

      local hitRect = game.runtime.uiManifest.startMenu.interactive.positions[4].hitRect
      game.runtime.input:pointerMove("acceptance:start-menu:pointer", hitRect.x + 1, hitRect.y + 1)
      game:step()
      Assert.equal(menuStatus(game).selectedPosition, 2, "pointer hover over a position hole changes nothing")
    end)
  end)
end

function T.tests.production_start_menu_uses_field_bounded_integer_placement()
  local cases = {
    { width = 640, height = 480 },
    { width = 1280, height = 720 },
    { width = 1920, height = 1080 },
    { width = 2560, height = 1440 },
    { width = 1080, height = 1920 },
  }
  withEveryVersion(function(harness, versionId)
    local first = cases[1]
    withGame(harness, versionId, {
      width = first.width,
      height = first.height,
      topology = topology(first.width, first.height),
    }, function(game)
      for index, size in ipairs(cases) do
        if index > 1 then
          game.runtime:resizePresentation(size.width, size.height, topology(size.width, size.height))
        end
        openMenu(game)
        local placement = assert(game.runtime.startMenuPlacement, "the open menu must have a placement record")
        local frame = placement.frame
        local safe = game.runtime.screenTopology.surfaces[1].safeRect
        local preferredScale = game.runtime.fieldPixelScale:resolvedScale()
        Assert.isTrue(placement.scale > 0, size.width .. "x" .. size.height .. " scale is positive")
        Assert.equal(
          placement.scale,
          math.floor(placement.scale),
          size.width .. "x" .. size.height .. " scale is integer"
        )
        Assert.isTrue(placement.scale <= preferredScale, size.width .. "x" .. size.height .. " scale is field-bounded")
        Assert.equal(frame.width, 256 * placement.scale, size.width .. "x" .. size.height .. " width is canonical")
        Assert.equal(frame.height, 192 * placement.scale, size.width .. "x" .. size.height .. " height is canonical")
        Assert.equal(frame.x, math.floor(frame.x), size.width .. "x" .. size.height .. " origin x is snapped")
        Assert.equal(frame.y, math.floor(frame.y), size.width .. "x" .. size.height .. " origin y is snapped")
        Assert.isTrue(
          frame.x >= safe.x
            and frame.y >= safe.y
            and frame.x + frame.width <= safe.x + safe.width
            and frame.y + frame.height <= safe.y + safe.height,
          size.width .. "x" .. size.height .. " frame stays inside the safe rect"
        )

        local reference = game.runtime.viewport.referenceFrame
        local sideWidth = safe.x + safe.width - (reference.x + reference.width)
        if size.width >= size.height and sideWidth < 256 then
          Assert.isTrue(
            frame.x < reference.x + reference.width,
            size.width .. "x" .. size.height .. " rejects an undersized side partition"
          )
        end
        closeMenu(game)
      end
    end)
  end)
end

return T
