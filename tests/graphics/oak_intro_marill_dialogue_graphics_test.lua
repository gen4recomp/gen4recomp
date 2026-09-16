-- Production Oak composition graphics coverage. It drives the real generated
-- intro state to Marill's dialogue and checks that the final dialogue pass does
-- not hide the generated Marill pixels at wide, 4:3, or tall host sizes.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local PixelScale = require("libs.ui.src.PixelScale")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local RomImporter = require("romdump.src.source.RomImporter")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")

local T = {}

local SIZES = {
  { width = 1920, height = 1080, name = "wide" },
  { width = 800, height = 600, name = "four-three" },
  { width = 390, height = 844, name = "tall" },
}

local function candidate(versionId)
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "graphics-oak-" .. versionId
      end,
    },
    versionId = versionId,
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, sourceFacing = 1 },
  })
end

local function driveToMarillDialogue(state)
  for _ = 1, 20000 do
    local view = state:view()
    if view.phase == "oak_live_alongside" and view.revealWidget == "marill" and view.dialogue ~= nil then
      return view
    end
    local dialogue = state.dialogueController
    if dialogue:isModal() then
      local status = dialogue:status()
      if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
        state:keypressed("return")
      else
        state:tick(1)
      end
    else
      state:tick(1)
    end
  end
  error("production Oak flow did not reach visible Marill dialogue")
end

local function quantized(value)
  return math.floor(value * 255 + 0.5)
end

local function differs(first, second, x, y)
  local fr, fg, fb, fa = first:getPixel(x, y)
  local sr, sg, sb, sa = second:getPixel(x, y)
  return quantized(fr) ~= quantized(sr)
    or quantized(fg) ~= quantized(sg)
    or quantized(fb) ~= quantized(sb)
    or quantized(fa) ~= quantized(sa)
end

local function render(scope, state, view, includeDialogue)
  local graphics = love.graphics
  local canvas = scope:own(graphics.newCanvas(state.width, state.height))
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  if includeDialogue then
    state:draw()
  else
    state.renderer:draw(view)
  end
  graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function finishDialogueBoundary(state)
  local initialKey = state:view().messageKey
  Assert.notNil(initialKey, "profile flow requires an active dialogue")
  for _ = 1, 12000 do
    local view = state:view()
    if view.messageKey ~= initialKey then
      return
    end
    local status = state.dialogueController:status()
    if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
      state:keypressed("return")
    else
      state:tick(1)
    end
  end
  error("profile dialogue did not reach its semantic completion boundary")
end

local function reachFinalFullArtHold(state, female)
  for _ = 1, 20000 do
    if state:view().messageKey == "profile.gender_question" then
      break
    end
    if state.dialogueController:isModal() then
      finishDialogueBoundary(state)
    else
      state:tick(1)
    end
  end
  Assert.equal(state:view().messageKey, "profile.gender_question")
  finishDialogueBoundary(state)
  Assert.equal(state:view().phase, "gender_select")
  if female then
    state:keypressed("right")
  end
  state:keypressed("return")
  finishDialogueBoundary(state)
  state:keypressed("return")
  finishDialogueBoundary(state)
  for _ = 1, 20000 do
    if state:view().phase == "name_edit" then
      break
    end
    if state.dialogueController:isModal() then
      finishDialogueBoundary(state)
    else
      state:tick(1)
    end
  end
  Assert.equal(state:view().phase, "name_edit")
  state:textinput("GOLD")
  state:keypressed("return")
  state:tick(26)
  finishDialogueBoundary(state)
  state:keypressed("return")
  finishDialogueBoundary(state)
  state:keypressed("return")
  for _ = 1, 20000 do
    if state:view().phase == "final_full_art_hold" then
      return
    end
    state:tick(1)
  end
  error("profile flow did not reach the full-art hold")
end

local function copyView(view)
  local copy = {}
  for key, value in pairs(view) do
    copy[key] = value
  end
  return copy
end

