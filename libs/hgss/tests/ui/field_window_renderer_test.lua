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

-- The renderer owns both generated atlases: the dialogue strip beside the
-- masked application strip, each sampled with nearest filtering so frame
-- pixels stay crisp at integer scales.
function T.constructor_acquires_dialogue_and_application_atlases_with_nearest_sampling()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 }, { 144, 16 } } })
  local window = openWindow(lg)
  Assert.equal(#lg.images, 2, "dialogue and application strips are both acquired")
  for index, image in ipairs(lg.images) do
    Assert.deepEqual(
      image.filters[#image.filters],
      { min = "nearest", mag = "nearest" },
      "atlas " .. index .. " samples with nearest filtering"
    )
  end
  window:release()
end

-- Atlas selection follows the presentation path: ordinary windows sample
-- the original dialogue strip while application chrome samples the masked
-- strip through the same shared row rectangles.
function T.application_chrome_samples_the_masked_atlas_while_dialogue_uses_the_original()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 }, { 144, 16 } } })
  local window = openWindow(lg)
  local box = { x = 8, y = 24, width = 256, height = 192 }
  window:drawWindow({ x = 16, y = 152, width = 216, height = 32 }, 0, { 0, 0, 0, 1 })
  window:drawApplicationFrame(box, 0)
  local dialogueImage, applicationImage = nil, nil
  for _, call in ipairs(lg.draws) do
    if call.quad ~= nil then
      if dialogueImage == nil then
        dialogueImage = call.image
      elseif call.image ~= dialogueImage and applicationImage == nil then
        applicationImage = call.image
      end
    end
  end
  Assert.notNil(dialogueImage, "window drawing samples an atlas")
  Assert.notNil(applicationImage, "application chrome samples a second atlas")
  Assert.isTrue(dialogueImage ~= applicationImage, "chrome never falls back to the dialogue strip")
  Assert.isTrue(dialogueImage == lg.images[1], "dialogue keeps the first atlas")
  Assert.isTrue(applicationImage == lg.images[2], "chrome uses the masked atlas")
  window:release()
end

-- A missing application strip is the same typed atlas failure as a missing
-- dialogue strip: construction fails loudly and the already-acquired
-- dialogue image is released exactly once, never kept half-valid.
-- Window chrome draws the masked border first, then the title text, then
-- the dismiss mark only when the window is dismissible. The title fits
-- inside the shared title region and the mark stays centered in the
-- shared dismiss rectangle; ordinary window drawing stays free of text
-- and controls.
local function chromeText(lg)
  local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
  return FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
end

local function chromeGeometry(box)
  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local locate = FieldDialogueTheme.applicationChromeGeometry
  if type(locate) ~= "function" then
    error("the shared theme must locate window chrome geometry for drawing", 0)
  end
  return locate(box)
end

