-- Covered field entry: a new-game-only, presentation-only initial reveal.
-- A FieldState built with the initial-reveal option must draw its first
-- frame fully black over the already-constructed field/player, reveal
-- through the reversed shared fade steps on the source-frame cadence,
-- track resizes, gate gameplay input until complete, and leave ordinary
-- entries (and post-reveal input) untouched.

local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local FieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController")
local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {}

local JOYSTICK = {
  getID = function()
    return 7
  end,
}

-- Boots a real FieldState with a stubbed FieldRuntime that carries every
-- field draw/input touches. The entry cover under test is requested through
-- the public construction option only; no test-only internal field is set.
---@param withCover boolean
---@return FieldState state
---@return table probe
local function boot(withCover)
  local input = FieldInput.new()
  local hostWidth, hostHeight = love.graphics.getDimensions()
  local viewport = FieldViewport.new(hostWidth, hostHeight, { mode = "expanded" })
  viewport.worldViewport = { x = 0, y = 0, width = hostWidth, height = hostHeight }
  local dims = { width = hostWidth, height = hostHeight }
  local bootTopology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = hostWidth, height = hostHeight },
    touch = false,
    role = "world",
  })
  local placement = StartMenuLayout.resolve(bootTopology, { x = 0, y = 0, width = hostWidth, height = hostHeight })
  local cache = FieldStatePresentationFixture.cache()
  local terrain = FieldStatePresentationFixture.terrainEffects(cache)
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, _)
    return setmetatable({
      cacheFs = cache,
      uiManifest = FieldUiFixture.manifest(),
      fieldEntranceIndicatorAsset = {
        model = { batches = {}, materials = {} },
        effects = {
          surf_attachment = {
            model = { batches = {}, materials = {} },
            presentation = { yawDegrees = { north = 180, south = 0, west = 270, east = 90 } },
          },
        },
      },
      fieldEmoteModels = {
        exclamation = {
          schema = "g4-field-emote-v1",
          anchorOffset = { x = 0, y = 2, z = 0.0625 },
          model = { batches = {}, materials = {} },
        },
      },
      fieldEffectAssets = { effects = terrain },
      fieldTerrainEffectController = FieldTerrainEffectController.new({
        effects = terrain,
        modelFactory = function()
          error("the terrain model factory is installed by presentation resources", 0)
        end,
      }),
      windowStyles = {
        resolve = function() end,
      },
      menuHost = {
        setScreenTopology = function() end,
        setPresentationMetrics = function() end,
        presentation = function()
          return nil
        end,
      },
      actors = {
        visualRevision = function()
          return 0
        end,
        collectSpriteIds = function() end,
        drawRecords = function()
          return {}
        end,
      },
      playerVisual = {
        spriteId = 0,
        drawRecord = function()
          return { visible = false }
        end,
      },
      startMenuPlacement = placement,
      resizePresentation = function(_, width, height)
        viewport.worldViewport = { x = 0, y = 0, width = width, height = height }
        dims.width, dims.height = width, height
      end,
      dispose = function() end,
      update = function() end,
      errorText = nil,
      runtimeMap = {
        mapId = 61,
        mapSymbol = "MAP_NEW_BARK",
        sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
      },
      player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
      session = {
        renderAlpha = function()
          return 0.5
        end,
      },
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      viewport = viewport,
      camera = { zoom = 1 },
      transition = { fadeAlpha = 0 },
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
      input = input,
      actionKeys = {},
      cancelKeys = {},
      menuKeys = { m = true },
      zoom = {
        zoomOut = function() end,
        zoomIn = function() end,
        reset = function() end,
      },
      applyZoomChange = function() end,
    }, FieldRuntime)
  end
  local game = { saveId = "save-00000001", versionId = "heartgold" }
  local options = {
    topologyProvider = function(width, height)
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = width, height = height },
        touch = false,
        role = "world",
      })
    end,
  }
  if withCover then
    options.initialFadeIn = true
  end
  local ok, state = pcall(FieldState.new, game, options)
  FieldRuntime.new = originalNew
  if not ok then
    error(state, 0)
  end
  local worlds = 0
  state.presentationResources.renderer = {
    draw = function()
      worlds = worlds + 1
    end,
    release = function() end,
  } --[[@as any]]
  return state,
    {
      input = input,
      viewport = viewport,
      dims = dims,
      worlds = function()
        return worlds
      end,
    }
