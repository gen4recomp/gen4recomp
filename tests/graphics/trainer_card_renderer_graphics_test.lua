-- Graphics smoke tests for the Trainer Card renderer: the canonical 256x192
-- front viewer renders pixel-exact against an independently composed
-- reference (the fixture card art with the audited label/value glyphs at the
-- source anchors, and the real generated assets from the shared derived
-- cache when a UI class is present), every graphics state the draw touched
-- is proven restored against the real driver, and release frees the owned
-- images. The construction/draw failure paths are injected fakes and stay in
-- trainer_card_renderer_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local TrainerCardRenderer = require("libs.hgss.src.ui.TrainerCardRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")

local T = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

local function canonicalPlacement()
  local PixelScale = require("libs.ui.src.PixelScale")
  return assert(
    PixelScale.placeFixed(
      { x = 0, y = 0, width = CANONICAL_WIDTH, height = CANONICAL_HEIGHT },
      CANONICAL_WIDTH,
      CANONICAL_HEIGHT
    ),
    "the canonical host must admit a one-x card placement"
  )
end

-- The demo presentation: the implemented profile fields only.
local function demoPresentation()
  return {
    open = true,
    name = "GOLD",
    trainerId = 0,
    visibleTrainerId = 0,
    money = 0,
    playTimeSeconds = 0,
  }
end

-- Renders one canonical card presentation into a real canvas and returns its
-- ImageData. The manifest drives the front rect and asset path, so the caller
-- passes the manifest the cache belongs to (the fixture manifest for fixture
-- caches, the real generated manifest for the shared derived cache).
---@param scope GraphicsScope
---@param cacheFs CacheFs
---@param manifest table
---@param presentation table
---@return love.ImageData
local function canonicalRender(scope, cacheFs, manifest, presentation)
  local lg = love.graphics
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
  local renderer = scope:own(TrainerCardRenderer.new({
    cacheFs = cacheFs,
    manifest = manifest,
    text = text,
  }))
  local canvas = scope:own(lg.newCanvas(CANONICAL_WIDTH, CANONICAL_HEIGHT))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  renderer:draw(presentation, canonicalPlacement())
  lg.setCanvas()
  return scope:own(canvas:newImageData())
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

-- Pastes one text string's glyph pixels into the reference at the given
-- origin using the fixture font def and the per-code solid glyph colors.
---@param reference love.ImageData
---@param fontDef table
---@param text string
---@param originX number
---@param originY number
---@return integer
local function pasteText(reference, fontDef, text, originX, originY)
  local x = originX
  for i = 1, #text do
    local char = text:sub(i, i)
    local code = fontDef.charmap[char] or 0
    local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
    local r, g, b = FieldUiFixture.cardGlyphColor(code)
    for y = 0, glyph.h - 1 do
      for gx = 0, glyph.w - 1 do
        reference:setPixel(math.floor(x + gx), math.floor(originY + y), r / 255, g / 255, b / 255, 1)
      end
    end
    x = x + glyph.advance
  end
  return x
end

-- The independent fixture reference: the card art pixels plus the audited
-- labels and the two authoritative values at the source anchors. Built
-- without the renderer, so a draw regression (wrong rect, wrong anchor,
-- wrong alignment, wrong glyph) is a mismatch.
---@param presentation table
---@return love.ImageData
local function fixtureReference(presentation)
  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local art =
    love.image.newImageData(love.filesystem.newFileData(FieldUiFixture.cardBytes(), FieldUiFixture.TRAINER_CARD_PATH))
  local function blend(target, source, originX, originY)
    for y = 0, source:getHeight() - 1 do
      for x = 0, source:getWidth() - 1 do
        local r, g, b, a = source:getPixel(x, y)
        if a > 0 then
          target:setPixel(originX + x, originY + y, r, g, b, a)
        end
      end
    end
  end
  blend(reference, art, 0, 0)
  local fontDef = FieldUiFixture.cardFontDef()
  local function measure(text)
    local width = 0
    for i = 1, #text do
      local code = fontDef.charmap[text:sub(i, i)] or 0
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      width = width + glyph.advance
    end
    return width
  end
  for _, anchor in ipairs(TrainerCardRenderer.LABEL_ANCHORS) do
    pasteText(reference, fontDef, anchor.text, anchor.x, anchor.y)
  end
  pasteText(reference, fontDef, presentation.name, TrainerCardRenderer.NAME_RIGHT_EDGE - measure(presentation.name), 24)
  local trainerId = string.format("%05d", presentation.visibleTrainerId)
  pasteText(reference, fontDef, trainerId, TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE - measure(trainerId), 24)
  pasteText(reference, fontDef, tostring(presentation.money), 152 - measure(tostring(presentation.money)), 48)
  local minutes = math.floor(presentation.playTimeSeconds / 60)
  local playTime = string.format("%d:%02d", math.floor(minutes / 60), minutes % 60)
  pasteText(reference, fontDef, playTime, 240 - measure(playTime), 128)
  return reference
