-- Main Menu root presentation boundary: the startup menu resolves a
-- function-selected interface on the primary/world surface, accepts a
-- per-case override pair, and never enters the field application lifecycle.
-- The menu state owns its presentation session beside its existing
-- controller; overrides map their own controls onto existing save operations.

local Assert = require("tests.support.Assert")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = { tests = {} }

local function singleStore()
  return {
    listMetadata = function()
      return {
        {
          saveId = "save-00000001",
          versionId = "heartgold",
          playerData = { profile = { name = "PLAYER" } },
          playTimeSeconds = 60,
        },
      }
    end,
    load = function(_, _)
      return {
        saveId = "save-00000001",
        versionId = "heartgold",
        playerData = { profile = { name = "PLAYER" } },
        playTimeSeconds = 60,
      }
    end,
  }
end

local function fakeRenderer()
  return { draw = function() end, dispose = function() end }
end

local function measurementFor(topology, width, height, signature)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = signature,
  }
end

local function worldAuxPair()
  return ScreenTopology.dualDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    role = "world",
    touch = false,
  }, {
    id = "sub",
    rect = { x = 300, y = 0, width = 256, height = 192 },
    role = "auxiliary",
    touch = true,
  })
end

local function singleWorld(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function menuWith(measurement, overrides)
  local results = {}
  local menu = MainMenuState.new({
    saveStore = singleStore(),
    readyVersions = { "heartgold" },
    renderer = fakeRenderer(),
    onResult = function(result)
      results[#results + 1] = result
    end,
    displayMeasurement = measurement,
    overrides = overrides,
  })
  return menu, results
end

function T.tests.default_menu_occupies_the_primary_surface_only_on_a_physical_dual()
  local pair = worldAuxPair()
  local measurement = measurementFor(pair, 556, 192, "main-menu-dual-primary-only")
  local menu, _ = menuWith(measurement, nil)
  local plan =
    assert(menu:view().presentation, "Main Menu must publish its presentation plan on a physical dual display")
  Assert.isTrue(#plan.panes >= 1, "the dual plan must carry its primary content pane")
  for _, pane in ipairs(plan.panes) do
    local frame = assert(pane.placement, "every menu pane needs its resolved placement").frame
    Assert.isTrue(
      frame.x + frame.width <= 256,
      "no menu pane may extend into the auxiliary surface: the save UI stays primary-only"
    )
  end
  Assert.deepEqual(plan.frames, {}, "the startup menu publishes no application frame")
  local hostBackgrounds =
    assert(plan.content.hostBackgrounds, "the startup menu carries its leaf-owned host backgrounds")
  Assert.equal(#hostBackgrounds, 2, "the dual startup menu paints both host surfaces itself")
end

function T.tests.outside_presses_never_dismiss_the_startup_menu()
  local topology = singleWorld(1280, 720)
  local measurement = measurementFor(topology, 1280, 720, "main-menu-outside-guard")
  local menu, _ = menuWith(measurement, nil)
  local plan = assert(menu:view().presentation, "Main Menu must publish its presentation plan")
  local mapped = plan.mapInput({ type = "pointer_down", pointerId = "mouse:1", outside = true }, menu:view(), plan)
  Assert.isNil(mapped, "an outside press carries no menu action and never dismisses")
end

function T.tests.a_wide_only_override_replaces_rendering_and_input_together()
  local topology = singleWorld(1280, 720)
  local measurement = measurementFor(topology, 1280, 720, "main-menu-wide-replacement")
  local customRenderings = 0
  local overrides = {
    wide = function(_, _)
      return {
        panes = {},
        frames = {},
        content = {},
        inputKey = "replacement-wide",
        render = function(_, _, _)
          customRenderings = customRenderings + 1
        end,
        mapInput = function(_, _, _)
          return { type = "activateNewGame" }
        end,
      }
    end,
  }
  local menu, results = menuWith(measurement, overrides)
  local plan = assert(menu:view().presentation, "Main Menu must publish its overridden presentation plan")
  Assert.equal(plan.inputKey, "replacement-wide", "the wide override must supply the published plan")
  plan.render({}, menu:view(), plan)
  Assert.equal(customRenderings, 1, "the override render callback must execute")
  local mapped = assert(
    plan.mapInput({ type = "pointer_down", pointerId = "mouse:1" }, menu:view(), plan),
    "the override mapper must produce its semantic command"
  )
  Assert.equal(mapped.type, "activateNewGame", "the override mapper must target the existing menu operation")
  menu:view()
  Assert.deepEqual(results, {}, "publishing an override plan must not publish a route result by itself")
end

function T.tests.overridden_menu_returns_its_normal_route_result_without_a_field_host()
  local topology = singleWorld(640, 480)
  local measurement = measurementFor(topology, 640, 480, "main-menu-route-result")
  local menu, results = menuWith(measurement, nil)
  local plan = assert(menu:view().presentation, "Main Menu must publish its presentation plan")
  Assert.isTrue(type(plan.render) == "function", "the default plan must carry its render callback")
  Assert.isTrue(type(plan.mapInput) == "function", "the default plan must carry its input mapper")
  menu:keypressed("return")
  Assert.equal(#results, 1, "confirming the focused save must publish exactly one route result")
  Assert.equal(results[1].kind, "continue", "the focused save must continue through the normal route")
end

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local DisplayContext = require("game.hgss.src.ui.DisplayContext")

local function planOf(menu, what)
  return assert(menu:view().presentation, "the menu must publish its presentation plan " .. what)
end

local function placementOf(menu, what)
  local plan = planOf(menu, what)
  return assert(plan.panes[1].placement, "the menu plan must carry its content placement " .. what)
end

local function densityCases()
  return {
    { width = 320, height = 240, scale = 1 },
    { width = 640, height = 480, scale = 2 },
    { width = 1280, height = 720, scale = 3 },
    { width = 2560, height = 1440, scale = 3 },
  }
end

function T.tests.density_selects_the_capped_integer_scale_per_viewport()
  for _, case in ipairs(densityCases()) do
    local topology = singleWorld(case.width, case.height)
    local menu, _ = menuWith(measurementFor(topology, case.width, case.height, "density-" .. case.scale), nil)
    local placement = placementOf(menu, "at " .. case.width .. "x" .. case.height)
    Assert.equal(placement.pixelScale, case.scale, "the density rule must cap at 3")
    Assert.equal(placement.logicalWidth, case.width / case.scale, "the logical viewport follows the density")
    Assert.equal(placement.logicalHeight, case.height / case.scale, "the logical viewport follows the density")
  end
end

function T.tests.translated_safe_rectangles_keep_input_and_drawing_inside()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 100, y = 50, width = 640, height = 480 },
    role = "world",
    touch = false,
  })
  local menu, _ = menuWith(measurementFor(topology, 740, 530, "translated-safe-rect"), nil)
  local placement = placementOf(menu, "in the translated safe rectangle")
  Assert.isTrue(
    placement.frame.x >= 100 and placement.frame.y >= 50,
    "the translated placement must stay inside its usable bounds"
  )
  Assert.isTrue(
    placement.frame.x + placement.frame.width <= 740 and placement.frame.y + placement.frame.height <= 530,
    "the translated placement must not escape its usable bounds"
  )
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, 10, 10)
  local backX, backY = LayoutGeometry.hostToLogical(placement, hostX, hostY)
  assert(backX ~= nil, "the translated point must invert exactly")
  assert(backY ~= nil, "the translated point must invert exactly")
  Assert.near(backX, 10, 1e-6, "translated placement must invert exactly")
  Assert.near(backY, 10, 1e-6, "translated placement must invert exactly")
end

function T.tests.equivalent_fresh_measurements_resolve_identically()
  local firstTopology = singleWorld(640, 480)
  local secondTopology = singleWorld(640, 480)
  local first, _ = menuWith(measurementFor(firstTopology, 640, 480, "fresh-measurement"), nil)
  local second, _ = menuWith(measurementFor(secondTopology, 640, 480, "fresh-measurement"), nil)
  local firstPlacement = placementOf(first, "for the first equivalent measurement")
  local secondPlacement = placementOf(second, "for the second equivalent measurement")
  Assert.equal(secondPlacement.pixelScale, firstPlacement.pixelScale, "equivalent facts must fit identically")
  Assert.equal(secondPlacement.logicalWidth, firstPlacement.logicalWidth, "equivalent facts must size identically")
  Assert.equal(secondPlacement.logicalHeight, firstPlacement.logicalHeight, "equivalent facts must size identically")
end

function T.tests.dpi_two_keeps_the_logical_viewport_with_host_unit_scale()
  local topology = singleWorld(320, 240)
  local measurement = measurementFor(topology, 320, 240, "dpi-two-equivalent")
  measurement.pixelRatio = 2
  local menu, _ = menuWith(measurement, nil)
  local placement = placementOf(menu, "at pixel ratio 2")
  Assert.equal(placement.pixelScale, 2, "the same physical bounds must keep the integer density")
  Assert.equal(placement.logicalWidth, 320, "dots never change the logical viewport")
  Assert.equal(placement.logicalHeight, 240, "dots never change the logical viewport")
  Assert.equal(placement.scale, 1, "host units per logical pixel divide out the ratio")
end

function T.tests.tiny_hosts_keep_a_complete_fractional_viewport()
  local topology = singleWorld(240, 180)
  local menu, _ = menuWith(measurementFor(topology, 240, 180, "tiny-host-fallback"), nil)
  local plan = planOf(menu, "on the tiny host")
  local placement = assert(plan.panes[1].placement, "the fallback must stay presentable")
  Assert.equal(placement.logicalWidth, 256, "tiny hosts keep the complete logical viewport")
  Assert.equal(placement.logicalHeight, 192, "tiny hosts keep the complete logical viewport")
  Assert.isTrue(placement.scale < 1, "the fallback downscales instead of cropping controls away")
end

function T.tests.pointer_outside_the_visible_clip_reaches_no_control()
  local topology = singleWorld(640, 480)
  local menu, results = menuWith(measurementFor(topology, 640, 480, "clip-rejection"), nil)
  menu:mousepressed(-10, -10, 1)
  menu:mousereleased(-10, -10, 1)
  Assert.deepEqual(results, {}, "clipped presses must not publish route results")
  Assert.isNil(menu:view().popup, "clipped presses must not open overflow")
end

function T.tests.held_press_across_reflow_cancels_without_activating()
  -- A live display context (not a static record) so the resize changes
  -- the measured facts and the session reflow invalidates the capture.
  local results = {}
  local menu = MainMenuState.new({
    saveStore = singleStore(),
    readyVersions = { "heartgold" },
    renderer = fakeRenderer(),
    onResult = function(result)
      results[#results + 1] = result
    end,
    width = 640,
    height = 480,
    displayContext = DisplayContext.new({}),
  })
  local placement = placementOf(menu, "before the held press")
  local view = menu:view()
  local card = assert(view.layout.saves.cards["save-00000001"], "the reflow test needs its save card")
  local downX, downY = LayoutGeometry.logicalToHost(placement, card.overflow.x + 1, card.overflow.y + 1)
  menu:mousepressed(downX, downY, 1)
  Assert.notNil(menu:view().popup, "the held press opens overflow on press")
  menu:resize(1280, 720)
  menu:mousereleased(downX, downY, 1)
  Assert.deepEqual(results, {}, "a stale release across reflow must not continue the save")
  Assert.notNil(menu:view().popup, "cancellation must not dismiss the open popup")
  local fresh = menu:view()
  local freshDelete = assert(fresh.layout.popup.actions.delete, "geometry changes keep the popup")
  local freshPlacement = placementOf(menu, "after reflow")
  local pressX, pressY = LayoutGeometry.logicalToHost(freshPlacement, freshDelete.x + 1, freshDelete.y + 1)
  menu:mousepressed(pressX, pressY, 1)
  menu:mousereleased(pressX, pressY, 1)
  Assert.notNil(menu:view().confirmation, "fresh input must work after cancellation")
  Assert.deepEqual(results, {}, "fresh popup input must not continue either")
end

function T.tests.unknown_override_cases_fail_without_a_partial_plan()
  local topology = singleWorld(640, 480)
  local ok, err = pcall(function()
    menuWith(measurementFor(topology, 640, 480, "bad-override"), {
      widescreen = function() end,
    })
  end)
  Assert.isFalse(ok, "unknown override cases must fail at composition")
  Assert.isTrue(string.find(tostring(err), "unknown menu override case") ~= nil, "the failure must name the case")
end

function T.tests.non_function_overrides_fail_without_a_partial_plan()
  local topology = singleWorld(640, 480)
  local ok, err = pcall(function()
    menuWith(measurementFor(topology, 640, 480, "non-function-override"), { wide = "fullscreen" })
  end)
  Assert.isFalse(ok, "non-function overrides must fail at composition")
  Assert.isTrue(string.find(tostring(err), "must be a function") ~= nil, "the failure must name the contract")
end

function T.tests.disposal_releases_the_session_exactly_once()
  local topology = singleWorld(640, 480)
  local menu, _ = menuWith(measurementFor(topology, 640, 480, "disposal"), nil)
  planOf(menu, "before disposal")
  menu:dispose()
  menu:dispose()
  local ok, _ = pcall(function()
    menu:view()
  end)
  Assert.isFalse(ok, "a disposed menu resolves nothing")
end

return T
