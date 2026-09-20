-- Static HGSS user-frame presentation primitive shared by field dialogue
-- and the starter chooser: one owner for the generated dialogue frame-strip
-- image, its lazily built per-frame tile quads, and the content-background
-- fill behind a supplied content box. It owns no modal, controller, cursor,
-- or text lifecycle; callers supply the frame index, the content box, and
-- the background color.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")

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

-- The application frame draws only the rotated selected border around the
-- content box: no content fill, one draw per rotated tile instance from the
-- shared rotated tilemap, sampling the selected strip row with identity
-- tint and a visual quarter turn on every tile.
function T.application_frame_draws_only_the_rotated_selected_border()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  local box = { x = 8, y = 24, width = 256, height = 192 }
  window:drawApplicationFrame(box, 0)
  Assert.equal(#lg.rectangles, 0, "the application frame never fills its content box")
  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local expected = FieldDialogueTheme.applicationFrameTilePlacements(box)
  Assert.equal(#lg.draws, #expected, "every rotated tile instance draws exactly once")
  for index, call in ipairs(lg.draws) do
    local want = expected[index]
    Assert.equal(call.x, want.x, "border tile " .. index .. " keeps its rotated target x")
    Assert.equal(call.y, want.y, "border tile " .. index .. " keeps its rotated target y")
    Assert.equal(call.quad.x, want.tile * 8, "border tile samples the selected strip row")
    Assert.equal(call.quad.y, 0, "frame 0 samples the first strip row")
    Assert.near(math.abs(call.rotation or 0), math.pi / 2, 1e-9, "border tile art carries a visual quarter turn")
    Assert.deepEqual(call.color, { 1, 1, 1, 1 }, "border tiles draw with identity tint")
  end
  window:release()
end

-- The selected index moves artwork, not geometry: frame 1 samples the
-- second strip row at the same rotated targets and still fills nothing.
function T.application_frame_index_selects_artwork_without_moving_geometry()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  local box = { x = 8, y = 24, width = 256, height = 192 }
  window:drawApplicationFrame(box, 1)
  Assert.equal(#lg.rectangles, 0, "the application frame never fills its content box")
  Assert.isTrue(#lg.draws > 0, "the selected frame draws its border tiles")
  for _, call in ipairs(lg.draws) do
    Assert.equal(call.quad.y, 8, "frame 1 samples the second strip row")
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

return { tests = T }