end

-- Canonical golden: the fixture card front with the demo profile matches the
-- independent reference pixel for pixel.
function T.canonical_golden_matches_the_fixture_card_pixel_for_pixel(scope)
  local presentation = demoPresentation()
  local rendered = canonicalRender(scope, FieldUiFixture.trainerCardCache(), FieldUiFixture.manifest(), presentation)
  assertPixelsEqual(fixtureReference(presentation), rendered, "fixture trainer card golden")
end

-- The profile values are authoritative text placement: a boundary name and
-- trainer id render at their right-aligned anchors with the zero-padded id.
function T.profile_values_render_at_the_audited_anchors(scope)
  local presentation = demoPresentation()
  presentation.name = "ABCDEFG"
  presentation.visibleTrainerId = 65535
  local rendered = canonicalRender(scope, FieldUiFixture.trainerCardCache(), FieldUiFixture.manifest(), presentation)
  assertPixelsEqual(fixtureReference(presentation), rendered, "boundary profile golden")
end

-- The presentation carries only the implemented profile fields, so the card
-- never fabricates unowned values: a reference that fabricates a money value
-- must differ from the rendered card (the blank value rows are the contract,
-- never invented statistics).
function T.unimplemented_value_rows_never_fabricate_values(scope)
  local presentation = demoPresentation()
  local rendered = canonicalRender(scope, FieldUiFixture.trainerCardCache(), FieldUiFixture.manifest(), presentation)
  local fabricated = fixtureReference(presentation)
  -- Fabricate a money value glyph run at the money row (16,48) + the label
  -- width: the reference must then differ from the render.
  local fontDef = FieldUiFixture.cardFontDef()
  pasteText(fabricated, fontDef, "123", 16 + 5 * 8, 48)
  local quantize = function(v)
    return math.floor(v * 255 + 0.5)
  end
  local differs = false
  for y = 48, 63 do
    for x = 56, 79 do
      local er, eg, eb, ea = fabricated:getPixel(x, y)
      local ar, ag, ab, aa = rendered:getPixel(x, y)
      if
        quantize(er) ~= quantize(ar)
        or quantize(eg) ~= quantize(ag)
        or quantize(eb) ~= quantize(ab)
        or quantize(ea) ~= quantize(aa)
      then
        differs = true
      end
    end
  end
  Assert.isTrue(differs, "the render must stay blank where a fabricated value would appear")
end

