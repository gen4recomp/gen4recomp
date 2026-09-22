-- Production-composed Oak/profile transition checks using the generated cache
-- and the offscreen graphics host. Ticks alone never complete the handoff:
-- one real draw presents the full-black frame before the next tick may
-- finalize it.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {}

local function candidate(versionId)
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000001"
      end,
    },
    versionId = versionId,
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
  })
end

local function compose(scope, versionId, width, height)
  local audio = FakeAudioOutput.new()
  local state = OakIntroComposition.compose({
    candidate = candidate(versionId),
    versionId = versionId,
    graphics = love.graphics,
    audioOutput = { audio = audio.audio, sound = audio.sound },
    clock = {
      nowLocal = function()
        return { year = 2026, month = 8, day = 27, hour = 12, minute = 0, second = 0 }
      end,
    },
    randomU32 = function()
      return 0x12345678
    end,
    width = width,
    height = height,
    textInputHost = { setTextInput = function() end },
  })
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  return state
end

local function finishDialogue(state)
  local messageKey = assert(state:view().messageKey, "scenario requires an active dialogue")
  for _ = 1, 20000 do
    if state:view().messageKey ~= messageKey then
      return
    end
    local status = state.dialogueController:status()
    if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
      state:keypressed("return")
    else
      state:tick(1)
    end
  end
  error("dialogue did not reach its semantic completion boundary: " .. messageKey)
end

local function advanceUntilMessage(state, messageKey)
  for _ = 1, 20000 do
    if state:view().messageKey == messageKey then
      return
    end
    if state.dialogueController:isModal() then
      finishDialogue(state)
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not open: " .. messageKey)
end

local function beginGenderSelection(state)
  advanceUntilMessage(state, "profile.gender_question")
  finishDialogue(state)
  return state:view()
end

---@param inner OakIntroStateRectangle
---@param outer OakIntroStateRectangle
---@return boolean
local function inside(inner, outer)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

T.wide_host_enters_selection_immediately_with_oak_hidden = function(scope)
  local state = compose(scope, AcceptanceHarness.defaultVersion(), 1920, 1080)
  local entered = beginGenderSelection(state)
  Assert.equal(entered.phase, "gender_select")
  Assert.equal(entered.genderCompositionProgress, 1)
  Assert.isNil(entered.layout.subject, "Oak must be absent while the selector is shown")
  Assert.isNil(entered.layout.oakRegion, "Oak must be absent while the selector is shown")
  local selectorRegion = assert(entered.layout.selectorRegion)
  local before = {}
  for gender = 0, 1 do
    local entry = assert(entered.layout.genderButtons[gender])
    Assert.isTrue(inside(entry.rect, selectorRegion), "gender card must stay inside the selector region")
    before[gender] = entry.rect
  end

  for _ = 1, 26 do
    state:tick(1)
    local view = state:view()
    Assert.equal(view.phase, "gender_select")
    Assert.equal(view.genderCompositionProgress, 1)
    Assert.isNil(view.layout.subject)
  end
  local settled = state:view()
  for gender = 0, 1 do
    Assert.deepEqual(settled.layout.genderButtons[gender].rect, before[gender], "cards must not drift without a slide")
  end
end

T.resized_tall_host_keeps_selection_geometry_stable = function(scope)
  local state = compose(scope, AcceptanceHarness.defaultVersion(), 390, 844)
  local entered = beginGenderSelection(state)
  Assert.equal(entered.phase, "gender_select")
  Assert.isNil(entered.layout.subject)

  state:resize(430, 900)
  local resized = state:view()
  Assert.equal(resized.phase, "gender_select")
  local selectorRegion = assert(resized.layout.selectorRegion)
  for gender = 0, 1 do
    local entry = assert(resized.layout.genderButtons[gender])
    Assert.isTrue(inside(entry.rect, selectorRegion), "resized cards must stay inside the selector region")
  end

  state:keypressed("return")
  finishDialogue(state)
  Assert.equal(state:view().phase, "gender_confirm")
  state:keypressed("escape")
  local question = state:view()
  Assert.equal(question.phase, "gender_question")
  Assert.equal(question.genderCompositionProgress, 1)

  finishDialogue(state)
  local reentered = state:view()
  Assert.equal(reentered.phase, "gender_select")
  Assert.equal(reentered.genderCompositionProgress, 1)
  Assert.notNil(reentered.layout.genderButtons)