local function renderWithoutSubject(scope, state, view)
  local canvas = scope:own(love.graphics.newCanvas(state.width, state.height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  local background = copyView(view)
  background.visual = "background"
  background.primaryWidget = nil
  background.revealWidget = nil
  background.revealFrameIndex = nil
  state.renderer:draw(background)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function renderWithSubject(scope, state, view)
  local canvas = scope:own(love.graphics.newCanvas(state.width, state.height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  state.renderer:draw(view)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function assertSubjectPixelsUseSourceBounds(scope, state, view, widgetId, label)
  local widget = assert(state.manifest.widgets[widgetId])
  local layout = assert(view.layout)
  local canvas = assert(layout.sourceCanvas)
  local surface = assert(view.pixelSurface)
  local logicalX = PixelScale.snapLogical(canvas.origin.x + widget.sourceBounds.x * canvas.scale)
  local logicalY = PixelScale.snapLogical(canvas.origin.y + widget.sourceBounds.y * canvas.scale)
  local expectedX, expectedY = LayoutGeometry.logicalToHost(surface.placement, logicalX, logicalY)
  local expected = {
    x = expectedX,
    y = expectedY,
    width = widget.width * canvas.scale * surface.placement.scale,
    height = widget.height * canvas.scale * surface.placement.scale,
  }
  local background = renderWithoutSubject(scope, state, view)
  local subject = renderWithSubject(scope, state, view)
  local changed, outside = 0, 0
  for y = 0, subject:getHeight() - 1 do
    for x = 0, subject:getWidth() - 1 do
      if differs(background, subject, x, y) then
        changed = changed + 1
        local centerX, centerY = x + 0.5, y + 0.5
        if
          centerX < expected.x
          or centerX >= expected.x + expected.width
          or centerY < expected.y
          or centerY >= expected.y + expected.height
        then
          outside = outside + 1
        end
      end
    end
  end
  Assert.isTrue(changed > 0, label .. " must render visible profile pixels")
  Assert.equal(outside, 0, label .. " pixels must use the widget source bounds")
end

local function withProductionState(versionId, body)
  local state
  local ok, failure = xpcall(function()
    state = OakIntroComposition.compose({
      candidate = candidate(versionId),
      versionId = versionId,
      graphics = love.graphics,
      audioOutput = require("tests.acceptance.support.FakeAudioOutput").new(),
      width = SIZES[2].width,
      height = SIZES[2].height,
      textInputHost = { setTextInput = function() end },
      randomU32 = function()
        return 0x12345678
      end,
    })
    body(state)
  end, debug.traceback)
  if state then
    local disposed, disposeFailure = pcall(state.dispose, state)
    if not disposed and ok then
      ok, failure = false, disposeFailure
    end
  end
  if not ok then
    error(failure, 0)
  end
end

function T.marill_pixels_remain_visible_above_the_dialogue_at_host_sizes(scope)
  local readyCount = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      readyCount = readyCount + 1
      withProductionState(versionId, function(state)
        local manifest = assert(state.manifest)
        local intro = assert(manifest.widgets.marill)
        local cache = CacheFs.forVersion(versionId)
        local valid, validationError = IntroAssetCache.validateManifest(manifest)
        Assert.isTrue(valid, validationError and validationError.message or "intro manifest is invalid")
        local initialView = driveToMarillDialogue(state)

        for _, size in ipairs(SIZES) do
          state:resize(size.width, size.height)
          local view = state:view()
          local layout = assert(view.layout)
          local surface = assert(view.pixelSurface)
          local reveal = assert(layout.reveal, size.name .. " reveal layout missing")
          local dialogue = assert(layout.dialogue, size.name .. " dialogue layout missing")

          local withoutReveal = {}
          for key, value in pairs(view) do
            withoutReveal[key] = value
          end
          withoutReveal.revealWidget = nil
          withoutReveal.revealFrameIndex = nil

          local background = render(scope, state, withoutReveal, false)
          local revealOnly = render(scope, state, view, false)
          local final = render(scope, state, view, true)
          local frame = assert(intro.frames[view.revealFrameIndex or 1])
          local frameData = scope:own(
            love.image.newImageData(love.filesystem.newFileData(assert(cache:read(frame.image)), frame.image))
          )
          local minX, minY = frameData:getWidth(), frameData:getHeight()
          local maxX, maxY = -1, -1
          for y = 0, frameData:getHeight() - 1 do
            for x = 0, frameData:getWidth() - 1 do
              local _, _, _, alpha = frameData:getPixel(x, y)
              if alpha > 0 then
                minX, minY = math.min(minX, x), math.min(minY, y)
                maxX, maxY = math.max(maxX, x), math.max(maxY, y)
              end
            end
          end
          Assert.isTrue(
            maxX >= minX and maxY >= minY,
            size.name .. " generated Marill frame must contain visible pixels"
          )
          local fixedRevealX = layout.revealCanvas.origin.x
            + (intro.sourceCenter.x - intro.anchor.x) * layout.revealCanvas.scale
          local fixedRevealY = layout.revealCanvas.origin.y
            + (intro.sourceCenter.y - intro.anchor.y) * layout.revealCanvas.scale
          local revealX, revealY = LayoutGeometry.logicalToHost(
            surface.placement,
            PixelScale.snapLogical(reveal.x),
            PixelScale.snapLogical(reveal.y)
          )
          local revealWidth = reveal.width * surface.placement.scale
          local revealHeight = reveal.height * surface.placement.scale
          local dialogueX, dialogueY =
            LayoutGeometry.logicalToHost(surface.placement, dialogue.outerRect.x, dialogue.outerRect.y)
          local dialogueWidth = dialogue.outerRect.width * surface.placement.scale
          local dialogueHeight = dialogue.outerRect.height * surface.placement.scale
          local xStart = math.max(0, math.floor(revealX))
          local yStart = math.max(0, math.floor(revealY))
          local xEnd = math.min(size.width - 1, math.ceil(revealX + revealWidth) - 1)
          local yEnd = math.min(size.height - 1, math.ceil(revealY + revealHeight) - 1)
          local changedOutsideDialogue, survivedOutsideDialogue = 0, 0
          local expectedPixels, expectedSurvived = 0, 0
          local fixedHostX, fixedHostY = LayoutGeometry.logicalToHost(
            surface.placement,
            PixelScale.snapLogical(fixedRevealX),
            PixelScale.snapLogical(fixedRevealY)
          )
          local sourcePixelScale = reveal.scale * surface.placement.scale
          local expectedXStart = math.max(0, math.floor(fixedHostX + minX * sourcePixelScale))
          local expectedYStart = math.max(0, math.floor(fixedHostY + minY * sourcePixelScale))
          local expectedXEnd = math.min(size.width - 1, math.ceil(fixedHostX + (maxX + 1) * sourcePixelScale) - 1)
          local expectedYEnd = math.min(size.height - 1, math.ceil(fixedHostY + (maxY + 1) * sourcePixelScale) - 1)
          for y = yStart, yEnd do
            for x = xStart, xEnd do
              local centerX, centerY = x + 0.5, y + 0.5
              local inDialogue = centerX >= dialogueX
                and centerX < dialogueX + dialogueWidth
                and centerY >= dialogueY
                and centerY < dialogueY + dialogueHeight
              if not inDialogue and differs(background, revealOnly, x, y) then
                changedOutsideDialogue = changedOutsideDialogue + 1
                if not differs(revealOnly, final, x, y) then
                  survivedOutsideDialogue = survivedOutsideDialogue + 1
                end
              end
            end
          end
          for y = expectedYStart, expectedYEnd do
            for x = expectedXStart, expectedXEnd do
              if differs(background, revealOnly, x, y) then
                expectedPixels = expectedPixels + 1
                if not differs(revealOnly, final, x, y) then
                  expectedSurvived = expectedSurvived + 1
                end
              end
            end
          end
          Assert.isTrue(
            changedOutsideDialogue > 0,
            size.name .. " host must contain nontransparent Marill pixels outside the dialogue rectangle"
          )
          Assert.equal(
            survivedOutsideDialogue,
            changedOutsideDialogue,
            size.name .. " dialogue composition must preserve Marill pixels outside its rectangle"
          )
          Assert.isTrue(
            expectedPixels > 0,
            size.name .. " Marill pixels must occupy the source-faithful mapped location"
          )
          Assert.equal(
            expectedSurvived,
            expectedPixels,
            size.name .. " dialogue must preserve source-faithful Marill pixels"
          )
        end
        Assert.equal(initialView.revealWidget, "marill")
      end)
    end
  end
  Assert.isTrue(readyCount > 0, "derived-cache capability promised a ready game version")
end

function T.profile_and_shrink_pixels_follow_their_generated_source_bounds(scope)
  local readyCount = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      readyCount = readyCount + 1
      for _, female in ipairs({ false, true }) do
        withProductionState(versionId, function(state)
          reachFinalFullArtHold(state, female)
          local genderId = female and "female" or "male"
          local shrinkId = female and "shrink_female" or "shrink_male"

          state:resize(800, 600)
          local full = state:view()
          Assert.equal(full.primaryWidget, genderId)
          assertSubjectPixelsUseSourceBounds(scope, state, full, genderId, versionId .. " " .. genderId)

          state:resize(390, 844)
          full = state:view()
          assertSubjectPixelsUseSourceBounds(scope, state, full, genderId, versionId .. " resized " .. genderId)

          state:tick(30)
          for frameIndex = 1, 4 do
            local view = state:view()
            Assert.equal(view.primaryWidget, shrinkId)
            Assert.equal(view.visualFrameIndex, frameIndex)
            assertSubjectPixelsUseSourceBounds(
              scope,
              state,
              view,
              shrinkId,
              versionId .. " " .. shrinkId .. " frame " .. frameIndex
            )
            if frameIndex < 4 then
              state:tick(9)
            end
          end
        end)
      end
    end
  end
  Assert.isTrue(readyCount > 0, "derived-cache capability promised a ready game version")
end

function T.dialogue_shares_the_logical_grid_while_the_background_keeps_linear_sampling(scope)
  local readyCount = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      readyCount = readyCount + 1
      withProductionState(versionId, function(state)
        state:resize(640, 480)
        driveToMarillDialogue(state)

        local hostCanvas = scope:own(love.graphics.newCanvas(640, 480))
        local dialogueCanvas
        local dialogueDraw = state.dialogueRenderer.draw
        state.dialogueRenderer.draw = function(renderer, ...)
          dialogueCanvas = love.graphics.getCanvas()
          return dialogueDraw(renderer, ...)
        end
        local ok, failure = xpcall(function()
          love.graphics.setCanvas(hostCanvas)
          love.graphics.clear(0, 0, 0, 0)
          state:draw()
          love.graphics.setCanvas()
        end, debug.traceback)
        state.dialogueRenderer.draw = dialogueDraw
        if not ok then
          error(failure, 0)
        end

        Assert.notNil(dialogueCanvas, versionId .. " dialogue must be drawn during the scene pass")
        Assert.isTrue(dialogueCanvas ~= hostCanvas, versionId .. " dialogue must not be a physical post-pass")
        Assert.equal(dialogueCanvas:getWidth(), 320, versionId .. " logical dialogue width")
        Assert.equal(dialogueCanvas:getHeight(), 240, versionId .. " logical dialogue height")

        local background = assert(state.renderer.images[state.manifest.background.image])
        local minimum, magnification = background:getFilter()
        Assert.equal(minimum, "linear", versionId .. " background minification filter")
        Assert.equal(magnification, "linear", versionId .. " background magnification filter")

        local final = scope:own(hostCanvas:newImageData())
        for y = 0, 478, 2 do
          for x = 0, 638, 2 do
            local r, g, b, a = final:getPixel(x, y)
            local r2, g2, b2, a2 = final:getPixel(x + 1, y)
            local r3, g3, b3, a3 = final:getPixel(x, y + 1)
            local r4, g4, b4, a4 = final:getPixel(x + 1, y + 1)
            Assert.deepEqual(
              { r2, g2, b2, a2 },
              { r, g, b, a },
              versionId .. " final composite must repeat each logical pixel horizontally"
            )
            Assert.deepEqual(
              { r3, g3, b3, a3 },
              { r, g, b, a },
              versionId .. " final composite must repeat each logical pixel vertically"
            )
            Assert.deepEqual(
              { r4, g4, b4, a4 },
              { r, g, b, a },
              versionId .. " final composite must repeat each logical pixel in both axes"
            )
          end
        end
      end)
    end
  end
  Assert.isTrue(readyCount > 0, "derived-cache capability promised a ready game version")
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
