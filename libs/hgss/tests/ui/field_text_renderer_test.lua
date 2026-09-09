-- Color-band and focus-indicator presentation contracts for the shared
-- FieldTextRenderer, driven through the shared FakeGraphics namespace: glyph
-- quads must sample the color band named by the token's prepared colorIndex
-- (variant y = glyph.y + colorIndex * colorVariants.strideY), built lazily
-- per color; plain drawText stays on color 0 and color never changes glyph
-- advance or measured width; the focus-indicator strip is renderer-owned and
-- drawFocusIndicator(field, x, y) selects the imported frame rect at the
-- caller's position without deciding placement; out-of-range color indices
-- and focus fields fail loudly instead of clamping; release frees every owned
-- resource exactly once. The palette-driven drawLineWithPalette path draws
-- from the separate semantic mask atlas through the palette shader, sends
-- exact normalized uniforms, advances identically to drawLine, and ignores
-- token colorIndex entirely -- it is a source-fixed path, never blended with
-- the color-band semantics above. These tests use the shared fake, so the
-- base-band-tall fixture PNGs are never decoded.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")

local T = {}

-- The fake graphics namespace records every draw and created image; the
-- shared helper is tests/support/FakeGraphics.lua. Image sizes: the glyph
-- atlas (16px-wide base band), the 16x16 semantic glyph mask atlas, and the
-- 96x32 focus-indicator strip, in the order the ready font bundle's assets
-- are acquired.
local fakeGraphics = require("tests.support.FakeGraphics").new

local MASK_ATLAS_SIZE = { 16, 16 }
local FOCUS_STRIP_SIZE = { 96, 32 }

local function textRenderer(lg)
  return FieldTextRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
end

local function textRendererWithFont(lg, fontId)
  return FieldTextRenderer.new({
    cacheFs = FieldDialogueFixture.cacheWithFontId(fontId),
    fontId = fontId,
    graphics = lg,
  })
end

local function glyphToken(code, colorIndex)
  return { kind = "glyph", code = code, text = "x", raw = { code }, colorIndex = colorIndex } --[[@as MessageToken]]
end

-- The fixture font: baseHeight 16, strideY 16, every glyph rect at y=0 with
-- advance 6 (code 1/2) or 4 (code 0).
local function strideY()
  return FieldDialogueFixture.fontDef().colorVariants.strideY
end

-- The full-height atlas image the fake supplies (the fixture PNG is only
-- base-band tall and is never decoded by the fake).
local function atlasImageSize()
  local def = FieldDialogueFixture.fontDef()
  return { def.atlas.width, def.atlas.height }
end

local function imageSizes()
  return { atlasImageSize(), MASK_ATLAS_SIZE, FOCUS_STRIP_SIZE }
end

