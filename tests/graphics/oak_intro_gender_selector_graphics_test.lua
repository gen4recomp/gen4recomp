-- Final-pixel checks for the host-rendered gender controls and source portraits.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local function textRenderer()
  return {
    drawText = function() end,
    textWidth = function(_, value)
      return #value * 8
    end,
  }
end

local function choiceTextRenderer()
  local renderer = textRenderer()
  renderer.fontDef = { lineHeight = 16, palette = {} }
  for slot = 1, 16 do
    renderer.fontDef.palette[slot] = { r = 1, g = 1, b = 1 }
  end
  renderer.drawTextWithPalette = function() end
  return renderer
end

local function readyManifests()
  local result = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      local manifest = assert(cache:loadLua(IntroAssetCache.manifestPath()))
      Assert.isTrue(IntroAssetCache.validateManifest(manifest), versionId .. " intro manifest is invalid")
      result[#result + 1] = { cache = cache, manifest = manifest, versionId = versionId }
    end
  end
  Assert.isTrue(#result > 0, "derived-cache capability promised a ready game version")
  return result
end

local function newImage(cache, path)
  local bytes = assert(cache:read(path), "missing generated image " .. path)
  local image = love.graphics.newImage(love.filesystem.newFileData(bytes, path), { linear = false, mipmaps = false })
  image:setFilter("nearest", "nearest")
  return image
end

local function rendererFor(scope, cache, manifest)
  local uiManifest = assert(cache:loadLua(FieldUiAssetCache.manifestPath()))
  local renderer = OakIntroRenderer.new({
    manifest = manifest,
    uiManifest = uiManifest,
    imageLoader = function(path)
      return newImage(cache, path)
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  return renderer
end

local function selectorView(manifest, width, height, focus, delta)
  local view = {
    phase = "gender_select",
    visual = "background",
    visualFrameIndex = 1,
    primaryWidget = nil,
    revealWidget = nil,
    revealFrameIndex = 1,
    revealBrightness = 0,
    revealOpacity = 1,
    sceneBrightness = 0,
    finalFadeAlpha = 0,
    message = nil,
    messageKey = nil,
    name = "",
    genderFocus = focus or 0,
    genderCompositionProgress = 1,
    focusBlinkDelta = delta or 0,
  }
  view.pixelSurface = PixelScale.cover({ x = 0, y = 0, width = width, height = height }, 1)
  view.layout = OakIntroLayout.compute(width, height, view, {}, manifest, 1)
  return view
end

local function render(scope, renderer, view)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  renderer:draw(view)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function quantize(value)
  return math.floor(value * 255 + 0.5)
end

function T.card_interiors_use_opaque_source_tone_and_pulse(scope)
  local function clamp(value)
    return math.max(0, math.min(1, value))
  end
  local function expectedTone(manifest, delta)
    local tone = assert(manifest.genderSelector and manifest.genderSelector.defaultTone)
    return {
      r = quantize(clamp(tone.r / 255 + delta / 31)),
      g = quantize(clamp(tone.g / 255 + delta / 31)),
      b = quantize(clamp(tone.b / 255 + delta / 31)),
    }
  end
  local function interiorSample(card, portrait)
    for y = math.floor(card.y + 6), math.ceil(card.y + card.height - 6) - 1 do
      for x = math.floor(card.x + 6), math.ceil(card.x + card.width - 6) - 1 do
        if
          x < portrait.x
          or x >= portrait.x + portrait.width
          or y < portrait.y
          or y >= portrait.y + portrait.height
        then
          return x, y
        end
      end
    end
    return math.floor(card.x + card.width / 2), math.floor(card.y + card.height / 2)
  end
  for _, entry in ipairs(readyManifests()) do
    local selector = assert(entry.manifest.genderSelector)
    Assert.isNil(selector.unselectedRim, "selector rim fields must not survive the compact contract")
    Assert.isNil(selector.selectedRim, "selector rim fields must not survive the compact contract")
    for _, genderName in ipairs({ "male", "female" }) do
      local button = assert(selector.buttons[genderName])
      Assert.notNil(button.bounds)
      Assert.isNil(button.baseImage, genderName .. " card publishes no base image")
      Assert.isNil(button.fillMaskImage, genderName .. " card publishes no fill mask")
      Assert.isNil(button.rimMaskImage, genderName .. " card publishes no rim mask")
    end
    Assert.notNil(entry.manifest.widgets.naming_male, "naming subject is retained")
    Assert.notNil(entry.manifest.widgets.naming_female, "naming subject is retained")
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local focusedZero = selectorView(entry.manifest, 256, 192, 0, 0)
    local focusedPulse = selectorView(entry.manifest, 256, 192, 0, 8)
    local focusedImageZero = render(scope, renderer, focusedZero)
    local focusedImagePulse = render(scope, renderer, focusedPulse)
    local backgroundView = selectorView(entry.manifest, 256, 192)
    backgroundView.phase = "background"
    backgroundView.layout = OakIntroLayout.compute(256, 192, backgroundView, {}, entry.manifest, 1)
    local backgroundImage = render(scope, renderer, backgroundView)
    for gender = 0, 1 do
      local cardEntry = focusedZero.layout.genderButtons[gender]
      local card, portrait = cardEntry.rect, cardEntry.portraitRect
      local sx, sy = interiorSample(card, portrait)
      local ar, ag, ab = focusedImageZero:getPixel(sx, sy)
      local br, bg, bb = backgroundImage:getPixel(sx, sy)
      local toneZero = expectedTone(entry.manifest, 0)
      -- Unfocused card should be default tone, not background
      if gender == 1 then
        Assert.equal(quantize(ar), toneZero.r, entry.versionId .. " unfocused card interior red")
        Assert.equal(quantize(ag), toneZero.g, entry.versionId .. " unfocused card interior green")
        Assert.equal(quantize(ab), toneZero.b, entry.versionId .. " unfocused card interior blue")
      end
      Assert.isTrue(
        quantize(ar) ~= quantize(br) or quantize(ag) ~= quantize(bg) or quantize(ab) ~= quantize(bb),
        entry.versionId .. " card interior must be opaque tone, not background"
      )
    end
    -- Focused pulse: male card interior must change with delta, female stays
    local maleCard = focusedZero.layout.genderButtons[0]
    local femaleCard = focusedZero.layout.genderButtons[1]
    local mx, my = interiorSample(maleCard.rect, maleCard.portraitRect)
    local fx, fy = interiorSample(femaleCard.rect, femaleCard.portraitRect)
    local mr0, mg0, mb0 = focusedImageZero:getPixel(mx, my)
    local mr1, mg1, mb1 = focusedImagePulse:getPixel(mx, my)
    local fr0, fg0, fb0 = focusedImageZero:getPixel(fx, fy)
    local fr1, fg1, fb1 = focusedImagePulse:getPixel(fx, fy)
    local expectedPulse = expectedTone(entry.manifest, 8)
    local expectedZero = expectedTone(entry.manifest, 0)
    Assert.isTrue(
      quantize(mr0) ~= quantize(mr1) or quantize(mg0) ~= quantize(mg1) or quantize(mb0) ~= quantize(mb1),
      entry.versionId .. " focused card must pulse with blink delta"
    )
    Assert.near(quantize(mr1), expectedPulse.r, 1, entry.versionId .. " pulsed focused red")
    Assert.near(quantize(mg1), expectedPulse.g, 1, entry.versionId .. " pulsed focused green")
    Assert.near(quantize(mb1), expectedPulse.b, 1, entry.versionId .. " pulsed focused blue")
    Assert.near(quantize(mr0), expectedZero.r, 1, entry.versionId .. " focused zero red")
    Assert.equal(quantize(fr0), quantize(fr1), entry.versionId .. " unfocused card must not pulse")
    Assert.equal(quantize(fg0), quantize(fg1), entry.versionId .. " unfocused card must not pulse green")
    Assert.equal(quantize(fb0), quantize(fb1), entry.versionId .. " unfocused card must not pulse blue")
    -- Portraits remain untinted across focus changes (center is opaque; transparent border would show fill)
    for gender = 0, 1 do
      local portrait = focusedZero.layout.genderButtons[gender].portraitRect
      local cx = math.floor(portrait.x + portrait.width / 2)
      local cy = math.floor(portrait.y + portrait.height / 2)
      for dy = -2, 2 do
        for dx = -2, 2 do
          local x, y = cx + dx, cy + dy
          local fr, fg, fb = focusedImageZero:getPixel(x, y)
          local ur, ug, ub = focusedImagePulse:getPixel(x, y)
          Assert.equal(quantize(fr), quantize(ur), entry.versionId .. " portrait must not recolor with pulse red")
          Assert.equal(quantize(fg), quantize(ug), entry.versionId .. " portrait must not recolor with pulse green")
          Assert.equal(quantize(fb), quantize(ub), entry.versionId .. " portrait must not recolor with pulse blue")
        end
      end
    end
  end
end

function T.selected_frame_changes_without_recoloring_portraits(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local focusedView = selectorView(entry.manifest, 256, 192, 0, 0)
    local unfocusedView = selectorView(entry.manifest, 256, 192, 1, 0)
    local focused = render(scope, renderer, focusedView)
    local unfocused = render(scope, renderer, unfocusedView)
    local card = focusedView.layout.genderButtons[0].rect
    local changed = false
    local yStart = math.max(0, math.floor(card.y))
    local yEnd = math.min(focused:getHeight() - 1, math.ceil(card.y + card.height) - 1)
    local xStart = math.max(0, math.floor(card.x))
    local xEnd = math.min(focused:getWidth() - 1, math.ceil(card.x + card.width) - 1)
    for y = yStart, yEnd do
      for x = xStart, xEnd do
        local fr, fg, fb = focused:getPixel(x, y)
        local ur, ug, ub = unfocused:getPixel(x, y)
        if quantize(fr) ~= quantize(ur) or quantize(fg) ~= quantize(ug) or quantize(fb) ~= quantize(ub) then
          changed = true
          break
        end
      end
      if changed then
        break
      end
    end
    Assert.isTrue(changed, "focused card rim must differ from its unfocused rendering")
    for gender = 0, 1 do
      local portrait = focusedView.layout.genderButtons[gender].portraitRect
      local portraitYStart = math.max(0, math.floor(portrait.y))
      local portraitYEnd = math.min(focused:getHeight() - 1, math.ceil(portrait.y + portrait.height) - 1)
      local portraitXStart = math.max(0, math.floor(portrait.x))
      local portraitXEnd = math.min(focused:getWidth() - 1, math.ceil(portrait.x + portrait.width) - 1)
      for y = portraitYStart, portraitYEnd do
        for x = portraitXStart, portraitXEnd do
          local fr, fg, fb = focused:getPixel(x, y)
          local ur, ug, ub = unfocused:getPixel(x, y)
          Assert.equal(quantize(fr), quantize(ur), "focus must not recolor portrait red channel")
          Assert.equal(quantize(fg), quantize(ug), "focus must not recolor portrait green channel")
          Assert.equal(quantize(fb), quantize(ub), "focus must not recolor portrait blue channel")
        end
      end
    end
  end
end

function T.both_source_gender_portraits_remain_visible_inside_cards(scope)
  for _, entry in ipairs(readyManifests()) do
    local view = selectorView(entry.manifest, 256, 192)
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local actual = render(scope, renderer, view)
    local backgroundView = selectorView(entry.manifest, 256, 192)
    backgroundView.phase = "background"
    backgroundView.layout = OakIntroLayout.compute(256, 192, backgroundView, {}, entry.manifest, 1)
    local background = render(scope, renderer, backgroundView)
    for gender = 0, 1 do
      local entryLayout = view.layout.genderButtons[gender]
      local portrait = entryLayout.portraitRect
      local card = entryLayout.rect
      Assert.isTrue(portrait.x >= card.x and portrait.y >= card.y)
      Assert.isTrue(portrait.x + portrait.width <= card.x + card.width)
      Assert.isTrue(portrait.y + portrait.height <= card.y + card.height)
      local visible = false
      for y = math.floor(portrait.y), math.ceil(portrait.y + portrait.height) - 1 do
        for x = math.floor(portrait.x), math.ceil(portrait.x + portrait.width) - 1 do
          local actualRed, actualGreen, actualBlue = actual:getPixel(x, y)
          local backgroundRed, backgroundGreen, backgroundBlue = background:getPixel(x, y)
          if
            quantize(actualRed) ~= quantize(backgroundRed)
            or quantize(actualGreen) ~= quantize(backgroundGreen)
            or quantize(actualBlue) ~= quantize(backgroundBlue)
          then
            visible = true
            break
          end
        end
        if visible then
          break
        end
      end
      Assert.isTrue(visible, entry.versionId .. " portrait is not visible")
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "derived_cache" }
suite.metadata.derivedAssets = { "bootstrap" }
return suite