end

local FieldState = require("game.hgss.src.field.FieldState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController")

-- Drives a production-composed Oak state through profile selection into
-- the shrink animation using semantic input only.
local function driveToShrink(state)
  for _ = 1, 30000 do
    local view = state:view()
    if view.phase == "shrink_animation" then
      return
    end
    if view.phase == "complete" then
      error("Oak completed before reaching the shrink animation", 0)
    end
    if view.phase == "name_edit" then
      state.controller:inputText("GOLD")
      state.controller:press("submit")
      state:tick(26)
    elseif state.dialogueController:isModal() then
      local status = state.dialogueController:status()
      if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
        state:keypressed("return")
      else
        state:tick(1)
      end
    else
      state:keypressed("return")
      state:tick(1)
    end
  end
  error("Oak did not reach the shrink animation", 0)
end

-- A covered field entry over a stubbed runtime: the presentation resources
-- are real, so the first drawn frame proves the player/runtime is
-- constructed beneath the entry black.
local function bootCoveredField(scope)
  local hostWidth, hostHeight = love.graphics.getDimensions()
  local viewport = FieldViewport.new(hostWidth, hostHeight, { mode = "expanded" })
  viewport.worldViewport = { x = 0, y = 0, width = hostWidth, height = hostHeight }
  local cache = FieldStatePresentationFixture.cache()
  local terrain = FieldStatePresentationFixture.terrainEffects(cache)
  -- The draw path renders through the real field renderer, which needs a
  -- camera with projection matrices; identity matrices suffice for the
  -- black-frame entry cover under test.
  local identityMatrix = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  local camera = {
    zoom = 1,
    far = 1000,
    view = function()
      return identityMatrix
    end,
    projection = function()
      return identityMatrix
    end,
    billboardProjection = function()
      return identityMatrix
    end,
  }
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, _)
    return setmetatable({
      cacheFs = cache,
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
      uiManifest = FieldUiFixture.addStartMenuIconContract(FieldUiFixture.manifest()),
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
      resizePresentation = function() end,
      dispose = function() end,
      update = function() end,
      errorText = nil,
      runtimeMap = {
        mapId = 61,
        mapSymbol = "MAP_NEW_BARK",
        sceneRuntime = {
          mapDraws = {},
          staticBuildingDraws = {},
          animatedBuildingDraws = {},
          edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
          fog = (function()
            local fogTable = {}
            for index = 1, 32 do
              fogTable[index] = 0
            end
            return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable }
          end)(),
        },
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
      camera = camera,
      transition = { fadeAlpha = 0 },
      fieldPixelScale = {
        resolvedScale = function()
          return 2
        end,
      },
      fieldEntranceIndicator = {
        status = function()
          return { visible = false }
        end,
      },
      fieldEffectAssets = { effects = terrain },
      playerData = { options = { textFrame = 0 } },
      fieldTerrainEffectController = FieldTerrainEffectController.new({
        effects = terrain,
        modelFactory = function()
          error("the terrain model factory is installed by presentation resources", 0)
        end,
      }),
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
      input = {
        pressDirection = function() end,
        pressAction = function() end,
        pressMenu = function() end,
      },
      actionKeys = {},
      cancelKeys = {},
      menuKeys = {},
      zoom = {
        zoomOut = function() end,
        zoomIn = function() end,
        reset = function() end,
      },
      applyZoomChange = function() end,
    }, FieldRuntime)
  end
  local ok, state = pcall(FieldState.new, { saveId = "save-00000001", versionId = "heartgold" }, {
    topologyProvider = function(width, height)
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = width, height = height },
        touch = false,
        role = "world",
      })
    end,
    initialFadeIn = true,
  })
  FieldRuntime.new = originalNew
  if not ok then
    error(state, 0)
  end
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  local testState = state --[[@as any]]
  testState.renderer = {
    draw = function() end,
    release = function() end,
  }
  return state
