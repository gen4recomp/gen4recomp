-- Headless theme geometry tests: the dialogue box is the canonical HGSS
-- content rect 16,152,216,32 (2/19/27/4 tiles at 8px) inside the centered
-- 4:3 reference canvas at 4:3, 16:9, and ultrawide aspects, with constant
-- reference-space dimensions and two full 16px text lines inside the 32px
-- height. Layout returns reference-canvas geometry plus one origin/scale
-- mapping; the renderer applies that transform itself, so layout rects
-- always stay in reference space. Production-metrics coverage at the bottom
-- proves the theme's font metrics feed the paginator without marker-string
-- width: style controls leave layout unchanged and resolved substitutions
-- keep their replacement glyph advances.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DialogueLayout = require("libs.hgss.src.ui.DialogueLayout")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}

local function frame(width, height)
  return FieldViewport.new(width, height, { mode = "expanded" }).referenceFrame
end

-- The reference-space box must stay inside the reference canvas at every
-- host aspect: the renderer draws it under one origin+scale transform, so a
-- screen-mapped rect here would be scaled twice and pushed off-screen.
local function assertBoxInsideReferenceCanvas(layout, label)
  local box = layout.box
  Assert.isTrue(box.x >= 0 and box.y >= 0, label .. " box in reference space")
  Assert.isTrue(box.x + box.width <= FieldDialogueTheme.referenceWidth + 1e-9, label .. " box inside canvas width")
  Assert.isTrue(box.y + box.height <= FieldDialogueTheme.referenceHeight + 1e-9, label .. " box inside canvas height")
end

function T.box_is_the_canonical_hgss_content_rect()
  local box = FieldDialogueTheme.box
  Assert.deepEqual(box, { x = 16, y = 152, width = 216, height = 32 }, "canonical dialogue content rect")
  -- Two 16px text lines fit exactly inside the 32px content height.
  Assert.isTrue(
    FieldDialogueTheme.textInsetY * 2 + FieldDialogueTheme.lineHeight * FieldDialogueTheme.maxLines <= box.height,
    "two 16px lines fit in the content height"
  )
  -- The text area stays inside the box horizontally.
  Assert.isTrue(
    FieldDialogueTheme.textInsetX * 2 + FieldDialogueTheme.textWidth <= box.width,
    "text area inside the box"
  )
end

-- The renderer draws under one translate(origin)+scale transform, so layout
-- geometry must stay in reference-canvas coordinates at every host aspect;
-- screen-mapped output there would be scaled twice and pushed off-screen.
function T.reference_geometry_stays_in_reference_canvas()
  for _, size in ipairs({ { 960, 720 }, { 1280, 720 }, { 1920, 720 } }) do
    local ref = frame(size[1], size[2])
    local layout = FieldDialogueTheme.layout(ref, ref.height / 192)
    Assert.isTrue(layout.box.x >= 0 and layout.box.y >= 0, "box in reference space")
    Assert.isTrue(layout.box.x + layout.box.width <= FieldDialogueTheme.referenceWidth + 1e-9)
    Assert.isTrue(layout.box.y + layout.box.height <= FieldDialogueTheme.referenceHeight + 1e-9)
    Assert.isTrue(
      layout.text.y >= layout.box.y and layout.text.y + layout.text.height <= layout.box.y + layout.box.height + 1e-9,
      "text area inside the box"
    )
  end
end

function T.layout_maps_inside_the_reference_frame_at_43()
  local ref = frame(960, 720)
  local layout = FieldDialogueTheme.layout(ref, ref.height / 192)
  Assert.near(layout.scale, 720 / 192)
  Assert.deepEqual(layout.origin, { x = 0, y = 0 })
  assertBoxInsideReferenceCanvas(layout, "4:3")
end

function T.layout_maps_inside_the_centered_frame_at_169()
  local reference = frame(1280, 720)
  Assert.near(reference.width, 720 * 4 / 3)
  Assert.near(reference.x, (1280 - reference.width) / 2)
  assertBoxInsideReferenceCanvas(FieldDialogueTheme.layout(reference, reference.height / 192), "16:9")
end

function T.layout_maps_inside_the_centered_frame_ultrawide()
  local reference = frame(1920, 720)
  local layout = FieldDialogueTheme.layout(reference, reference.height / 192)
  Assert.near(reference.x, (1920 - reference.width) / 2)
  assertBoxInsideReferenceCanvas(layout, "ultrawide")
end

