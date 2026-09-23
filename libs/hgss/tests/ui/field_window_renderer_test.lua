-- Static HGSS user-frame presentation primitive shared by field dialogue
-- and the starter chooser: one owner for the generated dialogue frame-strip
-- image, its lazily built per-frame tile quads, and the content-background
-- fill behind a supplied content box. It owns no modal, controller, cursor,
-- or text lifecycle; callers supply the frame index, the content box, and
-- the background color.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local fakeGraphics = require("tests.support.FakeGraphics").new

local function windowRenderer()
  local ok, module = pcall(require, "libs.hgss.src.ui.FieldWindowRenderer")
  if not ok then
    error("the shared window-frame primitive is missing: " .. tostring(module), 0)
  end
  return module
end

local function openWindow(lg, manifest, cache)
  local FieldWindowRenderer = windowRenderer()
  return FieldWindowRenderer.new({
    cacheFs = cache or FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest or FieldUiFixture.manifest(),
    graphics = lg,
  })
end

local function syntheticImageData(width, height)
  local pixels = {}
  for y = 0, height - 1 do
    pixels[y] = {}
    for x = 0, width - 1 do
      pixels[y][x] = { 0, 0, 0, 0 }
    end
  end
  return {
    getWidth = function()
      return width
    end,
    getHeight = function()
      return height
    end,
    getPixel = function(_, x, y)
      return table.unpack(pixels[y][x])
    end,
    setPixel = function(_, x, y, r, g, b, a)
      pixels[y][x] = { r, g, b, a }
    end,
  }
end

local function paintRow(data, x0, x1, y, color)
  for x = x0, x1 do
    data:setPixel(x, y, color[1], color[2], color[3], color[4])
  end
end

local function paintColumn(data, x, y0, y1, color)
  for y = y0, y1 do
    data:setPixel(x, y, color[1], color[2], color[3], color[4])
  end
end

function T.keyed_copy_clears_only_menu_overlap_white()
  local FieldWindowRenderer = windowRenderer()
  local data = syntheticImageData(144, 8)
  local frames = { count = 1, frameTiles = { [0] = { x = 0, y = 0, width = 144, height = 8 } } }
  local white = { 1, 1, 1, 1 }
  local art = { 0.2, 0.4, 0.2, 1 }
  local border = { 0.1, 0.1, 0.1, 1 }
  -- Bottom span: fill rows over a border; only the menu-facing row clears.
  paintRow(data, 112, 119, 0, white)
  paintRow(data, 112, 119, 1, white)
  paintRow(data, 112, 119, 2, border)
  -- Side stripe with a white rim through all rows: fully exterior.
  paintColumn(data, 48, 0, 7, art)
  paintColumn(data, 49, 0, 7, art)
  paintColumn(data, 50, 0, 7, art)
  paintColumn(data, 51, 0, 7, art)
  paintColumn(data, 52, 0, 7, white)
  paintColumn(data, 53, 0, 7, art)
  paintColumn(data, 54, 0, 7, art)
  paintColumn(data, 55, 0, 7, art)
  -- Outer corner with edge-touching decoration white: fully exterior.
  paintRow(data, 96, 103, 0, art)
  paintRow(data, 96, 103, 1, art)
  paintRow(data, 96, 99, 2, art)
  paintRow(data, 100, 103, 2, white)
  paintRow(data, 96, 99, 3, art)
  paintRow(data, 100, 103, 3, white)
  -- Inner side column: fully over content, fill clears throughout.
  paintColumn(data, 56, 0, 7, art)
  paintColumn(data, 57, 0, 7, art)
  paintColumn(data, 58, 0, 7, white)
  paintColumn(data, 59, 0, 7, white)
  paintColumn(data, 60, 0, 7, white)
  paintColumn(data, 61, 0, 7, white)
  paintColumn(data, 62, 0, 7, white)
  paintColumn(data, 63, 0, 7, white)
  -- Top span: menu-facing row clears, exterior band stays.
  paintRow(data, 16, 23, 3, white)
  paintRow(data, 16, 23, 6, white)
  paintRow(data, 16, 23, 7, white)
  paintRow(data, 16, 23, 4, border)
  FieldWindowRenderer.keyApplicationCopy(data, frames)
  Assert.equal(select(4, data:getPixel(114, 0)), 0, "menu-facing span fill clears")
  Assert.equal(select(4, data:getPixel(114, 1)), 1, "exterior span fill stays opaque")
  Assert.equal(select(4, data:getPixel(52, 4)), 1, "exterior side rims stay opaque")
  Assert.equal(select(4, data:getPixel(101, 2)), 1, "exterior corner decoration stays opaque")
  Assert.equal(select(4, data:getPixel(60, 4)), 0, "inner side fill clears over content")
  Assert.equal(select(4, data:getPixel(18, 7)), 0, "menu-facing cap row clears")
  Assert.equal(select(4, data:getPixel(18, 3)), 1, "exterior cap bands stay opaque")