end

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

-- The state-boundary contract of the covered handoff, asserted semantically:
-- the last intro-owned frame is a presented fully black frame with the
-- candidate published only after that presentation, the first field-owned
-- frame is fully black with the player/runtime already constructed, and the
-- reveal out of black is monotonic with bounded steps, so no visible cut can
-- occur between them.
T.covered_handoff_keeps_black_between_intro_and_field = function(scope)
  local state = compose(scope, AcceptanceHarness.defaultVersion(), 640, 480)
  driveToShrink(state)
  local shrinkTicks = 0
  while state:view().phase == "shrink_animation" and shrinkTicks < 500 do
    Assert.isNil(state.controller:result(), "the candidate stays unpublished while shrinking")
    state:tick(1)
    shrinkTicks = shrinkTicks + 1
  end
  Assert.isTrue(state:view().phase ~= "shrink_animation", "the shrink animation must terminate")
  local boundary = state:view()
  Assert.near(boundary.finalFadeAlpha, 0, 1e-9, "the post-shrink cover starts transparent")
  Assert.isNil(state.controller:result(), "the candidate stays unpublished until the cover is black")
  local outgoing = {}
  for _ = 1, 6 do
    state:tick(1)
    outgoing[#outgoing + 1] = state:view().finalFadeAlpha
  end
  Assert.deepEqual(
    outgoing,
    { 2 / 16, 5 / 16, 7 / 16, 10 / 16, 13 / 16, 1 },
    "the outgoing cover follows the shared outward fade"
  )
  Assert.isTrue(state:view().phase ~= "complete", "full black must wait for a presented draw, not complete")
  Assert.isNil(state.controller:result(), "the candidate stays unpublished until the black frame is presented")
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the waiting cover stays black")
  state:draw()
  Assert.isTrue(state:view().phase ~= "complete", "drawing must not itself complete the handoff")
  state:tick(1)
  Assert.equal(state:view().phase, "complete", "the intro completes on the update after the presented black frame")
  Assert.notNil(state.controller:result(), "the candidate publishes after the presented full black")
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the last intro-owned frame is fully black")

  local field = bootCoveredField(scope)
  Assert.notNil(field.runtime, "the field runtime is constructed before the first field frame")
  Assert.notNil(field.runtime.playerVisual, "the player visual is constructed beneath the entry black")
  local sink = {}
  local restore = spyRectangles(sink)
  local drawOk, drawErr = pcall(function()
    field:draw()
  end)
  restore()
  if not drawOk then
    error(drawErr, 0)
  end
  local firstAlpha
  for _, call in ipairs(sink) do
    if call[1] == 0 and call[2] == 0 and call[3] == 0 then
      firstAlpha = call[4]
    end
  end
  Assert.equal(firstAlpha, 1, "the first field-owned frame is fully black")
  local alphas = { 1 }
  for _ = 1, 6 do
    field:update(1 / 30)
    local stepSink = {}
    restore = spyRectangles(stepSink)
    drawOk, drawErr = pcall(function()
      field:draw()
    end)
    restore()
    if not drawOk then
      error(drawErr, 0)
    end
    for _, call in ipairs(stepSink) do
      if call[1] == 0 and call[2] == 0 and call[3] == 0 then
        alphas[#alphas + 1] = call[4]
      end
    end
  end
  for index = 2, #alphas do
    Assert.isTrue(alphas[index] < alphas[index - 1], "the field reveals monotonically out of black")
    Assert.isTrue(
      alphas[index - 1] - alphas[index] <= 3 / 16 + 1e-9,
      "no reveal step may cut abruptly between black and field"
    )
  end
  Assert.isTrue(math.abs(alphas[1] - 1) < 1e-9, "intro black and field black meet with no visible cut")
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
return suite
