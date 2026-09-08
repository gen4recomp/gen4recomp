-- Graphics smoke tests for the dialogue renderer: the synthetic font atlas is
-- decoded into a real Image, the box is drawn at every host aspect, the frame
-- is rendered at canonical 256x192 and compared pixel-exact against an
-- independently composed reference for two frame styles (frame 0 and frame 1
-- of the fixture strip, mirroring the compiled class's distinct palettes),
-- and every graphics state the draw touched is proven restored against the
-- real driver. The construction/draw failure paths are injected fakes and
-- stay in field_dialogue_renderer_test.lua.

local Assert = require("tests.support.Assert")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192
local CURSOR_PLACEMENT = FieldUiFixture.manifest().dialogueFrames.continueCursor.placement

local function renderer(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return scope:own(FieldDialogueRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = FieldUiFixture.manifest(),
    text = text,
  }))
end

-- Steps a fixture dialogue until its text is fully revealed and the cursor is
-- at phase zero, so the canonical render is deterministic.
---@param controller FieldDialogueController
local function settleDialogue(controller)
  controller:step({})
  for _ = 1, 100 do
    local status = controller:status()
    if status.state == "WAITING_CLOSE" and status.cursorPhase == 0 then
      break
    end
    controller:step({})
  end
  local status = controller:status()
  Assert.equal(status.state, "WAITING_CLOSE")
  Assert.equal(status.cursorPhase, 0, "cursor phase is deterministic in the settled render")
end

-- The canonical 256x192 render of the fixture dialogue for one frame style.
---@param scope GraphicsScope
---@param frameIndex integer
---@return love.ImageData
local function canonicalRender(scope, frameIndex)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB", frameIndex)
  settleDialogue(controller)
  local viewport = FieldViewport.new(CANONICAL_WIDTH, CANONICAL_HEIGHT, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local presentation = DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = CANONICAL_WIDTH, height = CANONICAL_HEIGHT },
    { maxScale = fieldScale, cursorPlacement = CURSOR_PLACEMENT }
  )
  local canvas = scope:own(lg.newCanvas(CANONICAL_WIDTH, CANONICAL_HEIGHT))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  dialogue:draw(controller, presentation)
  lg.setCanvas()
  return scope:own(canvas:newImageData())
end

-- The independent reference for the canonical render: the fixture's own tile
-- bytes placed by the frame tilemap, the opaque field-window fill, and the
-- fixture font's two glyphs at the layout text origin. Built without the
-- renderer, so a draw regression (wrong quad, wrong position, wrong frame row,
-- wrong scale) is a mismatch.
---@param frameIndex integer
---@return love.ImageData
local function goldenReference(frameIndex)
  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local rgba = FieldUiFixture.framePixels(frameIndex)
  local presentation = DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = CANONICAL_WIDTH, height = CANONICAL_HEIGHT },
    {
      maxScale = FieldViewport.new(CANONICAL_WIDTH, CANONICAL_HEIGHT, { mode = "expanded" }):logicalPixelScale(1),
      cursorPlacement = CURSOR_PLACEMENT,
    }
  )
  local placements = FieldDialogueTheme.frameTilePlacements({
    x = presentation.box.x,
    y = presentation.box.y,
    width = presentation.box.width,
    height = presentation.box.height,
  } --[[@as FieldDialogueTheme.Rect]])
  local function paste(x, y, r, g, b, a)
    reference:setPixel(math.floor(x), math.floor(y), r, g, b, a)
  end
  local function pasteLocal(lx, ly, r, g, b, a)
    paste(presentation.origin.x + lx * presentation.scale, presentation.origin.y + ly * presentation.scale, r, g, b, a)
  end
  for _, p in ipairs(placements) do
    for row = 0, (p.spanY or 1) - 1 do
      for col = 0, (p.spanX or 1) - 1 do
        for ty = 0, 7 do
          for tx = 0, 7 do
            local index = (ty * 144 + p.tile * 8 + tx) * 4 + 1
            pasteLocal(
              p.x + col * 8 + tx,
              p.y + row * 8 + ty,
              rgba:byte(index) / 255,
              rgba:byte(index + 1) / 255,
              rgba:byte(index + 2) / 255,
              rgba:byte(index + 3) / 255
            )
          end
        end
      end
    end
  end
  local background = FieldDialogueFixture.fontDef().palette[16]
  for y = presentation.box.y, presentation.box.y + presentation.box.height - 1 do
    for x = presentation.box.x, presentation.box.x + presentation.box.width - 1 do
      pasteLocal(x, y, background.r, background.g, background.b, 1)
    end
  end
  -- Text: glyph A (atlas columns 0..7, red) then glyph B (columns 8..15,
  -- green), both 8x16 at the presentation text origin with advance 6.
  local glyphs = {
    { x = presentation.text.x, red = true },
    { x = presentation.text.x + 6, red = false },
  }
  for _, glyph in ipairs(glyphs) do
    for ty = 0, 15 do
      for tx = 0, 7 do
        if glyph.red then
          pasteLocal(glyph.x + tx, presentation.text.y + ty, 200 / 255, 40 / 255, 40 / 255, 1)
        else
          pasteLocal(glyph.x + tx, presentation.text.y + ty, 40 / 255, 200 / 255, 40 / 255, 1)
        end
      end
    end
  end
  local cursorR, cursorG, cursorB = FieldUiFixture.continueCursorColor(frameIndex, 0)
  for y = 0, 15 do
    for x = 0, 15 do
      pasteLocal(presentation.cursor.x + x, presentation.cursor.y + y, cursorR / 255, cursorG / 255, cursorB / 255, 1)
    end
  end
  return reference
