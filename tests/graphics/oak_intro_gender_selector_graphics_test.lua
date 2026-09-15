-- Final-pixel checks for the host-rendered gender controls and source portraits.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
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

local function newImageData(cache, path)
  local bytes = assert(cache:read(path), "missing generated image " .. path)
  return love.image.newImageData(love.filesystem.newFileData(bytes, path))
end

local function rendererFor(scope, cache, manifest)
  local renderer = OakIntroRenderer.new({
    manifest = manifest,
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

function T.card_selection_pulses_without_recoloring_portraits(scope)
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
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local focusedZero = selectorView(entry.manifest, 256, 192, 0, 0)
    local focusedPulse = selectorView(entry.manifest, 256, 192, 0, 8)
    local focusedImageZero = render(scope, renderer, focusedZero)
    local focusedImagePulse = render(scope, renderer, focusedPulse)
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
      local yStart = math.max(0, math.floor(portrait.y))
      local yEnd = math.min(focused:getHeight() - 1, math.ceil(portrait.y + portrait.height) - 1)
      local xStart = math.max(0, math.floor(portrait.x))
      local xEnd = math.min(focused:getWidth() - 1, math.ceil(portrait.x + portrait.width) - 1)
      for y = yStart, yEnd do
        for x = xStart, xEnd do
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

function T.source_selector_roles_are_rendered_with_semantic_colors(scope)
  for _, entry in ipairs(readyManifests()) do
    local selector = assert(entry.manifest.genderSelector)
    local images = {}
    for _, genderName in ipairs({ "male", "female" }) do
      local button = assert(selector.buttons[genderName])
      images[genderName] = {
        base = newImageData(entry.cache, assert(button.baseImage)),
        fill = newImageData(entry.cache, assert(button.fillMaskImage)),
        rim = newImageData(entry.cache, assert(button.rimMaskImage)),
      }
      scope:own(images[genderName].base)
      scope:own(images[genderName].fill)
      scope:own(images[genderName].rim)
    end

    local renderer = rendererFor(scope, entry.cache, entry.manifest)
    local zero = render(scope, renderer, selectorView(entry.manifest, 256, 192, 0, 0))
    local pulse = render(scope, renderer, selectorView(entry.manifest, 256, 192, 0, 8))
    local femaleFocus = render(scope, renderer, selectorView(entry.manifest, 256, 192, 1, 0))
    local defaultTone = assert(selector.defaultTone)
    local unselectedRim = assert(selector.unselectedRim)
    local selectedRim = assert(selector.selectedRim)

    local function roleSample(genderName, role, output)
      local mask = images[genderName][role]
      local data = mask
      local gender = genderName == "male" and 0 or 1
      local card = assert(selectorView(entry.manifest, 256, 192, 0, 0).layout.genderButtons[gender]).rect
      local x, mappedX, mappedY
      for row = 0, data:getHeight() - 1 do
        for column = 0, data:getWidth() - 1 do
          local _, _, _, alpha = data:getPixel(column, row)
          local outputX = PixelScale.snapLogical(card.x) + column
          local outputY = PixelScale.snapLogical(card.y) + row
          if
            alpha >= 0.99
            and outputX >= 0
            and outputX < output:getWidth()
            and outputY >= 0
            and outputY < output:getHeight()
          then
            x, mappedX, mappedY = column, outputX, outputY
            break
          end
        end
        if x ~= nil then
          break
        end
      end
      Assert.notNil(x, "generated selector role mask has no opaque pixels")
      local bounds = assert(selector.buttons[genderName].bounds)
      Assert.equal(card.width, bounds.width, "generated selector card width must match its source bounds")
      Assert.equal(card.height, bounds.height, "generated selector card height must match its source bounds")
      return output:getPixel(mappedX, mappedY)
    end

    local mr, mg, mb = roleSample("male", "fill", zero)
    Assert.equal(quantize(mr), defaultTone.r, entry.versionId .. " male fill red")
    Assert.equal(quantize(mg), defaultTone.g, entry.versionId .. " male fill green")
    Assert.equal(quantize(mb), defaultTone.b, entry.versionId .. " male fill blue")
    local fr, fg, fb = roleSample("female", "fill", zero)
    Assert.equal(quantize(fr), defaultTone.r, entry.versionId .. " female fill red")
    Assert.equal(quantize(fg), defaultTone.g, entry.versionId .. " female fill green")
    Assert.equal(quantize(fb), defaultTone.b, entry.versionId .. " female fill blue")

    local ur, ug, ub = roleSample("female", "rim", zero)
    Assert.equal(quantize(ur), unselectedRim.r, entry.versionId .. " unselected rim red")
    Assert.equal(quantize(ug), unselectedRim.g, entry.versionId .. " unselected rim green")
    Assert.equal(quantize(ub), unselectedRim.b, entry.versionId .. " unselected rim blue")
    local sr, sg, sb = roleSample("male", "rim", zero)
    Assert.equal(quantize(sr), selectedRim.r, entry.versionId .. " selected rim red")
    Assert.equal(quantize(sg), selectedRim.g, entry.versionId .. " selected rim green")
    Assert.equal(quantize(sb), selectedRim.b, entry.versionId .. " selected rim blue")

    local pulseR, pulseG, pulseB = roleSample("male", "fill", pulse)
    Assert.isTrue(
      quantize(pulseR) ~= quantize(mr) or quantize(pulseG) ~= quantize(mg) or quantize(pulseB) ~= quantize(mb),
      entry.versionId .. " selected fill must pulse"
    )

    local femaleR, femaleG, femaleB = roleSample("female", "fill", femaleFocus)
    Assert.equal(quantize(femaleR), defaultTone.r, entry.versionId .. " female focused fill red")
    Assert.equal(quantize(femaleG), defaultTone.g, entry.versionId .. " female focused fill green")
    Assert.equal(quantize(femaleB), defaultTone.b, entry.versionId .. " female focused fill blue")

    local baseZero = roleSample("male", "base", zero)
    local baseFemaleFocus = roleSample("male", "base", femaleFocus)
    Assert.equal(quantize(baseZero), quantize(baseFemaleFocus), entry.versionId .. " base red must be immutable")
    local portrait = selectorView(entry.manifest, 256, 192, 0, 0).layout.genderButtons[0].portraitRect
    for y = math.floor(portrait.y), math.ceil(portrait.y + portrait.height) - 1 do
      for x = math.floor(portrait.x), math.ceil(portrait.x + portrait.width) - 1 do
        local ar, ag, ab = zero:getPixel(x, y)
        local br, bg, bb = femaleFocus:getPixel(x, y)
        Assert.equal(quantize(ar), quantize(br), entry.versionId .. " portrait red must remain unchanged")
        Assert.equal(quantize(ag), quantize(bg), entry.versionId .. " portrait green must remain unchanged")
        Assert.equal(quantize(ab), quantize(bb), entry.versionId .. " portrait blue must remain unchanged")
      end
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "derived_cache" }
return suite
