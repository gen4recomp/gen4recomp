-- Responsive Oak/profile renderer. It owns images and atlas crops for the
-- intro manifest; semantic timing and transition decisions remain in the
-- engine controller.

local TextButton = require("libs.ui.src.TextButton")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")
local HgssCardButton = require("libs.hgss.src.ui.HgssCardButton")
local PixelScale = require("libs.ui.src.PixelScale")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")

---@class OakIntroRenderer
---@field graphics table<string, unknown>
---@field text FieldTextRenderer
---@field choiceText FieldTextRenderer
---@field assets table<string, unknown>
---@field bindings table<string, unknown>
---@field manifest table<string, unknown>
---@field logicalCanvas table<string, unknown>?
---@field logicalCanvasWidth integer?
---@field logicalCanvasHeight integer?
---@field draw fun(self: OakIntroRenderer, view: table<string, unknown>, overlay: (fun())?)
---@field dispose fun(self: OakIntroRenderer)
local REQUIRED_ASSETS = {
  "oak",
  "marill",
  "marill_appear",
  "male",
  "female",
  "shrink_male",
  "shrink_female",
  "ball_open",
  "gender_male",
  "gender_female",
  "naming_male",
  "naming_female",
}

local OakIntroRenderer = {}
OakIntroRenderer.__index = OakIntroRenderer

local REVEAL_SHADER = [[
  uniform number brightness;
  vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 sampled = Texel(texture, texture_coords) * color;
    sampled.rgb = mix(sampled.rgb, vec3(1.0), brightness);
    return sampled;
  }
]]

local function cardTone(manifest)
  local selector = assert(manifest.genderSelector, "Oak renderer requires a generated gender selector")
  return assert(selector.defaultTone, "Oak renderer requires a generated gender selector tone")
end

local function paletteColor(definition, slot)
  local color = assert(definition.palette and definition.palette[slot], "Oak font palette slot is missing: " .. slot)
  local r, g, b =
    assert(tonumber(color.r or color[1])), assert(tonumber(color.g or color[2])), assert(tonumber(color.b or color[3]))
  if r > 1 or g > 1 or b > 1 then
    r, g, b = r / 255, g / 255, b / 255
  end
  return { r = r * 255, g = g * 255, b = b * 255 }
end

local function defaultImageLoader(path)
  return love.graphics.newImage(path, { linear = false, mipmaps = false })
end

local function releaseAll(resources)
  for index = #resources, 1, -1 do
    if resources[index].release then
      pcall(resources[index].release, resources[index])
    end
  end
end