function T.text_area_fits_two_lines_of_font_height()
  local ref = frame(960, 720)
  local layout = FieldDialogueTheme.layout(ref, ref.height / 192)
  local text = layout.text
  local box = layout.box
  Assert.isTrue(
    text.y + layout.lineHeight * FieldDialogueTheme.maxLines <= box.y + box.height + 1e-9,
    "two lines fit the content height"
  )
  Assert.near(text.width, FieldDialogueTheme.textWidth)
end

-- The frame tilemap is the audited DrawFrameAndWindow2 composition
-- (asm/render_window.s sub_0200E6B4 at the pinned decomp commit): the
-- window content box is 27x4 tiles at (2,19), and the frame fills the full
-- 256x192 reference canvas around it -- one tile above and below, two tiles
-- left, three right, all 18 strip tiles placed. Tiles are given in strip
-- order; a span entry repeats the tile across the named axis.
function T.frame_tile_placements_match_the_draw_frame_and_window2_composition()
  local placements = FieldDialogueTheme.frameTilePlacements(FieldDialogueTheme.box)
  Assert.deepEqual(placements, {
    { tile = 0, x = 0, y = 144 },
    { tile = 1, x = 8, y = 144 },
    { tile = 2, x = 16, y = 144, spanX = 27 },
    { tile = 3, x = 232, y = 144 },
    { tile = 4, x = 240, y = 144 },
    { tile = 5, x = 248, y = 144 },
    { tile = 6, x = 0, y = 152, spanY = 4 },
    { tile = 7, x = 8, y = 152, spanY = 4 },
    { tile = 9, x = 232, y = 152, spanY = 4 },
    { tile = 10, x = 240, y = 152, spanY = 4 },
    { tile = 11, x = 248, y = 152, spanY = 4 },
    { tile = 12, x = 0, y = 184 },
    { tile = 13, x = 8, y = 184 },
    { tile = 14, x = 16, y = 184, spanX = 27 },
    { tile = 15, x = 232, y = 184 },
    { tile = 16, x = 240, y = 184 },
    { tile = 17, x = 248, y = 184 },
  }, "frame tiles compose the window around the content box")
  -- The frame never covers the content region (16,152,216,32) and never
  -- escapes the 256x192 reference canvas.
  local box = FieldDialogueTheme.box
  local function overlaps(a, b)
    return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
  end
  for _, p in ipairs(placements) do
    local rect = { x = p.x, y = p.y, width = 8 * (p.spanX or 1), height = 8 * (p.spanY or 1) }
    Assert.isFalse(overlaps(rect, box), "frame tile " .. p.tile .. " must not cover the content rect")
    Assert.isTrue(rect.x >= 0 and rect.x + rect.width <= FieldDialogueTheme.referenceWidth, "tile inside canvas")
    Assert.isTrue(rect.y >= 0 and rect.y + rect.height <= FieldDialogueTheme.referenceHeight, "tile inside canvas")
  end
end

function T.font_metrics_resolve_advances_with_fallback()
  local fontDef = FieldUiFixture.cardFontDef()
  fontDef.glyphs[1].advance = 6
  fontDef.glyphs[0].advance = 4
  local metrics = FieldDialogueTheme.fontMetrics(fontDef)
  Assert.equal(metrics.glyphWidth(1), 6)
  Assert.equal(metrics.glyphWidth(99), 4, "unknown codes use the fallback glyph")
end

