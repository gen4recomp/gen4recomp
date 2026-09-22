-- HGSS naming surface renderer composing generated source visuals with
-- shared field text. The opaque base draws first, the selected transparent
-- page overlay draws over it at its manifest placement, then the
-- OAM-composed support backing, page controls, entry slots, keyboard and
-- entered-name text from the generated text geometry, the animated player
-- subject from the manifest, and the animated cursor visual with its
-- source palette pulse mask on top. Subject and cursor frames resolve
-- deterministically from the snapshot presentation clocks against the
-- generated durations and playback modes. Non-player subjects stay
-- host-owned: the host injects drawSubject and the renderer only brackets
-- the call with balanced graphics state. Generated images are owned here
-- and released on dispose; the text renderer and subject resources stay
-- host-owned.

local PixelScale = require("libs.ui.src.PixelScale")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local Rgb555 = require("libs.codec.src.Rgb555")

local NamingScreenRenderer = {}

---@class NamingScreenRendererOptions
---@field graphics table<string, function>
---@field text table<string, function>
---@field drawSubject fun(graphics: table<string, function>, subject: table<string, unknown>, rect: table<string, number>)
---@field manifest table<string, unknown>
---@field imageLoader fun(path: string): unknown

---@class NamingScreenRenderer
---@field graphics table<string, function>
---@field text table<string, function>
---@field drawSubject fun(graphics: table<string, function>, subject: table<string, unknown>, rect: table<string, number>)?
---@field naming table<string, unknown>
---@field placement table<string, number>
---@field images table<string, unknown>
---@field quads table<table, table<string, unknown>>
---@field atlasSizes table<string, table<string, integer>>
---@field released boolean
---@field new fun(options: NamingScreenRendererOptions): NamingScreenRenderer
---@field draw fun(self: NamingScreenRenderer, view: NamingScreenSnapshot, layout: NamingScreenLayoutResult)
---@field dispose fun(self: NamingScreenRenderer)
NamingScreenRenderer.__index = NamingScreenRenderer

local PAGE_KEYS = { "upper", "lower", "symbols" }
local CONTROL_KEYS = { "upper", "lower", "symbols", "back", "ok", "backing" }
local HOME_KEYS = { "upper", "lower", "symbols", "back", "ok" }

local function imagePath(manifest, entry, what)
  assert(type(entry) == "table", "naming chrome " .. what .. " is missing")
  if type(entry.image) == "string" and entry.image ~= "" then
    return entry.image
  end
  local assets = manifest.assets
  local record = type(assets) == "table" and assets[entry.asset] or nil
  if type(record) == "table" and type(record.image) == "string" and record.image ~= "" then
    return record.image
  end
  error("naming chrome " .. what .. " names no generated image", 0)
end