-- Canonical golden: the real generated Trainer Card assets render pixel-exact
-- against an independent reference decoded from the same compiled PNG and the
-- real font definition (the card art is baked at compile time; the renderer's
-- job is placement and composition). Skips explicitly when no UI class is
-- present in the shared derived cache.
function T.canonical_golden_matches_the_real_generated_card_pixel_for_pixel(scope, context)
  local cache = CacheFs.forVersion("heartgold")
  if cache:getInfo(FieldUiAssetCache.manifestPath()) == nil then
    context:skip("no field-UI class in the shared derived cache")
    return
  end
  local manifest = assert(cache:loadLua(FieldUiAssetCache.manifestPath()), "the manifest must load")
  local front = manifest.assets[FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT]
  Assert.notNil(front, "the generated class indexes the trainer card front")
  local trainerCard = assert(manifest.trainerCard, "the generated class carries the trainer card section")
  local fontDef = assert(cache:loadLua("data/generated/field/font/font-0.lua"), "the real font def must load")
  Assert.equal(fontDef.schema, FieldFontCache.SCHEMA, "the real font def schema")

  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local art = love.image.newImageData(love.filesystem.newFileData(assert(cache:read(front.image)), front.image))
  local function blend(target, source, originX, originY)
    for y = 0, source:getHeight() - 1 do
      for x = 0, source:getWidth() - 1 do
        local r, g, b, a = source:getPixel(x, y)
        if a > 0 then
          target:setPixel(originX + x, originY + y, r, g, b, a)
        end
      end
    end
  end
  blend(reference, art, trainerCard.front.x, trainerCard.front.y)

  -- The audited text anchors, composed against the real font's advances.
  local function measureText(text)
    local width = 0
    for i = 1, #text do
      local code = fontDef.charmap[text:sub(i, i)]
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      width = width + glyph.advance + (fontDef.letterSpacing or 0)
    end
    return width
  end
  local function pasteRealText(text, originX, originY)
    local x = originX
    for i = 1, #text do
      local char = text:sub(i, i)
      local code = fontDef.charmap[char]
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      local glyphData = love.image.newImageData(
        love.filesystem.newFileData(assert(cache:read("assets/generated/field/font/font-0.png")), "font-0.png")
      )
      local width, height = glyph.w, glyph.h
      local tile = love.image.newImageData(width, height)
      tile:paste(glyphData, 0, 0, glyph.x, glyph.y, width, height)
      for y = 0, height - 1 do
        for gx = 0, width - 1 do
          local r, g, b, a = tile:getPixel(gx, y)
          if a > 0 then
            reference:setPixel(x + gx, originY + y, r, g, b, a)
          end
        end
      end
      x = x + glyph.advance + (fontDef.letterSpacing or 0)
    end
    return x
  end
  for _, anchor in ipairs(TrainerCardRenderer.LABEL_ANCHORS) do
    pasteRealText(anchor.text, anchor.x, anchor.y)
  end
  local name = "GOLD"
  pasteRealText(name, TrainerCardRenderer.NAME_RIGHT_EDGE - measureText(name), 24)
  local money = "0"
  pasteRealText(money, 152 - measureText(money), 48)
  local playTime = "0:00"
  pasteRealText(playTime, 240 - measureText(playTime), 128)
  local trainerId = string.format("%05d", 0)
  pasteRealText(trainerId, TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE - measureText(trainerId), 24)

  local rendered = canonicalRender(scope, cache, manifest, demoPresentation())
  assertPixelsEqual(reference, rendered, "real generated trainer card golden")
end

function T.restores_graphics_state_after_draw(scope)
  local lg = love.graphics
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.trainerCardCache() }))
  local renderer = scope:own(TrainerCardRenderer.new({
    cacheFs = FieldUiFixture.trainerCardCache(),
    manifest = FieldUiFixture.manifest(),
    text = text,
  }))

  local canvas = scope:own(lg.newCanvas(64, 64))
  local shader = lg.getShader()
  lg.setCanvas(canvas)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  local PixelScale = require("libs.ui.src.PixelScale")
  local restorePlacement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 1280, height = 720 }, CANONICAL_WIDTH, CANONICAL_HEIGHT),
    "the probe host must admit a card placement"
  )
  renderer:draw(demoPresentation(), restorePlacement)

  local function assertRestored(canvasExpected, shaderExpected)
    Assert.equal(lg.getCanvas(), canvasExpected)
    Assert.equal(lg.getShader(), shaderExpected)
    local blend, alpha = lg.getBlendMode()
    Assert.equal(blend, "add")
    Assert.equal(alpha, "alphamultiply")
    local depthMode, depthWrite = lg.getDepthMode()
    Assert.equal(depthMode, "lequal")
    Assert.equal(depthWrite, true)
    Assert.equal(lg.isWireframe(), true)
    Assert.equal(lg.getMeshCullMode(), "back")
    local r, g, b, a = lg.getColor()
    Assert.near(r, 0.2, 1e-6)
    Assert.near(g, 0.4, 1e-6)
    Assert.near(b, 0.6, 1e-6)
    Assert.near(a, 0.8, 1e-6)
    local sx, sy, sw, sh = lg.getScissor()
    Assert.equal(sx, 4)
    Assert.equal(sy, 8)
    Assert.equal(sw, 32)
    Assert.equal(sh, 16)
  end
  assertRestored(canvas, shader)
end

-- Release is the contract here; it is still scoped so a failed assertion does
-- not leak the renderer. The scope's later release exercises repeat safety.
function T.release_frees_the_owned_images(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.trainerCardCache() }))
  local renderer = scope:own(TrainerCardRenderer.new({
    cacheFs = FieldUiFixture.trainerCardCache(),
    manifest = FieldUiFixture.manifest(),
    text = text,
  }))

  renderer:release()

  Assert.isNil(renderer._cardImage)
end