-- A colored glyph token must sample the color band named by its
-- prepared colorIndex: variant y = glyph.y + colorIndex * strideY.
function T.colored_glyph_quads_select_their_color_band()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  local stride = strideY()
  for _, colorIndex in ipairs({ 0, 1, 6 }) do
    text:drawLine({ glyphToken(1, colorIndex) }, 10, 20)
    local call = lg.draws[#lg.draws]
    Assert.equal(call.quad.y, 0 + colorIndex * stride, "color " .. colorIndex .. " samples its band")
  end
  text:release()
end

-- Color carries no width; drawing the same glyphs in two colors must
-- produce identical x advances (only the sampled band differs).
function T.drawing_the_same_text_in_two_colors_preserves_x_advances()
  local function coloredXs(colorIndex)
    local lg = fakeGraphics({ imageSizes = imageSizes() })
    local text = textRenderer(lg)
    text:drawLine({ glyphToken(2, colorIndex), glyphToken(1, colorIndex) }, 0, 0)
    text:release()
    return { lg.draws[1].x, lg.draws[2].x }
  end
  Assert.deepEqual(coloredXs(6), coloredXs(0), "the color variant never changes the x advances")
end

-- Plain drawText stays on color 0 (the base band), so unstyled callers
-- like the Trainer Card are visually unchanged.
function T.plain_draw_text_stays_on_color_zero()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  text:drawText("A", 4, 8)
  Assert.equal(#lg.draws, 1)
  Assert.equal(lg.draws[1].quad.y, 0, "drawText never leaves the base band")
  text:release()
end

-- drawFocusIndicator() selects the imported frame rect of the requested
-- field and draws it at exactly the caller's position; the method owns no
-- placement decision.
function T.draw_focus_indicator_selects_the_requested_frame_rect()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  for field = 0, 3 do
    text:drawFocusIndicator(field, 200 + field, 152)
    local call = lg.draws[#lg.draws]
    Assert.equal(call.quad.x, field * 24, "field " .. field .. " samples its own strip rect")
    Assert.equal(call.quad.y, 0)
    Assert.equal(call.quad.w, 24, "the indicator frame is 24px wide")
    Assert.equal(call.quad.h, 32, "the indicator frame is 32px tall")
    Assert.equal(call.x, 200 + field, "the caller's x is passed through")
    Assert.equal(call.y, 152, "the caller's y is passed through")
  end
  text:release()
end

-- A color index outside 0..6 must fail loudly, never silently clamp to
-- color 0.
function T.invalid_color_indices_fail_loudly()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  for _, bad in ipairs({ -1, 7 }) do
    Assert.throws(function()
      text:drawLine({ glyphToken(1, bad) }, 0, 0)
    end, "color index " .. tostring(bad) .. " must raise, never clamp to color 0")
  end
  text:release()
end

-- A focus field outside 0..3 must fail loudly with a typed error.
function T.invalid_focus_fields_fail_loudly()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  for _, bad in ipairs({ -1, 4 }) do
    local err = Assert.throws(function()
      text:drawFocusIndicator(bad, 0, 0)
    end, "focus field " .. tostring(bad) .. " must raise")
    Assert.isTrue(Errors.is(err), "the invalid focus field raises a typed error")
  end
  text:release()
end

-- Construction acquires the normal atlas, the mask atlas, and the palette
-- shader exactly once each, then the focus-indicator strip: five resources
-- total (two images, one shader, then a third image), no repeats.
function T.construction_loads_every_owned_resource_exactly_once()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  Assert.equal(#lg.images, 3, "the atlas, mask atlas, and focus strip are the only created images")
  Assert.equal(#lg.shaders, 1, "the palette shader is created exactly once")
  Assert.equal(lg.images[1]:getWidth(), atlasImageSize()[1])
  Assert.equal(lg.images[2]:getWidth(), MASK_ATLAS_SIZE[1])
  Assert.equal(lg.images[3]:getWidth(), FOCUS_STRIP_SIZE[1])
  text:release()
end

-- A cache without the focus-indicator PNG must not build a half renderer:
-- the typed error names the missing artifact before any image is created
-- (the atlas and mask reads already succeeded and are read-only, so nothing
-- is acquired before the failing read).
function T.missing_focus_image_is_a_typed_error()
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:remove(FieldDialogueFixture.FOCUS_INDICATOR_PATH)
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = cache, graphics = lg })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FONT_FOCUS_IMAGE_MISSING", "raises FONT_FOCUS_IMAGE_MISSING")
  Assert.equal(#lg.images, 0, "no image was created before the focus strip read failed")
end

-- A cache without the semantic glyph mask atlas must not build a half
-- renderer either: the typed error names the missing artifact before any
-- image is created.
function T.missing_mask_atlas_is_a_typed_error()
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:remove(FieldDialogueFixture.MASK_ATLAS_PATH)
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = cache, graphics = lg })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FONT_MASK_ATLAS_MISSING", "raises FONT_MASK_ATLAS_MISSING")
  Assert.equal(#lg.images, 0, "no image was created before the mask atlas read failed")
end

-- A mask-image creation failure after the normal atlas exists must release
-- the already-acquired atlas before the constructor rethrows.
function T.mask_image_failure_releases_the_acquired_atlas()
  local lg = fakeGraphics({ imageSizes = imageSizes(), failOnImageCall = 2 })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image failure")
  Assert.equal(#lg.images, 1, "only the normal atlas was created before the mask atlas failed")
  Assert.equal(lg.images[1].released, true, "the acquired atlas was released")
end

-- A shader-creation failure after both atlases exist must release both
-- images before the constructor rethrows.
function T.shader_failure_releases_both_atlases()
  local lg = fakeGraphics({ imageSizes = imageSizes(), failOnShaderCall = 1 })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newShader failure", 1, true) ~= nil, "rethrows the shader failure")
  Assert.equal(#lg.images, 2, "both atlases were created before the shader failed")
  Assert.equal(lg.images[1].released, true, "the normal atlas was released")
  Assert.equal(lg.images[2].released, true, "the mask atlas was released")
end

-- A focus-strip creation failure after both atlases and the shader exist
-- must release the acquired atlases before the constructor rethrows.
function T.focus_image_failure_releases_the_acquired_atlases()
  local lg = fakeGraphics({ imageSizes = imageSizes(), failOnImageCall = 3 })
  local err = Assert.throws(function()
    FieldTextRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont(), graphics = lg })
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image failure")
  Assert.equal(#lg.images, 2, "both atlases were created before the focus strip failed")
  Assert.equal(lg.images[1].released, true, "the normal atlas was released")
  Assert.equal(lg.images[2].released, true, "the mask atlas was released")
end

-- Releasing the shared text renderer releases every image and the shader it
-- owns exactly once; a second release is safe.
function T.release_releases_every_owned_resource_exactly_once()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  Assert.isTrue(#lg.images == 3, "the renderer owns the atlas, mask atlas, and focus-indicator image")
  text:release()
  for index, image in ipairs(lg.images) do
    Assert.isTrue(image.released, "owned image " .. index .. " is released")
  end
  Assert.isTrue(lg.shaders[1].released, "the owned shader is released")
  text:release()
  Assert.isTrue(lg.images[1].released, "releasing twice is safe")
end

-- drawLineWithPalette sends exactly the caller's normalized uniforms, draws
-- from the mask atlas (not the normal atlas), advances identically to
-- drawLine, skips control tokens, never mutates the token stream, and
-- ignores token.colorIndex entirely.
function T.draw_line_with_palette_sends_normalized_uniforms_and_draws_the_mask_atlas()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  local palette = {
    foreground = { r = 255, g = 0, b = 0 },
    shadow = { r = 0, g = 128, b = 0 },
    background = { r = 0, g = 0, b = 255 },
  }
  text:drawLineWithPalette({ glyphToken(1, 4) }, 10, 20, palette)

  local shader = lg.shaders[1]
  local function sent(name)
    for _, send in ipairs(shader.sends) do
      if send.name == name then
        return send.value
      end
    end
    Assert.fail("uniform " .. name .. " was never sent")
  end
  Assert.deepEqual(sent("u_foreground"), { 1, 0, 0, 1 })
  Assert.deepEqual(sent("u_shadow"), { 0, 128 / 255, 0, 1 })
  Assert.deepEqual(sent("u_background"), { 0, 0, 1, 1 })

  Assert.equal(#lg.draws, 1)
  Assert.equal(lg.draws[1].image, lg.images[2], "the palette path draws from the mask atlas, not the normal atlas")
  text:release()
end

function T.draw_line_with_palette_advances_identically_to_draw_line()
  local palette =
    { foreground = { r = 1, g = 2, b = 3 }, shadow = { r = 4, g = 5, b = 6 }, background = { r = 7, g = 8, b = 9 } }
  local function xsFor(method)
    local lg = fakeGraphics({ imageSizes = imageSizes() })
    local text = textRenderer(lg)
    if method == "drawLine" then
      text:drawLine({ glyphToken(2, 3), glyphToken(1, 3) }, 0, 0)
    else
      text:drawLineWithPalette({ glyphToken(2, 3), glyphToken(1, 3) }, 0, 0, palette)
    end
    text:release()
    return { lg.draws[1].x, lg.draws[2].x }
  end
  Assert.deepEqual(xsFor("drawLineWithPalette"), xsFor("drawLine"), "the palette path advances exactly like drawLine")
end

function T.draw_line_with_palette_skips_control_tokens_and_never_mutates_them()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  local palette =
    { foreground = { r = 1, g = 2, b = 3 }, shadow = { r = 4, g = 5, b = 6 }, background = { r = 7, g = 8, b = 9 } }
  local wait = { kind = "wait", control = 514, name = "WAIT", args = {}, raw = {} } --[[@as MessageToken]]
  local before = { kind = wait.kind, control = wait.control, name = wait.name, args = wait.args, raw = wait.raw }
  local glyph = glyphToken(1, 0)
  text:drawLineWithPalette({ wait, glyph }, 10, 20, palette)
  Assert.equal(#lg.draws, 1, "the control token draws nothing")
  Assert.equal(lg.draws[1].x, 10, "WAIT occupies zero pixels")
  Assert.deepEqual(wait, before, "the control token is never mutated")
  text:release()
end

-- The palette path is source-fixed and must ignore token.colorIndex: two
-- otherwise identical tokens differing only by colorIndex draw at the same
-- position with the same uniforms sent.
function T.draw_line_with_palette_ignores_token_color_index()
  local palette = {
    foreground = { r = 10, g = 20, b = 30 },
    shadow = { r = 40, g = 50, b = 60 },
    background = { r = 70, g = 80, b = 90 },
  }
  local function drawAt(colorIndex)
    local lg = fakeGraphics({ imageSizes = imageSizes() })
    local text = textRenderer(lg)
    text:drawLineWithPalette({ glyphToken(1, colorIndex) }, 0, 0, palette)
    local quad = lg.draws[1].quad
    text:release()
    return { quad.x, quad.y, quad.w, quad.h }
  end
  Assert.deepEqual(drawAt(0), drawAt(6), "colorIndex never changes the sampled quad on the palette path")
end

function T.draw_text_with_palette_uses_utf8_glyphs_fallback_and_palette_shader()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  local palette = {
    foreground = { r = 255, g = 0, b = 0 },
    shadow = { r = 0, g = 128, b = 0 },
    background = { r = 0, g = 0, b = 255 },
  }
  text:drawTextWithPalette("AB?", 10, 20, palette)

  Assert.equal(#lg.draws, 3)
  Assert.equal(lg.draws[1].image, lg.images[2], "plain palette text uses the semantic mask atlas")
  Assert.equal(lg.draws[1].x, 10)
  Assert.equal(lg.draws[2].x, 16, "the second glyph uses the font advance")
  Assert.equal(lg.draws[3].x, 22, "the fallback glyph follows the preceding glyph advance")
  Assert.equal(lg.draws[3].quad.x, lg.draws[1].quad.x, "unknown glyphs use the existing fallback glyph")
  Assert.equal(lg.draws[3].quad.y, lg.draws[1].quad.y)
  Assert.deepEqual(lg.shaders[1].sends[1].value, { 1, 0, 0, 1 })
  Assert.equal(lg.getShader(), nil, "plain palette text restores the existing shader postcondition")
  text:release()
end

function T.font_four_renderer_uses_the_parameterized_cache_assets()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRendererWithFont(lg, 4)
  text:drawTextWithPalette("A", 10, 20, {
    foreground = { r = 255, g = 0, b = 0 },
    shadow = { r = 0, g = 255, b = 0 },
    background = { r = 0, g = 0, b = 255 },
  })
  Assert.equal(#lg.draws, 1)
  text:release()
end

local function callerVariants()
  return {
    { foreground = { r = 11, g = 22, b = 33 }, shadow = { r = 44, g = 55, b = 66 } },
    { foreground = { r = 70, g = 80, b = 90 }, shadow = { r = 100, g = 110, b = 120 } },
    { foreground = { r = 130, g = 140, b = 150 }, shadow = { r = 160, g = 170, b = 180 } },
    { foreground = { r = 190, g = 200, b = 210 }, shadow = { r = 220, g = 230, b = 240 } },
    { foreground = { r = 1, g = 2, b = 3 }, shadow = { r = 4, g = 5, b = 6 } },
    { foreground = { r = 7, g = 8, b = 9 }, shadow = { r = 10, g = 11, b = 12 } },
    { foreground = { r = 13, g = 14, b = 15 }, shadow = { r = 16, g = 17, b = 18 } },
  }
end

local function normalized(color)
  return { color.r / 255, color.g / 255, color.b / 255, 1 }
end

-- One prepared line switching colors mid-line draws every glyph from the
-- semantic mask atlas through the caller-supplied variant named by each
-- glyph's own color index, on one fixed background, with glyph advances
-- identical to drawLine, leaving no shader bound.
function T.draw_line_with_color_variants_selects_caller_colors_per_glyph()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  local variants = callerVariants()
  local background = { r = 21, g = 22, b = 23 }
  local tokens = { glyphToken(1, 0), glyphToken(2, 3), glyphToken(1, 3), glyphToken(2, 2), glyphToken(1, 0) }
  text:drawLineWithColorVariants(tokens, 10, 20, variants, background)

  Assert.equal(#lg.draws, 5, "every glyph token draws exactly once")
  for index, call in ipairs(lg.draws) do
    Assert.equal(call.image, lg.images[2], "glyph " .. index .. " draws from the mask atlas")
  end

  local plainGraphics = fakeGraphics({ imageSizes = imageSizes() })
  local plain = textRenderer(plainGraphics)
  plain:drawLine(tokens, 10, 20)
  for index, call in ipairs(lg.draws) do
    Assert.equal(call.x, plainGraphics.draws[index].x, "glyph " .. index .. " advances exactly like drawLine")
    Assert.equal(call.y, plainGraphics.draws[index].y, "glyph " .. index .. " keeps the drawLine baseline")
  end
  plain:release()

  local foregrounds, shadows, backgrounds = {}, {}, {}
  for _, send in ipairs(lg.shaders[1].sends) do
    if send.name == "u_foreground" then
      foregrounds[#foregrounds + 1] = send.value
    elseif send.name == "u_shadow" then
      shadows[#shadows + 1] = send.value
    elseif send.name == "u_background" then
      backgrounds[#backgrounds + 1] = send.value
    end
  end
  local function distinct(sequence)
    local collapsed = {}
    for _, value in ipairs(sequence) do
      local last = collapsed[#collapsed]
      local same = last ~= nil and #last == #value
      if same then
        for index = 1, #value do
          if last[index] ~= value[index] then
            same = false
            break
          end
        end
      end
      if not same then
        collapsed[#collapsed + 1] = value
      end
    end
    return collapsed
  end
  local variantOrder = { 1, 4, 3, 1 }
  local expectedForegrounds, expectedShadows = {}, {}
  for _, variantIndex in ipairs(variantOrder) do
    expectedForegrounds[#expectedForegrounds + 1] = normalized(variants[variantIndex].foreground)
    expectedShadows[#expectedShadows + 1] = normalized(variants[variantIndex].shadow)
  end
  Assert.deepEqual(distinct(foregrounds), expectedForegrounds, "foreground follows each color boundary")
  Assert.deepEqual(distinct(shadows), expectedShadows, "shadow follows each color boundary")
  Assert.equal(#backgrounds, 1, "one fixed background covers the whole line")
  Assert.deepEqual(backgrounds[1], normalized(background), "the background is the caller-supplied color")

  Assert.equal(lg.getShader(), nil, "the palette shader is unbound after the draw")
  text:release()
end

-- A line with no glyph tokens draws nothing and still leaves graphics
-- state clean: no palette shader stays bound.
function T.draw_line_with_color_variants_leaves_state_clean_without_glyphs()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  local variants = callerVariants()
  local background = { r = 21, g = 22, b = 23 }
  text:drawLineWithColorVariants({}, 10, 20, variants, background)
  local wait = { kind = "wait", control = 514, name = "WAIT", args = {}, raw = {} } --[[@as MessageToken]]
  text:drawLineWithColorVariants({ wait }, 10, 20, variants, background)
  Assert.equal(#lg.draws, 0, "no glyph token means no draw")
  Assert.equal(lg.getShader(), nil, "no palette shader stays bound without glyphs")
  text:release()
end

-- A color index outside the variant range fails loudly instead of
-- clamping to a neighboring caller color.
function T.draw_line_with_color_variants_rejects_unknown_color_indices()
  local lg = fakeGraphics({ imageSizes = imageSizes() })
  local text = textRenderer(lg)
  local variants = callerVariants()
  local background = { r = 21, g = 22, b = 23 }
  for _, bad in ipairs({ -1, 7 }) do
    local err = Assert.throws(function()
      text:drawLineWithColorVariants({ glyphToken(1, bad) }, 0, 0, variants, background)
    end, "color index " .. tostring(bad) .. " must raise")
    Assert.isTrue(
      tostring(err):find("nil value", 1, true) == nil,
      "the failure names the color index, not a missing drawing path"
    )
  end
  text:release()
end

return { tests = T }
