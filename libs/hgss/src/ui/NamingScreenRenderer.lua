-- HGSS naming surface renderer composing generated source visuals with
-- shared field text. The opaque base draws first, the selected transparent
-- page overlay draws over it at its manifest placement, then the
-- OAM-composed support backing, page controls, entry slots, keyboard and
-- entered-name text from the generated text geometry, the cursor visual, and
-- the player subject from the manifest. Non-player subjects stay host-owned:
-- the host injects drawSubject and the renderer only brackets the call with
-- balanced graphics state. Generated images are owned here and released on
-- dispose; the text renderer and subject resources stay host-owned.

local PixelScale = require("libs.ui.src.PixelScale")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

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

local function acquireOrder()
  local order = { "base", "upper", "lower", "symbols" }
  for _, key in ipairs(CONTROL_KEYS) do
    order[#order + 1] = "control:" .. key
  end
  order[#order + 1] = "cursor:keyboard"
  for _, key in ipairs(HOME_KEYS) do
    order[#order + 1] = "cursor:home:" .. key
  end
  order[#order + 1] = "slot:normal"
  order[#order + 1] = "slot:selected"
  order[#order + 1] = "subject:male"
  order[#order + 1] = "subject:female"
  return order
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
  local paths = { base = imagePath(options.manifest, naming.base, "base") }
  for _, key in ipairs(PAGE_KEYS) do
    paths[key] = imagePath(options.manifest, naming.pages[key], key .. " page")
  end
  for _, key in ipairs(CONTROL_KEYS) do
    paths["control:" .. key] =
      imagePath(options.manifest, requireSprite(naming.controls, key, key .. " control"), key .. " control")
  end
  paths["cursor:keyboard"] =
    imagePath(options.manifest, requireSprite(naming.cursor, "keyboard", "keyboard cursor"), "keyboard cursor")
  for _, key in ipairs(HOME_KEYS) do
    paths["cursor:home:" .. key] =
      imagePath(options.manifest, requireSprite(naming.cursor.home, key, key .. " home cursor"), key .. " home cursor")
  end
  paths["slot:normal"] =
    imagePath(options.manifest, requireSprite(naming.entrySlots, "normal", "normal slot"), "normal slot")
  paths["slot:selected"] =
    imagePath(options.manifest, requireSprite(naming.entrySlots, "selected", "selected slot"), "selected slot")
  for _, key in ipairs({ "male", "female" }) do
    paths["subject:" .. key] =
      imagePath(options.manifest, requireSprite(naming.playerSubjects, key, key .. " subject"), key .. " subject")
  end
  ---@type NamingScreenRenderer
  local renderer = setmetatable({
    graphics = options.graphics,
    text = options.text,
    drawSubject = options.drawSubject,
    naming = naming,
    placement = naming.placement,
    images = {},
    released = false,
  }, NamingScreenRenderer)
  local acquired = renderer.images
  local order = acquireOrder()
  local ok, failure = pcall(function()
    for _, key in ipairs(order) do
      acquired[key] = options.imageLoader(paths[key])
      assert(acquired[key] ~= nil, "naming image loader returned no image for " .. key)
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
  for _, key in ipairs(CONTROL_KEYS) do
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
  local cursor = view.cursor
  if cursor.row == 1 then
    local controlId = homeControlAt(cursor.column)
    if controlId ~= nil then
      local record = naming.cursor.home[controlId]
      drawVisual("cursor:home:" .. controlId, record.anchor.x + record.offset.x, record.anchor.y + record.offset.y)
    end
  else
    local record = naming.cursor.keyboard
    drawVisual(
      "cursor:keyboard",
      record.anchor.x + (cursor.column - 1) * record.stepX + record.offset.x,
      record.anchor.y + (cursor.row - 2) * record.stepY + record.offset.y
    )
  end
  if view.subject.kind == "player" then
    local gender = view.subject.gender == 1 and "female" or "male"
    local record = naming.playerSubjects[gender]
    drawVisual("subject:" .. gender, record.anchor.x + record.offset.x, record.anchor.y + record.offset.y)
  else
    g.push()
    self.drawSubject(g, view.subject, layout.subject)
    g.pop()
  end
  g.pop()
end

function NamingScreenRenderer:dispose()
  if self.released then
    return
  end
  self.released = true
  for _, key in ipairs(acquireOrder()) do
    local image = self.images[key]
    if image ~= nil then
      pcall(image.release, image)
      self.images[key] = nil
    end
  end
  self.drawSubject = nil
end

NamingScreenRenderer.release = NamingScreenRenderer.dispose
return NamingScreenRenderer
