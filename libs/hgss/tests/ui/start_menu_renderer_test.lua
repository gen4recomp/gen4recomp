-- Failure-path and manifest-authority tests for the Start Menu renderer,
-- driven through an injected graphics namespace so the Nth-construction and
-- mid-draw failures can be provoked deterministically. The renderer resolves
-- the whole canonical surface from the generated manifest's `startMenu`
-- section (background rect, slot rects, cursor frames with
-- durations; the action-icon art is baked into the background PNG) and never
-- repeats source coordinates; a quad failure after the
-- background and cursor images exist must release both, and a missing
-- manifest, background, or cursor asset is a typed error. Drawing the
-- surface consumes the StartMenuLayout placement record -- the same record
-- hit testing maps through -- so rendering and hit testing share one
-- transform and there is never a second set of scaled rectangles; the
-- surface uses only the two generated images -- no generic field-menu theme
-- colors or primitives -- and a draw that raises must still balance the
-- transform stack and restore every captured graphics state. The
-- real-context smokes live in start_menu_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")
local StartMenuRenderer = require("libs.hgss.src.ui.StartMenuRenderer")

local T = {}

-- The runtime-validated manifest every construction passes in: the renderer
-- never reloads it from the cache itself.
local MANIFEST = FieldUiFixture.manifest()

-- The fake graphics namespace records every draw/transform/primitive and
-- holds the settable state the renderers must restore exactly; the shared
-- helper is tests/support/FakeGraphics.lua. The Start Menu surface must
-- never call a themed primitive (rectangle/polygon/print), so the primitive
-- record is part of the surface contract.
local fakeGraphics = require("tests.support.FakeGraphics").new

-- The canonical placement record through the real pure layout module: the
-- 256x192 surface resolved onto a canonical 256x192 host. Rendering and hit
-- testing consume the same record shape, so a draw regression against the
-- transform is a mismatch.
local function canonicalPlacement()
  return StartMenuLayout.resolve(
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = false,
      role = "world",
    }),
    { x = 0, y = 0, width = 256, height = 192 },
    1
  )
end

local function menuCache()
  return FieldUiFixture.startMenuCache()
end

-- The runtime-validated manifest is a required constructor input: the
-- renderer never reloads the manifest from the cache itself, so a
-- construction without one is rejected.
function T.missing_manifest_is_rejected()
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()) })
  end)
  Assert.isTrue(tostring(err):find("requires the runtime-validated field-UI manifest", 1, true) ~= nil)
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = false })
  end)
  Assert.isTrue(tostring(err):find("StartMenuRenderer requires love.graphics", 1, true) ~= nil)
end

-- The manifest names the background and cursor assets; a cache without the
-- background PNG must not build a half-surface renderer.
function T.missing_background_asset_is_a_typed_error()
  local cache = menuCache()
  cache:remove(FieldUiFixture.START_MENU_BACKGROUND_PATH)
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = cache, manifest = MANIFEST })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_UI_START_MENU_BACKGROUND_MISSING",
    "raises FIELD_UI_START_MENU_BACKGROUND_MISSING"
  )
end

