-- Loads the compiled dialogue font definition for runtime text layout. This
-- deliberately owns no atlas or graphics objects; presentation loads those
-- separately when it creates the dialogue renderer. A loaded definition must
-- satisfy the v4 codec contract before presentation construction: the seven
-- color bands over a positive base-band stride, an atlas tall enough for every
-- band, a named semantic glyph mask atlas path, and the four 24x32 focus frames
-- with four source-slot layer rects each. A stale or malformed definition is
-- rejected here, not at individual draw calls.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local FieldFontLoader = {}

-- Returns nil + a reason string when the definition violates the v4 codec
-- contract. No mutation.
---@param definition table<string, unknown>
---@return boolean?, string?
local function definitionValid(definition)
  local variants = definition.colorVariants
  if type(variants) ~= "table" or variants.count ~= FieldMessageText.COLOR_VARIANT_COUNT then
    return nil, "colorVariants must declare exactly " .. FieldMessageText.COLOR_VARIANT_COUNT .. " bands"
  end
  if type(variants.strideY) ~= "number" or variants.strideY <= 0 or variants.strideY % 1 ~= 0 then
    return nil, "colorVariants.strideY must be a positive integer"
  end
  local atlas = definition.atlas
  if
    type(atlas) ~= "table"
    or type(atlas.baseHeight) ~= "number"
    or atlas.baseHeight <= 0
    or atlas.baseHeight % 1 ~= 0
  then
    return nil, "atlas.baseHeight must be a positive integer"
  end
  if type(atlas.height) ~= "number" or atlas.height < atlas.baseHeight * variants.count then
    return nil, "atlas height must fit every color band"
  end
  if type(definition.maskAtlasPath) ~= "string" or definition.maskAtlasPath == "" then
    return nil, "maskAtlasPath must name the semantic glyph mask atlas"
  end
  local focus = definition.focusIndicators
  if
    type(focus) ~= "table"
    or focus.count ~= FieldMessageText.FOCUS_INDICATOR_COUNT
    or type(focus.frames) ~= "table"
  then
    return nil, "focusIndicators must declare exactly " .. FieldMessageText.FOCUS_INDICATOR_COUNT .. " frames"
  end
  local slots = { 11, 12, 13, 14 }
  if type(focus.sourcePaletteSlots) ~= "table" or #focus.sourcePaletteSlots ~= #slots then
    return nil, "focusIndicators.sourcePaletteSlots must be exactly {11,12,13,14}"
  end
  for index, slot in ipairs(slots) do
    if focus.sourcePaletteSlots[index] ~= slot then
      return nil, "focusIndicators.sourcePaletteSlots must be exactly {11,12,13,14}"
    end
  end
  for index in pairs(focus.sourcePaletteSlots) do
    if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #slots then
      return nil, "focusIndicators.sourcePaletteSlots must be exactly {11,12,13,14}"
    end
  end
  local atlasWidth = FieldFontCache.FOCUS_FRAME_WIDTH * #slots
  local atlasHeight = FieldFontCache.FOCUS_FRAME_HEIGHT * focus.count
  for field = 0, focus.count - 1 do
    local frame = focus.frames[field]
    if type(frame) ~= "table" or type(frame.layers) ~= "table" then
      return nil, "focus frame " .. field .. " must carry four source-slot layers"
    end
    for index, slot in ipairs(slots) do
      local rect = frame.layers[slot]
      local expectedX = (index - 1) * FieldFontCache.FOCUS_FRAME_WIDTH
      local expectedY = field * FieldFontCache.FOCUS_FRAME_HEIGHT
      if
        type(rect) ~= "table"
        or rect.x ~= expectedX
        or rect.y ~= expectedY
        or rect.width ~= FieldFontCache.FOCUS_FRAME_WIDTH
        or rect.height ~= FieldFontCache.FOCUS_FRAME_HEIGHT
        or rect.x < 0
        or rect.y < 0
        or rect.x + rect.width > atlasWidth
        or rect.y + rect.height > atlasHeight
      then
        return nil, "focus frame " .. field .. " slot " .. slot .. " has invalid layer geometry"
      end
    end
    local layerCount = 0
    for slot in pairs(frame.layers) do
      if slot ~= 11 and slot ~= 12 and slot ~= 13 and slot ~= 14 then
        return nil, "focus frame " .. field .. " has an unsupported source-slot layer"
      end
      layerCount = layerCount + 1
    end
    if layerCount ~= #slots then
      return nil, "focus frame " .. field .. " must carry exactly four layers"
    end
  end
  for field in pairs(focus.frames) do
    if type(field) ~= "number" or field % 1 ~= 0 or field < 0 or field >= focus.count then
      return nil, "focusIndicators.frames has an unsupported frame"
    end
  end
  return true
end

---@param cacheFs CacheFs
---@param fontId integer?
---@return FieldFontDef
function FieldFontLoader.load(cacheFs, fontId)
  assert(cacheFs and cacheFs.loadLua, "FieldFontLoader requires a CacheFs-shaped object")
  fontId = fontId or 0
  local path = FieldFontCache.defPath(fontId)
  local definition = cacheFs:loadLua(path)
  if type(definition) ~= "table" or definition.schema ~= FieldFontCache.SCHEMA then
    Errors.raise(
      FieldErrors.FONT_DEF_MISSING,
      "no " .. FieldFontCache.SCHEMA .. " definition at " .. path,
      { fontId = fontId, path = path }
    )
  end
  local valid, reason = definitionValid(definition --[[@as table]])
  if not valid then
    Errors.raise(
      FieldErrors.FONT_DEF_INVALID,
      FieldFontCache.SCHEMA .. " definition at " .. path .. " is malformed: " .. reason,
      { fontId = fontId, path = path, reason = reason }
    )
  end
  return definition --[[@as FieldFontDef]]
end

return FieldFontLoader
