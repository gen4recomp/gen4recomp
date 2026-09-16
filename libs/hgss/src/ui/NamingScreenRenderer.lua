-- HGSS naming surface renderer composing generated source chrome with shared
-- field text. The opaque base draws first, the selected transparent page
-- overlay draws over it at its manifest placement, then the host-owned
-- subject, the entered name, and the keyboard/control glyphs; exactly one
-- focus mark remains on the selected cell. Subject art stays host-owned: the
-- host injects drawSubject and the renderer only brackets the call with
-- balanced graphics state. Generated images are owned here and released on
-- dispose; the text renderer and subject resources stay host-owned.

local PixelScale = require("libs.ui.src.PixelScale")

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
---@field placement table<string, number>
---@field images table<string, unknown>
---@field released boolean
---@field new fun(options: NamingScreenRendererOptions): NamingScreenRenderer
---@field draw fun(self: NamingScreenRenderer, view: NamingScreenSnapshot, layout: NamingScreenLayoutResult)
---@field dispose fun(self: NamingScreenRenderer)
NamingScreenRenderer.__index = NamingScreenRenderer

local PAGE_KEYS = { "upper", "lower", "symbols" }

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
  local paths = { base = imagePath(options.manifest, naming.base, "base") }
  for _, key in ipairs(PAGE_KEYS) do
    paths[key] = imagePath(options.manifest, naming.pages[key], key .. " page")
  end
  ---@type NamingScreenRenderer
  local renderer = setmetatable({
    graphics = options.graphics,
    text = options.text,
    drawSubject = options.drawSubject,
    placement = naming.placement,
    images = {},
    released = false,
  }, NamingScreenRenderer)
  local acquired = renderer.images
  local ok, failure = pcall(function()
    acquired.base = options.imageLoader(paths.base)
    assert(acquired.base ~= nil, "naming image loader returned no image for the base")
    for _, key in ipairs(PAGE_KEYS) do
      acquired[key] = options.imageLoader(paths[key])
      assert(acquired[key] ~= nil, "naming image loader returned no image for the " .. key .. " page")
    end
  end)
  if not ok then
    for _, key in ipairs({ "base", "upper", "lower", "symbols" }) do
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

local function center(text, region, measure)
  return PixelScale.snapLogical(region.x + (region.width - measure(text)) / 2)
end

function NamingScreenRenderer:draw(view, layout)
  assert(not self.released, "naming renderer is released")
  assert(type(view) == "table" and type(layout) == "table", "naming draw requires view and layout")
  assert(type(view.subject) == "table", "naming draw requires a semantic subject")
  assert(type(layout.surface) == "table", "naming draw requires a canonical surface")
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
  g.push()
  self.drawSubject(g, view.subject, layout.subject)
  g.pop()
  local text = view.text or ""
  g.setColor(1, 1, 1, 1)
  self.text:drawText(
    text,
    center(text, layout.nameSlots, function(value)
      return self.text.textWidth and self.text:textWidth(value) or 0
    end),
    layout.nameSlots.y + 4
  )
  for row = 1, 6 do
    for column = 1, 13 do
      local cell = view.grid[row][column]
      if cell.kind == "glyph" then
        local cellRect = layout.cells[row][column]
        local glyphWidth = self.text.textWidth and self.text:textWidth(cell.glyph) or 0
        g.setColor(1, 1, 1, 1)
        self.text:drawText(cell.glyph, cellRect.x + (cellRect.width - glyphWidth) / 2, cellRect.y + 2)
      end
    end
  end
  local labels = { upper = "Upper", lower = "Lower", symbols = "Symbols", back = "Back", ok = "OK" }
  for id, region in pairs(layout.controls) do
    local label = labels[id]
    local labelWidth = self.text.textWidth and self.text:textWidth(label) or 0
    g.setColor(1, 1, 1, 1)
    self.text:drawText(label, region.x + (region.width - labelWidth) / 2, region.y + 2)
  end
  local cursor = view.cursor
  local selectedRect = layout.cells[cursor.row][cursor.column]
  g.setColor(0.96, 0.82, 0.40, 1)
  g.rectangle("line", selectedRect.x, selectedRect.y, selectedRect.width, selectedRect.height)
  g.pop()
end

function NamingScreenRenderer:dispose()
  if self.released then
    return
  end
  self.released = true
  for _, key in ipairs({ "base", "upper", "lower", "symbols" }) do
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