-- Generated intro widgets share one image acquisition and release owner.
local function loadResources(manifest, graphics, imageLoader)
  local bindings, acquired = {}, {}
  local imagesByPath = {}
  local assets = {}
  local ok, failure = pcall(function()
    for assetId, asset in pairs(manifest.widgets) do
      assets[assetId] = asset
    end
    assets.background = {
      image = manifest.background.image,
      width = manifest.background.width,
      height = manifest.background.height,
      sampling = manifest.background.sampling,
      frames = {
        {
          x = 0,
          y = 0,
          image = manifest.background.image,
          width = manifest.background.width,
          height = manifest.background.height,
          duration = 1,
        },
      },
    }
    for assetId, asset in pairs(assets) do
      bindings[assetId] = {}
      for frameIndex, frame in ipairs(asset.frames) do
        local image = imagesByPath[frame.image]
        if image == nil then
          image = imageLoader(frame.image)
          assert(image ~= nil, "intro image loader returned no image for " .. assetId)
          imagesByPath[frame.image] = image
          acquired[#acquired + 1] = image
          if image.setFilter then
            assert(asset.sampling == "linear" or asset.sampling == "nearest", "intro asset sampling is invalid")
            image:setFilter(asset.sampling, asset.sampling)
          end
        end
        local quad =
          graphics.newQuad(frame.x or 0, frame.y or 0, frame.width, frame.height, image:getWidth(), image:getHeight())
        bindings[assetId][frameIndex] = { image = image, quad = quad }
      end
    end
  end)
  if not ok then
    releaseAll(acquired)
    error(failure, 0)
  end
  return imagesByPath, bindings, assets
end

local function drawAsset(self, assetId, frameIndex, region, opacity, brightness, tint)
  assert(self.assets[assetId] ~= nil, "intro asset is missing: " .. assetId)
  local binding = self.bindings[assetId] and self.bindings[assetId][frameIndex or 1]
  assert(binding ~= nil, "intro frame is missing: " .. assetId)
  local scale = assert(region.scale, "pixel-authored Oak region scale is required")
  assert(scale > 0 and scale == math.floor(scale), "pixel-authored Oak region scale must be a positive integer")
  local x = PixelScale.snapLogical(region.x)
  local y = PixelScale.snapLogical(region.y)
  if brightness ~= nil then
    assert(brightness >= 0 and brightness <= 1, "intro reveal brightness is out of range")
  end
  if opacity ~= nil then
    assert(opacity >= 0 and opacity <= 1, "intro reveal opacity is out of range")
  end
  if brightness and brightness > 0 then
    self.revealShader:send("brightness", brightness)
    self.graphics.setShader(self.revealShader)
  end
  local tr, tg, tb = 1, 1, 1
  if tint ~= nil then
    tr, tg, tb = tint.r or tint[1], tint.g or tint[2], tint.b or tint[3]
  end
  self.graphics.setColor(tr, tg, tb, opacity or 1)
  self.graphics.draw(binding.image, binding.quad, x, y, 0, scale, scale)
  if brightness and brightness > 0 then
    self.graphics.setShader(nil)
  end
end

---@param options table<string, unknown>
---@return OakIntroRenderer
function OakIntroRenderer.new(options)
  assert(type(options) == "table", "Oak renderer requires options")
  assert(type(options.manifest) == "table", "Oak renderer requires the generated intro manifest")
  assert(type(options.manifest.widgets) == "table", "Oak renderer requires generated intro widgets")
  assert(type(options.manifest.background) == "table", "Oak renderer requires a generated intro background")
  local assets = options.manifest.widgets
  assert(options.manifest.background, "Oak renderer requires a generated background")
  local selector = assert(options.manifest.genderSelector, "Oak renderer requires a generated gender selector")
  assert(selector.defaultTone, "Oak renderer requires a generated gender selector tone")
  for _, assetId in ipairs(REQUIRED_ASSETS) do
    assert(assets[assetId], "Oak renderer requires generated asset " .. assetId)
  end
  local graphics = options.graphics or love.graphics
  local text = assert(options.text, "Oak renderer requires the shared FieldTextRenderer")
  local choiceText = assert(options.choiceText, "Oak renderer requires the font-4 FieldTextRenderer")
  assert(type(text.drawText) == "function", "Oak renderer requires FieldTextRenderer.drawText")
  assert(type(text.textWidth) == "function", "Oak renderer requires FieldTextRenderer.textWidth")
  assert(type(choiceText.drawTextWithPalette) == "function", "Oak renderer requires palette text rendering")
  local imageLoader = options.imageLoader or defaultImageLoader
  assert(type(imageLoader) == "function", "Oak renderer image loader must be callable")
  local uiManifest = assert(
    type(options.uiManifest) == "table" and options.uiManifest,
    "Oak renderer requires the validated field-UI manifest"
  ) --[[@as table<string, unknown>]]
  local images, bindings, renderedAssets = loadResources(options.manifest, graphics, imageLoader)
  local ok, revealShader = pcall(graphics.newShader, REVEAL_SHADER)
  if not ok then
    local acquired = {}
    for _, image in pairs(images) do
      acquired[#acquired + 1] = image
    end
    releaseAll(acquired)
    error(revealShader, 0)
  end
  if revealShader == nil then
    local acquired = {}
    for _, image in pairs(images) do
      acquired[#acquired + 1] = image
    end
    releaseAll(acquired)
    error("Oak renderer shader construction returned no shader", 0)
  end
  local renderer = setmetatable({
    assets = renderedAssets,
    manifest = options.manifest,
    graphics = graphics,
    text = text,
    choiceText = choiceText,
    namingScreen = nil,
    images = images,
    bindings = bindings,
    revealShader = revealShader,
    logicalCanvas = nil,
    logicalCanvasWidth = nil,
    logicalCanvasHeight = nil,
    released = false,
  }, OakIntroRenderer)
  local function drawNamingSubject(_, subject, rect)
    local gender = type(subject) == "table" and subject.gender == 1 and 1 or 0
    drawAsset(renderer, gender == 1 and "naming_female" or "naming_male", 1, {
      x = rect.x,
      y = rect.y,
      width = rect.width,
      height = rect.height,
      scale = 1,
    })
  end
  -- The naming chrome shares the generated image loader: a naming acquisition
  -- failure releases the intro images and shader already acquired here before
  -- rethrowing, so no partial renderer ever escapes.
  local namingOk, namingOrFailure = pcall(NamingScreenRenderer.new, {
    graphics = graphics,
    text = text,
    drawSubject = drawNamingSubject,
    manifest = uiManifest,
    imageLoader = imageLoader,
  })
  if not namingOk then
    local acquired = {}
    for _, image in pairs(images) do
      acquired[#acquired + 1] = image
    end
    releaseAll(acquired)
    if revealShader and revealShader.release then
      pcall(revealShader.release, revealShader)
    end
    error(namingOrFailure, 0)
  end
  renderer.namingScreen = namingOrFailure --[[@as table<string, unknown>]]
  ---@cast renderer OakIntroRenderer
  return renderer
end

local function drawBackground(self, region)
  local asset = assert(self.assets.background, "intro asset is missing: background")
  local binding = assert(self.bindings.background and self.bindings.background[1], "intro frame is missing: background")
  local frame = asset.frames[1]
  local sx = region.width / frame.width
  local sy = region.height / frame.height
  self.graphics.setColor(1, 1, 1, 1)
  self.graphics.draw(binding.image, binding.quad, region.x, region.y, 0, sx, sy)
end

---@param surface table<string, unknown>
function OakIntroRenderer:_ensureLogicalCanvas(surface)
  assert(not self.released, "Oak renderer is released")
  local width = assert(surface.allocationWidth)
  local height = assert(surface.allocationHeight)
  if self.logicalCanvas and self.logicalCanvasWidth == width and self.logicalCanvasHeight == height then
    return
  end
  local ok, replacement = pcall(self.graphics.newCanvas, width, height)
  if not ok then
    error(replacement, 0)
  end
  assert(replacement ~= nil, "Oak logical Canvas construction returned no Canvas")
  local configured, failure = pcall(function()
    if replacement.setFilter then
      replacement:setFilter("nearest", "nearest")
    end
  end)
  if not configured then
    if replacement.release then
      replacement:release()
    end
    error(failure, 0)
  end
  local previous = self.logicalCanvas
  self.logicalCanvas = replacement
  self.logicalCanvasWidth = width
  self.logicalCanvasHeight = height
  if previous and previous.release then
    previous:release()
  end
end

local function setCompositeScissor(graphics, frame)
  local x, y, width, height = graphics.getScissor()
  if x == nil then
    graphics.setScissor(frame.x, frame.y, frame.width, frame.height)
    return
  end
  local right = math.min(x + width, frame.x + frame.width)
  local bottom = math.min(y + height, frame.y + frame.height)
  local left = math.max(x, frame.x)
  local top = math.max(y, frame.y)
  graphics.setScissor(left, top, math.max(0, right - left), math.max(0, bottom - top))
end

---@param view table<string, unknown>
function OakIntroRenderer:_draw(view)
  assert(not self.released, "Oak renderer is released")
  local graphics = self.graphics
  local layout = view.layout
  graphics.clear(0.04, 0.05, 0.09, 1)
  drawBackground(self, layout.viewport)
  if view.primaryWidget ~= nil and layout.subject ~= nil then
    drawAsset(self, view.primaryWidget, view.visualFrameIndex, layout.subject)
  elseif view.primaryWidget == nil and view.visual ~= "background" and layout.subject ~= nil then
    drawAsset(self, view.visual, view.visualFrameIndex, layout.subject)
  end
  if view.revealWidget ~= nil and layout.reveal ~= nil then
    drawAsset(self, view.revealWidget, view.revealFrameIndex, layout.reveal, view.revealOpacity, view.revealBrightness)
  end
  if view.sceneBrightness > 0 then
    assert(view.sceneBrightness <= 1, "intro scene brightness is out of range")
    graphics.setColor(1, 1, 1, view.sceneBrightness)
    graphics.rectangle("fill", layout.viewport.x, layout.viewport.y, layout.viewport.width, layout.viewport.height)
  end
  local finalFadeAlpha = view.finalFadeAlpha or 0
  if finalFadeAlpha > 0 then
    graphics.setColor(0, 0, 0, finalFadeAlpha)
    graphics.rectangle("fill", layout.viewport.x, layout.viewport.y, layout.viewport.width, layout.viewport.height)
  end
  if view.phase == "gender_select" or view.phase == "gender_confirm" then
    if view.phase == "gender_select" then
      for gender = 0, 1 do
        local entry = assert(layout.genderButtons and layout.genderButtons[gender])
        local selected = view.genderFocus == gender
        local function drawGenderPortrait(rect)
          drawAsset(self, entry.portraitId, 1, rect)
        end
        HgssCardButton.draw(graphics, entry.button, {
          defaultTone = cardTone(self.manifest),
          selected = selected,
          focusBlinkDelta = selected and view.focusBlinkDelta or 0,
          contentRect = entry.portraitRect,
          drawContent = drawGenderPortrait,
        })
      end
    elseif layout.selectedProfileButton then
      local entry = layout.selectedProfileButton
      local function drawSelectedProfilePortrait(rect)
        drawAsset(self, entry.portraitId, 1, rect)
      end
      HgssCardButton.draw(graphics, entry.button, {
        defaultTone = cardTone(self.manifest),
        selected = true,
        focusBlinkDelta = view.focusBlinkDelta or 0,
        contentRect = entry.portraitRect,
        drawContent = drawSelectedProfilePortrait,
      })
    end
  end
  if layout.confirmationButtons then
    local labels = assert(view.choiceLabels)
    local textPalette = {
      foreground = paletteColor(self.choiceText.fontDef, 16),
      shadow = paletteColor(self.choiceText.fontDef, 2),
      background = paletteColor(self.choiceText.fontDef, 1),
    }
    textPalette.background.a = 0
    local function measureChoiceText(text)
      return self.choiceText:textWidth(text)
    end
    local function drawChoiceText(text, x, y)
      self.choiceText:drawTextWithPalette(text, x, y, textPalette)
    end
    local adapter = {
      measure = measureChoiceText,
      lineHeight = self.choiceText.fontDef.lineHeight,
      draw = drawChoiceText,
    }
    for choice = 0, 1 do
      local entry = assert(layout.confirmationButtons[choice])
      local selected = view.confirmationChoice.selected == choice
      local label = assert(labels[choice])
      TextButton.draw(graphics, entry.button, {
        label = label,
        selected = selected,
        text = adapter,
      })
    end
  end
  graphics.setColor(1, 1, 1, 1)
  if view.phase == "name_edit" then
    self.namingScreen:draw(assert(view.namingScreen), assert(layout.namingScreen))
  end
end

function OakIntroRenderer:draw(view, overlay)
  assert(not self.released, "Oak renderer is released")
  assert(type(view.pixelSurface) == "table", "Oak draw requires a pixel surface")
  if overlay ~= nil then
    assert(type(overlay) == "function", "Oak draw overlay must be callable")
  end
  local surface = view.pixelSurface
  self:_ensureLogicalCanvas(surface)
  local graphics = self.graphics
  FieldDrawState.protectedDraw(graphics, function()
    local callerCanvas = graphics.getCanvas()
    graphics.setCanvas(self.logicalCanvas)
    self:_draw(view)
    if overlay then
      overlay()
    end
    graphics.setCanvas(callerCanvas)
    local placement = surface.placement
    setCompositeScissor(graphics, placement.frame)
    graphics.setShader(nil)
    graphics.setColor(1, 1, 1, 1)
    graphics.setBlendMode("replace", "premultiplied")
    graphics.draw(self.logicalCanvas, placement.origin.x, placement.origin.y, 0, placement.scale, placement.scale)
  end)
end

function OakIntroRenderer:dispose()
  if self.released then
    return
  end
  self.released = true
  local resources = {}
  for _, image in pairs(self.images) do
    resources[#resources + 1] = image
  end
  releaseAll(resources)
  self.images = {}
  self.bindings = {}
  if self.namingScreen then
    self.namingScreen:dispose()
    self.namingScreen = nil
  end
  if self.logicalCanvas and self.logicalCanvas.release then
    self.logicalCanvas:release()
  end
  self.logicalCanvas = nil
  self.logicalCanvasWidth = nil
  self.logicalCanvasHeight = nil
  if self.revealShader and self.revealShader.release then
    self.revealShader:release()
  end
  self.revealShader = nil
end

return OakIntroRenderer
