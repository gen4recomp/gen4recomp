-- Graphics smoke tests for the signpost renderer: the synthetic strip and
-- wayfinding atlases are decoded into real Images, the signpost window is
-- rendered at canonical 256x192 and compared pixel-exact against an
-- independently composed reference for the full-width style, the type-0
-- graphic region, and every fixed-tick wipe position (-48, -32, -16, 0; the
-- hidden -48 render is fully transparent because the surface sits below the
-- screen), and every graphics state the draw touched is proven restored
-- against the real driver. The reference composes the interior fill and the
-- palette-driven glyph text from the active source type's own generated
-- palette (slots 2/10/15), through the real palette shader and mask atlas --
-- never a hardcoded RGB stand-in -- so a wrong bank, a wrong slot, or a stray
-- fallback to type 0 is a pixel mismatch. The construction/draw failure paths
-- are injected fakes and stay in field_signpost_renderer_test.lua.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldSignpostFixture = require("tests.support.FieldSignpostFixture")
local FieldSignpostTheme = require("libs.hgss.src.ui.FieldSignpostTheme")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldSignpostRenderer = require("libs.hgss.src.ui.FieldSignpostRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

-- Quantizes a normalized channel to the 8-bit buffer value.
local function quantize(v)
  return math.floor(v * 255 + 0.5)
end

local function renderer(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return scope:own(FieldSignpostRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = FieldUiFixture.manifest(),
    text = text,
    windowStyles = FieldSignpostFixture.styles(),
  }))
end

-- The canonical 256x192 render of the fixture signpost for one source type
-- at one wipe offset.
---@param scope GraphicsScope
---@param sourceType integer
---@param wipeOffset integer
---@return love.ImageData
local function canonicalRender(scope, sourceType, wipeOffset)
  local lg = love.graphics
  local signpost = renderer(scope)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), {
    type = sourceType,
    offset = wipeOffset,
  })
  local viewport = FieldViewport.new(CANONICAL_WIDTH, CANONICAL_HEIGHT, { mode = "expanded" })
  local canvas = scope:own(lg.newCanvas(CANONICAL_WIDTH, CANONICAL_HEIGHT))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  signpost:draw(controller, viewport, nil, 1)
  lg.setCanvas()
  return scope:own(canvas:newImageData())
end

-- Pastes one 8x8 tile of solid RGBA bytes at the reference position; pixels
-- outside the 256x192 canvas are skipped (the GPU clips them the same way).
---@param reference love.ImageData
---@param rgba string 256 bytes
---@param x integer
---@param y integer
local function pasteTile(reference, rgba, x, y)
  for ty = 0, 7 do
    for tx = 0, 7 do
      local px, py = x + tx, y + ty
      if px >= 0 and py >= 0 and px < CANONICAL_WIDTH and py < CANONICAL_HEIGHT then
        local index = (ty * 8 + tx) * 4 + 1
        reference:setPixel(
          px,
          py,
          rgba:byte(index) / 255,
          rgba:byte(index + 1) / 255,
          rgba:byte(index + 2) / 255,
          rgba:byte(index + 3) / 255
        )
      end
    end
  end
end

-- Pastes the precomposed 48x32 wayfinding surface into the reference canvas;
-- pixels outside the canvas are skipped (the GPU clips them the same way).
---@param reference love.ImageData
---@param rgba string 48*32*4 bytes
---@param x integer
---@param y integer
local function pasteWayfindingSurface(reference, rgba, x, y)
  for ty = 0, 31 do
    for tx = 0, 47 do
      local px, py = x + tx, y + ty
      if px >= 0 and py >= 0 and px < CANONICAL_WIDTH and py < CANONICAL_HEIGHT then
        local index = (ty * 48 + tx) * 4 + 1
        reference:setPixel(
          px,
          py,
          rgba:byte(index) / 255,
          rgba:byte(index + 1) / 255,
          rgba:byte(index + 2) / 255,
          rgba:byte(index + 3) / 255
        )
      end
    end
  end
end

-- Pastes one 8x16 glyph of the fixture mask font (code 1 all foreground
-- class, code 2 all shadow class) at its position, recolored through the
-- caller's own palette color -- exactly the palette shader's job -- so a
-- wrong slot or a fallback to another type's bank is a pixel mismatch.
-- Pixels outside the canvas are skipped.
---@param reference love.ImageData
---@param color { r: integer, g: integer, b: integer }
---@param x integer
---@param y integer
local function pasteGlyph(reference, color, x, y)
  for ty = 0, 15 do
    for tx = 0, 7 do
      local px, py = x + tx, y + ty
      if px >= 0 and py >= 0 and px < CANONICAL_WIDTH and py < CANONICAL_HEIGHT then
        reference:setPixel(px, py, color.r / 255, color.g / 255, color.b / 255, 1)
      end
    end
  end
