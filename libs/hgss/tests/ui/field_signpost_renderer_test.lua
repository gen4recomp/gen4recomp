-- Failure-path, geometry, and wipe-contract tests for the signpost renderer,
-- driven through an injected graphics namespace: construction typed errors
-- with release of already-acquired images, per-type frame/wayfinding/text
-- geometry from the immutable style catalogue, the wipe translation (whole
-- surface, hidden position below the screen), the active-only visibility key
-- (the wipe-out endpoint reset never flashes), and stateless offset
-- interpolation clamped between fixed ticks: the renderer holds no
-- interpolation state and lerps the controller's paired wipe history without
-- ever calling back into it. The canonical pixel goldens live in
-- field_signpost_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldSignpostController = require("libs.hgss.src.interaction.FieldSignpostController")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldSignpostFixture = require("tests.support.FieldSignpostFixture")
local FieldSignpostRenderer = require("libs.hgss.src.ui.FieldSignpostRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}

local function formattedMessage(lines)
  return FieldSignpostFixture.message(lines) --[[@as FieldMessageProvider.FormattedMessage]]
end

-- The runtime-validated manifest every construction passes in: the renderer
-- never reloads it from the cache itself.
local MANIFEST = FieldUiFixture.manifest()

-- The fake graphics namespace records every draw/transform/primitive and
-- holds the settable state the renderers must restore exactly; the shared
-- helper is tests/support/FakeGraphics.lua.
local fakeGraphics = require("tests.support.FakeGraphics").new

-- The created images in order: font atlas (16x16), semantic glyph mask atlas
-- (16x16), focus strip (96x32), signpost strip (144x8), wayfinding atlas
-- (48x128).
local function uiCache()
  return FieldUiFixture.cacheWithFontAndFrames()
end

-- The shared font assets: the fixture font carries three glyphs, so the text
-- renderer creates three images (glyph atlas, semantic glyph mask atlas, and
-- focus strip) and three glyph quads ahead of the signpost renderer's own
-- strip/wayfinding images and tile quads.
local function withTextRenderer(cache, lg)
  return FieldTextRenderer.new({ cacheFs = cache, graphics = lg })
end

local function renderer(lg, cache)
  return FieldSignpostRenderer.new({
    cacheFs = cache or uiCache(),
    manifest = MANIFEST,
    text = withTextRenderer(cache or uiCache(), lg),
    graphics = lg,
    windowStyles = FieldSignpostFixture.styles(),
  })
end

-- The draw calls per owned image.
local function drawsFor(lg, image)
  local out = {}
  for _, call in ipairs(lg.draws) do
    if call.image == image then
      out[#out + 1] = call
    end
  end
  return out
end

-- The shared text renderer owns the font atlas, the semantic glyph mask
-- atlas, and the focus strip (the fixture font carries three glyphs); the
-- signpost renderer owns the strip and wayfinding images. Signpost text
-- draws through the palette path, from the mask atlas (images[2]).
local function textDraws(lg)
  return drawsFor(lg, lg.images[2])
end

local function frameDraws(lg)
  return drawsFor(lg, lg.images[4])
end

local function wayfindingDraws(lg)
  return drawsFor(lg, lg.images[5])
end

local function renderedDraws(opts)
  opts = opts or {}
  local lg = fakeGraphics(opts.graphics or {})
  local r = renderer(lg)
  local controller = opts.controller
  if not controller and opts.type ~= nil then
    controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), {
      type = opts.type,
      map = opts.map or 0,
      offset = opts.offset,
    })
  end
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  r:draw(controller, viewport, opts.alpha, viewport:logicalPixelScale(1))
  r:release()
  return lg
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    FieldSignpostRenderer.new({ cacheFs = uiCache(), manifest = MANIFEST, graphics = false })
  end)
  Assert.isTrue(tostring(err):find("FieldSignpostRenderer requires love.graphics", 1, true) ~= nil)
end

function T.requires_a_window_style_catalogue()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local err = Assert.throws(function()
    FieldSignpostRenderer.new({ cacheFs = uiCache(), manifest = MANIFEST, graphics = lg, windowStyles = false })
  end)
  Assert.isTrue(tostring(err):find("FieldSignpostRenderer requires a window style catalogue", 1, true) ~= nil)
end

-- The runtime-validated manifest is a required constructor input: the
-- renderer never reloads the manifest from the cache itself, so a
-- construction without one is rejected.
function T.missing_ui_manifest_is_rejected()
  local lg = fakeGraphics()
  local text = withTextRenderer(FieldDialogueFixture.cacheWithFont(), lg)
  local err = Assert.throws(function()
    FieldSignpostRenderer.new({
      cacheFs = FieldDialogueFixture.cacheWithFont(),
      text = text,
      graphics = lg,
      windowStyles = FieldSignpostFixture.styles(),
    })
  end)
  Assert.isTrue(tostring(err):find("requires the runtime-validated field-UI manifest", 1, true) ~= nil)
  text:release()