end

-- Compares two ImageData buffers 8-bit channel by 8-bit channel; a single
-- differing pixel fails with its canonical coordinates.
local function assertPixelsEqual(expected, actual, label)
  Assert.equal(expected:getWidth(), actual:getWidth(), label .. " width")
  Assert.equal(expected:getHeight(), actual:getHeight(), label .. " height")
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
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

function T.loads_the_shared_font_atlas_and_own_frame_strip(scope)
  local dialogue = renderer(scope)

  Assert.equal(dialogue._text.fontDef.schema, FieldFontCache.SCHEMA)
  Assert.notNil(dialogue._text._atlas)
  Assert.equal(dialogue._text._atlas:getWidth(), 16)
  Assert.notNil(dialogue._window, "the shared window primitive is owned")
  Assert.notNil(dialogue._window._frameImage, "the generated frame strip is loaded")
  Assert.equal(dialogue._window._frameImage:getWidth(), 144)
end

function T.restores_graphics_state_after_draw(scope)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB")
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

  dialogue:draw(
    controller,
    DialoguePresentationLayout.compute(viewport.referenceFrame, {
      maxScale = viewport:logicalPixelScale(1),
      cursorPlacement = CURSOR_PLACEMENT,
    })
  )

  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
end

function T.a_closed_controller_draws_nothing_and_changes_no_state(scope)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueController.new({
    layout = function()
      return { pages = {}, warnings = {}, lineHeight = 0, lineSpacing = 0 }
    end,
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
  })

  lg.setColor(0.1, 0.2, 0.3, 0.4)
  local viewport = FieldViewport.new(960, 720, { mode = "expanded" })
  dialogue:draw(
    controller,
    DialoguePresentationLayout.compute(viewport.referenceFrame, {
      maxScale = viewport:logicalPixelScale(1),
      cursorPlacement = CURSOR_PLACEMENT,
    })
  )

  Assert.near(lg.getColor(), 0.1, 1e-6)
  Assert.isNil(lg.getShader())
end