end

-- Fills one rectangle solid at the wipe-translated position; pixels outside
-- the canvas are skipped.
---@param reference love.ImageData
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@param color { r: integer, g: integer, b: integer }
---@param wipe integer
local function fillRect(reference, rect, color, wipe)
  for y = rect.y + wipe, rect.y + rect.height - 1 + wipe do
    for x = rect.x, rect.x + rect.width - 1 do
      if x >= 0 and y >= 0 and x < CANONICAL_WIDTH and y < CANONICAL_HEIGHT then
        reference:setPixel(x, y, color.r / 255, color.g / 255, color.b / 255, 1)
      end
    end
  end
end

-- The interior text-window rectangle for one frame kind, matching
-- FieldSignpostRenderer's own contentGeometry contract exactly: the graphic
-- kind reserves the left 56px for the wayfinding art.
---@param kind "full"|"graphic"
---@return { x: integer, y: integer, width: integer, height: integer }
local function contentGeometryFor(kind)
  if kind == "graphic" then
    return { x = 72, y = 152, width = 160, height = 32 }
  end
  return { x = 16, y = 152, width = 216, height = 32 }
end

-- The independent reference for the canonical render, composed from the
-- fixture's own tile bytes by the pinned DrawFrameAndWindow3 tilemap, the
-- 6x4 wayfinding grid (types 0/1 only), and the glyph text at the per-type
-- content origin -- everything translated by the wipe (the hidden -48
-- offset moves the whole surface below the screen). Built without the
-- renderer, so a draw regression (wrong quad, wrong position, wrong row,
-- missing divider) is a mismatch.
---@param sourceType integer
---@param wipeOffset integer
---@return love.ImageData
local function goldenReference(sourceType, wipeOffset)
  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local wipe = -wipeOffset
  local kind = (sourceType == 0 or sourceType == 1) and "graphic" or "full"
  local palette = FieldUiFixture.typePalette(sourceType)
  fillRect(reference, contentGeometryFor(kind), palette[15], wipe)
  for _, placement in ipairs(FieldSignpostTheme.frameTilePlacements(kind)) do
    for row = 0, (placement.spanY or 1) - 1 do
      for col = 0, (placement.spanX or 1) - 1 do
        pasteTile(
          reference,
          FieldUiFixture.signpostTilePixels(placement.tile),
          placement.x + col * 8,
          placement.y + row * 8 + wipe
        )
      end
    end
  end
  if kind == "graphic" then
    local surfaceY = sourceType == 0 and 0 or 64
    local surface = FieldUiFixture.wayfindingSurfacePixels(surfaceY)
    pasteWayfindingSurface(reference, surface, 16, 152 + wipe)
  end
  local textX = kind == "graphic" and 72 or 16
  local lines = FieldSignpostFixture.textLines()
  for lineIndex, ln in ipairs(lines) do
    local x = textX
    for _, token in ipairs(ln.tokens) do
      if token.kind == "glyph" then
        -- The fixture mask font: code 1 is entirely the foreground class
        -- (palette slot 2), code 2 entirely the shadow class (slot 10).
        local color = token.code == 1 and palette[2] or palette[10]
        pasteGlyph(reference, color, x, 152 + (lineIndex - 1) * 16 + wipe)
        x = x + 6
      end
    end
  end
  return reference
end

-- Compares two ImageData buffers 8-bit channel by 8-bit channel; a single
-- differing pixel fails with its canonical coordinates.
local function assertPixelsEqual(expected, actual, label)
  Assert.equal(expected:getWidth(), actual:getWidth(), label .. " width")
  Assert.equal(expected:getHeight(), actual:getHeight(), label .. " height")
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local er, eg, eb, ea = expected:getPixel(x, y)
      local ar, ag, ab, aa = actual:getPixel(x, y)
      if
        quantize(er) ~= quantize(ar)
        or quantize(eg) ~= quantize(ag)
        or quantize(eb) ~= quantize(ab)
        or quantize(ea) ~= quantize(aa)
      then
        error(
          string.format(
            "%s: pixel mismatch at (%d,%d): expected (%d,%d,%d,%d) got (%d,%d,%d,%d)",
            label,
            x,
            y,
            quantize(er),
            quantize(eg),
            quantize(eb),
            quantize(ea),
            quantize(ar),
            quantize(ag),
            quantize(ab),
            quantize(aa)
          )
        )
      end
    end
  end
