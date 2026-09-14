-- Failure-path, geometry, and presentation-contract tests for the trainer
-- card renderer, driven through an injected graphics namespace: construction
-- typed errors with release of already-acquired images, the audited front
-- label/value anchors resolved against the synthetic font (right-aligned
-- name and five-digit trainer id), the presentation carrying only the
-- implemented profile fields so the unimplemented value rows stay blank
-- (no value text, no pokedex row), the card surface drawn at the manifest
-- front rect, and draw-time state restoration. The canonical pixel goldens
-- live in trainer_card_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local TrainerCardRenderer = require("libs.hgss.src.ui.TrainerCardRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local T = {}

-- The runtime-validated manifest every construction passes in: the renderer
-- never reloads it from the cache itself.
local MANIFEST = FieldUiFixture.manifest()

local CANONICAL = FieldViewport.new(256, 192, { mode = "expanded" })

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  if not ok and Errors.is(err) then
    Assert.equal((err --[[@as Errors.Error]]).code, code)
    return
  end
  error("expected structured error " .. code .. ", got: " .. tostring(err), 2)
end

-- The fake graphics namespace records every draw/transform/primitive and
-- holds the settable state the renderers must restore exactly; the shared
-- helper is tests/support/FakeGraphics.lua.
local fakeGraphics = require("tests.support.FakeGraphics").new

-- A full presentation snapshot: the implemented profile fields only.
local function presentation(overrides)
  local status = {
    open = true,
    name = "GOLD",
    gender = 0,
    trainerId = 0,
    visibleTrainerId = 0,
    money = 0,
    playTimeSeconds = 0,
  }
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

local function fixtureCache()
  return FieldUiFixture.trainerCardCache()
end

-- The construction order: the 512x32 font atlas, its semantic glyph mask
-- atlas, the 96x32 focus strip, then the 256x256 card front.
local function renderedGraphics(opts)
  opts = opts or {}
  local sizes = { { 512, 32 }, { 16, 16 }, { 96, 32 }, { 256, 256 } }
  if opts.imageSizes then
    for index, size in ipairs(opts.imageSizes) do
      sizes[index] = size
    end
  end
  opts.imageSizes = sizes
  return fakeGraphics(opts)
end

-- The shared font atlas: the fixture charset carries 64 glyphs plus the
-- fallback, so the text renderer creates one image and 65 glyph quads ahead
-- of the card renderer's own image and quad.
local function withTextRenderer(cache, lg)
  return FieldTextRenderer.new({ cacheFs = cache, graphics = lg })
end

local function cardRenderer(graphics, cache)
  return TrainerCardRenderer.new({
    cacheFs = cache or fixtureCache(),
    manifest = MANIFEST,
    text = withTextRenderer(cache or fixtureCache(), graphics),
    graphics = graphics,
  })
end

-- The glyph quads drawn for one text string: { code, x, y } in draw order,
-- advancing by the font's advances. The renderer draws every text in
-- one pass, so the expected run is compared against the glyph draws starting
-- at offset (the number of glyphs already verified). Iteration goes through
-- the shared UTF-8 glyph iterator, so expectations stay correct for
-- multibyte names.
local function drawnGlyphs(graphics, text, originX, originY, offset, fontDef)
  fontDef = fontDef or FieldUiFixture.cardFontDef()
  local runs = {}
  local x = originX
  for char in Utf8Glyphs.iter(text) do
    local code = fontDef.charmap[char] or 0
    local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
    runs[#runs + 1] = { code = code, x = x, y = originY, advance = glyph.advance }
    x = x + glyph.advance
  end
  local glyphDraws = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.kind == "draw" then
      local quad = draw.quad
      if quad and quad.w == 8 and quad.h == 16 then
        glyphDraws[#glyphDraws + 1] = { x = draw.x, y = draw.y, quadX = quad.x }
      end
    end
  end
  local start = offset or 0
  Assert.isTrue(#glyphDraws >= start + #runs, "every glyph of " .. text .. " is drawn once")
  for index, run in ipairs(runs) do
    Assert.equal(glyphDraws[start + index].x, run.x, text .. " glyph " .. index .. " x")
    Assert.equal(glyphDraws[start + index].y, run.y, text .. " glyph " .. index .. " y")
    Assert.equal(glyphDraws[start + index].quadX, (run.code - 1) * 8, text .. " glyph " .. index .. " atlas column")
  end
  return runs, start + #runs
end

function T.construction_requires_a_cache_fs_and_graphics()
  Assert.throws(function()
    TrainerCardRenderer.new({})
  end)
  local manifestOnly = CacheFs.forVersion("heartgold", FakeCache.new())
  manifestOnly:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  throwsCode("FONT_DEF_MISSING", function()
    FieldTextRenderer.new({ cacheFs = manifestOnly, graphics = renderedGraphics() })
  end)
  Assert.throws(function()
    local missingGraphics = {} ---@type any
    TrainerCardRenderer.new({ cacheFs = fixtureCache(), graphics = missingGraphics })
  end)
end

-- The card front read fails before the renderer acquires anything; the
-- caller-owned shared text renderer stays alive.
function T.construction_failure_missing_card_front_acquires_nothing()
  local graphics = renderedGraphics({ imageSizes = { { 512, 32 } } })
  local cache = FieldUiFixture.trainerCardCache()
  cache:remove(FieldUiFixture.TRAINER_CARD_PATH)
  local text = withTextRenderer(cache, graphics)
  throwsCode("FIELD_UI_TRAINER_CARD_FRONT_MISSING", function()
    TrainerCardRenderer.new({ cacheFs = cache, manifest = MANIFEST, text = text, graphics = graphics })
  end)
  Assert.equal(graphics.images[1].released, false, "the caller-owned text renderer atlas stays alive")
  text:release()
end

-- The runtime-validated manifest is a required constructor input: the
-- renderer never reloads the manifest from the cache itself, so a
-- construction without one is rejected.
function T.construction_failure_missing_manifest_is_rejected()
  local graphics = renderedGraphics()
  local text = withTextRenderer(fixtureCache(), graphics)
  local err = Assert.throws(function()
    TrainerCardRenderer.new({ cacheFs = fixtureCache(), text = text, graphics = graphics })
  end)
  Assert.isTrue(tostring(err):find("requires the runtime-validated field-UI manifest", 1, true) ~= nil)
  text:release()
end

-- A quad failure after the card image was created must release the acquired
-- card image before the constructor rethrows (the 65 glyph quads belong to
-- the caller-owned text renderer and succeed first).
function T.quad_failure_releases_the_acquired_card_image()
  local graphics = renderedGraphics({ failOnQuadCall = 66 })
  local text = withTextRenderer(fixtureCache(), graphics)
  local ok = pcall(function()
    TrainerCardRenderer.new({ cacheFs = fixtureCache(), manifest = MANIFEST, text = text, graphics = graphics })
  end)
  Assert.isFalse(ok, "the quad failure must propagate")
  Assert.equal(graphics.images[1].released, false, "the caller-owned text renderer atlas stays alive")
  Assert.equal(graphics.images[2].released, false, "the caller-owned text renderer mask atlas stays alive")
  Assert.equal(graphics.images[3].released, false, "the caller-owned text renderer focus strip stays alive")
  Assert.equal(graphics.images[4].released, true, "the card image was released")
  text:release()
end

function T.resolves_the_manifest_front_surface()
  local renderer = cardRenderer(renderedGraphics())
  Assert.deepEqual(renderer.card.front, { x = 0, y = 0, width = 256, height = 256 })
end

function T.draw_is_a_noop_without_a_presentation()
  local renderer = cardRenderer(renderedGraphics())
  renderer:draw(nil, CANONICAL, 1)
end

function T.draw_uses_the_supplied_integer_scale_for_a_640_by_480_reference_frame()
  local graphics = renderedGraphics()
  local renderer = cardRenderer(graphics)
  local viewport = FieldViewport.new(640, 480, { mode = "expanded" })

  renderer:draw(presentation(), viewport, 2)

  Assert.deepEqual(graphics.transforms, {
    { "translate", 64, 96 },
    { "scale", 2, 2 },
  }, "the card uses the caller's fitted integer scale")
end

function T.draw_rejects_a_fractional_active_scale()
  local renderer = cardRenderer(renderedGraphics())
  local err = Assert.throws(function()
    renderer:draw(presentation(), CANONICAL, 1.5)
  end)
  Assert.isTrue(tostring(err):find("positive integer", 1, true) ~= nil, "fractional card scales are rejected")
end

function T.draw_presents_the_card_art_then_the_audited_labels_and_values()
  local graphics = renderedGraphics()
  local renderer = cardRenderer(graphics)
  renderer:draw(presentation(), CANONICAL, 1)

  local firstDraw = nil ---@type any
  for _, draw in ipairs(graphics.draws) do
    if draw.kind == "draw" then
      firstDraw = draw
      break
    end
  end
  Assert.notNil(firstDraw, "the card art is drawn first")
  Assert.deepEqual(firstDraw.quad, { x = 0, y = 0, w = 256, h = 256, imgW = 256, imgH = 256 })
  Assert.equal(firstDraw.x, 0, "the card art is drawn at the manifest front origin")
  Assert.equal(firstDraw.y, 0)

  drawnGlyphs(graphics, "ID No.", 16, 24)
  local offset = 6
  local function at(text, x, y)
    local _, nextOffset = drawnGlyphs(graphics, text, x, y, offset)
    offset = nextOffset
  end
  at("NAME", 136, 24)
  at("MONEY", 16, 48)
  at("SCORE", 16, 104)
  at("TIME", 16, 128)
  at("ADVENTURE STARTED", 16, 144)
end

function T.draw_right_aligns_the_name_and_the_five_digit_trainer_id()
  local graphics = renderedGraphics()
  local renderer = cardRenderer(graphics)
  renderer:draw(presentation({ name = "GOLD", visibleTrainerId = 12345 }), CANONICAL, 1)

  -- The six audited labels precede the values in draw order; the fixture
  -- glyphs advance 8px each.
  local labelGlyphs = 6 + 4 + 5 + 5 + 4 + 17
  local nameRuns = drawnGlyphs(graphics, "GOLD", 240 - 4 * 8, 24, labelGlyphs)
  Assert.equal(nameRuns[#nameRuns].x + 8, 240, "the name right edge is the audited anchor")
  local idRuns = drawnGlyphs(graphics, "12345", 112 - 5 * 8, 24, labelGlyphs + 4 + 1 + 4)
  Assert.equal(idRuns[#idRuns].x + 8, 112, "the trainer id right edge is the audited anchor")
end

-- A multibyte player name (É = U+00C9, a real two-byte glyph at code 360 in
-- the fixture font) travels the same shared text path: one run per glyph
-- sequence, right-aligned against the audited anchor by the glyph-advance
-- measurement, never per byte.
function T.draw_right_aligns_a_multibyte_name_through_the_shared_text_path()
  local graphics = renderedGraphics()
  local multibyte = FieldUiFixture.cardFontDefWithMultibyte()
  local renderer = cardRenderer(graphics, FieldUiFixture.trainerCardCache(multibyte))
  renderer:draw(presentation({ name = "\195\137lise", visibleTrainerId = 12345 }), CANONICAL, 1)

  local labelGlyphs = 6 + 4 + 5 + 5 + 4 + 17
  -- É advances 6px; l/i/s/e advance 8px each, so the name is 38px wide.
  local nameRuns = drawnGlyphs(graphics, "\195\137lise", 240 - 38, 24, labelGlyphs, multibyte)
  Assert.equal(#nameRuns, 5, "the multibyte name is five glyphs, not six bytes")
  Assert.equal(nameRuns[1].code, 360, "the first glyph is the encoded É, not the fallback")
  Assert.equal(nameRuns[#nameRuns].x + 8, 240, "the name right edge is the audited anchor")
  local idRuns = drawnGlyphs(graphics, "12345", 112 - 5 * 8, 24, labelGlyphs + 5 + 1 + 4)
  Assert.equal(idRuns[#idRuns].x + 8, 112, "the trainer id right edge is the audited anchor")
end

function T.draw_zero_pads_the_trainer_id_to_five_digits()
  local graphics = renderedGraphics()
  local renderer = cardRenderer(graphics)
  renderer:draw(presentation({ visibleTrainerId = 0 }), CANONICAL, 1)
  drawnGlyphs(graphics, "00000", 112 - 5 * 8, 24, 6 + 4 + 5 + 5 + 4 + 17 + 4 + 1 + 4)
end

-- The presentation carries the implemented profile fields, so the card draws
-- the audited labels plus name, money, time, and the five-digit id. The source-
-- gated score, adventure, and pokedex value rows stay blank.
function T.draw_renders_the_authentic_blank_for_unimplemented_value_rows()
  local graphics = renderedGraphics()
  local renderer = cardRenderer(graphics)
  renderer:draw(presentation(), CANONICAL, 1)

  local glyphDraws = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.kind == "draw" and draw.quad and draw.quad.w == 8 and draw.quad.h == 16 then
      glyphDraws[#glyphDraws + 1] = draw
    end
  end
  -- The six audited labels plus name, money, time, and five-digit id.
  Assert.equal(#glyphDraws, 6 + 4 + 5 + 5 + 4 + 17 + 4 + 1 + 4 + 5)
  -- Nothing below the last audited text row: the bottom band stays art-only.
  for _, draw in ipairs(glyphDraws) do
    Assert.isFalse(draw.y >= 160, "no text may enter the art-only band below the audited rows")
  end
  -- No pokedex row: the audited label prints only with pokedex data.
  for _, draw in ipairs(glyphDraws) do
    Assert.isFalse(draw.y == 72, "the pokedex row stays blank without pokedex data")
  end
end

function T.release_frees_the_owned_card_image_and_is_idempotent()
  local graphics = renderedGraphics()
  local text = withTextRenderer(fixtureCache(), graphics)
  local renderer = TrainerCardRenderer.new({
    cacheFs = fixtureCache(),
    manifest = MANIFEST,
    text = text,
    graphics = graphics,
  })
  renderer:release()
  renderer:release()
  Assert.equal(graphics.images[1].released, false, "the caller-owned text renderer atlas stays alive")
  Assert.equal(graphics.images[2].released, false, "the caller-owned text renderer mask atlas stays alive")
  Assert.equal(graphics.images[3].released, false, "the caller-owned text renderer focus strip stays alive")
  Assert.equal(graphics.images[4].released, true, "the card image was released")
  text:release()
end

function T.draw_restores_every_graphics_state_it_touches()
  local lg = fakeGraphics({
    canvas = "canvas",
    shader = "shader",
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = true,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
    scissor = { 4, 8, 32, 16 },
  })
  local renderer = cardRenderer(lg)
  renderer:draw(presentation(), FieldViewport.new(1280, 720, { mode = "expanded" }), 3)
  Assert.equal(lg.pushDepth(), 0, "the transform stack is balanced")
  Assert.equal(lg.getCanvas(), "canvas")
  Assert.equal(lg.getShader(), "shader")
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

function T.draw_error_balances_the_transform_stack()
  local graphics = renderedGraphics({ failOnDrawCall = 1 })
  local renderer = cardRenderer(graphics)
  local ok = pcall(function()
    renderer:draw(presentation(), CANONICAL, 1)
  end)
  Assert.isFalse(ok, "the draw failure must propagate")
  Assert.equal(graphics.pushDepth(), 0, "a draw error must not leave the transform stack unbalanced")
end

function T.clips_the_card_to_the_reference_frame_without_changing_placement()
  local graphics = renderedGraphics({
    canvas = "canvas",
    shader = "shader",
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = true,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
    scissor = { 4, 8, 32, 16 },
  })
  local renderer = cardRenderer(graphics)
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  viewport.referenceFrame = { x = 31, y = 19, width = 255, height = 191 }
  renderer:draw(presentation(), viewport, 1)

  Assert.deepEqual(graphics.scissorIntersections, {
    {
      requested = { 31, 19, 255, 191 },
      effective = { 31, 19, 5, 5 },
    },
  }, "trainer card clips to the reference frame and caller scissor")
  Assert.deepEqual(graphics.transforms, {
    { "translate", 31, 18 },
    { "scale", 1, 1 },
  }, "trainer card keeps its bottom-centered one-x placement")
  local sx, sy, sw, sh = graphics.getScissor()
  Assert.equal(sx, 4)
  Assert.equal(sy, 8)
  Assert.equal(sw, 32)
  Assert.equal(sh, 16)
  renderer:release()
end

return { tests = T }