-- Near-fit margin crop keeps every profile value visible: the shared
-- bounded-overdraw policy admits a triple-pixel placement with a
-- three-logical-pixel crop per edge on a 750x560 host (doubled and centred
-- on 640x480, identical physical result at DPI 2), and the card draws
-- through that supplied placement with the full card inside the visible clip
-- while cropped margins stay clear.
function T.near_fit_crop_keeps_all_profile_text_visible(scope)
  local PixelScale = require("libs.ui.src.PixelScale")
  local budget = { left = 4, right = 4, top = 4, bottom = 4 }
  local protected = { x = 8, y = 8, width = 240, height = 176 }
  local near = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 750, height = 560 }, CANONICAL_WIDTH, CANONICAL_HEIGHT, {
      maxOverdraw = budget,
      protectedRect = protected,
    }),
    "the 750x560 host must admit a cropped card placement"
  )
  Assert.equal(near.pixelScale, 3, "the near-fit host uses triple pixels")
  Assert.deepEqual(near.crop, { left = 3, right = 3, top = 3, bottom = 3 }, "near-fit crop")
  local exact = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, CANONICAL_WIDTH, CANONICAL_HEIGHT, {
      maxOverdraw = budget,
      protectedRect = protected,
    }),
    "the 640x480 host must admit a card placement"
  )
  Assert.equal(exact.pixelScale, 2, "the exact-fit host stays doubled")
  Assert.deepEqual(exact.crop, { left = 0, right = 0, top = 0, bottom = 0 }, "exact-fit crop")
  local dense = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 375, height = 280 }, CANONICAL_WIDTH, CANONICAL_HEIGHT, {
      maxOverdraw = budget,
      protectedRect = protected,
      pixelRatio = 2,
    }),
    "the DPI-2 host must admit the same physical placement"
  )
  Assert.equal(dense.pixelScale, 3, "the DPI-2 host matches the physical triple pixels")
  Assert.deepEqual(dense.crop, { left = 3, right = 3, top = 3, bottom = 3 }, "DPI-2 crop")

  local presentation = demoPresentation()
  presentation.name = "ABCDEFG"
  presentation.visibleTrainerId = 65535
  presentation.money = 12345
  presentation.playTimeSeconds = 3723
  local cacheFs = FieldUiFixture.trainerCardCache()
  local manifest = FieldUiFixture.manifest()
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
  local renderer = scope:own(TrainerCardRenderer.new({ cacheFs = cacheFs, manifest = manifest, text = text }))
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(750, 560))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  renderer:draw(presentation, near)
  lg.setCanvas()
  local data = scope:own(canvas:newImageData())
  local clip = assert(near.clipRect, "the cropped placement must carry its visible clip")
  local function hostPoint(lx, ly)
    return near.origin.x + lx * near.scale, near.origin.y + ly * near.scale
  end
  -- every audited text anchor (label origins plus the right-aligned value
  -- edges) maps inside the visible clip, so no profile value hides in a
  -- cropped margin
  local anchors = {
    { 16, 24 },
    { 136, 24 },
    { 16, 48 },
    { 16, 104 },
    { 16, 128 },
    { 16, 144 },
    { 240, 24 },
    { 112, 24 },
    { 152, 48 },
    { 240, 128 },
  }
  for _, anchor in ipairs(anchors) do
    local hx, hy = hostPoint(anchor[1], anchor[2])
    Assert.isTrue(
      hx >= clip.x and hy >= clip.y and hx < clip.x + clip.width and hy < clip.y + clip.height,
      string.format("anchor (%d,%d) stays inside the visible clip", anchor[1], anchor[2])
    )
  end
  -- the full card paints inside the clip: its centre is opaque art, while
  -- the cropped corners stay clear
  local cx, cy = hostPoint(128, 96)
  local _, _, _, ca = data:getPixel(math.floor(cx), math.floor(cy))
  Assert.isTrue(ca > 0, "the card art paints inside the visible clip")
  local function assertClear(px, py, label)
    local r, g, b, a = data:getPixel(px, py)
    Assert.isTrue(
      a == 0,
      label .. string.format(" stays clear (got %s,%s,%s,%s)", tostring(r), tostring(g), tostring(b), tostring(a))
    )
  end
  assertClear(0, 0, "cropped top-left margin")
  assertClear(749, 0, "cropped top-right margin")
  assertClear(0, 559, "cropped bottom-left margin")
  assertClear(749, 559, "cropped bottom-right margin")
end

return GraphicsSmoke.suite(T)
