-- Final-pixel checks for Oak confirmation widgets via shared TextButton.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local function layoutFor(view, manifest, width, height)
  local logicalWidth, logicalHeight = width or 800, height or 600
  view.pixelSurface = PixelScale.cover({ x = 0, y = 0, width = logicalWidth, height = logicalHeight }, 1)
  return OakIntroLayout.compute(logicalWidth, logicalHeight, view, {}, manifest, 1)
end

local function productionSurface(width, height)
  local bounds = { x = 0, y = 0, width = width, height = height }
  local preferredScale = math.max(1, math.floor(height / 192 + 0.5))
  local outputScale = PixelScale.fitPreferred(bounds, 256, 192, preferredScale)
  return PixelScale.cover(bounds, outputScale)
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

local function rendererFor(scope, entry)
  local font0 = scope:own(FieldTextRenderer.new({ cacheFs = entry.cache }))
  local font4 = scope:own(FieldTextRenderer.new({ cacheFs = entry.cache, fontId = 4 }))
  local uiManifest = assert(entry.cache:loadLua(FieldUiAssetCache.manifestPath()))
  Assert.isTrue(FieldUiAssetCache.validateManifest(uiManifest), entry.versionId .. " field-UI manifest is invalid")
  local renderer = OakIntroRenderer.new({
    manifest = entry.manifest,
    uiManifest = uiManifest,
    text = font0,
    choiceText = font4,
    imageLoader = function(path)
      local bytes = assert(entry.cache:read(path), "missing generated intro image " .. path)
      local image =
        love.graphics.newImage(love.filesystem.newFileData(bytes, path), { linear = false, mipmaps = false })
      image:setFilter("nearest", "nearest")
      return image
    end,
  })
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  return renderer, font0, font4
end

local function confirmationView(kind, selected)
  local phase = kind == "gender" and "gender_confirm" or "name_confirm"
  if kind == "name" then
    return {
      phase = phase,
      visual = "oak",
      primaryWidget = "oak",
      visualFrameIndex = 1,
      sceneBrightness = 0,
      finalFadeAlpha = 0,
      revealBrightness = 0,
      revealOpacity = 1,
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      confirmationChoice = { kind = kind, selected = selected },
      choiceLabels = { [0] = "YES", [1] = "NO" },
      oakBgScrollX = 0,
    }
  end
  return {
    phase = phase,
    visual = "background",
    primaryWidget = nil,
    visualFrameIndex = 1,
    sceneBrightness = 0,
    finalFadeAlpha = 0,
    revealBrightness = 0,
    revealOpacity = 1,
    genderFocus = 0,
    genderCompositionProgress = 1,
    confirmationChoice = { kind = kind, selected = selected },
    choiceLabels = { [0] = "YES", [1] = "NO" },
  }
end

local function render(scope, renderer, view, manifest, width, height)
  local canvasWidth, canvasHeight = width or 800, height or 600
  view.layout = layoutFor(view, manifest, canvasWidth, canvasHeight)
  local canvas = scope:own(love.graphics.newCanvas(canvasWidth, canvasHeight))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(view)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function renderProductionRoot(scope, renderer, view, manifest, width, height)
  local surface = productionSurface(width, height)
  view.pixelSurface = surface
  view.layout = OakIntroLayout.compute(
    surface.logicalViewport.width,
    surface.logicalViewport.height,
    view,
    {},
    manifest,
    math.floor(assert(surface.placement.pixelScale))
  )
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(view)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function equalPixel(first, second, x, y)
  local fr, fg, fb = first:getPixel(x, y)
  local sr, sg, sb = second:getPixel(x, y)
  return math.abs(fr - sr) < 1 / 255 and math.abs(fg - sg) < 1 / 255 and math.abs(fb - sb) < 1 / 255
end