end

-- The manifest names the signpost strip; a cache without the PNG must not
-- build a half-frame renderer. The shared text renderer is caller-owned and
-- stays alive; the renderer itself acquires nothing before the strip read
-- fails.
function T.missing_signpost_strip_is_a_typed_error()
  local cache = FieldDialogueFixture.cacheWithFont()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 } } })
  local text = withTextRenderer(cache, lg)
  local err = Assert.throws(function()
    FieldSignpostRenderer.new({
      cacheFs = cache,
      manifest = MANIFEST,
      text = text,
      graphics = lg,
      windowStyles = FieldSignpostFixture.styles(),
    })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_UI_SIGNPOST_TILES_MISSING",
    "raises FIELD_UI_SIGNPOST_TILES_MISSING"
  )
  Assert.equal(#lg.images, 3, "the font atlas, mask atlas, and focus strip were acquired before the strip failed")
  Assert.equal(lg.images[1].released, false, "the caller-owned text renderer atlas stays alive")
  Assert.equal(lg.images[2].released, false, "the caller-owned text renderer mask atlas stays alive")
  Assert.equal(lg.images[3].released, false, "the caller-owned text renderer focus strip stays alive")
  text:release()
end

-- Same for the wayfinding atlas: the strip exists, the wayfinding PNG does
-- not; the renderer acquires nothing before the read fails.
function T.missing_wayfinding_atlas_is_a_typed_error()
  local cache = uiCache()
  cache:remove(FieldUiFixture.WAYFINDING_PATH)
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 } } })
  local text = withTextRenderer(cache, lg)
  local err = Assert.throws(function()
    FieldSignpostRenderer.new({
      cacheFs = cache,
      manifest = MANIFEST,
      text = text,
      graphics = lg,
      windowStyles = FieldSignpostFixture.styles(),
    })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_UI_WAYFINDING_MISSING", "raises FIELD_UI_WAYFINDING_MISSING")
  Assert.equal(#lg.images, 3, "only the font atlas, mask atlas, and focus strip exist when the wayfinding read fails")
  Assert.equal(lg.images[1].released, false, "the caller-owned text renderer atlas stays alive")
  Assert.equal(lg.images[2].released, false, "the caller-owned text renderer mask atlas stays alive")
  Assert.equal(lg.images[3].released, false, "the caller-owned text renderer focus strip stays alive")
  text:release()
end

-- Frame-strip tile quads are built lazily per source type at draw time (like
-- the wayfinding row cache), so construction itself performs no quad work of
-- its own: the only remaining construction failure after both reads succeed
-- is decoding the second (wayfinding) image, which must release the strip
-- image already created before the constructor rethrows (the three glyph
-- quads belong to the caller-owned text renderer and succeed first).
function T.constructor_failure_releases_all_acquired_images()
  local lg = fakeGraphics({
    imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } },
    failOnImageCall = 5,
  })
  local text = withTextRenderer(uiCache(), lg)
  local err = Assert.throws(function()
    FieldSignpostRenderer.new({
      cacheFs = uiCache(),
      manifest = MANIFEST,
      text = text,
      graphics = lg,
      windowStyles = FieldSignpostFixture.styles(),
    })
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image decode failure")
  Assert.equal(
    #lg.images,
    4,
    "the atlas, mask atlas, focus strip, and strip were created before the wayfinding failure"
  )
  Assert.equal(lg.images[1].released, false, "the caller-owned text renderer atlas stays alive")
  Assert.equal(lg.images[2].released, false, "the caller-owned text renderer mask atlas stays alive")
  Assert.equal(lg.images[3].released, false, "the caller-owned text renderer focus strip stays alive")
  Assert.equal(lg.images[4].released, true, "the strip was released")
  text:release()
end

-- The signpost renderer owns exactly the signpost strip and the wayfinding
-- atlas (the font atlas and focus strip belong to the shared text renderer);
-- a full-width draw creates nothing more.
function T.loads_exactly_the_shared_font_and_owned_assets()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  Assert.equal(#lg.images, 5, "only the five composed images are created")
  local viewport0 = FieldViewport.new(256, 192, { mode = "expanded" })
  r:draw(
    FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2 }),
    viewport0,
    nil,
    viewport0:logicalPixelScale(1)
  )
  Assert.equal(#lg.images, 5, "drawing creates no further images")
  r:release()
end

-- Frame-strip quads are built lazily per source type and cached: a second
-- draw of the same type must not rebuild them. Proven by injecting a quad
-- failure at the call a rebuild would need (one past the 3 glyph quads the
-- shared text renderer builds at construction, the strip's 144px/18-tile row
-- built on the first draw's frame, and the 2 mask-atlas quads the first
-- draw's palette text builds for its 2 distinct glyph codes) and showing the
-- second draw still succeeds.
function T.frame_quads_are_cached_per_source_type()
  local lg =
    fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } }, failOnQuadCall = 24 })
  local r = renderer(lg)
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2 })
  r:draw(controller, viewport, nil, fieldScale)
  local firstDrawFrames = #frameDraws(lg)
  Assert.isTrue(firstDrawFrames > 0, "the first draw draws the frame")
  r:draw(controller, viewport, nil, fieldScale)
  Assert.equal(#frameDraws(lg), firstDrawFrames * 2, "the second draw reuses the cached quads without raising")
  r:release()
end

-- Visibility is keyed on status().active, never on logicalYOffset alone: an
-- inactive controller (including the wipe-out endpoint-check state with the
-- stored offset reset to 0) draws nothing and changes no state.
function T.an_inactive_controller_draws_nothing_and_changes_no_state()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = true,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
    scissor = { 4, 8, 32, 16 },
    imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } },
  })
  local r = renderer(lg)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 })
  controller:setCommand("wipe_out")
  for _ = 1, 4 do
    controller:updateFixed()
  end
  local status = controller:status()
  Assert.equal(status.active, false, "the endpoint check cleared the window")
  Assert.equal(status.logicalYOffset, 0, "the stored offset reset to 0")
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(controller, viewport, nil, viewport:logicalPixelScale(1))
  end
  Assert.equal(#lg.draws, 0, "the cleared window never flashes at the reset position")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
  r:release()
end

-- A full-width source type: the complete frame (tiles 0..17 minus the
-- divider 8), text at the content origin (16,152), all translated by the
-- wipe offset.
function T.full_width_type_draws_the_full_frame_and_text_at_the_content_origin()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(
      FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2 }),
      viewport,
      nil,
      viewport:logicalPixelScale(1)
    )
  end

  local frames = frameDraws(lg)
  Assert.isTrue(#frames > 0, "the frame is drawn")
  for _, call in ipairs(frames) do
    Assert.isTrue(call.quad.x ~= 64, "the divider tile 8 is not placed for a full-width type")
  end
  local topEdge = 0
  local expectedX = 16
  for _, call in ipairs(frames) do
    if call.quad.x == 16 and call.quad.y == 0 then
      topEdge = topEdge + 1
      Assert.equal(call.x, expectedX, "the top edge spans the full 27 content tiles")
      Assert.equal(call.y, 192, "the wipe offset -48 places the frame top below the screen")
      expectedX = expectedX + 8
    end
  end
  Assert.equal(topEdge, 27)

  local text = textDraws(lg)
  Assert.equal(#text, 3, "the two fixture lines carry three glyphs")
  Assert.equal(text[1].x, 16, "full-width text starts at the content origin x=16")
  Assert.equal(text[1].y, 200, "the whole surface is translated by the wipe offset")
  Assert.equal(text[3].y, 216, "the second line sits one line height below")
  r:release()
end

-- Type 0: the text window moves right of the wayfinding area, the precomposed
-- 48x32 wayfinding surface draws once at (16, 152), and the divider tile 8
-- spans the window height between graphic and text.
function T.type_zero_draws_the_graphic_region_and_the_shifted_text()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(
      FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0, offset = 0 }),
      viewport,
      nil,
      viewport:logicalPixelScale(1)
    )
  end

  local text = textDraws(lg)
  Assert.equal(text[1].x, 72, "type-0 text starts after the 56px graphic region")

  local wayfinding = wayfindingDraws(lg)
  Assert.equal(#wayfinding, 1, "the precomposed 48x32 wayfinding surface draws once")
  Assert.deepEqual(
    { wayfinding[1].quad.x, wayfinding[1].quad.y, wayfinding[1].quad.w, wayfinding[1].quad.h },
    { 0, 0, 48, 32 },
    "the final surface samples the full 48x32 rect"
  )
  Assert.equal(wayfinding[1].x, 16)
  Assert.equal(wayfinding[1].y, 152)

  local divider = 0
  for _, call in ipairs(frameDraws(lg)) do
    if call.quad.x == 64 then
      divider = divider + 1
      Assert.equal(call.y, 152 + (divider - 1) * 8, "the divider spans the window height")
      Assert.equal(call.x, 64)
    end
  end
  Assert.equal(divider, 4)
  r:release()
end

-- Type 1 map 0 samples the type-1 map-0 surface (the manifest rect at y=64);
-- the geometry is otherwise identical to type 0.
function T.type_one_samples_the_map_zero_row()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(
      FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 1, offset = 0 }),
      viewport,
      nil,
      viewport:logicalPixelScale(1)
    )
  end
  local wayfinding = wayfindingDraws(lg)
  Assert.equal(#wayfinding, 1)
  Assert.equal(wayfinding[1].quad.y, 64, "type 1 map 0 samples the atlas surface at y=64")
  Assert.equal(wayfinding[1].quad.h, 32, "the final surface is 32px tall")
  r:release()
end

-- The (type, map) pair selects the surface: a type-0 map-1 appearance samples
-- the map-1 atlas surface (y=32), never the map-0 surface (y=0).
function T.type_zero_map_one_samples_the_map_one_row()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(
      FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0, map = 1, offset = 0 }),
      viewport,
      nil,
      viewport:logicalPixelScale(1)
    )
  end
  local wayfinding = wayfindingDraws(lg)
  Assert.equal(#wayfinding, 1)
  Assert.equal(wayfinding[1].quad.y, 32, "map 1 samples the map-1 atlas surface, not the map-0 surface")
  Assert.equal(wayfinding[1].quad.h, 32, "the final surface is 32px tall")
  r:release()
end

-- A type requiring graphic art without a manifest row for its exact
-- (type, map) pair is a manifest/source-contract failure: the lookup never
-- falls back to another map's row.
function T.a_missing_type_map_pair_is_a_manifest_contract_failure()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0, map = 2, offset = 0 })
  Assert.throws(function()
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(controller, viewport, nil, viewport:logicalPixelScale(1))
  end, "a missing (type, map) row must raise")
  r:release()
