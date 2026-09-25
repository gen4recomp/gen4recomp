-- Dev-mode behavior over the developer overlay. Product mode (the
-- default) never renders the overlay and F3 is inert there; dev mode starts
-- with the overlay hidden and F3 toggles it. The zoom keys are product
-- camera controls and stay available in both modes.

local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local InactivePokemonNaming = require("tests.support.InactivePokemonNaming")

local T = {}

-- A bare FieldState (no boot) shaped like a live presentation state: the
-- canonical runtime fields the draw path touches, a stubbed renderer, and the
-- development flag under test. The player visual record is invisible, so the
-- actor assembly never touches the presentation asset provider.
local function drawableState(development)
  return setmetatable({
    development = development == true,
    _developmentOverlayVisible = false,
    _fpsElapsed = 0,
    _fpsFrames = 0,
    _fps = 0,
    runtime = {
      pokemonNaming = InactivePokemonNaming.new(),
      runtimeMap = {
        mapId = 61,
        mapSymbol = "MAP_NEW_BARK",
        sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
      },
      player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
      playerVisual = {
        drawRecord = function()
          return { visible = false }
        end,
      },
      actors = {
        drawRecords = function()
          return {}
        end,
      },
      session = {
        renderAlpha = function()
          return 0.5
        end,
      },
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      viewport = FieldViewport.new(640, 480, { mode = "expanded" }),
      camera = { zoom = 1 },
      transition = { fadeAlpha = 0 },
      fieldPixelScale = {
        resolvedScale = function()
          return 3
        end,
      },
      fieldEntranceIndicator = {
        status = function()
          return { visible = false }
        end,
      },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      scripts = {
        dialogueHost = {
          yesNoPresentation = function()
            return nil
          end,
        },
      },
      signpost = {
        isModal = function()
          return false
        end,
      },
      applicationHost = {
        status = function()
          return { phase = "closed", fadeAlpha = 0 }
        end,
      },
      menuHost = {
        presentation = function()
          return nil
        end,
      },
      resizePresentation = function() end,
    },
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    presentationResources = {
      renderer = { draw = function() end },
      fieldEntranceIndicatorRenderer = {
        drawItems = function()
          return {}
        end,
      },
      fieldEmoteRenderer = {
        drawItems = function()
          return {}
        end,
      },
    },
    actorPresentation = {
      drawItems = function()
        return {}
      end,
      records = function()
        return {}
      end,
    },
  }, FieldState)
end

-- Counts the HUD's graphics calls through the real offscreen graphics host,
-- restoring print/rectangle on every path.
local function withHudGraphicsSpy(fn)
  local graphics = love.graphics
  local counts = { print = 0, rectangle = 0 }
  local original = {}
  for name in pairs(counts) do
    original[name] = graphics[name]
    graphics[name] = function()
      counts[name] = counts[name] + 1
    end
  end
  local ok, err = pcall(fn)
  for name in pairs(original) do
    graphics[name] = original[name]
  end
  if not ok then
    error(err, 0)
  end
  return counts
end