end

function T.keyed_copy_clears_only_edge_connected_fill()
  local FieldWindowRenderer = windowRenderer()
  local data = syntheticImageData(24, 8)
  local fill = { 1, 1, 1, 1 }
  local art = { 0.2, 0.4, 0.2, 1 }
  paintRow(data, 0, 7, 0, fill)
  paintRow(data, 0, 7, 1, art)
  data:setPixel(11, 3, fill[1], fill[2], fill[3], fill[4])
  data:setPixel(12, 3, fill[1], fill[2], fill[3], fill[4])
  data:setPixel(11, 4, fill[1], fill[2], fill[3], fill[4])
  data:setPixel(12, 4, fill[1], fill[2], fill[3], fill[4])
  paintRow(data, 16, 23, 6, art)
  FieldWindowRenderer.clearEdgeWhite(data, 0, 0)
  FieldWindowRenderer.clearEdgeWhite(data, 8, 0)
  FieldWindowRenderer.clearEdgeWhite(data, 16, 0)
  Assert.equal(select(4, data:getPixel(4, 0)), 0, "edge-connected fill becomes transparent")
  Assert.equal(select(4, data:getPixel(4, 1)), 1, "border art below the fill stays opaque")
  Assert.equal(select(4, data:getPixel(11, 3)), 1, "isolated interior white stays opaque")
  Assert.equal(select(4, data:getPixel(20, 6)), 1, "solid art without white stays opaque")
end