function T.draws_inside_the_reference_frame_at_every_host_aspect(scope)
  local dialogue = renderer(scope)

  for _, size in ipairs({ { 960, 720 }, { 1280, 720 }, { 1920, 720 }, { 640, 480 } }) do
    local controller = FieldDialogueFixture.openDialogue("AB", 0)
    local viewport = FieldViewport.new(size[1], size[2], { mode = "expanded" })
    local presentation = DialoguePresentationLayout.compute(viewport.referenceFrame, {
      maxScale = viewport:logicalPixelScale(1),
      cursorPlacement = CURSOR_PLACEMENT,
    })
    dialogue:draw(controller, presentation)

    -- The resolved 256x48 strip must fit the host rectangle that produced
    -- it at every host aspect.
    local outer = presentation.outerRect
    local host = presentation.bounds
    local label = size[1] .. "x" .. size[2]
    Assert.isTrue(outer.x >= host.x - 1e-9, "dialogue inside host at " .. label)
    Assert.isTrue(outer.x + outer.width <= host.x + host.width + 1e-9, "dialogue inside host at " .. label)
    Assert.isTrue(outer.y >= host.y - 1e-9, "dialogue inside host at " .. label)
    Assert.isTrue(outer.y + outer.height <= host.y + host.height + 1e-9, "dialogue inside host at " .. label)
  end
end

-- Canonical golden: the frame 0 render matches the independent reference
-- pixel for pixel. The frame tilemap fills the 256x192 canvas around the
-- opaque content rect, and the text sits at the layout origin.
function T.canonical_golden_matches_frame_zero_pixel_for_pixel(scope)
  local rendered = canonicalRender(scope, 0)
  assertPixelsEqual(goldenReference(0), rendered, "frame 0 golden")
end

-- Canonical golden: frame 1 selects a different strip row, so the artwork
-- changes while the content geometry (transparent content rect, text at the
-- same origin) stays identical.
function T.canonical_golden_matches_frame_one_pixel_for_pixel(scope)
  local frame0 = canonicalRender(scope, 0)
  local frame1 = canonicalRender(scope, 1)
  assertPixelsEqual(goldenReference(1), frame1, "frame 1 golden")

  -- The frame region differs (different palette), the content rect uses the
  -- field-window fill in both, and the text pixels are identical.
  local quantize = function(v)
    return math.floor(v * 255 + 0.5)
  end
  local function pixel(data, x, y)
    local r, g, b, a = data:getPixel(math.floor(x), math.floor(y))
    return quantize(r), quantize(g), quantize(b), quantize(a)
  end
  local f0r, f0g, f0b = pixel(frame0, 0, 144)
  local f1r, f1g, f1b = pixel(frame1, 0, 144)
  Assert.isTrue(f0r ~= f1r or f0g ~= f1g or f0b ~= f1b, "frame styles have distinct artwork")

  local box = FieldDialogueTheme.box
  for _, frame in ipairs({ frame0, frame1 }) do
    local r, g, b, a = pixel(frame, box.x + box.width / 2, box.y + box.height / 2)
    local background = FieldDialogueFixture.fontDef().palette[16]
    Assert.equal(r, math.floor(background.r * 255 + 0.5), "the content rect uses the field-window fill")
    Assert.equal(g, math.floor(background.g * 255 + 0.5))
    Assert.equal(b, math.floor(background.b * 255 + 0.5))
    Assert.equal(a, 255)
  end

  local ta0r, ta0g, ta0b, ta0a = frame0:getPixel(16, 152)
  local ta1r, ta1g, ta1b, ta1a = frame1:getPixel(16, 152)
  Assert.equal(quantize(ta0r), quantize(ta1r), "text pixels identical across frames")
  Assert.equal(quantize(ta0g), quantize(ta1g))
  Assert.equal(quantize(ta0b), quantize(ta1b))
  Assert.equal(quantize(ta0a), quantize(ta1a))
  Assert.equal(quantize(ta0r), 200, "the first glyph renders at the layout origin")
end

-- Release is the contract here; it is still scoped so a failed assertion does
-- not leak the renderer. The scope's later release exercises repeat safety.
function T.release_frees_the_owned_frame_strip(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local dialogue = scope:own(FieldDialogueRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = FieldUiFixture.manifest(),
    text = text,
  }))

  dialogue:release()

  Assert.isNil(dialogue._frameImage)
end

return GraphicsSmoke.suite(T)
