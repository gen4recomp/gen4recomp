-- Failure-path and frame-resolution tests for the dialogue renderer, driven
-- through an injected graphics namespace so the Nth-construction and
-- mid-draw failures can be provoked deterministically: a quad failure after
-- the frame strip exists must release what was acquired, a missing generated
-- UI manifest or frame strip is a typed error, and the player's selected
-- frame index resolves the manifest strip rect (frame 0 vs frame 1 sample
-- different rows, both composed by the canonical frame tilemap). A draw that
-- raises must still balance the transform stack and restore every captured
-- graphics state. The real-context smokes live in
-- field_dialogue_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")

local T = {}

-- The runtime-validated manifest every construction passes in: the renderer
-- never reloads it from the cache itself.
local MANIFEST = FieldUiFixture.manifest()

-- The fake graphics namespace records every draw/transform/primitive and
-- holds the settable state the renderers must restore exactly; the shared
-- helper is tests/support/FakeGraphics.lua.
local fakeGraphics = require("tests.support.FakeGraphics").new

-- A resolved presentation at exactly the field scale: exactly-fitting host
-- bounds so the cap resolves to the requested scale with origin (0,0).
local function presentationAtFieldScale(fieldScale)
  return DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = 256 * fieldScale, height = 48 * fieldScale },
    { maxScale = fieldScale, cursorPlacement = MANIFEST.dialogueFrames.continueCursor.placement }
  )
end

local function uiCache()
  return FieldUiFixture.cacheWithFontAndFrames()
end

local CURSOR_ASSET = "hgss.dialogue_continue_cursor"
local CURSOR_PATH = "assets/generated/field/ui/dialogue-continue-cursor.png"

local function cursorManifest()
  local manifest = FieldUiFixture.manifest()
  manifest.assets[CURSOR_ASSET] = { image = CURSOR_PATH, width = 48, height = 320 }
  manifest.dialogueFrames.frameTiles[2] = { x = 0, y = 16, width = 144, height = 8 }
  manifest.dialogueFrames.frameTiles[3] = { x = 0, y = 24, width = 144, height = 8 }
  manifest.dialogueFrames.count = 4
  manifest.dialogueFrames.continueCursor = {
    asset = CURSOR_ASSET,
    cycle = { 0, 1, 2, 1 },
    framePrinterTicks = 9,
    placement = { x = 240, y = 168, width = 16, height = 16 },
    styles = {
      [3] = {
        phases = {
          [0] = { x = 0, y = 48, width = 16, height = 16 },
          [1] = { x = 16, y = 48, width = 16, height = 16 },
          [2] = { x = 32, y = 48, width = 16, height = 16 },
        },
      },
    },
  }
  return manifest
end

local function cursorCache()
  local cache = uiCache()
  cache:write(CURSOR_PATH, "cursor")
  return cache
end

-- The shared font assets: the fixture font carries three glyphs, so the text
-- renderer creates three images (glyph atlas, semantic mask atlas, and focus
-- strip) and three glyph quads ahead of the dialogue renderer's own strip
-- image and tile quads.
local function withTextRenderer(cache, lg)
  return FieldTextRenderer.new({ cacheFs = cache, graphics = lg })
end

function T.missing_def_is_a_typed_error()
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()) })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FONT_DEF_MISSING", "raises FONT_DEF_MISSING")
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = uiCache(), graphics = false })
  end)
  Assert.isTrue(tostring(err):find("FieldTextRenderer requires love.graphics", 1, true) ~= nil)
end

-- The runtime-validated manifest is a required constructor input: the
-- renderer never reloads the manifest from the cache itself, so a
-- construction without one is rejected.
function T.missing_ui_manifest_is_rejected()
  local lg = fakeGraphics()
  local text = withTextRenderer(FieldDialogueFixture.cacheWithFont(), lg)
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), text = text, graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("requires the runtime-validated field-UI manifest", 1, true) ~= nil)
  text:release()
end