-- Every generated PNG the renderer draws, in deterministic acquisition
-- order: static visuals by semantic key, then each unique animation atlas
-- (normal frames first, pulse masks alongside their cursor record).
local function acquireOrder(naming)
  local order = { "base", "upper", "lower", "symbols" }
  for _, key in ipairs(CONTROL_KEYS) do
    order[#order + 1] = "control:" .. key
  end
  order[#order + 1] = "slot:normal"
  order[#order + 1] = "slot:selected"
  local seen = {}
  local function animationAssets(records)
    for _, record in ipairs(records) do
      for _, frame in ipairs(record.frames) do
        if not seen[frame.asset] then
          seen[frame.asset] = true
          order[#order + 1] = "atlas:" .. frame.asset
        end
      end
      if record.pulseAsset ~= nil and not seen[record.pulseAsset] then
        seen[record.pulseAsset] = true
        order[#order + 1] = "atlas:" .. record.pulseAsset
      end
    end
  end
  animationAssets({ naming.playerSubjects.male, naming.playerSubjects.female })
  animationAssets({ naming.cursor.keyboard })
  local homeRecords = {}
  for _, key in ipairs(HOME_KEYS) do
    homeRecords[#homeRecords + 1] = naming.cursor.home[key]
  end
  animationAssets(homeRecords)
  return order
end

local function trunc0(value)
  return value < 0 and math.ceil(value) or math.floor(value)
end

local function pulseGreen5(angle)
  return math.max(0, math.min(31, 15 + trunc0(math.sin(math.rad(angle)) * 10)))
end

-- The source focus-glow color: palette entry 29 with red 29, blue 0, and
-- the angle-driven green role, converted through the shared 5-bit decoder.
local function pulseColor(angle)
  local rgb = Rgb555.decode(29 + pulseGreen5(angle) * 32)
  return { r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255 }
end

local function frameDurations(frames)
  local total = 0
  for _, frame in ipairs(frames) do
    total = total + frame.duration
  end
  return total
end

local function frameAt(entries, tick)
  local remaining = tick
  for _, entry in ipairs(entries) do
    if remaining < entry.frame.duration then
      return entry.index
    end
    remaining = remaining - entry.frame.duration
  end
  return entries[#entries].index
end

local function indexed(frames)
  local entries = {}
  for index, frame in ipairs(frames) do
    entries[index] = { frame = frame, index = index }
  end
  return entries
end

local function reversedEntries(frames)
  local entries = {}
  for index = #frames, 1, -1 do
    entries[#entries + 1] = { frame = frames[index], index = index }
  end
  return entries
end

-- Resolve the generated animation frame for a presentation tick. Forward
-- playback holds its last frame; looping playback repeats its loop segment
-- (forward from the loop start, reverse back down to it) after one full
-- pass. Reverse modes traverse the same frames in the opposite order.
local function resolveFrameIndex(record, tick)
  local frames = record.frames
  local total = frameDurations(frames)
  local mode = record.playMode
  if mode == "forward" then
    return frameAt(indexed(frames), math.min(tick, total - 1))
  elseif mode == "forward_loop" then
    if tick < total then
      return frameAt(indexed(frames), tick)
    end
    local start = record.loopStartFrameIdx + 1
    local prefix = 0
    for index = 1, start - 1 do
      prefix = prefix + frames[index].duration
    end
    return frameAt(indexed(frames), prefix + (tick - total) % (total - prefix))
  elseif mode == "reverse" then
    return frameAt(reversedEntries(frames), math.min(tick, total - 1))
  elseif mode == "reverse_loop" then
    local entries = reversedEntries(frames)
    if tick < total then
      return frameAt(entries, tick)
    end
    local region = {}
    for index = 1, #frames - record.loopStartFrameIdx do
      region[#region + 1] = entries[index]
    end
    local regionTotal = 0
    for _, entry in ipairs(region) do
      regionTotal = regionTotal + entry.frame.duration
    end
    local prefix = total - regionTotal
    return frameAt(region, prefix + (tick - total) % regionTotal)
  end
  error("unknown naming animation play mode: " .. tostring(mode), 0)
end

local function requireSprite(section, key, what)
  local entry = type(section) == "table" and section[key] or nil
  assert(type(entry) == "table", "naming renderer requires the " .. what .. " visual")
  assert(type(entry.anchor) == "table", "naming renderer requires the " .. what .. " anchor")
  assert(type(entry.offset) == "table", "naming renderer requires the " .. what .. " frame offset")
  return entry
end

---@param options { graphics: table<string, function>, text: table<string, function>, drawSubject: fun(graphics: table<string, function>, subject: table<string, unknown>, rect: table<string, number>), manifest: table<string, unknown>, imageLoader: fun(path: string): unknown }
---@return NamingScreenRenderer
function NamingScreenRenderer.new(options)
  assert(type(options) == "table" and options.graphics and options.text, "naming renderer requires graphics and text")
  assert(type(options.text.drawText) == "function", "naming renderer requires FieldTextRenderer.drawText")
  assert(type(options.drawSubject) == "function", "naming renderer requires a host drawSubject callback")
  assert(type(options.manifest) == "table", "naming renderer requires the field-UI naming manifest")
  assert(type(options.imageLoader) == "function", "naming renderer requires the generated image loader")
  local naming = options.manifest.namingScreen
  assert(type(naming) == "table", "naming renderer requires the namingScreen manifest section")
  assert(type(naming.base) == "table", "naming renderer requires the naming base entry")
  assert(type(naming.pages) == "table", "naming renderer requires the naming page entries")
  assert(type(naming.placement) == "table", "naming renderer requires the naming page placement")
  assert(type(naming.text) == "table", "naming renderer requires the naming text geometry")
  assert(type(naming.controls) == "table", "naming renderer requires the naming controls")
  assert(type(naming.cursor) == "table", "naming renderer requires the naming cursor")
  assert(type(naming.entrySlots) == "table", "naming renderer requires the naming entry slots")
  assert(type(naming.playerSubjects) == "table", "naming renderer requires the naming player subjects")
  for _, key in ipairs(CONTROL_KEYS) do
    requireSprite(naming.controls, key, key .. " control")
  end
  requireSprite(naming.entrySlots, "normal", "normal slot")
  requireSprite(naming.entrySlots, "selected", "selected slot")
  local animatedRecords = {
    naming.playerSubjects.male,
    naming.playerSubjects.female,
    naming.cursor.keyboard,
  }
  for _, key in ipairs(HOME_KEYS) do
    animatedRecords[#animatedRecords + 1] = naming.cursor.home[key]
  end
  for _, record in ipairs(animatedRecords) do
    assert(
      type(record) == "table" and type(record.frames) == "table",
      "naming renderer requires generated animation frames"
    )
    assert(
      record.playMode == "forward"
        or record.playMode == "forward_loop"
        or record.playMode == "reverse"
        or record.playMode == "reverse_loop",
      "naming renderer requires a supported animation play mode"
    )
    assert(
      type(record.loopStartFrameIdx) == "number"
        and record.loopStartFrameIdx % 1 == 0
        and record.loopStartFrameIdx >= 0
        and record.loopStartFrameIdx < #record.frames,
      "naming renderer requires a loop start inside its animation frames"
    )
  end
  local paths = { base = imagePath(options.manifest, naming.base, "base") }
  for _, key in ipairs(PAGE_KEYS) do
    paths[key] = imagePath(options.manifest, naming.pages[key], key .. " page")
  end
  for _, key in ipairs(CONTROL_KEYS) do
    paths["control:" .. key] = imagePath(options.manifest, naming.controls[key], key .. " control")
  end
  paths["slot:normal"] = imagePath(options.manifest, naming.entrySlots.normal, "normal slot")
  paths["slot:selected"] = imagePath(options.manifest, naming.entrySlots.selected, "selected slot")
  local function animationPath(assetId, what)
    local assets = options.manifest.assets
    local record = type(assets) == "table" and assets[assetId] or nil
    if type(record) == "table" and type(record.image) == "string" and record.image ~= "" then
      return record.image, record.width, record.height
    end
    error("naming animation " .. what .. " names no generated image", 0)
  end
  local atlasSizes = {}
  for _, record in ipairs(animatedRecords) do
    for _, frame in ipairs(record.frames) do
      if atlasSizes[frame.asset] == nil then
        local image, width, height = animationPath(frame.asset, "frame")
        paths["atlas:" .. frame.asset] = image
        atlasSizes[frame.asset] = { width = width, height = height }
      end
    end
    if record.pulseAsset ~= nil and atlasSizes[record.pulseAsset] == nil then
      local image, width, height = animationPath(record.pulseAsset, "pulse mask")
      paths["atlas:" .. record.pulseAsset] = image
      atlasSizes[record.pulseAsset] = { width = width, height = height }
    end
  end
  ---@type NamingScreenRenderer
  local renderer = setmetatable({
    graphics = options.graphics,
    text = options.text,
    drawSubject = options.drawSubject,
    naming = naming,
    placement = naming.placement,
    images = {},
    quads = {},
    atlasSizes = atlasSizes,
    released = false,
  }, NamingScreenRenderer)
  local acquired = renderer.images
  local order = acquireOrder(naming)
  local ok, failure = pcall(function()
    for _, key in ipairs(order) do
      local image = options.imageLoader(paths[key])
      assert(image ~= nil, "naming image loader returned no image for " .. key)
      acquired[key] = image
      assert(type(image.setFilter) == "function", "naming image filtering is unavailable for " .. key)
      image:setFilter("nearest", "nearest")
    end
    for _, record in ipairs(animatedRecords) do
      for _, frame in ipairs(record.frames) do
        local atlas = assert(atlasSizes[frame.asset], "naming animation frame names an unindexed atlas")
        renderer.quads[frame] = {
          quad = options.graphics.newQuad(
            frame.rect.x,
            frame.rect.y,
            frame.rect.width,
            frame.rect.height,
            atlas.width,
            atlas.height
          ),
        }
        if record.pulseAsset ~= nil then
          local maskAtlas = assert(atlasSizes[record.pulseAsset], "naming cursor names an unindexed pulse atlas")
          renderer.quads[frame].maskQuad = options.graphics.newQuad(
            frame.pulseRect.x,
            frame.pulseRect.y,
            frame.pulseRect.width,
            frame.pulseRect.height,
            maskAtlas.width,
            maskAtlas.height
          )
        end
      end
    end
  end)
  if not ok then
    for _, key in ipairs(order) do
      local image = acquired[key]
      if image ~= nil then
        pcall(image.release, image)
        acquired[key] = nil
      end
    end
    renderer.quads = {}
    error(failure, 0)
  end
  return renderer
end

local function homeControlAt(column)
  if column == 1 or column == 2 then
    return "upper"
  elseif column == 3 or column == 4 then
    return "lower"
  elseif column == 5 or column == 6 then
    return "symbols"
  elseif column == 9 or column == 10 or column == 11 then
    return "back"
  elseif column == 12 or column == 13 then
    return "ok"
  end
  return nil
end

function NamingScreenRenderer:draw(view, layout)
  assert(not self.released, "naming renderer is released")
  assert(type(view) == "table" and type(layout) == "table", "naming draw requires view and layout")
  assert(type(view.subject) == "table", "naming draw requires a semantic subject")
  assert(type(layout.surface) == "table", "naming draw requires a canonical surface")
  local naming = assert(self.naming, "naming renderer requires its manifest section")
  local page = self.images[view.page]
  if page == nil then
    error("unknown naming page: " .. tostring(view.page), 0)
  end
  local g = self.graphics
  g.push()
  g.translate(layout.surface.x, layout.surface.y)
  g.setColor(1, 1, 1, 1)
  g.draw(self.images.base, 0, 0)
  g.draw(page, self.placement.x, self.placement.y)
  local function drawVisual(imageKey, x, y)
    local image = assert(self.images[imageKey], "naming visual is missing: " .. imageKey)
    g.draw(image, PixelScale.snapLogical(x), PixelScale.snapLogical(y))
  end
  -- The support backing composites first so the home controls it frames
  -- stay visible above it.
  do
    local backing = naming.controls.backing
    drawVisual("control:backing", backing.anchor.x + backing.offset.x, backing.anchor.y + backing.offset.y)
  end
  for _, key in ipairs(HOME_KEYS) do
    local record = naming.controls[key]
    drawVisual("control:" .. key, record.anchor.x + record.offset.x, record.anchor.y + record.offset.y)
  end
  local slots = naming.entrySlots
  local entered = 0
  for _ in Utf8Glyphs.iter(view.text or "") do
    entered = entered + 1
  end
  for index = 0, (view.maxLength or entered) - 1 do
    local record = slots.normal
    drawVisual("slot:normal", slots.origin.x + index * slots.stepX + record.offset.x, slots.origin.y + record.offset.y)
  end
  if entered < (view.maxLength or entered) then
    local record = slots.selected
    drawVisual(
      "slot:selected",
      slots.origin.x + entered * slots.stepX + record.offset.x,
      slots.origin.y + record.offset.y
    )
  end
  g.setColor(1, 1, 1, 1)
  local keyboard = naming.text.keyboard.cells
  for row = 2, 6 do
    for column = 1, 13 do
      local cell = view.grid[row][column]
      if cell.kind == "glyph" then
        local textCell = keyboard[row - 1][column]
        local glyphWidth = self.text.textWidth and self.text:textWidth(cell.glyph) or 0
        self.text:drawText(cell.glyph, textCell.x + (textCell.width - glyphWidth) / 2, textCell.y)
      end
    end
  end
  local name = naming.text.name
  local slot = 0
  for glyph in Utf8Glyphs.iter(view.text or "") do
    self.text:drawText(glyph, name.x + slot * name.advanceX, name.y)
    slot = slot + 1
  end
  local presentation = assert(view.presentation, "naming draw requires snapshot presentation clocks")
  assert(
    type(presentation.subjectTick) == "number"
      and type(presentation.cursorTick) == "number"
      and type(presentation.glowAngle) == "number",
    "naming draw requires snapshot presentation clocks"
  )
  if view.subject.kind == "player" then
    local gender = view.subject.gender == 1 and "female" or "male"
    local record = naming.playerSubjects[gender]
    local frame = record.frames[resolveFrameIndex(record, presentation.subjectTick)]
    self:_drawAnimatedFrame(record, frame, record.anchor.x, record.anchor.y, nil)
  else
    g.push()
    self.drawSubject(g, view.subject, layout.subject)
    g.pop()
  end
  -- The focus cursor composites last so it stays above the control it
  -- highlights.
  local cursor = view.cursor
  if cursor.row == 1 then
    local controlId = homeControlAt(cursor.column)
    if controlId ~= nil then
      local record = naming.cursor.home[controlId]
      local frame = record.frames[resolveFrameIndex(record, presentation.cursorTick)]
      self:_drawAnimatedFrame(record, frame, record.anchor.x, record.anchor.y, presentation.glowAngle)
    end
  else
    local record = naming.cursor.keyboard
    local frame = record.frames[resolveFrameIndex(record, presentation.cursorTick)]
    self:_drawAnimatedFrame(
      record,
      frame,
      record.origin.x + (cursor.column - 1) * record.stepX,
      record.origin.y + (cursor.row - 2) * record.stepY,
      presentation.glowAngle
    )
  end
  g.pop()
end

-- Draw one resolved animation frame at its anchor plus the generated frame
-- offset. Cursor frames additionally draw their pulse mask tinted with the
-- current glow color; only mask pixels take the tint.
function NamingScreenRenderer:_drawAnimatedFrame(record, frame, anchorX, anchorY, glowAngle)
  local g = self.graphics
  local visual = assert(self.quads[frame], "naming animation frame was not acquired")
  local image = assert(self.images["atlas:" .. frame.asset], "naming animation atlas is missing")
  g.draw(
    image,
    visual.quad,
    PixelScale.snapLogical(anchorX + frame.offset.x),
    PixelScale.snapLogical(anchorY + frame.offset.y)
  )
  if glowAngle ~= nil and record.pulseAsset ~= nil then
    local maskImage = assert(self.images["atlas:" .. record.pulseAsset], "naming pulse-mask atlas is missing")
    local tint = pulseColor(glowAngle)
    g.setColor(tint.r, tint.g, tint.b, 1)
    g.draw(
      maskImage,
      assert(visual.maskQuad, "naming cursor frame was not masked"),
      PixelScale.snapLogical(anchorX + frame.offset.x),
      PixelScale.snapLogical(anchorY + frame.offset.y)
    )
    g.setColor(1, 1, 1, 1)
  end
end

function NamingScreenRenderer:dispose()
  if self.released then
    return
  end
  self.released = true
  for key, image in pairs(self.images) do
    if image ~= nil then
      pcall(image.release, image)
      self.images[key] = nil
    end
  end
  self.quads = {}
  self.drawSubject = nil
end

NamingScreenRenderer.release = NamingScreenRenderer.dispose
return NamingScreenRenderer