-- A missing cursor PNG after the background was acquired must release the
-- background before raising.
function T.missing_cursor_asset_is_a_typed_error_and_releases_the_background()
  local cache = menuCache()
  cache:remove(FieldUiFixture.START_MENU_CURSOR_PATH)
  local lg = fakeGraphics({ imageSizes = { { 256, 192 } } })
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = cache, manifest = MANIFEST, graphics = lg })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_UI_START_MENU_CURSOR_MISSING",
    "raises FIELD_UI_START_MENU_CURSOR_MISSING"
  )
  Assert.equal(#lg.images, 1, "the background was acquired before the cursor failed")
  Assert.equal(lg.images[1].released, true, "the acquired background was released")
end

-- A quad failure after both images were created must release both before the
-- constructor rethrows.
function T.constructor_failure_releases_background_and_cursor()
  local lg = fakeGraphics({
    imageSizes = { { 256, 192 }, { 16, 32 } },
    failOnQuadCall = 2,
  })
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil, "rethrows the quad failure")
  Assert.equal(#lg.images, 2, "background and cursor were created before the failure")
  Assert.equal(lg.images[1].released, true, "the background was released")
  Assert.equal(lg.images[2].released, true, "the cursor was released")
end

-- The renderer resolves the whole surface from the manifest's startMenu
-- section: background rect, the slot rects, and the cursor
-- frames with their durations. The fixture's values are the only authority;
-- the renderer must not carry its own copy of the geometry.
function T.resolves_the_start_menu_section_from_the_manifest()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  local manifest = FieldUiFixture.manifest().startMenu

  Assert.deepEqual(renderer.menu.background, manifest.background, "the background rect comes from the manifest")
  for id, rect in pairs(manifest.slots) do
    Assert.deepEqual(renderer.menu.slots[id], rect, "slot " .. id .. " comes from the manifest")
  end
  Assert.equal(#renderer.menu.cursor.frames, #manifest.cursor.frames, "every cursor frame is resolved")
  for index, frame in ipairs(manifest.cursor.frames) do
    Assert.deepEqual(renderer.menu.cursor.frames[index], frame, "cursor frame " .. index .. " comes from the manifest")
  end
  renderer:release()
end

-- A non-canonical manifest is resolved verbatim: a hard-coded canonical grid
-- would fail this test, which is what keeps the generated metadata the
-- authority (no source coordinates may be repeated in runtime code).
function T.the_manifest_geometry_is_the_authority_not_a_hard_coded_grid()
  local cache = menuCache()
  local manifest = FieldUiFixture.manifest()
  manifest.startMenu.slots = {
    [1] = { x = 10, y = 20, width = 100, height = 30 },
    [2] = { x = 120, y = 20, width = 100, height = 30 },
  }
  manifest.startMenu.cursor.frames = {
    { x = 0, y = 8, width = 8, height = 8, duration = 4 },
    { x = 8, y = 8, width = 8, height = 8, duration = 9 },
  }
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = cache, manifest = manifest, graphics = lg })
  Assert.deepEqual(renderer.menu.slots[1], { x = 10, y = 20, width = 100, height = 30 })
  Assert.deepEqual(renderer.menu.slots[2], { x = 120, y = 20, width = 100, height = 30 })
  Assert.deepEqual(renderer.menu.cursor.frames[1], { x = 0, y = 8, width = 8, height = 8, duration = 4 })
  Assert.deepEqual(renderer.menu.cursor.frames[2], { x = 8, y = 8, width = 8, height = 8, duration = 9 })

  -- The cursor derives its placement from the manifest slot rect: centered
  -- over the presented slot, sized by the manifest frame rect.
  renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, canonicalPlacement())
  local backgroundDraw = lg.draws[1]
  Assert.deepEqual(
    { backgroundDraw.quad.x, backgroundDraw.quad.y, backgroundDraw.quad.w, backgroundDraw.quad.h },
    { 0, 0, 256, 192 },
    "the background quad is the manifest background rect"
  )
  Assert.equal(backgroundDraw.x, 0)
  Assert.equal(backgroundDraw.y, 0)
  local cursorDraw = lg.draws[2]
  Assert.deepEqual(
    { cursorDraw.quad.x, cursorDraw.quad.y, cursorDraw.quad.w, cursorDraw.quad.h },
    { 0, 8, 8, 8 },
    "the cursor quad is the manifest frame rect"
  )
  Assert.equal(cursorDraw.x, 10 + 50 - 4, "the cursor centers on the slot x center")
  Assert.equal(cursorDraw.y, 20 + 15 - 4, "the cursor centers on the slot y center")
  renderer:release()
end

-- The canonical surface: background over the manifest rect, then the cursor
-- frame centered over the presented slot.
function T.draws_the_background_and_the_cursor_over_the_presented_slot()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, canonicalPlacement())
  renderer:release()

  Assert.equal(#lg.draws, 2, "one background draw and one cursor draw")
  local backgroundDraw = lg.draws[1]
  Assert.equal(backgroundDraw.image, lg.images[1], "the background image is drawn first")
  Assert.deepEqual(
    { backgroundDraw.quad.x, backgroundDraw.quad.y, backgroundDraw.quad.w, backgroundDraw.quad.h },
    { 0, 0, 256, 192 }
  )
  Assert.equal(backgroundDraw.quad.imgW, 256, "the background quad samples the background atlas")
  Assert.equal(backgroundDraw.x, 0, "the background covers the manifest rect")
  Assert.equal(backgroundDraw.y, 0)

  local cursorDraw = lg.draws[2]
  Assert.equal(cursorDraw.image, lg.images[2], "the cursor image is drawn over the background")
  local slot = FieldUiFixture.START_MENU_SLOTS[1]
  Assert.equal(cursorDraw.x, slot.x + slot.width / 2 - 8, "the cursor centers on the presented slot")
  Assert.equal(cursorDraw.y, slot.y + slot.height / 2 - 8)
end

-- An open menu always has a selection: the controller rejects empty entries,
-- so a presented menu without a cursor slot is an impossible presentation and
-- must be rejected, never drawn as a background-only surface.
function T.an_open_menu_presentation_requires_a_cursor_slot()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  Assert.throws(function()
    renderer:draw({}, canonicalPlacement())
  end, "an open menu presentation without a cursor slot must be rejected")
  renderer:release()
  Assert.equal(#lg.draws, 0, "no rejected draw reaches the graphics namespace")
end

-- The nil-presentation no-op is the closed-menu channel: with no open menu,
-- the renderer draws nothing (the released-renderer no-op is covered by the
-- release test below).
function T.a_nil_presentation_draws_nothing()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  renderer:draw(nil, canonicalPlacement())
  renderer:release()

  Assert.equal(#lg.draws, 0, "a nil presentation draws nothing")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced")
end

-- The presented frame index selects the manifest frame's quad: frame 0
-- samples the first atlas row, frame 1 the second (the fixture stacks the
-- two frames at y=0 and y=16).
function T.cursor_frame_index_selects_the_frame_quad()
  local function cursorQuad(frameIndex)
    local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
    local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
    renderer:draw({ cursorSlotId = 5, cursorFrameIndex = frameIndex }, canonicalPlacement())
    renderer:release()
    return lg.draws[2].quad
  end
  Assert.deepEqual({ cursorQuad(0).x, cursorQuad(0).y }, { 0, 0 }, "frame 0 samples the first atlas row")
  Assert.deepEqual({ cursorQuad(1).x, cursorQuad(1).y }, { 0, 16 }, "frame 1 samples the second atlas row")
end

-- Slot ids and frame indexes are the manifest's key space: outside values
-- are programming faults, never silently clamped or dropped.
function T.rejects_unknown_slot_ids_and_frame_indexes()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 0, cursorFrameIndex = 0 }, canonicalPlacement())
  end, "slot 0 is outside the generated slot set")
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 11, cursorFrameIndex = 0 }, canonicalPlacement())
  end, "slot 11 is outside the generated slot set")
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 2 }, canonicalPlacement())
  end, "frame 2 is outside the generated frame set")
  renderer:release()
