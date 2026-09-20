-- The single theme record for field dialogue presentation: the 256 x 192
-- reference canvas (matching the DS top-screen aspect),
-- the canonical HGSS message-box content rect and text metrics
-- the user-frame tilemap composition, and the reference-to-screen
-- mapping into FieldViewport.referenceFrame.
-- The content rect is 16,152,216,32: DIALOG_BOX_X=2, DIALOG_BOX_Y=19,
-- DIALOG_BOX_W=27, DIALOG_BOX_H=4 tiles at 8px/tile (src/dialog_box.c,
-- pret/pokeheartgold commit 008257708bd41df5b8c9037e019088ba24df0a87).
-- The frame tilemap is the DrawFrameAndWindow2 composition
-- (asm/render_window.s sub_0200E6B4 at the same commit): 18 strip tiles
-- placed around the box -- one tile above and below, two left, three right.
-- All geometry is pure so the box layout is testable headlessly at every
-- host aspect; the LÖVE renderer draws exactly what this module computes.

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class FieldDialogueTheme
---@field schema string
---@field referenceWidth integer
---@field referenceHeight integer
---@field box FieldDialogueTheme.Rect
---@field textInsetX integer
---@field textInsetY integer
---@field lineHeight integer
---@field maxLines integer
---@field textWidth integer
---@field textHeight integer
---@field frameTilePlacements fun(box: FieldDialogueTheme.Rect): { tile: integer, x: integer, y: integer, spanX?: integer, spanY?: integer }[]
---@field layout fun(referenceFrame: unknown, fieldScale: number, cursorPlacement?: FieldDialogueTheme.Rect): FieldDialogueTheme.Layout
---@field fontMetrics fun(fontDef: FieldFontDef): FieldDialogueTheme.Metrics
---@field measureText fun(fontDef: FieldFontDef): fun(text: string): number
local FieldDialogueTheme = {}

FieldDialogueTheme.schema = "g4-field-dialogue-theme-v1"

-- Reference canvas: the DS top screen is 256 x 192.
FieldDialogueTheme.referenceWidth = 256
FieldDialogueTheme.referenceHeight = 192

-- Canonical HGSS message-box content rect: 2 tiles in, 19 tiles down,
-- 27 tiles wide, 4 tiles tall on the 32x24-tile field screen.
FieldDialogueTheme.box = {
  x = 16,
  y = 152,
  width = 216,
  height = 32,
}

-- Text area inside the box: two 16px lines fill the 32px content height
-- (HGSS prints from the window origin); a small horizontal inset keeps the
-- text clear of the window border.
FieldDialogueTheme.textInsetX = 0
FieldDialogueTheme.textInsetY = 0
FieldDialogueTheme.lineHeight = 16
FieldDialogueTheme.maxLines = 2
FieldDialogueTheme.textWidth = 216
FieldDialogueTheme.textHeight = 32

-- The extracted glyph atlas and HGSS user-frame artwork carry their own
-- baked colors; the dialogue renderer does not own cursor presentation data.
-- The audited DrawFrameAndWindow2 tilemap: every tile of the user-frame
-- strip placed around the content box, in strip order. Positions are
-- reference-canvas pixels; a span entry repeats the tile across the named
-- axis in 8px tile steps. The content box stays uncovered and the composed
-- frame exactly fills the 256x192 reference canvas.

---@param box FieldDialogueTheme.Rect
---@return { tile: integer, x: integer, y: integer, spanX?: integer, spanY?: integer }[]
function FieldDialogueTheme.frameTilePlacements(box)
  assert(
    type(box) == "table" and box.x and box.y and box.width and box.height,
    "frameTilePlacements requires the content box"
  )
  local left = box.x - 16
  local right = box.x + box.width
  local top = box.y - 8
  local bottom = box.y + box.height
  return {
    { tile = 0, x = left, y = top },
    { tile = 1, x = left + 8, y = top },
    { tile = 2, x = box.x, y = top, spanX = box.width / 8 },
    { tile = 3, x = right, y = top },
    { tile = 4, x = right + 8, y = top },
    { tile = 5, x = right + 16, y = top },
    { tile = 6, x = left, y = box.y, spanY = box.height / 8 },
    { tile = 7, x = left + 8, y = box.y, spanY = box.height / 8 },
    { tile = 9, x = right, y = box.y, spanY = box.height / 8 },
    { tile = 10, x = right + 8, y = box.y, spanY = box.height / 8 },
    { tile = 11, x = right + 16, y = box.y, spanY = box.height / 8 },
    { tile = 12, x = left, y = bottom },
    { tile = 13, x = left + 8, y = bottom },
    { tile = 14, x = box.x, y = bottom, spanX = box.width / 8 },
    { tile = 15, x = right, y = bottom },
    { tile = 16, x = right + 8, y = bottom },
    { tile = 17, x = right + 16, y = bottom },
  }
