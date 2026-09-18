-- Failure-path and manifest-authority tests for the Start Menu SUB selector
-- renderer, driven through an injected graphics namespace so the
-- Nth-construction and mid-draw failures can be provoked deterministically.
-- The renderer resolves the whole canonical surface from the generated
-- manifest's `startMenu` section (the SUB chrome, the icon table with
-- source-composed normal/selected visuals, and the interactive position
-- records) and never repeats source coordinates; an acquisition or quad
-- failure after images exist must release everything acquired so far, and a
-- missing manifest, SUB chrome, or icon atlas is a typed error. Drawing the
-- surface consumes the StartMenuLayout placement record -- the same record
-- hit testing maps through -- so rendering and hit testing share one
-- transform and there is never a second set of scaled rectangles; the
-- surface uses only the generated images -- no generic field-menu theme
-- colors or primitives -- and a draw that raises must still balance the
-- transform stack and restore every captured graphics state. The
-- real-context smokes live in start_menu_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")
local StartMenuRenderer = require("libs.hgss.src.ui.StartMenuRenderer")

local T = {}

-- The runtime-validated manifest every construction passes in: the renderer
-- never reloads it from the cache itself.
local function iconManifest()
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addStartMenuIconContract(manifest)
  return manifest
end

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

-- A cache carrying the SUB selector PNGs the icon contract indexes: the SUB
-- chrome plus the shared icon atlas (normal band over the selected band)
-- and the palette record.
local function iconCache(manifest)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldUiFixture.writeStartMenuSelectorPngs(cache)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  return cache
end

local ICON_MANIFEST = iconManifest()

-- Recording stand-in for the shared FieldTextRenderer: palette-driven
-- draws record beside plain draws, and the generated font palette carries
-- the slots the renderer resolves its label roles from.
local function recordingText()
  local text = {
    draws = {},
    fontDef = {
      palette = { [15] = { r = 1, g = 2, b = 3 }, [3] = { r = 4, g = 5, b = 6 }, [1] = { r = 7, g = 8, b = 9 } },
    },
  }
  function text.drawText(_, str, x, y)
    text.draws[#text.draws + 1] = { text = str, x = x, y = y }
  end
  function text.drawTextWithPalette(_, str, x, y, palette)
    text.draws[#text.draws + 1] = { text = str, x = x, y = y, palette = palette }
  end
  function text.textWidth(_, str)
    return #str * 8
  end
  return text
end

-- The runtime-validated manifest is a required constructor input: the
-- renderer never reloads the manifest from the cache itself, so a
-- construction without one is rejected.
function T.missing_manifest_is_rejected()
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()), text = recordingText() })
  end)
  Assert.isTrue(tostring(err):find("requires the runtime-validated field-UI manifest", 1, true) ~= nil)
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    StartMenuRenderer.new({
      cacheFs = iconCache(ICON_MANIFEST),
      manifest = ICON_MANIFEST,
      text = recordingText(),
      graphics = false,
    })
  end)
  Assert.isTrue(tostring(err):find("StartMenuRenderer requires love.graphics", 1, true) ~= nil)
end