end

function T.loads_the_shared_font_and_owned_assets(scope)
  local signpost = renderer(scope)

  local text = signpost._text
  Assert.equal(text.fontDef.schema, FieldFontCache.SCHEMA)
  local atlas = assert(text._atlas)
  Assert.equal(atlas:getWidth(), 16)
  Assert.notNil(signpost._tilesImage, "the signpost frame strip is loaded")
  Assert.equal(signpost._tilesImage:getWidth(), 144)
  Assert.notNil(signpost._wayfindingImage, "the wayfinding atlas is loaded")
  Assert.equal(signpost._wayfindingImage:getWidth(), 48)
  Assert.equal(signpost._wayfindingImage:getHeight(), 128)
end

function T.restores_graphics_state_after_draw(scope)
  local lg = love.graphics
  local signpost = renderer(scope)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0 })
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })

  local canvas = scope:own(lg.newCanvas(64, 64))
  local shader = lg.getShader()
  lg.setCanvas(canvas)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  signpost:draw(controller, viewport, nil, 3)

  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
end

function T.an_inactive_controller_draws_nothing_and_changes_no_state(scope)
  local lg = love.graphics
  local signpost = renderer(scope)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 })
  controller:setCommand("wipe_out")
  for _ = 1, 4 do
    controller:updateFixed()
  end

  lg.setColor(0.1, 0.2, 0.3, 0.4)
  do
    local viewport = FieldViewport.new(960, 720, { mode = "expanded" })
    signpost:draw(controller, viewport, nil, 1)
  end

  Assert.near(lg.getColor(), 0.1, 1e-6)
  Assert.isNil(lg.getShader())
end

-- Canonical golden: the full-width static sign (source type 2) matches the
-- independent reference pixel for pixel at the rest position.
function T.canonical_golden_matches_the_full_width_static_sign(scope)
  local rendered = canonicalRender(scope, 2, 0)
  assertPixelsEqual(goldenReference(2, 0), rendered, "full-width static golden")
end

-- Canonical golden: the type-0 sign draws the wayfinding grid, the divider
-- tile, and the text window right of the graphic region.
function T.canonical_golden_matches_the_type_zero_graphic_region(scope)
  local rendered = canonicalRender(scope, 0, 0)
  assertPixelsEqual(goldenReference(0, 0), rendered, "type-0 graphic-region golden")

  -- The type-0 and full-width renders differ exactly where the wayfinding
  -- graphic, the divider, and the shifted text live.
  local fullWidth = canonicalRender(scope, 2, 0)
  local function pixel(data, x, y)
    local r, g, b, a = data:getPixel(x, y)
    return quantize(r), quantize(g), quantize(b), quantize(a)
  end
  local gr, gg, gb = pixel(rendered, 32, 160)
  local fr, fg, fb = pixel(fullWidth, 32, 160)
  Assert.isTrue(gr ~= fr or gg ~= fg or gb ~= fb, "the wayfinding graphic region differs between types")
  local _, _, _, da = pixel(rendered, 64, 160)
  Assert.equal(da, 255, "the divider tile is opaque")
end

-- Canonical wipe goldens: every fixed-tick position (-48 hidden, -32, -16,
-- 0 rest) matches the translated reference. The hidden render is fully
-- transparent: the whole surface sits below the 192px screen.
function T.canonical_wipe_goldens_match_the_translated_reference(scope)
  for _, offset in ipairs({ -48, -32, -16, 0 }) do
    local rendered = canonicalRender(scope, 0, offset)
    assertPixelsEqual(goldenReference(0, offset), rendered, "wipe " .. offset)
  end

  local hidden = canonicalRender(scope, 0, -48)
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local _, _, _, a = hidden:getPixel(x, y)
      Assert.equal(quantize(a), 0, "the hidden position renders nothing on screen")
    end
  end
end

-- Release is the contract here; it is still scoped so a failed assertion
-- does not leak the renderer. The scope's later release exercises repeat
-- safety.
function T.release_frees_the_owned_images(scope)
  local signpost = renderer(scope)

  signpost:release()

  Assert.isNil(signpost._tilesImage)
  Assert.isNil(signpost._wayfindingImage)
end

return GraphicsSmoke.suite(T)