end

-- The Start Menu is not a generic list menu: the surface draws only the two
-- generated images at identity tint. No theme-colored rectangles, polygons,
-- or text primitives may appear.
function T.draws_only_the_generated_images_with_no_generic_menu_styling()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  renderer:draw({ cursorSlotId = 3, cursorFrameIndex = 0 }, canonicalPlacement())
  renderer:release()

  Assert.equal(#lg.primitives, 0, "no themed primitives are drawn")
  for _, call in ipairs(lg.draws) do
    Assert.isTrue(call.image == lg.images[1] or call.image == lg.images[2], "only the generated images are drawn")
    Assert.equal(call.color[1], 1, "draws happen at identity tint")
    Assert.equal(call.color[2], 1)
    Assert.equal(call.color[3], 1)
    Assert.equal(call.color[4], 1)
  end
end

-- The record transform is the render placement: the surface draws under
-- translate(frame origin) + scale(placement scale), with the draw coordinates
-- staying canonical. The record's inverse is exactly what hit testing maps
-- through (StartMenuLayout.hostToLogical), so rendering and hit testing share
-- one transform with no second set of scaled rectangles.
function T.draw_consumes_the_placement_record_transform()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  renderer:draw({ cursorSlotId = 2, cursorFrameIndex = 0 }, {
    surfaceId = "main",
    frame = { x = 1440, y = 360, width = 512, height = 384 },
    scale = 2,
    logicalWidth = 256,
    logicalHeight = 192,
  })
  renderer:release()

  Assert.deepEqual(lg.transforms, {
    { "translate", 1440, 360 },
    { "scale", 2, 2 },
  }, "the placement record drives the render transform")
  Assert.equal(#lg.draws, 2)
  local backgroundDraw = lg.draws[1]
  Assert.equal(backgroundDraw.x, 0, "the draw coordinates stay canonical under the record transform")
  Assert.equal(backgroundDraw.y, 0)
  local slot = FieldUiFixture.START_MENU_SLOTS[2]
  Assert.equal(lg.draws[2].x, slot.x + slot.width / 2 - 8, "the cursor stays centered on the canonical slot")
  Assert.equal(lg.draws[2].y, slot.y + slot.height / 2 - 8)
end

-- The placement record is the renderer's required second argument: a draw
-- without it (or with a partial record) is a programming fault, never a
-- silent fallback to some other placement.
function T.rejects_a_missing_or_partial_placement_record()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  local nilPlacement = nil ---@type any
  local noFrame = { scale = 1 } ---@type any
  local noScale = { frame = { x = 0, y = 0, width = 256, height = 192 } } ---@type any
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, nilPlacement)
  end, "a nil placement record must be rejected")
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, noFrame)
  end, "a placement record without a frame must be rejected")
  Assert.throws(function()
    renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, noScale)
  end, "a placement record without a scale must be rejected")
  Assert.equal(#lg.draws, 0, "no rejected draw reaches the graphics namespace")
  renderer:release()
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
    imageSizes = { { 256, 192 }, { 16, 32 } },
    failOnDrawCall = 2,
  })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })

  local err = Assert.throws(function()
    renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, canonicalPlacement())
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced after a failed draw")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
  renderer:release()
end

-- Release frees the owned images and clears the quads; a draw after release
-- is a no-op (with or without a presentation) and a second release is safe.
function T.release_frees_the_images_and_draw_after_release_is_a_noop()
  local lg = fakeGraphics({ imageSizes = { { 256, 192 }, { 16, 32 } } })
  local renderer = StartMenuRenderer.new({ cacheFs = menuCache(), manifest = MANIFEST, graphics = lg })
  renderer:release()
  renderer:release()

  Assert.isNil(renderer._backgroundImage)
  Assert.isNil(renderer._cursorImage)
  Assert.isNil(renderer._backgroundQuad)
  Assert.isNil(renderer._cursorQuads)
  renderer:draw(nil, canonicalPlacement())
  renderer:draw({ cursorSlotId = 1, cursorFrameIndex = 0 }, canonicalPlacement())
  Assert.equal(#lg.draws, 0, "a released renderer draws nothing")
end

return { tests = T }