function T.rejects_a_missing_text_collaborator()
  local err = Assert.throws(function()
    local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
    StartMenuRenderer.new({ cacheFs = iconCache(ICON_MANIFEST), manifest = ICON_MANIFEST, graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("requires the shared text collaborator", 1, true) ~= nil)
end

-- The manifest names the SUB chrome asset; a cache without that PNG must
-- not build a half-surface renderer.
function T.missing_sub_chrome_asset_is_a_typed_error()
  local cache = iconCache(ICON_MANIFEST)
  cache:remove("assets/generated/field/ui/start-menu-chrome-sub.png")
  local err = Assert.throws(function()
    local lg = fakeGraphics({ imageSizes = { { 256, 256 } } })
    StartMenuRenderer.new({ cacheFs = cache, manifest = ICON_MANIFEST, text = recordingText(), graphics = lg })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_UI_START_MENU_CHROME_MISSING",
    "raises FIELD_UI_START_MENU_CHROME_MISSING"
  )
end

-- A missing icon atlas after the SUB chrome was acquired must release the
-- chrome before raising.
function T.missing_icons_asset_is_a_typed_error_and_releases_the_chrome()
  local cache = iconCache(ICON_MANIFEST)
  cache:remove("assets/generated/field/ui/start-menu-icons.png")
  local lg = fakeGraphics({ imageSizes = { { 256, 256 } } })
  local err = Assert.throws(function()
    StartMenuRenderer.new({ cacheFs = cache, manifest = ICON_MANIFEST, text = recordingText(), graphics = lg })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_UI_START_MENU_ICONS_MISSING",
    "raises FIELD_UI_START_MENU_ICONS_MISSING"
  )
  Assert.equal(#lg.images, 1, "the sub chrome was acquired before the atlas failed")
  Assert.equal(lg.images[1].released, true, "the acquired chrome was released")
end

-- A quad failure after both images were created must release both before
-- the constructor rethrows.
function T.constructor_quad_failure_releases_every_acquired_image()
  local lg = fakeGraphics({
    imageSizes = { { 256, 256 }, { 352, 80 } },
    failOnQuadCall = 2,
  })
  local err = Assert.throws(function()
    StartMenuRenderer.new({
      cacheFs = iconCache(ICON_MANIFEST),
      manifest = ICON_MANIFEST,
      text = recordingText(),
      graphics = lg,
    })
  end)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil, "rethrows the quad failure")
  Assert.equal(#lg.images, 2, "sub chrome and icon atlas were created before the failure")
  Assert.equal(lg.images[1].released, true, "the sub chrome was released")
  Assert.equal(lg.images[2].released, true, "the icon atlas was released")
end

-- An image failure on the second acquisition must release the first image:
-- partial acquisition never leaks.
function T.constructor_second_image_failure_releases_the_first_image()
  local lg = fakeGraphics({
    imageSizes = { { 256, 256 }, { 352, 80 } },
    failOnImageCall = 2,
  })
  local err = Assert.throws(function()
    StartMenuRenderer.new({
      cacheFs = iconCache(ICON_MANIFEST),
      manifest = ICON_MANIFEST,
      text = recordingText(),
      graphics = lg,
    })
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image failure")
  Assert.equal(#lg.images, 1, "only the sub chrome was created before the failure")
  Assert.equal(lg.images[1].released, true, "the sub chrome was released exactly once")
end

-- The renderer resolves the whole surface from the manifest's startMenu
-- section: the SUB chrome, the icon table with composed visuals, and the
-- interactive position records. The fixture's values are the only authority;
-- the renderer must not carry its own copy of the geometry.
function T.resolves_the_start_menu_section_from_the_manifest()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  local manifest = iconManifest().startMenu

  Assert.deepEqual(
    renderer.menu.interactive,
    manifest.interactive,
    "the interactive position records come from the manifest"
  )
  Assert.deepEqual(renderer.menu.iconTable, manifest.iconTable, "the icon table comes from the manifest")
  renderer:release()
end

-- A non-canonical manifest is resolved verbatim: a hard-coded grid would
-- fail this test, which is what keeps the generated metadata the authority
-- (no source coordinates may be repeated in runtime code).
function T.the_manifest_geometry_is_the_authority_not_a_hard_coded_grid()
  local manifest = iconManifest()
  manifest.startMenu.interactive = {
    cancelHitRect = { x = 8, y = 0, width = 152, height = 16 },
    positions = {
      [0] = {
        anchor = { x = 30, y = 40 },
        labelWindow = { x = 8, y = 48, width = 72, height = 16 },
        hitRect = { x = 16, y = 22, width = 60, height = 32 },
        navigation = { up = { 0, 0, 0 }, down = { 0, 0, 0 }, left = { 0, 0, 0 }, right = { 0, 0, 0 } },
      },
    },
  }
  local row = assert(manifest.startMenu.iconTable[1])
  row.visual.normal.offset = { x = 5, y = -3 }
  row.visual.selected.offset = { x = 5, y = -3 }
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer =
    StartMenuRenderer.new({ cacheFs = iconCache(manifest), manifest = manifest, text = recordingText(), graphics = lg })
  Assert.deepEqual(renderer.menu.interactive.positions[0].anchor, { x = 30, y = 40 })

  -- The icon draws at the manifest anchor plus the visual offset: no
  -- centering correction is ever applied.
  renderer:draw({
    selectedPosition = 0,
    actions = { { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" } },
  }, canonicalPlacement())
  local iconDraw = lg.draws[2]
  Assert.equal(iconDraw.x, 30 + 5, "the icon lands at the anchor plus the visual offset")
  Assert.equal(iconDraw.y, 40 - 3)
  renderer:release()
end

-- The canonical selector surface: the SUB chrome at the canonical origin,
-- then each presented action's normal icon at its anchor plus offset with
-- its label in the action's own label window.
function T.draws_the_sub_background_then_icons_with_labels()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local text = recordingText()
  local renderer =
    StartMenuRenderer.new({ cacheFs = iconCache(ICON_MANIFEST), manifest = ICON_MANIFEST, text = text, graphics = lg })
  renderer:draw({
    selectedPosition = 1,
    trainerGender = "male",
    actions = {
      { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" },
      { id = "vanilla.pokemon", position = 1, icon = 1, label = "POKEMON" },
    },
  }, canonicalPlacement())
  renderer:release()

  Assert.equal(#lg.draws, 3, "one sub background draw plus two icon draws")
  local backgroundDraw = lg.draws[1]
  Assert.equal(backgroundDraw.image, lg.images[1], "the sub chrome image is drawn first")
  Assert.deepEqual(
    { backgroundDraw.quad.x, backgroundDraw.quad.y, backgroundDraw.quad.w, backgroundDraw.quad.h },
    { 0, 0, 256, 256 }
  )
  Assert.equal(backgroundDraw.x, 0, "the sub chrome covers the canonical origin")
  Assert.equal(backgroundDraw.y, 0)
  -- Icon rows 1 and 2 are the first two sprite cells: normal rects at
  -- (0,0) and (32,0); anchors (24,22) and (24,62) with zero offsets.
  Assert.deepEqual({ lg.draws[2].quad.x, lg.draws[2].quad.y }, { 0, 0 }, "the first icon samples its normal rect")
  Assert.deepEqual({ lg.draws[2].x, lg.draws[2].y }, { 24, 22 }, "the first icon lands at its anchor")
  -- Position 1 holds the selection, so the second icon draws its selected
  -- visual from the bottom band.
  Assert.deepEqual(
    { lg.draws[3].quad.x, lg.draws[3].quad.y },
    { 32, 40 },
    "the selected icon samples its selected rect"
  )
  Assert.deepEqual({ lg.draws[3].x, lg.draws[3].y }, { 24, 62 }, "the selected icon lands at its anchor")
  Assert.equal(#text.draws, 2, "both resolved labels reach the shared text stack")
  Assert.equal(text.draws[1].text, "POKEDEX")
  Assert.equal(text.draws[2].text, "POKEMON")
end

-- The Bag icon is conditional on trainer gender: the female variant is a
-- first-class visual pair, not an unmapped spare.
function T.female_bag_variant_draws_the_conditional_icon_art()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  renderer:draw({
    selectedPosition = 2,
    trainerGender = "female",
    actions = {
      { id = "vanilla.bag", position = 2, icon = 2, label = "BAG" },
    },
  }, canonicalPlacement())
  renderer:release()

  -- The Bag row is the third sprite cell with its female pair at cell 10;
  -- position 2 holds the selection, so the female selected rect is sampled.
  local bagDraw = lg.draws[2]
  Assert.deepEqual(
    { bagDraw.quad.x, bagDraw.quad.y, bagDraw.quad.w, bagDraw.quad.h },
    { 10 * 32, 40, 32, 40 },
    "the female bag draws the conditional selected visual, not the default"
  )
  Assert.deepEqual({ bagDraw.x, bagDraw.y }, { 24, 102 }, "the female bag lands at the position anchor")
end

-- Selection is a visual swap, not cursor placement: the selected action's
-- icon draws its selected visual while unselected icons draw their normal
-- visuals, all from the shared atlas.
function T.selected_entry_draws_its_selected_visual()
  local manifest = iconManifest()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer =
    StartMenuRenderer.new({ cacheFs = iconCache(manifest), manifest = manifest, text = recordingText(), graphics = lg })
  renderer:draw({
    selectedPosition = 0,
    trainerGender = "male",
    actions = {
      { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" },
      { id = "vanilla.pokemon", position = 1, icon = 1, label = "POKEMON" },
    },
  }, canonicalPlacement())
  renderer:release()

  local iconDraws = { lg.draws[2], lg.draws[3] }
  Assert.deepEqual(
    { iconDraws[1].quad.x, iconDraws[1].quad.y },
    { 0, 40 },
    "the selected pokedex icon samples its selected visual"
  )
  Assert.deepEqual(
    { iconDraws[2].quad.x, iconDraws[2].quad.y },
    { 32, 0 },
    "the unselected pokemon icon samples its normal visual"
  )
  Assert.equal(iconDraws[1].image, iconDraws[2].image, "both visuals share the icon atlas")
end

-- Text-only icon-table rows carry no art: their actions draw labels without
-- an icon draw, and poke-icon rows without a poke asset draw nothing either.
function T.text_only_rows_draw_labels_without_icon_art()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local text = recordingText()
  local renderer =
    StartMenuRenderer.new({ cacheFs = iconCache(ICON_MANIFEST), manifest = ICON_MANIFEST, text = text, graphics = lg })
  renderer:draw({
    selectedPosition = 0,
    trainerGender = "male",
    actions = {
      { id = "vanilla.ball", position = 0, icon = 8, label = "BALL" },
    },
  }, canonicalPlacement())
  renderer:release()

  Assert.equal(#lg.draws, 1, "a text-only row draws no icon art, only the sub background")
  Assert.equal(#text.draws, 1, "the text-only row still draws its label")
  Assert.equal(text.draws[1].text, "BALL")
end

-- Labels center in their own source label window: windows are keyed by
-- source position, never by presentation order, so a sparse action list
-- still labels the right row.
function T.labels_draw_centered_in_their_own_position_windows()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local text = recordingText()
  local renderer =
    StartMenuRenderer.new({ cacheFs = iconCache(ICON_MANIFEST), manifest = ICON_MANIFEST, text = text, graphics = lg })
  renderer:draw({
    selectedPosition = 5,
    trainerGender = "male",
    actions = {
      { id = "vanilla.save", position = 5, icon = 5, label = "SAVE" },
    },
  }, canonicalPlacement())
  renderer:release()

  Assert.equal(#text.draws, 1)
  -- Position 5 labels from { x = 88, y = 88, width = 72 }: "SAVE" is 32px
  -- wide through the recording text, so x centers at 88 + (72 - 32) / 2.
  Assert.deepEqual({ text.draws[1].x, text.draws[1].y }, { 88 + 20, 88 })
end

-- Source positions and icon indices are the manifest's key space: outside
-- values are programming faults, never silently clamped or dropped.
function T.rejects_unknown_positions_and_icon_indices()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  Assert.throws(function()
    renderer:draw({ selectedPosition = 7, actions = {} }, canonicalPlacement())
  end, "position 7 is outside the generated position set")
  Assert.throws(function()
    renderer:draw({
      selectedPosition = 0,
      actions = { { id = "vanilla.save", position = 7, icon = 5, label = "SAVE" } },
    }, canonicalPlacement())
  end, "an action at position 7 is outside the generated position set")
  Assert.throws(function()
    renderer:draw({
      selectedPosition = 0,
      actions = { { id = "vanilla.save", position = 0, icon = 99, label = "SAVE" } },
    }, canonicalPlacement())
  end, "icon 99 is outside the icon table")
  renderer:release()
  Assert.equal(#lg.draws, 0, "no rejected draw reaches the graphics namespace")
end

-- An open menu always has a selection: the controller rejects empty
-- entries, so a presented menu without a selected position is an impossible
-- presentation and must be rejected, never drawn as a background-only
-- surface.
function T.an_open_menu_presentation_requires_a_selected_position()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  Assert.throws(function()
    renderer:draw({}, canonicalPlacement())
  end, "an open menu presentation without a selected position must be rejected")
  renderer:release()
  Assert.equal(#lg.draws, 0, "no rejected draw reaches the graphics namespace")
end

-- The nil-presentation no-op is the closed-menu channel: with no open menu,
-- the renderer draws nothing (the released-renderer no-op is covered by the
-- release test below).
function T.a_nil_presentation_draws_nothing()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  renderer:draw(nil, canonicalPlacement())
  renderer:release()

  Assert.equal(#lg.draws, 0, "a nil presentation draws nothing")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced")
end

-- The Start Menu is not a generic list menu: the surface draws only the
-- generated images at identity tint. No theme-colored rectangles, polygons,
-- or text primitives may appear.
function T.draws_only_the_generated_images_with_no_generic_menu_styling()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  renderer:draw({
    selectedPosition = 2,
    trainerGender = "male",
    actions = {
      { id = "vanilla.bag", position = 2, icon = 2, label = "BAG" },
    },
  }, canonicalPlacement())
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
-- translate(frame origin) + scale(placement scale), with the draw
-- coordinates staying canonical. The record's inverse is exactly what hit
-- testing maps through (StartMenuLayout.hostToLogical), so rendering and
-- hit testing share one transform with no second set of scaled rectangles.
function T.draw_consumes_the_placement_record_transform()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  renderer:draw({
    selectedPosition = 0,
    actions = { { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" } },
  }, {
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
  Assert.deepEqual({ lg.draws[2].x, lg.draws[2].y }, { 24, 22 }, "the icon stays at the canonical anchor plus offset")
end

-- The placement record is the renderer's required second argument: a draw
-- without it (or with a partial record) is a programming fault, never a
-- silent fallback to some other placement.
function T.rejects_a_missing_or_partial_placement_record()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  local presentation = { selectedPosition = 0, actions = {} }
  local nilPlacement = nil ---@type any
  local noFrame = { scale = 1 } ---@type any
  local noScale = { frame = { x = 0, y = 0, width = 256, height = 192 } } ---@type any
  Assert.throws(function()
    renderer:draw(presentation, nilPlacement)
  end, "a nil placement record must be rejected")
  Assert.throws(function()
    renderer:draw(presentation, noFrame)
  end, "a placement record without a frame must be rejected")
  Assert.throws(function()
    renderer:draw(presentation, noScale)
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
    imageSizes = { { 256, 256 }, { 352, 80 } },
    failOnDrawCall = 2,
  })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })

  local err = Assert.throws(function()
    renderer:draw({
      selectedPosition = 0,
      actions = { { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" } },
    }, canonicalPlacement())
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced after a failed draw")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
  renderer:release()
end

-- Labels render through the palette-driven text path with the generated
-- start menu record, centered in their own source label window exactly as
-- before. The shared manifest record is the only label color authority:
-- the text collaborator's font palette, when present, is never consulted.
function T.labels_draw_through_the_palette_path_with_the_generated_record()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local text = recordingText()
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = text,
    graphics = lg,
  })
  renderer:draw({
    selectedPosition = 0,
    trainerGender = "male",
    actions = {
      { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" },
    },
  }, canonicalPlacement())
  renderer:release()

  Assert.equal(#text.draws, 1, "the resolved label reaches the palette-driven text path")
  local draw = text.draws[1]
  Assert.equal(draw.text, "POKEDEX")
  Assert.deepEqual(
    draw.palette.foreground,
    ICON_MANIFEST.startMenu.labelPalette.foreground,
    "the foreground comes from the generated start menu record, not the font palette"
  )
  Assert.deepEqual(
    draw.palette.shadow,
    ICON_MANIFEST.startMenu.labelPalette.shadow,
    "the shadow comes from the generated start menu record, not the font palette"
  )
  Assert.equal(draw.palette.background.a, 0, "the label background stays transparent over chrome")
  -- Position 0 labels from { x = 8, y = 48, width = 72 }: "POKEDEX" is
  -- 56px wide through the recording text, so x centers at 8 + (72-56)/2.
  Assert.deepEqual({ draw.x, draw.y }, { 8 + 8, 48 }, "the palette path keeps label centering")
end

-- A manifest without the generated label record cannot build the surface:
-- the renderer fails loudly instead of falling back to the font palette.
function T.rejects_a_manifest_without_the_generated_label_palette()
  local manifest = iconManifest()
  manifest.startMenu.labelPalette = nil
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local err = Assert.throws(function()
    StartMenuRenderer.new({
      cacheFs = iconCache(manifest),
      manifest = manifest,
      text = recordingText(),
      graphics = lg,
    })
  end)
  Assert.isTrue(
    tostring(err):find("must carry the start menu label palette", 1, true) ~= nil,
    "construction names the missing generated label record"
  )
end

-- Labels consume the generated start menu palette record with a
-- compositing-transparent background: the text collaborator needs no font
-- palette for label colors and glyph background pixels reveal chrome.
function T.labels_use_the_generated_start_menu_palette_with_transparent_background()
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addStartMenuIconContract(manifest)
  manifest.startMenu.labelPalette = {
    foreground = { r = 248, g = 248, b = 248, a = 1 },
    shadow = { r = 112, g = 112, b = 112, a = 1 },
    background = { r = 40, g = 48, b = 56, a = 0 },
  }
  local text = { draws = {}, plainDraws = {} }
  function text.drawText(_, str, x, y)
    text.plainDraws[#text.plainDraws + 1] = { text = str, x = x, y = y }
  end
  function text.drawTextWithPalette(_, str, x, y, labelPalette)
    text.draws[#text.draws + 1] = { text = str, x = x, y = y, palette = labelPalette }
  end
  function text.textWidth(_, str)
    return #str * 8
  end
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(manifest),
    manifest = manifest,
    text = text,
    graphics = lg,
  })
  renderer:draw({
    selectedPosition = 0,
    trainerGender = "male",
    actions = {
      { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" },
    },
  }, canonicalPlacement())
  renderer:release()
  Assert.equal(#text.draws, 1, "the resolved label reaches the palette-driven text path")
  Assert.equal(#text.plainDraws, 0, "labels must not use the plain text path")
  local draw = text.draws[1]
  Assert.deepEqual(
    draw.palette.foreground,
    manifest.startMenu.labelPalette.foreground,
    "the foreground comes from the generated start menu record"
  )
  Assert.deepEqual(
    draw.palette.shadow,
    manifest.startMenu.labelPalette.shadow,
    "the shadow comes from the generated start menu record"
  )
  Assert.equal(draw.palette.background.a, 0, "the label background stays transparent over chrome")
  Assert.equal(draw.palette.foreground.a, 1, "the transparent background keeps the foreground opaque")
  Assert.equal(draw.palette.shadow.a, 1, "the transparent background keeps the shadow opaque")
end

-- Labels draw only through the palette-driven text path, so a text
-- collaborator without that path cannot build the surface.
function T.rejects_a_text_collaborator_without_the_palette_path()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local plainText = { draws = {} }
  function plainText.drawText(_, str, x, y)
    plainText.draws[#plainText.draws + 1] = { text = str, x = x, y = y }
  end
  function plainText.textWidth(_, str)
    return #str * 8
  end
  Assert.throws(function()
    StartMenuRenderer.new({
      cacheFs = iconCache(ICON_MANIFEST),
      manifest = ICON_MANIFEST,
      text = plainText,
      graphics = lg,
    })
  end)
end

-- Release frees the owned images and clears the quads; a draw after release
-- is a no-op (with or without a presentation) and a second release is safe.
function T.release_frees_the_images_and_draw_after_release_is_a_noop()
  local lg = fakeGraphics({ imageSizes = { { 256, 256 }, { 352, 80 } } })
  local renderer = StartMenuRenderer.new({
    cacheFs = iconCache(ICON_MANIFEST),
    manifest = ICON_MANIFEST,
    text = recordingText(),
    graphics = lg,
  })
  renderer:release()
  renderer:release()

  Assert.isNil(renderer._subImage)
  Assert.isNil(next(renderer._imageByAsset))
  renderer:draw(nil, canonicalPlacement())
  renderer:draw({ selectedPosition = 0, actions = {} }, canonicalPlacement())
  Assert.equal(#lg.draws, 0, "a released renderer draws nothing")
end

return { tests = T }