-- A frame-15-like bottom edge for alignment tests: the span tile carries
-- white fill rows over its border while the inner corner tile carries
-- opaque art in the same rows. Frame 1 stays solid grey.
local function patternedBottomStrip()
  local grey = { 100, 100, 100, 255 }
  local white = { 255, 255, 255, 255 }
  local dark = { 74, 66, 66, 255 }
  local blue = { 74, 115, 255, 255 }
  local orange = { 255, 132, 0, 255 }
  local yellow = { 255, 230, 25, 255 }
  local green = { 20, 120, 60, 255 }
  local clear = { 0, 0, 0, 0 }
  local grid = {}
  for y = 0, 15 do
    grid[y] = {}
    for x = 0, 143 do
      grid[y][x] = grey
    end
  end
  local function paint(x0, x1, y, color)
    for x = x0, x1 do
      grid[y][x] = color
    end
  end
  for y = 0, 2 do
    paint(112, 119, y, white)
    paint(104, 105, y, orange)
    paint(106, 108, y, yellow)
    paint(109, 111, y, white)
  end
  paint(112, 119, 3, dark)
  paint(112, 119, 4, blue)
  paint(112, 119, 5, dark)
  paint(112, 119, 6, clear)
  paint(112, 119, 7, clear)
  paint(104, 111, 3, dark)
  paint(104, 111, 4, blue)
  paint(104, 111, 5, dark)
  paint(104, 111, 6, clear)
  paint(104, 111, 7, clear)
  for y = 0, 7 do
    paint(96, 97, y, clear)
    paint(98, 103, y, green)
  end
  for y = 0, 7 do
    paint(48, 49, y, clear)
    paint(50, 55, y, green)
  end
  local parts = {}
  for y = 0, 15 do
    for x = 0, 143 do
      local color = grid[y][x]
      parts[#parts + 1] = string.char(color[1], color[2], color[3], color[4])
    end
  end
  return PngWriter.encode(144, 16, table.concat(parts))
end

local function cacheWithStrip(png)
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:write(FieldUiFixture.STRIP_PATH, png)
  return cache
end

function T.application_border_samples_whole_keyed_tiles()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local FieldWindowRenderer = windowRenderer()
  local window = FieldWindowRenderer.new({
    cacheFs = cacheWithStrip(patternedBottomStrip()),
    manifest = FieldUiFixture.manifest(),
    graphics = lg,
  })
  local function quadRect(tile)
    local quad = window:clipQuad(0, tile)
    return { quad.x, quad.y, quad.w, quad.h }
  end
  Assert.deepEqual(quadRect(6), { 48, 0, 8, 8 }, "the outer column keeps its tile: one band")
  Assert.deepEqual(quadRect(12), { 96, 0, 8, 8 }, "the outer corner keeps its full ornament")
  Assert.deepEqual(quadRect(14), { 112, 0, 8, 8 }, "the span keeps its full tile")
  local err = Assert.throws(function()
    window:clipQuad(0, 5)
  end)
  Assert.isTrue(tostring(err):find("carries no tile", 1, true) ~= nil, "off-tilemap tiles fail loudly")
  window:drawApplicationFrame({ x = 8, y = 24, width = 256, height = 192 }, 0)
  Assert.isTrue(#lg.draws > 0, "the frame draws its border tiles")
  local keyed = lg.images[2]
  for _, call in ipairs(lg.draws) do
    Assert.isTrue(call.image == keyed, "every application tile samples the keyed copy")
  end
  window:release()
end

function T.fill_and_frame_tiles_follow_the_shared_tilemap()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  window:drawWindow({ x = 16, y = 152, width = 216, height = 32 }, 0, { 0, 0, 0, 1 })
  Assert.equal(#lg.rectangles, 1, "the content background is filled once")
  Assert.equal(lg.rectangles[1].mode, "fill")
  Assert.deepEqual(
    { lg.rectangles[1].x, lg.rectangles[1].y, lg.rectangles[1].w, lg.rectangles[1].h },
    { 16, 152, 216, 32 },
    "the fill covers the supplied content box"
  )
  Assert.equal(lg.draws[1].x, 0, "top-left corner tile at (0,144)")
  Assert.equal(lg.draws[1].y, 144)
  Assert.deepEqual(
    { lg.draws[1].quad.x, lg.draws[1].quad.y, lg.draws[1].quad.w, lg.draws[1].quad.h },
    { 0, 0, 8, 8 },
    "tile 0 samples the strip first row"
  )
  local topEdge, expectedX = 0, 16
  for _, call in ipairs(lg.draws) do
    if call.quad.x == 16 and call.quad.y == 0 then
      topEdge = topEdge + 1
      Assert.equal(call.x, expectedX, "top edge tile spans x=16..232")
      Assert.equal(call.y, 144)
      expectedX = expectedX + 8
    end
  end
  Assert.equal(topEdge, 27, "the top edge repeats across 27 tiles")
  window:release()
end

function T.frame_index_selects_the_manifest_strip_row_without_moving_geometry()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  window:drawWindow({ x = 16, y = 152, width = 216, height = 32 }, 1, { 0, 0, 0, 1 })
  Assert.deepEqual({ lg.draws[1].quad.x, lg.draws[1].quad.y }, { 0, 8 }, "frame 1 samples the second strip row")
  Assert.equal(lg.draws[1].x, 0)
  Assert.equal(lg.draws[1].y, 144, "frame change moves artwork, not geometry")
  window:release()
end

function T.missing_frame_strip_is_a_typed_error_without_acquiring()
  local FieldWindowRenderer = windowRenderer()
  local lg = fakeGraphics()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:remove(FieldUiFixture.STRIP_PATH)
  local err = Assert.throws(function()
    FieldWindowRenderer.new({ cacheFs = cache, manifest = FieldUiFixture.manifest(), graphics = lg })
  end)
  local Errors = require("libs.errors.src.Errors")
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_UI_FRAME_ATLAS_MISSING", "raises FIELD_UI_FRAME_ATLAS_MISSING")
  Assert.equal(#lg.images, 0, "no image is acquired before the strip read fails")
end

function T.release_is_idempotent_and_safe_before_draw()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  window:release()
  window:release()
end

function T.unknown_frame_index_fails_loudly()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  local err = Assert.throws(function()
    window:drawWindow({ x = 16, y = 152, width = 216, height = 32 }, 9, { 0, 0, 0, 1 })
  end)
  Assert.isTrue(tostring(err):find("outside the generated frame set", 1, true) ~= nil)
  window:release()
end

-- The application frame draws only border art around the content box:
-- direct side, bottom-cap, and top-cap tiles from the shared grouped
-- tilemap, sampling the selected dialogue strip row with identity tint.
-- Every tile blits directly with no artwork rotation: the sides reuse
-- the source side columns, each cap its own source edge row. Every
-- addressed quad keeps only its outer border columns or rows, never the
-- tiles' interior fill. No graphics transform is borrowed.
function T.application_frame_draws_only_the_direct_selected_border()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  local box = { x = 8, y = 24, width = 256, height = 192 }
  window:drawApplicationFrame(box, 0)
  Assert.equal(#lg.rectangles, 0, "the application frame never fills its content box")
  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local groups = FieldDialogueTheme.applicationFrameTilePlacements(box)
  Assert.equal(#lg.draws, #groups.sides + #groups.bottom + #groups.top, "sides, bottom, and top draw once each")
  local cursor = 0
  -- The fixture's solid tile colors provide no edge boundary, so the
  -- structural profile retains each full source tile. Real patterned rows
  -- exercise the measured offsets in the graphics smoke tests.
  local function expectQuad(tile, kind)
    if kind == "side" then
      return { x = tile * 8, y = 0, w = 8, h = 8 }
    end
    if kind == "top" then
      return { x = tile * 8, y = 0, w = 8, h = 8 }
    end
    if tile == 14 then
      return { x = tile * 8, y = 0, w = 8, h = 8 }
    end
    return { x = tile * 8, y = 0, w = 8, h = 8 }
  end
  local function assertDraws(list, kind, label)
    for _, want in ipairs(list) do
      cursor = cursor + 1
      local call = lg.draws[cursor]
      Assert.equal(call.x, want.flipX and want.x + 8 or want.x, label .. " keeps its target x")
      Assert.equal(call.y, want.y, label .. " keeps its target y")
      local quad = expectQuad(want.tile, kind)
      Assert.equal(call.quad.x, quad.x, label .. " addresses border columns")
      Assert.equal(call.quad.y, quad.y, label .. " addresses border rows")
      Assert.equal(call.quad.w, quad.w, label .. " " .. want.tile .. " never spans interior fill")
      Assert.equal(call.quad.h, quad.h, label .. " " .. want.tile .. " never spans interior fill")
      Assert.isTrue(call.rotation == nil or (want.flipX and call.rotation == 0), label .. " has no rotation")
      Assert.equal(call.sx, want.flipX and -1 or nil, label .. " mirrors only the right side")
      Assert.deepEqual(call.color, { 1, 1, 1, 1 }, label .. " draws with identity tint")
    end
  end
  assertDraws(groups.sides, "side", "side tile")
  assertDraws(groups.bottom, "cap", "bottom tile")
  assertDraws(groups.top, "top", "top tile")
  Assert.deepEqual(lg.transforms, {}, "the frame draw borrows no graphics transform")
  Assert.equal(lg.pushDepth(), 0, "the borrowed transform stack is balanced")
  window:release()
end

-- A tile failure mid-draw propagates with no borrowed state left behind:
-- the frame addresses no transform scope, so there is nothing to restore
-- and the defect surfaces instead of drawing a partial frame silently.
function T.application_frame_draw_failure_propagates_without_state()
  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local groups = FieldDialogueTheme.applicationFrameTilePlacements({ x = 8, y = 24, width = 256, height = 192 })
  local lg = fakeGraphics({
    imageSizes = { { 144, 16 } },
    failOnDrawCall = #groups.sides + #groups.bottom + 1,
  })
  local window = openWindow(lg)
  local err = Assert.throws(function()
    window:drawApplicationFrame({ x = 8, y = 24, width = 256, height = 192 }, 0)
  end, "the top-cap tile failure propagates")
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil)
  Assert.deepEqual(lg.transforms, {}, "no transform is borrowed on failure")
  Assert.equal(lg.pushDepth(), 0, "the transform stack stays balanced on failure")
  window:release()
end

-- The selected index moves artwork, not geometry: frame 1 samples the
-- second strip row at the same direct targets and still fills nothing.
function T.application_frame_index_selects_artwork_without_moving_geometry()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  local box = { x = 8, y = 24, width = 256, height = 192 }
  window:drawApplicationFrame(box, 1)
  Assert.equal(#lg.rectangles, 0, "the application frame never fills its content box")
  Assert.isTrue(#lg.draws > 0, "the selected frame draws its border tiles")
  for _, call in ipairs(lg.draws) do
    Assert.isTrue(call.quad.y == 8 or call.quad.y == 9, "frame 1 samples the second strip row")
  end
  window:release()
end

function T.application_frame_unknown_index_fails_loudly()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  local err = Assert.throws(function()
    window:drawApplicationFrame({ x = 8, y = 24, width = 256, height = 192 }, 9)
  end)
  Assert.isTrue(tostring(err):find("outside the generated frame set", 1, true) ~= nil)
  window:release()
end

-- The renderer owns the one generated dialogue atlas at construction:
-- the dialogue strip is acquired with nearest filtering so frame pixels
-- stay crisp at integer scales. The keyed application copy materializes
-- lazily on the first application draw, so dialogue-only callers never
-- pay for frames they never decorate.
function T.constructor_acquires_the_dialogue_atlas_with_nearest_sampling()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  Assert.equal(#lg.images, 1, "construction acquires only the dialogue strip")
  Assert.deepEqual(
    lg.images[1].filters[#lg.images[1].filters],
    { min = "nearest", mag = "nearest" },
    "the atlas samples with nearest filtering"
  )
  window:drawApplicationFrame({ x = 8, y = 24, width = 256, height = 192 }, 0)
  Assert.equal(#lg.images, 2, "the keyed application copy materializes on first use")
  Assert.deepEqual(
    lg.images[2].filters[#lg.images[2].filters],
    { min = "nearest", mag = "nearest" },
    "the keyed copy samples with nearest filtering"
  )
  window:release()
end

-- Ordinary windows paint exactly one content fill and sample every tile
-- from the dialogue strip: the frame primitive draws no decoration
-- beyond the selected border and fill.
function T.ordinary_window_drawing_samples_only_the_dialogue_strip()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  window:drawWindow({ x = 16, y = 152, width = 216, height = 32 }, 0, { 0, 0, 0, 1 })
  Assert.equal(#lg.rectangles, 1, "the ordinary window fills its content box exactly once")
  for _, call in ipairs(lg.draws) do
    Assert.isTrue(call.image == lg.images[1], "every ordinary tile samples the dialogue strip")
  end
  window:release()
end

-- The application border builds from the dialogue atlas alone: a manifest
-- with no application record constructs, acquires one strip image, and
-- the selected row still drives the border artwork.
function T.application_frame_builds_from_the_dialogue_atlas_alone()
  local FieldWindowRenderer = windowRenderer()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local manifest = FieldUiFixture.manifest()
  Assert.isNil(manifest.dialogueFrames.application, "no application record is published")
  Assert.isNil(manifest.assets["hgss.application_frame.tiles"], "no second atlas is indexed")
  local window = FieldWindowRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    graphics = lg,
  })
  Assert.equal(#lg.images, 1, "construction acquires only the dialogue strip")
  local box = { x = 8, y = 24, width = 256, height = 192 }
  window:drawApplicationFrame(box, 1)
  Assert.equal(#lg.images, 2, "the keyed application copy materializes on first use")
  Assert.equal(#lg.rectangles, 0, "the application frame never fills its content box")
  Assert.isTrue(#lg.draws > 0, "the selected frame draws its border tiles")
  for _, call in ipairs(lg.draws) do
    Assert.isTrue(
      call.image == lg.images[1] or call.image == lg.images[2] or call.image == lg.images[3],
      "every border tile samples a dialogue-strip copy"
    )
    Assert.isTrue(call.quad.y == 8 or call.quad.y == 9, "frame 1 samples the second strip row")
  end
  window:release()
end

return { tests = T }