end

-- Records real love.graphics rectangle fills with their colors; the entry
-- cover is the only overlay active in these scenarios, so every black fill
-- observed here belongs to it.
local function spyRectangles(sink)
  local realRectangle, realSetColor = love.graphics.rectangle, love.graphics.setColor
  local color = { 1, 1, 1, 1 }
  rawset(love.graphics, "setColor", function(r, g, b, a)
    color = { r, g, b, a }
    realSetColor(r, g, b, a)
  end)
  rawset(love.graphics, "rectangle", function(mode, x, y, w, h)
    sink[#sink + 1] = { color[1], color[2], color[3], color[4], mode, x, y, w, h }
    realRectangle(mode, x, y, w, h)
  end)
  return function()
    rawset(love.graphics, "rectangle", realRectangle)
    rawset(love.graphics, "setColor", realSetColor)
  end
end

local function blackAlphas(sink)
  local alphas = {}
  for _, call in ipairs(sink) do
    if call[1] == 0 and call[2] == 0 and call[3] == 0 then
      alphas[#alphas + 1] = call[4]
    end
  end
  return alphas
end

-- At least one black fill at this draw must span the whole current
-- presentation surface; multi-rectangle unions are allowed, so this checks
-- coverage rather than an exact rectangle count.
local function assertCoversViewport(sink, viewport, alpha)
  local bounds = viewport.worldViewport
  for _, call in ipairs(sink) do
    if call[1] == 0 and call[2] == 0 and call[3] == 0 and math.abs(call[4] - alpha) < 1e-9 then
      if
        call[6] <= bounds.x
        and call[7] <= bounds.y
        and call[6] + call[8] >= bounds.x + bounds.width
        and call[7] + call[9] >= bounds.y + bounds.height
      then
        return
      end
    end
  end
  error("no black entry overlay at alpha " .. tostring(alpha) .. " covers the presentation surface", 0)
end

function T.covered_entry_starts_black_and_reveals_through_the_shared_steps()
  local state, probe = boot(true)
  local ok, err = pcall(function()
    Assert.notNil(state.runtime, "the field runtime is constructed before the first covered frame")
    Assert.notNil(state.runtime.playerVisual, "the player visual is constructed beneath the cover")
    local sink = {}
    local restore = spyRectangles(sink)
    local drawOk, drawErr = pcall(function()
      state:draw()
    end)
    restore()
    if not drawOk then
      error(drawErr, 0)
    end
    Assert.equal(probe.worlds(), 1, "the world draws beneath the cover on the first frame")
    Assert.deepEqual(blackAlphas(sink), { 1 }, "the first field-owned frame is fully black")
    assertCoversViewport(sink, probe.viewport, 1)

    local observed = { 1 }
    for _ = 1, 6 do
      state:update(1 / 30)
      local stepSink = {}
      restore = spyRectangles(stepSink)
      drawOk, drawErr = pcall(function()
        state:draw()
      end)
      restore()
      if not drawOk then
        error(drawErr, 0)
      end
      for _, alpha in ipairs(blackAlphas(stepSink)) do
        observed[#observed + 1] = alpha
      end
    end
    Assert.deepEqual(
      observed,
      { 1, 14 / 16, 11 / 16, 9 / 16, 6 / 16, 3 / 16 },
      "the reveal follows the reversed six-step fade to fully revealed"
    )
    for index = 2, #observed do
      Assert.isTrue(observed[index] < observed[index - 1], "the reveal is monotonic")
    end
    Assert.equal(probe.worlds(), 7, "every reveal step keeps the constructed world drawing beneath")

    state:update(1 / 30)
    local settledSink = {}
    restore = spyRectangles(settledSink)
    drawOk, drawErr = pcall(function()
      state:draw()
    end)
    restore()
    if not drawOk then
      error(drawErr, 0)
    end
    Assert.deepEqual(blackAlphas(settledSink), {}, "the one-shot cover disappears after completion")
  end, debug.traceback)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.ordinary_entry_draws_no_cover_overlay()
  local state, _ = boot(false)
  local ok, err = pcall(function()
    local sink = {}
    local restore = spyRectangles(sink)
    local drawOk, drawErr = pcall(function()
      state:draw()
    end)
    restore()
    if not drawOk then
      error(drawErr, 0)
    end
    Assert.deepEqual(blackAlphas(sink), {}, "an ordinary Continue entry draws no cover overlay")
  end, debug.traceback)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.resize_mid_reveal_covers_the_resized_surface()
  local state, probe = boot(true)
  local ok, err = pcall(function()
    local sink = {}
    local restore = spyRectangles(sink)
    local drawOk, drawErr = pcall(function()
      state:draw()
    end)
    restore()
    if not drawOk then
      error(drawErr, 0)
    end
    assertCoversViewport(sink, probe.viewport, 1)
    state:update(1 / 30)
    state:resize(probe.dims.width + 160, probe.dims.height + 120)
    local resizedSink = {}
    restore = spyRectangles(resizedSink)
    drawOk, drawErr = pcall(function()
      state:draw()
    end)
    restore()
    if not drawOk then
      error(drawErr, 0)
    end
    assertCoversViewport(resizedSink, probe.viewport, 14 / 16)
  end, debug.traceback)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.gameplay_presses_are_gated_until_the_reveal_completes()
  local state, probe = boot(true)
  local calls = {}
  local recording = {}
  for _, name in ipairs({
    "pressDirection",
    "releaseDirection",
    "setStickAxis",
    "pointerDown",
    "pointerMove",
    "pointerUp",
    "pointerScroll",
    "pressAction",
    "releaseAction",
    "pressCancel",
    "releaseCancel",
    "pressMenu",
    "releaseMenu",
    "clearAll",
  }) do
    recording[name] = function(_, ...)
      calls[#calls + 1] = { name, ... }
    end
  end
  state.runtime.input = recording --[[@as FieldInput]]
  local ok, err = pcall(function()
    state:keypressed("down")
    state:keypressed("m")
    state:gamepadpressed(JOYSTICK, "dpdown")
    state:gamepadpressed(JOYSTICK, "a")
    state:gamepadpressed(JOYSTICK, "b")
    state:gamepadpressed(JOYSTICK, "x")
    state:gamepadaxis(JOYSTICK, "leftx", -0.75)
    state:mousepressed(12, 34, 1)
    state:mousemoved(15, 36, 3, 2, false)
    state:wheelmoved(2, -3)
    state:touchpressed(9, 3, 4)
    for _, call in ipairs(calls) do
      Assert.isTrue(
        call[1] ~= "pressDirection"
          and call[1] ~= "pressAction"
          and call[1] ~= "pressCancel"
          and call[1] ~= "pressMenu"
          and call[1] ~= "setStickAxis"
          and call[1] ~= "pointerDown"
          and call[1] ~= "pointerMove"
          and call[1] ~= "pointerScroll",
        "no gameplay press/pointer/axis may reach FieldInput under the cover: " .. call[1]
      )
    end
    -- Release and focus-loss paths stay safe while covered.
    state:keyreleased("down")
    state:keyreleased("m")
    state:gamepadreleased(JOYSTICK, "dpdown")
    state:mousereleased(15, 36, 1)
    state:touchreleased(9, 5, 6)
    state:focus(false)
    for _ = 1, 7 do
      state:update(1 / 30)
    end
    local afterCalls = #calls
    state:keypressed("down")
    state:keypressed("m")
    state:gamepadpressed(JOYSTICK, "dpdown")
    state:mousepressed(12, 34, 1)
    local gated = #calls - afterCalls
    Assert.isTrue(gated >= 4, "the same inputs route normally once the reveal completes")
    Assert.equal(probe.input:snapshot().heldDirection, nil)
  end, debug.traceback)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.no_stale_edge_survives_keys_held_under_the_cover()
  local state, probe = boot(true)
  local ok, err = pcall(function()
    state:keypressed("down")
    local during = probe.input:snapshot()
    Assert.isNil(during.pressedDirection, "a direction pressed under the cover leaves no edge")
    Assert.isNil(during.heldDirection, "a direction pressed under the cover leaves nothing held")
    state:keyreleased("down")
    state:focus(false)
    for _ = 1, 7 do
      state:update(1 / 30)
    end
    local settled = probe.input:snapshot()
    Assert.isNil(settled.pressedDirection, "releasing under the cover leaves no stale edge after the reveal")
    Assert.isNil(settled.heldDirection, nil)
    Assert.isFalse(settled.actionDown)
    state:keypressed("right")
    local routed = probe.input:snapshot()
    Assert.equal(routed.pressedDirection, "east", "normal input resumes after the reveal")
    state:keyreleased("right")
  end, debug.traceback)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