end

-- The wipe offset translates the whole surface: every frame, wayfinding, and
-- text draw at -48 sits exactly 48px below its rest position.
function T.the_wipe_offset_translates_the_whole_surface()
  local atRest = renderedDraws({ type = 0, offset = 0 })
  local hidden = renderedDraws({ type = 0, offset = -48 })
  Assert.equal(#atRest.draws, #hidden.draws, "the same surface is drawn at both offsets")
  for i = 1, #atRest.draws do
    Assert.equal(hidden.draws[i].x, atRest.draws[i].x, "the wipe never moves the surface horizontally")
    Assert.equal(hidden.draws[i].y, atRest.draws[i].y + 48, "the hidden offset sits 48px below the rest position")
    Assert.deepEqual(
      { hidden.draws[i].quad.x, hidden.draws[i].quad.y, hidden.draws[i].quad.w, hidden.draws[i].quad.h },
      { atRest.draws[i].quad.x, atRest.draws[i].quad.y, atRest.draws[i].quad.w, atRest.draws[i].quad.h },
      "the same tiles are sampled"
    )
  end
end

-- Interpolation is a pure function of the controller's paired wipe history:
-- the drawn offset lerps between status.previousLogicalYOffset and
-- status.logicalYOffset by the session alpha, clamped into [0, 1], and the
-- renderer holds no interpolation state of its own. One unchanged controller
-- (mid-wipe at previous -48, current -32) rendered at every alpha must hit
-- the same positions regardless of render order or repeated calls, and
-- drawing must never mutate the controller.
function T.interpolation_is_stateless_over_the_paired_wipe_history()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = -32 })
  local status = controller:status()
  Assert.equal(status.previousLogicalYOffset, -48, "the fixture wipes one step from -48")
  Assert.equal(status.logicalYOffset, -32, "the fixture holds the mid-wipe current offset")
  local lastY = function()
    local text = textDraws(lg)
    return text[#text].y
  end
  local function expect(alpha, y)
    r:draw(controller, viewport, alpha, viewport:logicalPixelScale(1))
    Assert.equal(lastY(), y, "alpha " .. string.format("%.2f", alpha) .. " lerps the paired history")
  end
  expect(0.00, 216)
  expect(0.25, 212)
  expect(0.50, 208)
  expect(0.75, 204)
  expect(1.00, 200)
  -- Repeated calls and a different order hit the same positions: the
  -- previous/current pair never moves.
  expect(1.00, 200)
  expect(0.00, 216)
  expect(0.50, 208)
  expect(0.25, 212)
  expect(0.75, 204)
  -- Alpha clamps into [0, 1] instead of extrapolating.
  expect(2, 200)
  expect(-1, 216)
  Assert.deepEqual(controller:status(), status, "drawing never mutates the controller")
  r:release()
end

-- An inactive draw is a no-op and poisons nothing: the next active draw
-- interpolates purely from that controller's own paired history, exactly as
-- a fresh renderer would.
function T.an_inactive_gap_leaves_the_next_draw_pure()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  r:draw(
    FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = -48 }),
    viewport,
    1,
    viewport:logicalPixelScale(1)
  )

  local fresh = FieldSignpostController.new({
    layout = function(msg)
      ---@cast msg any
      return { lines = msg._lines }
    end,
    policy = require("libs.hgss.src.ui.TextSpeedPolicy").forSpeed("mid"),
  })
  local before = #lg.draws
  do
    r:draw(fresh, viewport, 0, 1)
  end
  Assert.equal(#lg.draws, before, "the inactive controller draws nothing")

  local shown = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 })
  local status = shown:status()
  Assert.equal(status.previousLogicalYOffset, -16, "the wipe history pair of the shown controller")
  Assert.equal(status.logicalYOffset, 0)
  r:draw(shown, viewport, 0, viewport:logicalPixelScale(1))
  Assert.equal(textDraws(lg)[#textDraws(lg)].y, 184, "alpha 0 draws the pair's previous offset, never a stale one")
  r:draw(shown, viewport, 1, viewport:logicalPixelScale(1))
  Assert.equal(textDraws(lg)[#textDraws(lg)].y, 168, "alpha 1 draws the pair's current offset")
  r:release()
end

-- Wipe-out: the endpoint check clears the window and resets the stored
-- offset; the renderer must not re-present the surface at the reset position
-- on any later draw while inactive.
function T.wipe_out_never_flashes_the_cleared_window()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 })
  r:draw(controller, viewport, nil, fieldScale)
  Assert.isTrue(#lg.draws > 0, "the shown window draws")
  controller:setCommand("wipe_out")
  for _ = 1, 4 do
    controller:updateFixed()
  end
  local before = #lg.draws
  r:draw(controller, viewport, nil, fieldScale)
  Assert.equal(#lg.draws, before, "no draw after the endpoint check cleared the window")
  r:draw(controller, viewport, nil, fieldScale)
  Assert.equal(#lg.draws, before, "staying inactive draws nothing")
  r:release()
end

-- Typed print: only the revealed glyphs are drawn, so the wipe shows the
-- signpost text growing at the fixed cadence.
function T.typed_print_draws_only_the_revealed_glyphs()
  local lines = FieldSignpostFixture.textLines()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local controller = FieldSignpostFixture.shown(lines, { type = 2, offset = 0, text = false })
  controller:printTyped(formattedMessage(lines))
  controller:updateFixed()
  controller:updateFixed()
  r:draw(controller, viewport, nil, fieldScale)
  Assert.equal(#textDraws(lg), 1, "cadence 2 reveals one glyph")
  for _ = 1, 6 do
    controller:updateFixed()
  end
  r:draw(controller, viewport, nil, fieldScale)
  Assert.equal(#textDraws(lg), 4, "the finished print adds the remaining two glyphs")
  r:release()
end

-- An active window without a source appearance (a bare SHOW) is a degenerate
-- script state; the renderer draws the full-width box with the style's own
-- geometry and no wayfinding.
function T.an_active_window_without_appearance_draws_the_full_width_box()
  local controller = FieldSignpostController.new({
    layout = function(msg)
      ---@cast msg any
      return { lines = msg._lines }
    end,
    policy = require("libs.hgss.src.ui.TextSpeedPolicy").forSpeed("mid"),
  })
  controller:setCommand("show")
  controller:updateFixed()
  controller:printInstant(formattedMessage(FieldSignpostFixture.textLines()))
  Assert.isTrue(controller:status().active)
  Assert.isNil(controller:status().sourceAppearance)

  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(controller, viewport, nil, viewport:logicalPixelScale(1))
  end
  Assert.equal(#wayfindingDraws(lg), 0, "no wayfinding without a source appearance")
  Assert.equal(textDraws(lg)[1].x, 16, "the style's own full-width geometry applies")
  r:release()
end

-- A style without a per-source-type map (hgss.trainer_tip) draws its own
-- full-width geometry even for a source type that the signpost style would
-- give a graphic region.
function T.a_style_without_a_per_type_map_uses_its_own_geometry()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), {
    type = 0,
    offset = 0,
    styleId = "hgss.trainer_tip",
  })
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(controller, viewport, nil, viewport:logicalPixelScale(1))
  end
  Assert.equal(#wayfindingDraws(lg), 0, "trainer_tip has no wayfinding area")
  Assert.equal(textDraws(lg)[1].x, 16, "trainer_tip text is full width")
  r:release()
end

-- An unknown style id is a composition error: the catalogue can never
-- resolve it, so the draw raises after restoring the graphics state.
function T.an_unknown_style_id_is_a_programming_error()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = true,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
    scissor = { 4, 8, 32, 16 },
    imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } },
  })
  local r = renderer(lg)
  local controller = FieldSignpostController.new({
    layout = function(msg)
      ---@cast msg any
      return { lines = msg._lines }
    end,
    policy = require("libs.hgss.src.ui.TextSpeedPolicy").forSpeed("mid"),
    styleId = "no.such.style",
  })
  controller:setCommand("show")
  controller:updateFixed()
  Assert.throws(function()
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(controller, viewport, nil, viewport:logicalPixelScale(1))
  end, "unknown style ids must raise")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
  r:release()
end

-- A failure between graphics.push() and graphics.pop() must still pop the
-- transform stack and restore every captured graphics state exactly.
function T.draw_failure_balances_transform_stack_and_restores_state()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = true,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
    scissor = { 4, 8, 32, 16 },
    imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } },
    failOnDrawCall = 1,
  })
  local r = renderer(lg)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0, offset = 0 })
  local err = Assert.throws(function()
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(controller, viewport, nil, viewport:logicalPixelScale(1))
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced after a failed draw")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
  r:release()
end

-- Release frees every owned image; a later draw is a no-op.
function T.release_frees_all_owned_images_and_noops_drawing()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local text = withTextRenderer(uiCache(), lg)
  local r = FieldSignpostRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = text,
    graphics = lg,
    windowStyles = FieldSignpostFixture.styles(),
  })
  r:release()
  Assert.equal(lg.images[4].released, true)
  Assert.equal(lg.images[5].released, true)
  r:draw(
    FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2 }),
    FieldViewport.new(256, 192, { mode = "expanded" }),
    0,
    1
  )
  Assert.equal(#lg.draws, 0, "drawing after release is a no-op")
  text:release()
end

-- Reopening after a completed wipe-out must present a coherent hidden pair:
-- the activation frame stays at the hidden entry position for every render
-- alpha, and the following wipe moves monotonically toward visible with no
-- reversal, jump back to hidden, or second pass through the entry range.
-- Driven through a real controller lifecycle, never a hand-set offset.
function T.reopened_activation_stays_hidden_and_wipes_monotonically()
  local lines = FieldSignpostFixture.textLines()
  local controller = FieldSignpostFixture.shown(lines, { type = 2 })
  controller:setCommand("wipe_in")
  for _ = 1, 4 do
    controller:updateFixed()
  end
  Assert.equal(controller:status().logicalYOffset, 0, "the first wipe must reach the presented position")
  controller:setCommand("wipe_out")
  for _ = 1, 4 do
    controller:updateFixed()
  end
  Assert.equal(controller:status().active, false, "the wipe-out endpoint check must close the window")

  controller:setCommand("show")
  controller:updateFixed()
  local status = controller:status()
  Assert.equal(status.active, true, "the second SHOW must present the window")
  Assert.equal(status.logicalYOffset, -48, "the second SHOW must start hidden")

  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local function fillY(alpha)
    r:draw(controller, viewport, alpha, fieldScale)
    return lg.rectangles[#lg.rectangles].y
  end
  local hiddenY = fillY(1)
  for _, alpha in ipairs({ 0, 0.25, 0.5, 0.75, 1, -1, 2 }) do
    Assert.equal(fillY(alpha), hiddenY, "the reopened activation frame must stay hidden at alpha " .. tostring(alpha))
  end

  controller:setCommand("wipe_in")
  local restY = hiddenY - 48
  local presented = {}
  for _ = 1, 3 do
    controller:updateFixed()
    presented[#presented + 1] = fillY(1)
  end
  Assert.deepEqual(
    presented,
    { hiddenY - 16, hiddenY - 32, restY },
    "the wipe must move one 16px step per update from hidden to rest"
  )
  controller:updateFixed()
  Assert.equal(fillY(1), restY, "the endpoint check must hold the presented position")
  Assert.equal(fillY(0), restY, "the endpoint check must rest the interpolation pair coherently")
  r:release()
end

local focusToken = FieldDialogueFixture.focusToken
local focusDraws = FieldDialogueFixture.focusDraws

-- The content-window right-edge expectation from the same immutable style
-- catalogue the renderer resolves, so placement is asserted against the
-- signpost content rectangle, never against dialogue box geometry.
local function contentRightEdge(typeId, styleId)
  local style = assert(FieldSignpostFixture.styles():resolve(styleId or "hgss.signpost"))
  local content = typeId ~= nil and style.types and style.types[typeId].contentGeometry or style.contentGeometry
  assert(content ~= nil, "the style must carry content geometry")
  return content.x + content.width - 24, content.y
end

-- Sign text draws through the palette-driven path against the active source
-- type's own palette slots 2 (foreground), 10 (shadow), and 15 (background) --
-- never the field font's baked default color bands, and never a type-0
-- fallback for a real appearance.
function T.signpost_text_uses_the_active_type_palette_slots_2_10_15()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(
      FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 }),
      viewport,
      nil,
      viewport:logicalPixelScale(1)
    )
  end
  local palette = MANIFEST.signposts.types[2].palette
  local function norm(c)
    return { c.r / 255, c.g / 255, c.b / 255, 1 }
  end
  local shader = lg.shaders[1]
  local function sent(name)
    for _, send in ipairs(shader.sends) do
      if send.name == name then
        return send.value
      end
    end
    Assert.fail("uniform " .. name .. " was never sent")
  end
  Assert.deepEqual(sent("u_foreground"), norm(palette[2]))
  Assert.deepEqual(sent("u_shadow"), norm(palette[10]))
  Assert.deepEqual(sent("u_background"), norm(palette[15]))
  r:release()
end

-- The palette path is source-fixed: two otherwise identical glyph tokens
-- differing only by colorIndex must sample the same mask-atlas quad. The
-- signpost renderer itself holds no color state.
function T.signpost_text_ignores_token_color_index()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local lines = {
    {
      tokens = {
        { kind = "glyph", code = 1, text = "A", raw = { 1 }, colorIndex = 1 },
        { kind = "glyph", code = 2, text = "B", raw = { 2 }, colorIndex = 6 },
      },
    },
  }
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(FieldSignpostFixture.shown(lines, { type = 2, offset = 0 }), viewport, nil, viewport:logicalPixelScale(1))
  end
  local text = textDraws(lg)
  Assert.equal(#text, 2)
  Assert.equal(text[1].quad.y, 0, "colorIndex is ignored: the mask atlas has no color bands")
  Assert.equal(text[2].quad.y, 0, "colorIndex is ignored for every glyph")
  Assert.equal(text[2].x, text[1].x + 6, "colorIndex never changes the glyph advance")
  r:release()
end

-- The full-width sign's interior fill is exactly the content rectangle at
-- the active type's palette slot 15, and a full-width type never draws the
-- wayfinding surface.
function T.full_width_sign_fills_the_content_window_with_palette_slot_15()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(
      FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 }),
      viewport,
      nil,
      viewport:logicalPixelScale(1)
    )
  end
  Assert.equal(#lg.rectangles, 1, "the interior fill is the only rectangle primitive")
  local fill = lg.rectangles[1]
  Assert.equal(fill.mode, "fill")
  Assert.deepEqual({ fill.x, fill.y, fill.w, fill.h }, { 16, 152, 216, 32 })
  local slot15 = MANIFEST.signposts.types[2].palette[15]
  Assert.near(fill.color[1], slot15.r / 255, 1e-6)
  Assert.near(fill.color[2], slot15.g / 255, 1e-6)
  Assert.near(fill.color[3], slot15.b / 255, 1e-6)
  Assert.near(fill.color[4], 1, 1e-6)
  Assert.equal(#wayfindingDraws(lg), 0, "wayfinding is never drawn for a full-width type")
  r:release()
end

-- A graphic sign's interior fill covers only the text window right of the
-- 56px wayfinding graphic, never the graphic region itself.
function T.graphic_sign_fills_only_the_text_window_right_of_the_graphic()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(
      FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0, offset = 0 }),
      viewport,
      nil,
      viewport:logicalPixelScale(1)
    )
  end
  Assert.equal(#lg.rectangles, 1)
  local fill = lg.rectangles[1]
  Assert.equal(fill.mode, "fill")
  Assert.deepEqual({ fill.x, fill.y, fill.w, fill.h }, { 72, 152, 160, 32 })
  r:release()
end

-- The interior fill translates by the same wipe offset as the rest of the
-- signpost surface.
function T.the_interior_fill_shares_the_wipe_transform_with_the_rest_of_the_surface()
  local atRest = renderedDraws({ type = 2, offset = 0 })
  local hidden = renderedDraws({ type = 2, offset = -16 })
  Assert.equal(hidden.rectangles[1].y, atRest.rectangles[1].y + 16, "the fill wipes with the rest of the surface")
  Assert.equal(hidden.rectangles[1].x, atRest.rectangles[1].x, "the wipe never moves the fill horizontally")
end

-- A visible focus indicator draws once through the shared renderer at the
-- signpost content-window right edge (type 0 text window, right of the
-- wayfinding graphic), while the frame/wayfinding/text surface is unchanged.
function T.visible_focus_indicator_draws_at_the_signpost_content_right_edge()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local lines = FieldSignpostFixture.textLines()
  lines[#lines].tokens[#lines[#lines].tokens + 1] = focusToken(2)
  do
    local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
    r:draw(FieldSignpostFixture.shown(lines, { type = 0, offset = 0 }), viewport, nil, viewport:logicalPixelScale(1))
  end
  local focus = focusDraws(lg)
  Assert.equal(#focus, 1, "exactly one indicator frame is drawn")
  local x, y = contentRightEdge(0)
  Assert.equal(focus[1].x, x, "the indicator sits at the signpost content-window right edge")
  Assert.equal(focus[1].y, y, "the indicator sits at the signpost content-window top")
  Assert.deepEqual({ focus[1].quad.x, focus[1].quad.y }, { 2 * 24, 0 }, "field 2 samples its imported strip rect")
  Assert.equal(#wayfindingDraws(lg), 1, "the wayfinding surface is unchanged")
  Assert.equal(#textDraws(lg), 3, "the glyph surface is unchanged")
  r:release()
end

-- The indicator is part of the sliding signpost BG surface: the whole window
-- (frame, wayfinding, text, indicator) translates by the wipe offset, and the
-- same frame is sampled at every offset.
function T.focus_indicator_translates_with_the_signpost_wipe()
  local function drawAt(offset)
    local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
    local r = renderer(lg)
    local lines = FieldSignpostFixture.textLines()
    lines[#lines].tokens[#lines[#lines].tokens + 1] = focusToken(0)
    do
      local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
      r:draw(
        FieldSignpostFixture.shown(lines, { type = 2, offset = offset }),
        viewport,
        nil,
        viewport:logicalPixelScale(1)
      )
    end
    r:release()
    return focusDraws(lg)[1]
  end
  local rest = drawAt(0)
  local hidden = drawAt(-48)
  Assert.notNil(rest)
  Assert.equal(hidden.x, rest.x, "the wipe never moves the indicator horizontally")
  Assert.equal(hidden.y, rest.y + 48, "the indicator is part of the sliding signpost surface")
  Assert.deepEqual(
    { hidden.quad.x, hidden.quad.y, hidden.quad.w, hidden.quad.h },
    { rest.quad.x, rest.quad.y, rest.quad.w, rest.quad.h },
    "the same frame is sampled at every offset"
  )
end

-- Small hosts fit the 256x192 signpost surface inside the real world
-- viewport, mirroring the dialogue fit: the field scale caps, never forces,
-- the drawn scale, and the shrunken surface stays bottom-centered.
function T.constrained_signpost_shrinks_to_fit_the_real_world_viewport()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 8 }, { 48, 128 } } })
  local r = renderer(lg)
  local viewport = FieldViewport.new(1280, 600, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1.25)
  local bounds = { x = 5, y = 7, width = 200, height = 40 }
  viewport.worldViewport = { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height }
  r:draw(
    FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 }),
    viewport,
    1,
    fieldScale
  )
  local expectedScale = math.min(fieldScale, bounds.width / 256, bounds.height / 192)
  Assert.isTrue(expectedScale < fieldScale, "the fixture host must be too small for the field scale")
  Assert.equal(#lg.transforms, 2, "exactly one translate and one scale")
  Assert.near(lg.transforms[2][2], expectedScale, 1e-6, "the shrunken signpost fits the real bounds")
  Assert.near(lg.transforms[2][3], expectedScale, 1e-6, "the shrunken signpost fits the real bounds")
  local originX, originY = lg.transforms[1][2], lg.transforms[1][3]
  Assert.near(originX, bounds.x + (bounds.width - 256 * expectedScale) / 2, 1e-6, "horizontally centered")
  Assert.near(originY, bounds.y + bounds.height - 192 * expectedScale, 1e-6, "bottom-aligned")
  Assert.isTrue(originX >= bounds.x - 1e-6, "the fitted surface stays inside the host horizontally")
  Assert.isTrue(originX + 256 * expectedScale <= bounds.x + bounds.width + 1e-6, "the fitted surface stays inside")
  Assert.isTrue(originY >= bounds.y - 1e-6, "the fitted surface stays inside the host vertically")
  Assert.isTrue(originY + 192 * expectedScale <= bounds.y + bounds.height + 1e-6, "the fitted surface stays inside")
  r:release()
end

return { tests = T }