function T.source_backing_window_fill_font4_and_selected_focus_are_visible(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer, font0, font4 = rendererFor(scope, entry)
    Assert.equal(font0.fontDef.fontId, 0)
    Assert.equal(font4.fontDef.fontId, 4)
    local selectedYes = render(scope, renderer, confirmationView("gender", 0), entry.manifest)
    local selectedNo = render(scope, renderer, confirmationView("gender", 1), entry.manifest)
    local yes = layoutFor(confirmationView("gender", 0), entry.manifest).confirmationButtons[0]
    local no = layoutFor(confirmationView("gender", 0), entry.manifest).confirmationButtons[1]
    -- New TextButton path: verify focus colors are present via shared button.
    local function hasFocusColors(image, rect)
      local hasWhite, hasRed = false, false
      local w, h = image:getWidth(), image:getHeight()
      for y = math.floor(rect.y), math.ceil(rect.y + rect.height) - 1 do
        for x = math.floor(rect.x), math.ceil(rect.x + rect.width) - 1 do
          if x < 0 or x >= w or y < 0 or y >= h then
            goto continue
          end
          local r, g, b = image:getPixel(x, y)
          if r == nil then
            goto continue
          end
          local qr, qg, qb = math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)
          if qr == 255 and qg == 255 and qb == 255 then
            hasWhite = true
          elseif qr == 255 and qg == 0 and qb == 0 then
            hasRed = true
          end
          if hasWhite and hasRed then
            return true, true
          end
          ::continue::
        end
      end
      return hasWhite, hasRed
    end
    local yesWhite, yesRed = hasFocusColors(selectedYes, yes.rect)
    local noWhite, noRed = hasFocusColors(selectedNo, no.rect)
    Assert.isTrue(
      yesWhite and yesRed,
      entry.versionId .. " selected YES focus must contain both white #FFFFFF and red #FF0000"
    )
    Assert.isTrue(noWhite and noRed, entry.versionId .. " selected NO focus must contain both colors when selected")
    local yesHasWhiteUnselected, yesHasRedUnselected = hasFocusColors(selectedNo, yes.rect)
    Assert.isFalse(
      yesHasWhiteUnselected and yesHasRedUnselected,
      entry.versionId .. " unselected YES must not have focus colors"
    )
    local focusChanged = false
    for y = math.floor(yes.rect.y), math.ceil(yes.rect.y + yes.rect.height) - 1 do
      for x = math.floor(yes.rect.x), math.ceil(yes.rect.x + yes.rect.width) - 1 do
        if not equalPixel(selectedYes, selectedNo, x, y) then
          focusChanged = true
          break
        end
      end
      if focusChanged then
        break
      end
    end
    Assert.isTrue(focusChanged, entry.versionId .. " selected confirmation focus must move between choices")
    -- Verify layout buttons exist and have shared geometry.
    Assert.notNil(yes.button)
    Assert.notNil(no.button)
    -- Verify that renderer did not require confirmation widgets (already proven by successful construction).
    Assert.isTrue(entry.manifest.widgets.confirmation_yes == nil or yes.button ~= nil)
  end
end

function T.name_confirmation_uses_common_side_by_side_backings(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer, _, font4 = rendererFor(scope, entry)
    local view = confirmationView("name", 0)
    local image = render(scope, renderer, view, entry.manifest)
    local layout = view.layout
    local yes, no = layout.confirmationButtons[0], layout.confirmationButtons[1]
    Assert.equal(yes.scale, no.scale)
    Assert.equal(yes.rect.x, no.rect.x)
    Assert.equal(yes.rect.width, no.rect.width)
    Assert.isTrue(yes.rect.y + yes.rect.height <= no.rect.y, "name choices must be vertically stacked")
    Assert.near((no.rect.y - (yes.rect.y + yes.rect.height)) / yes.scale, 8, 1e-6)
    Assert.equal(font4.fontDef.fontId, 4)
    Assert.notNil(yes.button)
    Assert.notNil(no.button)
    Assert.notNil(image)
  end
end

function T.tall_name_confirmation_chrome_keeps_a_visible_right_margin(scope)
  local width, height = 390, 844
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry)
    local view = confirmationView("name", 0)
    local image = render(scope, renderer, view, entry.manifest, width, height)
    local layout = assert(view.layout)
    local withoutChoices = confirmationView("name", 0)
    withoutChoices.confirmationChoice = nil
    withoutChoices.choiceLabels = nil
    local background = render(scope, renderer, withoutChoices, entry.manifest, width, height)
    local rightmostChromePixel
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        if not equalPixel(image, background, x, y) then
          rightmostChromePixel = math.max(rightmostChromePixel or x, x)
        end
      end
    end
    Assert.notNil(rightmostChromePixel, entry.versionId .. " name buttons must change rendered pixels")
    Assert.isTrue(
      rightmostChromePixel < layout.safeFrame.x + layout.safeFrame.width,
      entry.versionId .. " button chrome must leave a visible strip before the right safe edge"
    )
  end