-- Records every HUD print line through the real offscreen graphics host,
-- restoring print/rectangle on every path.
local function withHudTextSpy(fn)
  local graphics = love.graphics
  local texts = {}
  local rectangles = 0
  local originalPrint, originalRectangle = graphics.print, graphics.rectangle
  graphics.print = function(text)
    texts[#texts + 1] = tostring(text)
  end
  graphics.rectangle = function()
    rectangles = rectangles + 1
  end
  local ok, err = pcall(fn)
  graphics.print, graphics.rectangle = originalPrint, originalRectangle
  if not ok then
    error(err, 0)
  end
  return { texts = texts, rectangles = rectangles }
end

-- A development drawable state with stubbed host input/update edges so the
-- overlay toggle and sampling can be driven deterministically: empty alias
-- sets, a recording semantic-input spy, a no-op runtime update, and a no-op
-- actor-presentation sync. Rendering still goes through the real draw path.
local function overlayFixture(development)
  local state = drawableState(development)
  state.runtime.actionKeys = {}
  state.runtime.cancelKeys = {}
  state.runtime.menuKeys = {}
  local calls = {}
  local function record(name)
    return function()
      calls[#calls + 1] = name
    end
  end
  -- The spy intentionally implements only the pressed-edge subset the
  -- overlay toggle must not reach; the held-state machine stays with the
  -- real input owner. An open record keeps the partial spy free of static
  -- missing-fields diagnostics.
  ---@type table<string, any>
  local input = {
    calls = calls,
    pressAction = record("action"),
    pressCancel = record("cancel"),
    pressMenu = record("menu"),
    pressDirection = record("direction"),
  }
  state.runtime.input = input
  state.runtime.update = function() end
  state.actorPresentation.sync = function() end
  return state
end

-- Names the semantic-input edges the spy recorded. The call log lives
-- beside the pressed-edge subset on the test spy, not on the production
-- input owner.
---@param state table<string, any>
---@return string[]
local function inputCalls(state)
  return state.runtime.input.calls
end

local function reportedFps(texts)
  for _, line in ipairs(texts) do
    local value = line:match("fps%s+([%d%.]+)")
    if value then
      return tonumber(value)
    end
  end
  return nil
end

-- Dev launches start with the developer overlay hidden.
function T.dev_mode_starts_with_the_developer_overlay_hidden()
  local counts = withHudGraphicsSpy(function()
    overlayFixture(true):draw()
  end)
  Assert.equal(counts.print, 0, "dev mode must start with the overlay hidden")
  Assert.equal(counts.rectangle, 0, "a hidden overlay draws no backdrop")
end

-- F3 toggles the developer overlay and never reaches gameplay input.
function T.dev_mode_f3_toggles_the_developer_overlay()
  local state = overlayFixture(true)
  state:keypressed("f3")
  local shown = withHudGraphicsSpy(function()
    state:draw()
  end)
  Assert.equal(shown.print, 4, "first F3 shows the map, player, fps, and controls lines")
  state:keypressed("f3")
  local hidden = withHudGraphicsSpy(function()
    state:draw()
  end)
  Assert.equal(hidden.print, 0, "second F3 hides the overlay again")
  Assert.equal(#inputCalls(state), 0, "F3 is consumed by the overlay toggle")
end

-- F3 is consumed by the overlay toggle even when bound as gameplay input.
function T.dev_mode_f3_is_consumed_before_gameplay_input()
  local state = overlayFixture(true)
  state.runtime.actionKeys = { f3 = true }
  state.runtime.cancelKeys = { f3 = true }
  state.runtime.menuKeys = { f3 = true }
  state:keypressed("f3")
  Assert.equal(#inputCalls(state), 0, "F3 never reaches semantic input in dev mode")
  local shown = withHudGraphicsSpy(function()
    state:draw()
  end)
  Assert.equal(shown.print, 4, "F3 still toggles the overlay when bound as a gameplay key")
end

-- A long host update publishes one sample over the actual accumulated
-- elapsed time, and an interval with no draws publishes 0 without
-- dividing by zero.
function T.active_sample_rollover_uses_accumulated_elapsed_time()
  local state = overlayFixture(true)
  state:keypressed("f3")
  for _ = 1, 10 do
    state:draw()
  end
  state:update(0.1)
  for _ = 1, 10 do
    state:draw()
  end
  state:update(0.6)
  local spy = withHudTextSpy(function()
    state:draw()
  end)
  local fps = reportedFps(spy.texts)
  Assert.notNil(fps, "the crossing update publishes a sample")
  Assert.near(assert(fps), 20 / 0.7, 0.05, "the sample divides by accumulated time, not the nominal window")
  state:keypressed("f3")
  state:keypressed("f3")
  state:update(0.5)
  local idle = withHudTextSpy(function()
    state:draw()
  end)
  Assert.near(reportedFps(idle.texts) or -1, 0, 0.05, "an interval with no draws samples 0")
end
-- F3 is inert outside development mode, even when bound as gameplay input.
function T.product_mode_f3_leaves_the_developer_overlay_hidden()
  local state = overlayFixture(false)
  state.runtime.actionKeys = { f3 = true }
  state.runtime.cancelKeys = { f3 = true }
  state:keypressed("f3")
  local counts = withHudGraphicsSpy(function()
    state:draw()
  end)
  Assert.equal(counts.print, 0, "product mode never renders the overlay")
  Assert.equal(#inputCalls(state), 0, "product F3 reaches no gameplay input")
end

-- The overlay reports a 500 ms sampled frame rate and drops save status.
function T.dev_mode_overlay_reports_sampled_fps_without_save_status()
  local state = overlayFixture(true)
  state:keypressed("f3")
  -- Draws precede updates so the first completed sample covers all thirty
  -- frames: sampling rollover publishes in update, so an update-first loop
  -- would publish mid-window over twenty-four frames instead.
  for _ = 1, 5 do
    for _ = 1, 6 do
      state:draw()
    end
    state:update(0.1)
  end
  local spy = withHudTextSpy(function()
    state:draw()
  end)
  Assert.equal(#spy.texts, 4, "overlay keeps map, player, fps, and controls lines")
  for _, line in ipairs(spy.texts) do
    Assert.isNil(line:find("save"), "save status must not appear in the overlay")
  end
  local fps = reportedFps(spy.texts)
  Assert.notNil(fps, "overlay reports a sampled fps line")
  Assert.near(assert(fps), 60, 0.15, "thirty frames over half a second samples about 60 fps")
  local mentionsToggle = false
  for _, line in ipairs(spy.texts) do
    if line:find("F3") then
      mentionsToggle = true
    end
  end
  Assert.isTrue(mentionsToggle, "controls mention the F3 toggle")
end

-- Hidden overlay intervals sample nothing and re-enabling starts fresh.
function T.hidden_overlay_discards_sampling_activity()
  local state = overlayFixture(true)
  state:keypressed("f3")
  state:update(0.1)
  state:draw()
  state:keypressed("f3")
  local hidden = withHudGraphicsSpy(function()
    state:update(1.0)
    state:draw()
    state:draw()
  end)
  Assert.equal(hidden.print, 0, "hidden overlay draws nothing")
  state:keypressed("f3")
  local spy = withHudTextSpy(function()
    state:draw()
  end)
  local fps = reportedFps(spy.texts)
  Assert.notNil(fps, "re-enabled overlay reports fps")
  Assert.near(assert(fps), 0, 0.05, "re-enable starts from a clean sample")
end

-- Product mode (the default) renders no developer overlay.
function T.product_mode_draw_renders_no_developer_overlay()
  local counts = withHudGraphicsSpy(function()
    drawableState(false):draw()
  end)
  Assert.equal(counts.print, 0, "product mode must not print the developer overlay")
  Assert.equal(counts.rectangle, 0, "product mode must not draw the HUD backdrop")
end

-- Dev mode shows the developer overlay only after the F3 toggle.
function T.dev_mode_draw_shows_the_developer_overlay_after_f3()
  local state = drawableState(true)
  state:keypressed("f3")
  local counts = withHudGraphicsSpy(function()
    state:draw()
  end)
  Assert.equal(counts.print, 4, "one F3 shows the four developer overlay lines")
  Assert.equal(counts.rectangle, 1, "a visible overlay keeps the HUD backdrop")
end

-- Product mode ignores the F1 save / F2 reset developer binds.
function T.product_mode_ignores_the_f1_and_f2_developer_binds()
  local saves, resets = 0, 0
  local state = setmetatable({
    runtime = {
      actionKeys = {},
      cancelKeys = {},
      menuKeys = {},
      saveSession = function()
        saves = saves + 1
      end,
      reset = function()
        resets = resets + 1
      end,
    },
  }, FieldState)
  state:keypressed("f1")
  state:keypressed("f2")
  Assert.equal(saves, 0, "product mode must ignore the F1 developer save bind")
  Assert.equal(resets, 0, "product mode must ignore the F2 developer reset bind")
end

-- Dev mode no longer exposes legacy persistence/reset binds.
function T.dev_mode_ignores_the_legacy_f1_and_f2_persistence_binds()
  local saves, resets = 0, 0
  local state = setmetatable({
    development = true,
    runtime = {
      actionKeys = {},
      cancelKeys = {},
      menuKeys = {},
      saveSession = function()
        saves = saves + 1
      end,
      reset = function()
        resets = resets + 1
      end,
    },
  }, FieldState)
  state:keypressed("f1")
  state:keypressed("f2")
  Assert.equal(saves, 0, "dev mode must not expose the legacy F1 save bind")
  Assert.equal(resets, 0, "dev mode must not expose the legacy F2 reset bind")
end

-- The zoom keys are product camera controls and stay available in both modes.
function T.product_mode_keeps_the_documented_zoom_controls()
  local zooms = {}
  local changes = 0
  local state = setmetatable({
    runtime = {
      actionKeys = {},
      cancelKeys = {},
      menuKeys = {},
      fieldPixelScale = {
        zoomOut = function()
          zooms[#zooms + 1] = "out"
        end,
        zoomIn = function()
          zooms[#zooms + 1] = "in"
        end,
        reset = function()
          zooms[#zooms + 1] = "reset"
        end,
      },
      applyFieldPixelScaleChange = function()
        changes = changes + 1
      end,
    },
  }, FieldState)
  state:keypressed("-")
  state:keypressed("=")
  state:keypressed("0")
  Assert.deepEqual(zooms, { "out", "in", "reset" }, "zoom keys are product controls, not gated")
  Assert.equal(changes, 3, "each zoom key reapplies the camera projection")
end

return { tests = T }