-- The visible glyph text of one laid-out line (non-glyph tokens skipped).
local function textOf(line)
  local out = {}
  for _, token in ipairs(line.tokens) do
    if token.kind == "glyph" then
      out[#out + 1] = token.text
    end
  end
  return table.concat(out)
end

-- Production metrics: FieldDialogueTheme.fontMetrics must not give a style
-- control a marker-string width, so [style-control, glyphs] lays out with the
-- same line widths and wrap positions as [glyphs] alone.
function T.style_controls_do_not_change_production_line_width_or_wrap()
  local def = FieldUiFixture.cardFontDef()
  local metrics = FieldDialogueTheme.fontMetrics(def)
  local glyphs = assert(FieldMessageProvider.asciiGlyphTokens("AAAA", def))
  local styled = { { kind = "style", control = 0xFF00, args = { 1 }, raw = { 0xFFFE, 0xFF00, 1, 1 } } }
  for i, token in ipairs(glyphs) do
    styled[i + 1] = token
  end
  -- "AAAA" (4 x 8px) exceeds the 24px line: the wrap must land identically.
  local opts = { width = 24, maxLines = 2 }
  local withControl = DialogueLayout.layout(styled, metrics, opts)
  local alone = DialogueLayout.layout(glyphs, metrics, opts)
  Assert.equal(#withControl.pages, #alone.pages, "the style control adds no page")
  for p = 1, #alone.pages do
    Assert.equal(#withControl.pages[p].lines, #alone.pages[p].lines, "page " .. p .. " wraps identically")
    for l = 1, #alone.pages[p].lines do
      Assert.equal(withControl.pages[p].lines[l].width, alone.pages[p].lines[l].width)
      Assert.equal(textOf(withControl.pages[p].lines[l]), textOf(alone.pages[p].lines[l]))
    end
  end
end

-- Production metrics: a resolved player-name substitution splices real glyph
-- tokens into the stream (FieldMessageProvider:format + asciiGlyphTokens), and
-- those replacement glyphs contribute their actual advances -- the fixture's
-- multibyte É contributes 6, each ASCII letter 8 -- never a marker width.
function T.resolved_substitutions_contribute_replacement_glyph_widths()
  local def = FieldUiFixture.cardFontDefWithMultibyte()
  local provider = FieldMessageProvider.new(CacheFs.forVersion("heartgold", FakeCache.new()))
  local name = "\195\137" .. "GOLD" -- ÉGOLD
  local formatted = provider:format({
    bankId = 0,
    messageId = 0,
    tokens = {
      { kind = "substitution", control = 0x0103, args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 0x0002, 0, 0 } },
      { kind = "eos", raw = { 0xFFFF } },
    },
  }, { playerName = name }, {
    [0x0103] = function()
      return FieldMessageProvider.asciiGlyphTokens(name, def)
    end,
  })
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
  local layout = DialogueLayout.layout(
    formatted.tokens,
    FieldDialogueTheme.fontMetrics(def),
    { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
  )
  Assert.equal(#layout.pages, 1)
  local line = layout.pages[1].lines[1]
  -- É (6) + G O L D (4 x 8) = 38
  Assert.equal(line.width, 6 + 4 * 8, "replacement glyphs keep their real advances")
  local codes = {}
  for _, token in ipairs(line.tokens) do
    codes[token.code] = true
  end
  Assert.isTrue(codes[360], "the resolved multibyte glyph rides in the laid-out line")
end

-- Static application boxes decorate content with one exterior 8px side
-- tile and one full side tile overlapping the body so edge motifs are never
-- cut, and 5px caps hugging their edge rows with thicker art overlapping
-- one pixel onto the content (the frame draws after content, so
-- transparent texels reveal it). Only border art is addressed (the
-- tiles' interior fill never paints); the body sits inside the exterior
-- room only on the outer side tiles.
function T.application_frame_insets_follow_border_thickness()
  local insets = FieldDialogueTheme.applicationFrameInsets()
  Assert.deepEqual(insets, { left = 8, top = 7, right = 8, bottom = 7 }, "inner side tiles overlap the body")
  Assert.isTrue(insets ~= FieldDialogueTheme.applicationFrameInsets(), "insets are fresh records")
end

-- Direct edge targets derive from the audited standard tilemap: the
-- side bands reuse the full source side columns (tiles 6 and 7 down
-- the target left, then mirrored on the right) with no cropping, stepping a full tile every 8px so edge
-- motifs render whole; each cap reuses its own source edge row in 8px
-- cells (top: corners 0/5 with span 2 above the body, bottom: corners
-- 12/17 with span 14 below), the 6px art overlapping one pixel onto the
-- content. Corners land exactly under their side bands and cover the
-- span ends. One side tile sits outside the exterior silhouette and the
-- other overlaps the body.
function T.application_frame_tiles_reuse_standard_edges_directly()
  local box = { x = 0, y = 24, width = 256, height = 192 }
  local groups = FieldDialogueTheme.applicationFrameTilePlacements(box)
  Assert.isTrue(
    type(groups.top) == "table" and type(groups.bottom) == "table" and type(groups.sides) == "table",
    "top, bottom, and sides group the frame"
  )
  local groupKeys = {}
  for key in pairs(groups) do
    groupKeys[#groupKeys + 1] = key
  end
  table.sort(groupKeys)
  Assert.deepEqual(groupKeys, { "bottom", "sides", "top" }, "exactly the caps and the sides")
  -- The caps extend one tile past the body and the inner side tiles
  -- overlap it. The right half mirrors the left source, so no side tile is
  -- cropped.
  local outerX = box.x - 8
  local capY = box.y + box.height
  local bottomY = capY - 1
  local rightX = box.x + box.width
  local corners = 0
  local middles = 0
  for _, entry in ipairs(groups.bottom) do
    Assert.isTrue(type(entry.x) == "number" and type(entry.y) == "number", "tiles carry target positions")
    Assert.equal(entry.y, bottomY, "every bottom cell shares the cap row")
    Assert.isTrue(entry.x >= outerX and entry.x <= rightX, "cap cells span the side geometry")
    if entry.tile == 12 or entry.tile == 13 then
      corners = corners + 1
    else
      Assert.equal(entry.tile, 14, "cap middles reuse the source bottom span")
      Assert.isTrue(entry.x >= box.x and entry.x < box.x + box.width, "middles run between corners")
      Assert.equal((entry.x - box.x) % 8, 0, "middles step every 8px")
      middles = middles + 1
    end
  end
  Assert.equal(corners, 4, "the bottom cap keeps both source tiles per corner")
  Assert.equal(middles, box.width / 8, "the span tiles the body width exactly")
  -- The top cap follows the bottom layout with the source top row: 8px
  -- corners plus the top span in exact 8px steps directly above the body,
  -- gapless across the same outer width.
  local topY = box.y - 7
  local topCorners = 0
  local topMiddles = 0
  for _, entry in ipairs(groups.top) do
    Assert.isTrue(type(entry.x) == "number" and type(entry.y) == "number", "top tiles carry target positions")
    Assert.equal(entry.y, topY, "top cells sit on the top row")
    Assert.isTrue(entry.x >= outerX and entry.x <= rightX, "top cells span the side geometry")
    if entry.tile == 0 or entry.tile == 1 then
      topCorners = topCorners + 1
    else
      Assert.equal(entry.tile, 2, "top middles reuse the source top span")
      Assert.isTrue(entry.x >= box.x and entry.x < box.x + box.width, "top middles run between corners")
      Assert.equal((entry.x - box.x) % 8, 0, "top middles step every 8px")
      topMiddles = topMiddles + 1
    end
  end
  Assert.equal(topCorners, 4, "the top cap keeps both source tiles per corner")
  Assert.equal(topMiddles, box.width / 8, "the top span tiles the body width exactly")
  Assert.equal(#groups.top, #groups.bottom, "the caps carry the same cell count")
  -- Both cap rows cover the complete body width plus their 8px corner
  -- cells.
  for _, list in ipairs({ groups.bottom, groups.top }) do
    for x = outerX, rightX + 7 do
      local covered = false
      for _, entry in ipairs(list) do
        if x >= entry.x and x < entry.x + 8 then
          covered = true
          break
        end
      end
      Assert.isTrue(covered, "the cap row covers column " .. x)
    end
  end
  -- Full side tiles step every 8px down the body and end exactly at the
  -- bottom cap's content boundary.
  local leftCount, rightCount = 0, 0
  for _, entry in ipairs(groups.sides) do
    Assert.isTrue(entry.y >= box.y and entry.y + 8 <= box.y + box.height, "side tiles end at the bottom corners")
    if entry.x < box.x + box.width / 2 then
      Assert.isTrue(entry.x == box.x - 8 or entry.x == box.x, "left keeps both dialogue columns")
      Assert.isTrue(entry.tile == 6 or entry.tile == 7, "the left band keeps the dialogue source")
      Assert.equal((entry.y - box.y) % 8, 0, "left tiles step every 8px")
      leftCount = leftCount + 1
    else
      Assert.isTrue(entry.x == box.x + box.width - 8 or entry.x == box.x + box.width, "right mirrors both left columns")
      Assert.isTrue(entry.tile == 6 or entry.tile == 7, "the right band mirrors the dialogue source")
      Assert.isTrue(entry.flipX, "the right band flips the source")
      Assert.equal((entry.y - box.y) % 8, 0, "right tiles step every 8px")
      rightCount = rightCount + 1
    end
  end
  Assert.equal(leftCount, 2 * box.height / 8, "two dialogue columns tile the left")
  Assert.equal(rightCount, 2 * box.height / 8, "two mirrored columns tile the right")
end
-- The inset frame box only needs 8px-compatible integral content: with no
-- overlap there is no minimum body size, but ragged content cannot tile.
function T.application_frame_tiles_reject_content_without_tile_room()
  local groups = FieldDialogueTheme.applicationFrameTilePlacements({ x = 0, y = 24, width = 16, height = 16 })
  Assert.isTrue(#groups.top > 0 and #groups.bottom > 0 and #groups.sides > 0, "a two-tile body still frames")
  Assert.throws(function()
    FieldDialogueTheme.applicationFrameTilePlacements({ x = 0, y = 24, width = 250, height = 192 })
  end, "a ragged body cannot tile")
end

return { tests = T }