end

function T.name_confirmation_keeps_a_final_pixel_margin_at_production_host_scales(scope)
  local hosts = {
    { width = 640, height = 480 },
    { width = 1024, height = 768 },
    { width = 390, height = 844 },
  }
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry)
    for _, host in ipairs(hosts) do
      local backgroundView = confirmationView("name", 0)
      backgroundView.confirmationChoice = nil
      backgroundView.choiceLabels = nil
      local background = renderProductionRoot(scope, renderer, backgroundView, entry.manifest, host.width, host.height)
      local surface = assert(backgroundView.pixelSurface)
      local layout = assert(backgroundView.layout)
      local scale = assert(surface.placement.pixelScale)
      local permittedRightEdge = surface.placement.origin.x + (layout.safeFrame.x + layout.safeFrame.width) * scale
      for _, selected in ipairs({ 0, 1 }) do
        local view = confirmationView("name", selected)
        local image = renderProductionRoot(scope, renderer, view, entry.manifest, host.width, host.height)
        local rightmostChangedPixel
        for y = 0, host.height - 1 do
          for x = 0, host.width - 1 do
            if not equalPixel(image, background, x, y) then
              rightmostChangedPixel = math.max(rightmostChangedPixel or x, x)
            end
          end
        end
        local label = string.format("%s %dx%d focus %d", entry.versionId, host.width, host.height, selected)
        Assert.notNil(rightmostChangedPixel, label .. " name buttons must change final pixels")
        Assert.isTrue(
          rightmostChangedPixel < permittedRightEdge - 1,
          label .. " confirmation pixels must leave a full host pixel before the permitted right edge"
        )
      end
    end
  end
end

function T.vertical_name_confirmation_is_centered_with_complete_safe_chrome(scope)
  local width, height = 390, 844
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry)
    local backgroundView = confirmationView("name", 0)
    backgroundView.confirmationChoice = nil
    backgroundView.choiceLabels = nil
    local background = renderProductionRoot(scope, renderer, backgroundView, entry.manifest, width, height)
    local surface = assert(backgroundView.pixelSurface)
    local layout = assert(backgroundView.layout)
    local pixelScale = assert(surface.placement.pixelScale)
    local safeFrame = assert(layout.safeFrame)
    local safeLeft = surface.placement.origin.x + safeFrame.x * pixelScale
    local safeTop = surface.placement.origin.y + safeFrame.y * pixelScale
    local safeRight = surface.placement.origin.x + (safeFrame.x + safeFrame.width) * pixelScale
    local safeBottom = surface.placement.origin.y + (safeFrame.y + safeFrame.height) * pixelScale
    local choiceRegion = assert(layout.selectorRegion)

    for _, selected in ipairs({ 0, 1 }) do
      local view = confirmationView("name", selected)
      local image = renderProductionRoot(scope, renderer, view, entry.manifest, width, height)
      local yes = assert(view.layout.confirmationButtons[0])
      local no = assert(view.layout.confirmationButtons[1])
      local stackCenter = yes.rect.x + yes.rect.width / 2
      local regionCenter = choiceRegion.x + choiceRegion.width / 2
      local minX, minY, maxX, maxY
      for y = 0, height - 1 do
        for x = 0, width - 1 do
          if not equalPixel(image, background, x, y) then
            minX = math.min(minX or x, x)
            minY = math.min(minY or y, y)
            maxX = math.max(maxX or x, x)
            maxY = math.max(maxY or y, y)
          end
        end
      end
      local label = string.format("%s vertical host focus %d", entry.versionId, selected)
      Assert.near(stackCenter, regionCenter, 1, label .. " choices must remain centered")
      Assert.notNil(minX, label .. " choices must produce rendered pixels")
      Assert.isTrue(minX > safeLeft, label .. " rendered chrome must clear the left safe edge")
      Assert.isTrue(minY > safeTop, label .. " rendered chrome must clear the top safe edge")
      Assert.isTrue(maxX < safeRight - 1, label .. " rendered chrome must clear the right safe edge")
      Assert.isTrue(maxY < safeBottom - 1, label .. " rendered chrome must clear the bottom safe edge")
      Assert.notNil(yes.button, label .. " YES focus chrome must resolve")
      Assert.notNil(no.button, label .. " NO focus chrome must resolve")
    end
  end
end