-- The manifest names the frame strip; a cache without the PNG must not build
-- a half-frame renderer. The shared text renderer is caller-owned and stays
-- alive; the renderer itself acquires nothing before the strip read fails.
function T.missing_frame_strip_is_a_typed_error()
  local cache = FieldDialogueFixture.cacheWithFont()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 } } })
  local text = withTextRenderer(cache, lg)
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = cache, manifest = MANIFEST, text = text, graphics = lg })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FIELD_UI_FRAME_ATLAS_MISSING", "raises FIELD_UI_FRAME_ATLAS_MISSING")
  Assert.equal(#lg.images, 3, "the font atlas, mask atlas, and focus strip were acquired before the strip failed")
  Assert.equal(lg.images[1].released, false, "the caller-owned text renderer atlas stays alive")
  Assert.equal(lg.images[2].released, false, "the caller-owned text renderer mask atlas stays alive")
  Assert.equal(lg.images[3].released, false, "the caller-owned text renderer focus strip stays alive")
  text:release()
end

-- The shared text renderer owns the font atlas and its glyph quads: a quad
-- failure after the atlas was created must release the acquired atlas before
-- the constructor rethrows.
function T.text_renderer_constructor_failure_releases_the_atlas()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 } }, failOnQuadCall = 1 })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = uiCache(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil, "rethrows the quad failure")
  Assert.equal(#lg.images, 2, "the font atlas and mask atlas were created before the failure")
  Assert.equal(lg.images[1].released, true, "the atlas was released")
  Assert.equal(lg.images[2].released, true, "the mask atlas was released")
end

-- The shared text renderer built against a cache without the atlas PNG must
-- not report a half-built object: the typed error names the missing artifact.
function T.text_renderer_missing_atlas_is_a_typed_error()
  local cache = uiCache()
  cache:remove("assets/generated/field/font/font-0.png")
  local lg = fakeGraphics({ imageSizes = { { 16, 16 } } })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = cache, graphics = lg })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FONT_ATLAS_MISSING", "raises FONT_ATLAS_MISSING")
  Assert.equal(#lg.images, 0, "no image was created before the atlas read failed")
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
    imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } },
    failOnDrawCall = 1,
  })
  local renderer = FieldDialogueRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = withTextRenderer(uiCache(), lg),
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local err = Assert.throws(function()
    renderer:draw(controller, presentationAtFieldScale(fieldScale))
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced after a failed draw")
  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)

  renderer:release()
end

-- The former nine-slice window is gone: the renderer owns only the frame
-- strip, creates no third slice source image, and draws the frame from the
-- generated strip tiles.
function T.no_nine_slice_assets_are_built()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } } })
  local renderer = FieldDialogueRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = withTextRenderer(uiCache(), lg),
    graphics = lg,
  })
  Assert.equal(#lg.images, 5, "the font atlases, frame strip, and continuation cursor are created")

  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local fieldScale = FieldViewport.new(256, 192, { mode = "expanded" }):logicalPixelScale(1)
  renderer:draw(controller, presentationAtFieldScale(fieldScale))
  Assert.equal(#lg.images, 5, "drawing creates no slice image")
  renderer:release()
end

-- The selected frame index resolves the manifest strip rect: frame 0 samples
-- the first strip row, frame 1 the second, and both place the tiles by the
-- canonical DrawFrameAndWindow2 tilemap around the content box.
function T.frame_index_resolves_the_manifest_strip_tiles()
  local function renderedDraws(frameIndex)
    local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } } })
    local renderer = FieldDialogueRenderer.new({
      cacheFs = uiCache(),
      manifest = MANIFEST,
      text = withTextRenderer(uiCache(), lg),
      graphics = lg,
    })
    local controller = FieldDialogueFixture.openDialogue("AB", frameIndex)
    local fieldScale = FieldViewport.new(256, 192, { mode = "expanded" }):logicalPixelScale(1)
    renderer:draw(controller, presentationAtFieldScale(fieldScale))
    renderer:release()
    return lg.draws
  end

  local frame0 = renderedDraws(0)
  Assert.equal(frame0[1].x, 0, "top-left corner tile at (0,0)")
  Assert.equal(frame0[1].y, 0)
  Assert.deepEqual(
    { frame0[1].quad.x, frame0[1].quad.y, frame0[1].quad.w, frame0[1].quad.h },
    { 0, 0, 8, 8 },
    "tile 0 quad samples the strip's first row"
  )
  Assert.equal(frame0[1].quad.imgW, 144, "frame quads sample the strip atlas")

  -- The top edge is one tile repeated across the 27 content tiles.
  local topEdge = 0
  local expectedX = 16
  for _, call in ipairs(frame0) do
    if call.quad.x == 16 and call.quad.y == 0 then
      topEdge = topEdge + 1
      Assert.equal(call.x, expectedX, "top edge tile spans x=16..232")
      Assert.equal(call.y, 0)
      expectedX = expectedX + 8
    end
  end
  Assert.equal(topEdge, 27, "the top edge repeats the tile across 27 tiles")

  local frame1 = renderedDraws(1)
  Assert.deepEqual({ frame1[1].quad.x, frame1[1].quad.y }, { 0, 8 }, "frame 1 tiles sample the second strip row")
  Assert.equal(frame1[1].x, 0)
  Assert.equal(frame1[1].y, 0, "frame change moves artwork, not geometry")