end

---@return { left: integer, top: integer, right: integer, bottom: integer }
function FieldDialogueTheme.applicationFrameInsets()
  return { left = 8, top = 24, right = 8, bottom = 16 }
end

-- Rotated application-frame tile targets derived from the audited
-- standard tilemap: the source composition around swapped content
-- dimensions expands to 8x8 instances, then the whole composition
-- rotates so source right becomes target top, source left becomes
-- target bottom, source top becomes target left, and source bottom
-- becomes target right. Returns tile identities with target positions;
-- drawing and artwork rotation stay with the frame renderer.
---@param box FieldDialogueTheme.Rect the target content box
---@return { tile: integer, x: number, y: number }[]
function FieldDialogueTheme.applicationFrameTilePlacements(box)
  assert(
    type(box) == "table" and box.x and box.y and box.width and box.height,
    "applicationFrameTilePlacements requires the content box"
  )
  assert(
    type(box.x) == "number" and type(box.y) == "number" and type(box.width) == "number" and type(box.height) == "number",
    "applicationFrameTilePlacements requires numeric box geometry"
  )
  assert(
    box.width > 0 and box.height > 0 and box.width == math.floor(box.width) and box.height == math.floor(box.height),
    "applicationFrameTilePlacements requires positive integral content dimensions"
  )
  assert(box.width % 8 == 0 and box.height % 8 == 0, "applicationFrameTilePlacements requires 8px-compatible content")
  local insets = FieldDialogueTheme.applicationFrameInsets()
  local targetOuterX = box.x - insets.left
  local targetOuterY = box.y - insets.top
  local sourceBox = { x = 16, y = 8, width = box.height, height = box.width }
  local sourceOuterWidth = sourceBox.width + 16 + 24
  local placements = {}
  for _, entry in ipairs(FieldDialogueTheme.frameTilePlacements(sourceBox)) do
    local countX = entry.spanX or 1
    local countY = entry.spanY or 1
    for ix = 0, countX - 1 do
      for iy = 0, countY - 1 do
        local sx = entry.x + ix * 8
        local sy = entry.y + iy * 8
        local tx = targetOuterX + sy
        local ty = targetOuterY + (sourceOuterWidth - sx - 8)
        placements[#placements + 1] = { tile = entry.tile, x = tx, y = ty }
      end
    end
  end
  return placements
end

-- Reference-to-screen mapping for one viewport. The canonical 256x192
-- surface is scaled by the resolved field pixel scale used for world
-- presentation —
-- and bottom-centered in the 4:3 referenceFrame, so zoom and resize
-- compensation affect world and field-attached UI together and wide hosts
-- keep the UI inside the canonical frame. All geometry is returned in
-- reference-canvas coordinates; the renderer applies origin + scale once.
-- Never return screen-mapped rects here: draw() applies the transform, and
-- double mapping pushes the box off-screen.

---@param referenceFrame unknown
---@param fieldScale number resolved field pixel scale, must be finite > 0
---@param cursorPlacement? FieldDialogueTheme.Rect generated source cursor placement for dialogue rendering
---@return FieldDialogueTheme.Layout
function FieldDialogueTheme.layout(referenceFrame, fieldScale, cursorPlacement)
  assert(
    type(referenceFrame) == "table"
      and type(referenceFrame.x) == "number"
      and type(referenceFrame.y) == "number"
      and type(referenceFrame.width) == "number"
      and type(referenceFrame.height) == "number"
      and referenceFrame.width > 0
      and referenceFrame.height > 0,
    "FieldDialogueTheme.layout requires a reference frame"
  )
  ---@cast referenceFrame FieldDialogueTheme.Rect
  assert(
    type(fieldScale) == "number"
      and fieldScale > 0
      and fieldScale == fieldScale
      and fieldScale ~= math.huge
      and fieldScale ~= -math.huge,
    "FieldDialogueTheme.layout requires a finite positive field scale"
  )
  local scale = fieldScale
  local origin = {
    x = referenceFrame.x + (referenceFrame.width - FieldDialogueTheme.referenceWidth * scale) / 2,
    y = referenceFrame.y + referenceFrame.height - FieldDialogueTheme.referenceHeight * scale,
  }
  local box = {
    x = FieldDialogueTheme.box.x,
    y = FieldDialogueTheme.box.y,
    width = FieldDialogueTheme.box.width,
    height = FieldDialogueTheme.box.height,
  }
  local text = {
    x = box.x + FieldDialogueTheme.textInsetX,
    y = box.y + FieldDialogueTheme.textInsetY,
    width = FieldDialogueTheme.textWidth,
    height = FieldDialogueTheme.textHeight,
  }
  local cursor
  if cursorPlacement ~= nil then
    assert(
      type(cursorPlacement) == "table"
        and type(cursorPlacement.x) == "number"
        and type(cursorPlacement.y) == "number"
        and type(cursorPlacement.width) == "number"
        and type(cursorPlacement.height) == "number"
        and cursorPlacement.width > 0
        and cursorPlacement.height > 0,
      "FieldDialogueTheme.layout requires a generated cursor placement"
    )
    cursor = {
      x = cursorPlacement.x,
      y = cursorPlacement.y,
      width = cursorPlacement.width,
      height = cursorPlacement.height,
    }
  end
  return {
    scale = scale,
    origin = origin,
    box = box,
    text = text,
    lineHeight = FieldDialogueTheme.lineHeight,
    cursor = cursor,
  }
end

-- The layout metrics object the paginator consumes: glyph advances from the
-- generated font definition, falling back to the compiled fallback glyph.
-- Control tokens carry no width: none of the controls implemented today has
-- spatial semantics, and the serialized marker spelling is not presentation
-- geometry. Returns a table with glyphWidth(code) only.

---@param fontDef FieldFontDef
---@return FieldDialogueTheme.Metrics
function FieldDialogueTheme.fontMetrics(fontDef)
  assert(
    type(fontDef) == "table" and type(fontDef.glyphs) == "table",
    "font metrics require a compiled field-font definition"
  )
  local function glyphWidth(code)
    local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
    return glyph and glyph.advance
  end
  return {
    glyphWidth = glyphWidth,
    lineHeight = fontDef.lineHeight or FieldDialogueTheme.lineHeight,
    lineSpacing = 0,
  }
end

-- Returns the field font's actual glyph-advance measurement for one text
-- string. Menu layout consumes this separately from dialogue token layout.
---@param fontDef FieldFontDef
---@return fun(text: string): number
function FieldDialogueTheme.measureText(fontDef)
  assert(
    type(fontDef) == "table" and type(fontDef.glyphs) == "table" and type(fontDef.charmap) == "table",
    "font text measurement requires a compiled field-font definition"
  )
  local function measureText(text)
    assert(type(text) == "string", "text measurement requires a string")
    local measured = 0
    for char in Utf8Glyphs.iter(text) do
      local code = fontDef.charmap[char] or 0
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      measured = measured + (glyph and glyph.advance or 0) + (fontDef.letterSpacing or 0)
    end
    return measured
  end
  return measureText
end

-- Reference-canvas rectangle.

---@class FieldDialogueTheme.Rect
---@field x number
---@field y number
---@field width number
---@field height number

-- Reference-space geometry plus the single origin/scale mapping to the
-- viewport's reference frame.

---@class FieldDialogueTheme.Layout
---@field scale number
---@field origin { x: number, y: number }
---@field box FieldDialogueTheme.Rect
---@field text FieldDialogueTheme.Rect
---@field lineHeight number
---@field cursor FieldDialogueTheme.Rect?

-- Metrics consumed by DialogueLayout: glyph advances from the generated font
-- definition. Non-glyph tokens get no width here, so DialogueLayout measures
-- them as widthless.

---@class FieldDialogueTheme.Metrics
---@field glyphWidth fun(code: integer): integer?
---@field lineHeight integer
---@field lineSpacing integer

return FieldDialogueTheme