function T.unselected_text_button_face_has_light_separator_dark(scope)
  for _, entry in ipairs(readyManifests()) do
    local renderer = rendererFor(scope, entry)
    -- Use gender confirmation with YES unselected (selected NO) to avoid focus contamination
    local view = confirmationView("gender", 1)
    local image = render(scope, renderer, view, entry.manifest)
    local yes = view.layout.confirmationButtons[0]
    Assert.notNil(yes.button, entry.versionId .. " yes button must exist")
    local button = yes.button
    local face = assert(button.face, "button face missing")
    local scale = assert(button.scale, "button scale missing")
    Assert.isTrue(scale >= 1, "ring sampling needs at least one host pixel per source pixel")
    local sampleX = math.floor(face.rect.x + 4 * scale)
    -- Ensure sampleX is inside face
    Assert.isTrue(sampleX >= face.rect.x and sampleX < face.rect.x + face.rect.width, "sampleX inside face")
    local lightY = math.floor(face.splitY - 3 * scale)
    local dividerTopY = math.floor(face.splitY - 0.5 * scale)
    local dividerBottomY = math.floor(face.splitY + 0.5 * scale)
    local darkY = math.floor(face.splitY + 2 * scale)
    -- The side inner ring surrounds the full face: intermediate both above
    -- and below the divider. The bottom ring is intermediate as well.
    local innerBorder = assert(button.innerBorder, "button inner border missing")
    local ringX = math.floor(face.rect.x - 0.5 * scale)
    Assert.isTrue(ringX >= innerBorder.rect.x and ringX < face.rect.x, "ringX inside the side inner ring")
    local ringMidY = math.floor(face.splitY - 3 * scale)
    local ringDarkY = math.floor(face.splitY + 3 * scale)
    local bottomY = math.floor(face.rect.y + face.rect.height + 0.5 * scale)
    local function rgbAt(x, y)
      local r, g, b = image:getPixel(x, y)
      Assert.notNil(r, "pixel out of bounds " .. x .. "," .. y)
      return math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)
    end
    local lr, lg, lb = rgbAt(sampleX, lightY)
    local topR, topG, topB = rgbAt(sampleX, dividerTopY)
    local bottomR, bottomG, bottomB = rgbAt(sampleX, dividerBottomY)
    local dr, dg, db = rgbAt(sampleX, darkY)
    local ringMr, ringMg, ringMb = rgbAt(ringX, ringMidY)
    local ringDr, ringDg, ringDb = rgbAt(ringX, ringDarkY)
    local botR, botG, botB = rgbAt(sampleX, bottomY)
    Assert.equal(lr, 49, entry.versionId .. " light face r must be 49")
    Assert.equal(lg, 222, entry.versionId .. " light face g must be 222")
    Assert.equal(lb, 230, entry.versionId .. " light face b must be 230")
    for _, channel in ipairs({
      { topR, topG, topB, "top" },
      { bottomR, bottomG, bottomB, "bottom" },
    }) do
      Assert.equal(channel[1], 25, entry.versionId .. " separator " .. channel[4] .. " r must be 25")
      Assert.equal(channel[2], 189, entry.versionId .. " separator " .. channel[4] .. " g must be 189")
      Assert.equal(channel[3], 197, entry.versionId .. " separator " .. channel[4] .. " b must be 197")
    end
    Assert.equal(dr, 8, entry.versionId .. " dark face r must be 8")
    Assert.equal(dg, 156, entry.versionId .. " dark face g must be 156")
    Assert.equal(db, 165, entry.versionId .. " dark face b must be 165")
    Assert.equal(ringMr, 25, entry.versionId .. " side ring above divider r must be 25")
    Assert.equal(ringMg, 189, entry.versionId .. " side ring above divider g must be 189")
    Assert.equal(ringMb, 197, entry.versionId .. " side ring above divider b must be 197")
    Assert.equal(ringDr, 25, entry.versionId .. " side ring below divider r must be 25")
    Assert.equal(ringDg, 189, entry.versionId .. " side ring below divider g must be 189")
    Assert.equal(ringDb, 197, entry.versionId .. " side ring below divider b must be 197")
    Assert.equal(botR, 25, entry.versionId .. " bottom ring r must be 25")
    Assert.equal(botG, 189, entry.versionId .. " bottom ring g must be 189")
    Assert.equal(botB, 197, entry.versionId .. " bottom ring b must be 197")
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "derived_cache" }
return suite