end

-- A request without a frame index (a host that carries no player options)
-- still draws its text; no frame tiles are fabricated.
function T.request_without_a_frame_index_draws_no_frame_tiles()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } } })
  local renderer = FieldDialogueRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = withTextRenderer(uiCache(), lg),
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB")
  local fieldScale = FieldViewport.new(256, 192, { mode = "expanded" }):logicalPixelScale(1)
  renderer:draw(controller, presentationAtFieldScale(fieldScale))
  for _, call in ipairs(lg.draws) do
    Assert.equal(call.quad.imgW, 16, "only font-atlas quads are drawn without a frame index")
  end
  renderer:release()
end

-- A waiting dialogue samples the generated phase and frame index: it draws the
-- generated cursor quad at the source placement, never a local blink polygon,
-- and repeated draws do not advance the controller-owned phase.
function T.waiting_dialogue_draws_the_generated_cursor_phase_without_blinking()
  local lg = fakeGraphics({
    imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 32 }, { 48, 320 } },
  })
  local cache = cursorCache()
  local text = withTextRenderer(cache, lg)
  local renderer = FieldDialogueRenderer.new({
    cacheFs = cache,
    manifest = cursorManifest(),
    text = text,
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB", 3)
  controller:step({ actionPressed = true })
  for _ = 1, 30 do
    controller:step({})
  end
  local status = controller:status()
  Assert.isTrue(status.waiting, "the dialogue must be waiting at its continuation boundary")
  local fieldScale = FieldViewport.new(256, 192, { mode = "expanded" }):logicalPixelScale(1)
  renderer:draw(controller, presentationAtFieldScale(fieldScale))
  local first = lg.draws[#lg.draws]
  Assert.equal(first.image, lg.images[5], "the continuation uses the generated cursor atlas")
  local expected = cursorManifest().dialogueFrames.continueCursor.styles[3].phases[status.cursorPhase]
  Assert.deepEqual({ first.quad.x, first.quad.y, first.quad.w, first.quad.h }, {
    expected.x,
    expected.y,
    expected.width,
    expected.height,
  })
  Assert.deepEqual({ first.x, first.y }, { 240, 24 })
  Assert.isFalse(#lg.primitives > 1 and lg.primitives[#lg.primitives] == "polygon", "cursor is not a triangle")
  local phaseQuad = first.quad
  renderer:draw(controller, presentationAtFieldScale(fieldScale))
  Assert.equal(lg.draws[#lg.draws].quad, phaseQuad, "draw does not invent timing")
  renderer:release()
  text:release()
end

-- A compact host presentation owns its cursor placement in the same local
-- reference surface as its box and text. The transform maps that placement
-- into an arbitrary host rectangle without changing the generated phase quad.
function T.compact_presentation_places_the_cursor_inside_its_window()
  local lg = fakeGraphics({
    imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 32 }, { 48, 320 } },
  })
  local cache = cursorCache()
  local text = withTextRenderer(cache, lg)
  local renderer = FieldDialogueRenderer.new({
    cacheFs = cache,
    manifest = cursorManifest(),
    text = text,
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB", 3)
  controller:step({ actionPressed = true })
  for _ = 1, 30 do
    controller:step({})
  end
  local status = controller:status()
  local presentation = DialoguePresentationLayout.compute({ x = 37, y = 11, width = 900, height = 420 }, {
    cursorPlacement = cursorManifest().dialogueFrames.continueCursor.placement,
  })

  renderer:draw(controller, presentation)
  local cursor = lg.draws[#lg.draws]
  local expected = cursorManifest().dialogueFrames.continueCursor.styles[3].phases[status.cursorPhase]
  Assert.equal(cursor.image, lg.images[5], "the compact presentation uses the generated cursor atlas")
  Assert.deepEqual({ cursor.quad.x, cursor.quad.y, cursor.quad.w, cursor.quad.h }, {
    expected.x,
    expected.y,
    expected.width,
    expected.height,
  })
  Assert.deepEqual({ cursor.x, cursor.y }, { presentation.cursor.x, presentation.cursor.y })
  local transformedX = presentation.origin.x + cursor.x * presentation.scale
  local transformedY = presentation.origin.y + cursor.y * presentation.scale
  Assert.isTrue(transformedX >= presentation.outerRect.x)
  Assert.isTrue(
    transformedX + cursor.quad.w * presentation.scale <= presentation.outerRect.x + presentation.outerRect.width,
    "the transformed cursor stays inside the compact window horizontally"
  )
  Assert.isTrue(transformedY >= presentation.outerRect.y)
  Assert.isTrue(
    transformedY + cursor.quad.h * presentation.scale <= presentation.outerRect.y + presentation.outerRect.height,
    "the transformed cursor stays inside the compact window"
  )

  renderer:release()
  text:release()
end

-- The content rectangle is an opaque fill using the compiled field-font
-- palette's source slot 15, drawn before the frame and glyphs.
function T.dialogue_content_uses_the_source_background_palette_slot()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } } })
  local text = withTextRenderer(uiCache(), lg)
  text.fontDef.palette = {}
  for index = 1, 16 do
    text.fontDef.palette[index] = { 0.01 * index, 0.02 * index, 0.03 * index, 1 }
  end
  local renderer = FieldDialogueRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = text,
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local fieldScale = FieldViewport.new(256, 192, { mode = "expanded" }):logicalPixelScale(1)
  local presentation = presentationAtFieldScale(fieldScale)
  renderer:draw(controller, presentation)
  Assert.equal(#lg.rectangles, 1, "the content rectangle is explicitly filled")
  Assert.equal(lg.rectangles[1].mode, "fill")
  Assert.deepEqual(lg.rectangles[1].color, text.fontDef.palette[16])
  Assert.equal(lg.rectangles[1].x, presentation.box.x)
  Assert.equal(lg.rectangles[1].y, presentation.box.y)
  Assert.equal(lg.rectangles[1].w, presentation.box.width)
  Assert.equal(lg.rectangles[1].h, presentation.box.height)
  renderer:release()
  text:release()
end

-- A dialogue controller whose single eos page carries the given tokens, so
-- the renderer suites drive the real reveal state machine (the same canned
-- layout convention as FieldDialogueFixture.openDialogue).
local function openedWithTokens(tokens, opts)
  opts = opts or {}
  local controller = FieldDialogueController.new({
    layout = function()
      return {
        pages = { { lines = { { tokens = tokens, width = 0 } }, breakKind = "eos" } },
        warnings = {},
        lineHeight = 8,
        lineSpacing = 0,
      } --[[@as DialogueLayout.Result]]
    end,
    policy = TextSpeedPolicy.forSpeed("mid"),
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
  })
  controller:open({
    id = "focus",
    message = { bankId = 543, messageId = 6, text = "x", tokens = tokens, hadUnresolvedSubstitutions = false },
    allowCancel = false,
  })
  return controller
end

local function glyphToken(code)
  return { kind = "glyph", code = code, text = "x", raw = { code } }
end

local focusToken = FieldDialogueFixture.focusToken
local focusDraws = FieldDialogueFixture.focusDraws

-- The indicator stays hidden while the reveal cursor has not reached
-- its source position (the controller keeps the token out of visibleLines).
function T.focus_indicator_not_reached_by_reveal_is_not_drawn()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } } })
  local renderer = FieldDialogueRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = withTextRenderer(uiCache(), lg),
    graphics = lg,
  })
  local controller = openedWithTokens({ glyphToken(1), glyphToken(2), focusToken(0) }, { printerDelay = 2 })
  controller:step({}) -- opening and two source updates reveal one glyph
  Assert.equal(controller:status().revealedGlyphs, 1, "the reveal cursor has not reached the trailing control")
  local fieldScale = FieldViewport.new(256, 192, { mode = "expanded" }):logicalPixelScale(1)
  renderer:draw(controller, presentationAtFieldScale(fieldScale))
  Assert.equal(#focusDraws(lg), 0, "a not-yet-visible indicator is never drawn")
  renderer:release()
end

-- Once the trailing indicator token is in the visible lines, exactly
-- one indicator frame draws at the content-window right edge (no textInsetX
-- subtraction), under the same reference-frame transform as the dialogue,
-- after the text; the continuation cursor still draws on its own blink
-- semantics -- the two are distinct source concepts, never mutually
-- suppressed.
function T.reached_focus_indicator_draws_at_the_content_window_right_edge()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } } })
  local renderer = FieldDialogueRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = withTextRenderer(uiCache(), lg),
    graphics = lg,
  })
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  local presentation = presentationAtFieldScale(viewport:logicalPixelScale(1))
  local controller = openedWithTokens({ glyphToken(1), glyphToken(2), focusToken(0) })
  controller:step({ actionPressed = true }) -- full reveal; eos page waits
  for _ = 1, 30 do
    controller:step({}) -- cursor blink on
  end
  local status = controller:status()
  Assert.equal(status.waiting, true)
  Assert.isTrue(status.cursorPhase ~= nil, "the continuation cursor exposes its generated phase")

  renderer:draw(controller, presentation)
  local focus = focusDraws(lg)
  Assert.equal(#focus, 1, "exactly one indicator frame is drawn")
  Assert.equal(
    focus[1].x,
    presentation.box.x + presentation.box.width - 24,
    "the indicator sits at the content-window right edge"
  )
  Assert.equal(focus[1].y, presentation.box.y, "the indicator sits at the content-window top")
  Assert.deepEqual(
    { focus[1].quad.x, focus[1].quad.y, focus[1].quad.w, focus[1].quad.h },
    { 0, 0, 24, 32 },
    "field 0 samples its imported strip rect"
  )
  Assert.equal(lg.draws[#lg.draws].quad, focus[1].quad, "the indicator draws after the frame and text")
  Assert.equal(#lg.primitives, 1, "only the opaque window fill is a primitive")
  renderer:release()
end

-- When several indicator tokens are visible in one window state, the
-- last one in source order wins; exactly one frame draws.
function T.the_last_visible_focus_field_wins()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } } })
  local renderer = FieldDialogueRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = withTextRenderer(uiCache(), lg),
    graphics = lg,
  })
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  local presentation = presentationAtFieldScale(viewport:logicalPixelScale(1))
  local controller = openedWithTokens({ glyphToken(1), focusToken(0), focusToken(3) })
  controller:step({ actionPressed = true })
  renderer:draw(controller, presentation)
  local focus = focusDraws(lg)
  Assert.equal(#focus, 1, "multiple visible controls still draw one frame")
  Assert.equal(focus[1].quad.x, 3 * 24, "the last visible field in source order wins")
  Assert.equal(
    focus[1].x,
    presentation.box.x + presentation.box.width - 24,
    "the frame keeps the content-window right-edge placement"
  )
  Assert.equal(focus[1].y, presentation.box.y)
  renderer:release()
end

local function recordingTextRenderer(focusCalls, lineCalls)
  return {
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
    drawLine = function()
      lineCalls[#lineCalls + 1] = true
    end,
    drawFocusIndicator = function(_, field, x, y)
      focusCalls[#focusCalls + 1] = { field = field, x = x, y = y }
    end,
  }
end

-- Focus-indicator visibility is renderer composition policy: the default
-- remains visible, while Oak's explicitly disabled renderer still draws text
-- and its dialogue window without publishing a focus-indicator call.
function T.focus_indicator_visibility_follows_renderer_policy()
  local function drawWithPolicy(disabled)
    local lg = fakeGraphics({ imageSizes = { { 96, 32 }, { 144, 16 } } })
    local cache = uiCache()
    local focusCalls = {}
    local lineCalls = {}
    local renderer = FieldDialogueRenderer.new({
      cacheFs = cache,
      manifest = MANIFEST,
      text = recordingTextRenderer(focusCalls, lineCalls),
      graphics = lg,
      drawFocusIndicator = not disabled,
    })
    local controller = openedWithTokens({ glyphToken(1), focusToken(0) })
    controller:step({ actionPressed = true })
    local fieldScale = FieldViewport.new(256, 192, { mode = "expanded" }):logicalPixelScale(1)
    renderer:draw(controller, presentationAtFieldScale(fieldScale))
    renderer:release()
    return focusCalls, lineCalls
  end

  local defaultFocus, defaultLines = drawWithPolicy(false)
  Assert.equal(#defaultFocus, 1, "the default renderer preserves focus-indicator drawing")
  Assert.isTrue(#defaultLines > 0, "the default renderer still draws dialogue content")

  local disabledFocus, disabledLines = drawWithPolicy(true)
  Assert.equal(#disabledFocus, 0, "the disabled renderer suppresses focus-indicator drawing")
  Assert.isTrue(#disabledLines > 0, "disabling focus does not suppress dialogue content")
end

-- A closed controller draws nothing and requires no presentation: the
-- inactive path returns before touching graphics state or validating.
function T.closed_controller_ignores_a_missing_presentation()
  local lg = fakeGraphics({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 144, 16 } } })
  local renderer = FieldDialogueRenderer.new({
    cacheFs = uiCache(),
    manifest = MANIFEST,
    text = withTextRenderer(uiCache(), lg),
    graphics = lg,
  })
  local controller = FieldDialogueController.new({
    layout = function()
      return { pages = {}, warnings = {}, lineHeight = 0, lineSpacing = 0 }
    end,
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
  })
  Assert.isFalse(controller:isModal(), "the controller was never opened")
  renderer:draw(controller, nil)
  Assert.equal(#lg.draws, 0, "a closed dialogue draws nothing")
  Assert.equal(lg.pushDepth(), 0, "a closed dialogue touches no transform state")
  renderer:release()
end

return { tests = T }