-- Glyph draws are the per-character image draws issued by the borrowed
-- text renderer: draws whose image is neither generated frame strip.
local function titleDraws(lg)
  local found = {}
  for index, call in ipairs(lg.draws) do
    if call.image ~= lg.images[1] and call.image ~= lg.images[2] then
      found[#found + 1] = { index = index, call = call }
    end
  end
  return found
end

local function borderDrawCount(lg)
  local count = 0
  for _, call in ipairs(lg.draws) do
    if call.image == lg.images[2] then
      count = count + 1
    end
  end
  return count
end

local function dashMarkCenter(lg)
  local marks = {}
  for _, rect in ipairs(lg.rectangles) do
    if rect.mode == "fill" then
      marks[#marks + 1] = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
    end
  end
  return marks
end

function T.window_chrome_layers_masked_art_then_title_then_dismiss_mark()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 }, { 144, 16 } } })
  local window = openWindow(lg)
  local text = chromeText(lg)
  local box = { x = 8, y = 24, width = 256, height = 192 }
  local geometry = chromeGeometry(box)
  window:drawApplicationChrome(box, 0, { title = "BAG", dismissible = true }, text)
  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local expectedBorder = #FieldDialogueTheme.applicationFrameTilePlacements(box)
  Assert.equal(borderDrawCount(lg), expectedBorder, "the masked border draws every tile instance")
  local titles = titleDraws(lg)
  Assert.equal(#titles, 3, "the three title glyphs draw once each")
  local lastBorder = 0
  for index, call in ipairs(lg.draws) do
    if call.image == lg.images[2] then
      lastBorder = index
    end
  end
  Assert.isTrue(titles[1].index > lastBorder, "every title glyph draws after the masked border")
  local firstY = titles[1].call.y
  for _, entry in ipairs(titles) do
    Assert.equal(entry.call.y, firstY, "the title draws on one text line")
    Assert.isTrue(
      entry.call.x >= geometry.title.x and entry.call.x <= geometry.title.x + geometry.title.width,
      "title glyphs stay inside the shared title region"
    )
  end
  for index = 2, #titles do
    Assert.isTrue(titles[index].call.x > titles[index - 1].call.x, "title glyphs advance left to right")
  end
  local lastGlyph = titles[#titles].call
  Assert.isTrue(lastGlyph.x <= geometry.dismiss.x, "the title ends before the dismiss control space")
  local marks = dashMarkCenter(lg)
  Assert.equal(#marks, 1, "the dismissible window draws exactly one dismiss mark")
  Assert.near(
    marks[1].x,
    geometry.dismiss.x + geometry.dismiss.width / 2,
    1,
    "the dismiss mark centers horizontally in its control"
  )
  Assert.near(
    marks[1].y,
    geometry.dismiss.y + geometry.dismiss.height / 2,
    1,
    "the dismiss mark centers vertically in its control"
  )
  window:release()
end

function T.starter_chrome_draws_title_without_a_dismiss_mark()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 }, { 144, 16 } } })
  local window = openWindow(lg)
  local text = chromeText(lg)
  local box = { x = 8, y = 24, width = 256, height = 192 }
  window:drawApplicationChrome(box, 0, { title = "STARTER CHOICE", dismissible = false }, text)
  Assert.isTrue(borderDrawCount(lg) > 0, "the titled window still draws its masked border")
  Assert.isTrue(#titleDraws(lg) > 0, "the titled window still draws its title")
  Assert.equal(#dashMarkCenter(lg), 0, "a non-dismissible window draws no dismiss mark")
  window:release()
end

function T.an_oversized_title_fails_before_painting()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 }, { 144, 16 } } })
  local window = openWindow(lg)
  local text = chromeText(lg)
  local box = { x = 8, y = 24, width = 256, height = 192 }
  local draw = window.drawApplicationChrome
  Assert.isTrue(type(draw) == "function", "the window renderer must draw titled dismissible chrome")
  local err = Assert.throws(function()
    draw(window, box, 0, { title = string.rep("W", 200), dismissible = true }, text)
  end, "an oversized title must fail loudly")
  Assert.isTrue(
    tostring(err):lower():find("title", 1, true) ~= nil,
    "the oversized-title failure names the title contract"
  )
  window:release()
end

function T.ordinary_window_drawing_stays_free_of_chrome()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 } } })
  local window = openWindow(lg)
  window:drawWindow({ x = 16, y = 152, width = 216, height = 32 }, 0, { 0, 0, 0, 1 })
  Assert.equal(#lg.rectangles, 1, "the ordinary window fills its content box exactly once")
  for _, call in ipairs(lg.draws) do
    Assert.isTrue(call.image == lg.images[1], "every ordinary tile samples the dialogue strip")
  end
  window:release()
end

function T.missing_application_strip_is_a_typed_error_releasing_the_dialogue_image()
  local FieldWindowRenderer = windowRenderer()
  local lg = fakeGraphics({ imageSizes = { { 144, 16 }, { 144, 16 } } })
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:remove(FieldUiFixture.APPLICATION_STRIP_PATH)
  local err = Assert.throws(function()
    FieldWindowRenderer.new({ cacheFs = cache, manifest = FieldUiFixture.manifest(), graphics = lg })
  end)
  local Errors = require("libs.errors.src.Errors")
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_UI_FRAME_ATLAS_MISSING", "raises FIELD_UI_FRAME_ATLAS_MISSING")
  Assert.equal(#lg.images, 1, "only the dialogue image was acquired before the failure")
  Assert.isTrue(lg.images[1].released, "the dialogue image is released on partial failure")
  Assert.equal(lg.images[1].releaseCount, 1, "the dialogue image is released exactly once")
end

return { tests = T }
