-- Graphics contract for the production field Yes/No renderer.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function loadYesNoRenderer()
  local ok, renderer = pcall(require, "libs.hgss.src.ui.FieldYesNoRenderer")
  Assert.isTrue(ok, "production field Yes/No renderer is required for the dual-display choice")
  return renderer
end

local function dualTopology(width, height)
  width, height = width or 256, height or 192
  return ScreenTopology.dualDisplay({
    id = "world",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    role = "world",
    touch = false,
  }, {
    id = "auxiliary",
    rect = { x = 520, y = 40, width = width, height = height },
    safeRect = { x = 520, y = 40, width = width, height = height },
    role = "auxiliary",
    touch = false,
  })
end

local function status(selectedIndex, frameIndex)
  return { active = true, selectedIndex = selectedIndex, yesText = "YES", noText = "NO", frameIndex = frameIndex }
end

local function testRenderer()
  local rendererModule = loadYesNoRenderer()
  local graphics = require("tests.support.FakeGraphics").new()
  local sourcePalette = {}
  local userPalette = {}
  for slot = 0, 15 do
    sourcePalette[slot] = { r = 30 + slot, g = 60 + slot, b = 90 + slot }
    userPalette[slot] = { r = 130 + slot, g = 160 + slot, b = 190 + slot }
  end
  local windowCalls = {}
  local textCalls = {}
  local window = {
    drawStandardWindow = function(_, box, fill)
      windowCalls[#windowCalls + 1] = {
        kind = "standard",
        box = { x = box.x, y = box.y, width = box.width, height = box.height },
        fill = fill,
        transformed = { graphics.transformPoint(box.x, box.y) },
      }
    end,
    standardFramePalette = function()
      return sourcePalette
    end,
    drawWindow = function(_, box, frameIndex, fill)
      local tiles = {}
      for _, tile in ipairs(FieldDialogueTheme.frameTilePlacements(box)) do
        local x, y = graphics.transformPoint(tile.x, tile.y)
        local farX, farY = graphics.transformPoint(
          tile.x + FieldDialogueTheme.frameTileSize * (tile.spanX or 1),
          tile.y + FieldDialogueTheme.frameTileSize * (tile.spanY or 1)
        )
        tiles[#tiles + 1] = { x = x, y = y, width = farX - x, height = farY - y }
      end
      windowCalls[#windowCalls + 1] = {
        kind = "user",
        frameIndex = frameIndex,
        box = { x = box.x, y = box.y, width = box.width, height = box.height },
        tiles = tiles,
        fill = fill,
        transformed = { graphics.transformPoint(box.x, box.y) },
      }
    end,
    framePalette = function(_, frameIndex)
      Assert.equal(frameIndex, 1)
      return userPalette
    end,
  }
  local text = {
    drawText = function() end,
    drawTextWithPalette = function(_, value, x, y, palette)
      textCalls[#textCalls + 1] = {
        value = value,
        x = x,
        y = y,
        palette = palette,
        transformed = { graphics.transformPoint(x, y) },
      }
    end,
  }
  return rendererModule.new({ text = text, window = window, graphics = graphics }),
    graphics,
    windowCalls,
    textCalls,
    sourcePalette
end

function T.dual_display_choice_keeps_canonical_content_under_a_two_x_placement()
  local renderer = testRenderer()
  local layout = renderer:layout(status(0, 1), dualTopology(512, 384), nil)
  Assert.equal(layout.presentation, "source")
  Assert.deepEqual(layout.content, { x = 200, y = 104, width = 48, height = 32 })
  Assert.deepEqual(layout.placement.frame, { x = 520, y = 40, width = 512, height = 384 })
  Assert.deepEqual(layout.placement.origin, { x = 520, y = 40 })
  Assert.equal(layout.placement.scale, 2)
  Assert.deepEqual(layout.placement.clipRect, { x = 520, y = 40, width = 512, height = 384 })
  renderer:release()
end

function T.single_display_choice_stays_inside_portrait_safe_area()
  local renderer = testRenderer()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 360, height = 640 },
    safeRect = { x = 12, y = 24, width = 336, height = 592 },
    role = "world",
    touch = false,
  })
  local bounds = { x = 12, y = 24, width = 336, height = 592 }
  local layout = renderer:layout(
    status(1, 1),
    topology,
    { x = 12, y = 300, width = 336, height = 160 },
    { bounds = bounds, preferredScale = 1 }
  )
  local hostContent = layout.placement.origin
  Assert.equal(layout.presentation, "adapted")
  Assert.deepEqual(layout.content, { x = 0, y = 0, width = 48, height = 32 })
  Assert.equal(layout.placement.scale, 1)
  Assert.isTrue(layout.placement.frame.x >= bounds.x)
  Assert.isTrue(layout.placement.frame.y >= bounds.y)
  Assert.isTrue(layout.placement.frame.x + layout.placement.frame.width <= bounds.x + bounds.width)
  Assert.isTrue(layout.placement.frame.y + layout.placement.frame.height <= bounds.y + bounds.height)
  Assert.isTrue(hostContent.x > layout.placement.frame.x, "the body remains inset inside the exterior frame")
  renderer:release()
end

function T.single_display_choice_uses_dialogue_aware_candidate_order()
  local renderer = testRenderer()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    safeRect = { x = 12, y = 24, width = 616, height = 432 },
    role = "world",
    touch = false,
  })
  local choice = status(0, 1)
  local right = 12 + 616 - 88
  local bounds = { x = 12, y = 24, width = 616, height = 432 }
  local adaptedHost = { bounds = bounds, preferredScale = 1 }
  local below = renderer:layout(choice, topology, { x = 100, y = 100, width = 200, height = 80 }, adaptedHost)
  Assert.deepEqual(
    below.placement.frame,
    { x = right, y = 180, width = 88, height = 48 },
    "below-right frame wins when it fits"
  )
  Assert.deepEqual(below.placement.origin, { x = right + 16, y = 188 }, "content sits inside the fitted frame")

  local above = renderer:layout(choice, topology, { x = 100, y = 410, width = 200, height = 40 }, adaptedHost)
  Assert.deepEqual(
    above.placement.frame,
    { x = right, y = 362, width = 88, height = 48 },
    "above-right fits the complete frame"
  )
  Assert.deepEqual(above.placement.origin, { x = right + 16, y = 370 }, "content retains its frame inset")

  local fallback = renderer:layout(choice, topology, bounds, adaptedHost)
  Assert.deepEqual(
    fallback.placement.frame,
    { x = right, y = 408, width = 88, height = 48 },
    "fallback fits at safe bottom-right"
  )
  Assert.deepEqual(fallback.placement.origin, { x = right + 16, y = 416 }, "fallback content remains inside the frame")
  renderer:release()
end

function T.adapted_choice_uses_the_field_bounds_and_preferred_integer_scale()
  local renderer = testRenderer()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    safeRect = { x = 200, y = 160, width = 100, height = 100 },
    role = "world",
    touch = false,
  })
  local bounds = { x = 10, y = 20, width = 500, height = 300 }
  local layout = renderer:layout(status(0, 1), topology, nil, { bounds = bounds, preferredScale = 3 })
  Assert.equal(layout.placement.scale, 3)
  Assert.deepEqual(layout.placement.frame, { x = 246, y = 176, width = 264, height = 144 })
  Assert.deepEqual(layout.placement.clipRect, bounds)
  renderer:release()
end

function T.list_cursor_and_labels_use_source_glyph_rows_and_palette_roles()
  local renderer, _, windowCalls, textCalls, sourcePalette = testRenderer()
  local topology = dualTopology()
  for selectedIndex = 0, 1 do
    local choice = status(selectedIndex)
    renderer:draw(choice, renderer:layout(choice, topology, nil))
  end
  Assert.equal(#windowCalls, 2)
  Assert.equal(windowCalls[1].kind, "standard")
  Assert.equal(windowCalls[2].kind, "standard")
  Assert.equal(#textCalls, 6)
  for selectedIndex = 0, 1 do
    local cursor = textCalls[selectedIndex * 3 + 1]
    Assert.equal(cursor.value, "‣")
    Assert.equal(cursor.x, 200)
    Assert.equal(cursor.y, 104 + selectedIndex * 16)
  end
  Assert.equal(textCalls[1].value, "‣")
  Assert.equal(textCalls[2].value, "YES")
  Assert.equal(textCalls[2].x, 208)
  Assert.equal(textCalls[2].y, 104)
  Assert.equal(textCalls[3].value, "NO")
  Assert.equal(textCalls[3].x, 208)
  Assert.equal(textCalls[3].y, 120)
  for _, call in ipairs(textCalls) do
    Assert.deepEqual(call.palette, {
      foreground = sourcePalette[1],
      shadow = sourcePalette[2],
      background = sourcePalette[15],
    })
  end
  Assert.deepEqual(windowCalls[1].fill, {
    sourcePalette[15].r / 255,
    sourcePalette[15].g / 255,
    sourcePalette[15].b / 255,
    1,
  })
  renderer:release()
end

function T.source_and_adapted_presentations_select_their_own_frame_contracts()
  local renderer, _, calls = testRenderer()
  local source = status(0, nil)
  renderer:draw(source, renderer:layout(source, dualTopology(), nil))
  local adapted = status(1, 1)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    role = "world",
    touch = false,
  })
  renderer:draw(
    adapted,
    renderer:layout(adapted, topology, nil, {
      bounds = { x = 0, y = 0, width = 640, height = 480 },
      preferredScale = 1,
    })
  )
  Assert.equal(calls[1].kind, "standard")
  Assert.equal(calls[2].kind, "user")
  Assert.equal(calls[2].frameIndex, 1)
  renderer:release()
end

function T.complete_menu_uses_one_two_x_transform_and_restores_graphics_state()
  local statusValue = status(1, nil)
  local origin = {
    canvas = {},
    shader = {},
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "less",
    depthWrite = true,
    wireframe = true,
    cullMode = "front",
    color = { 0.2, 0.3, 0.4, 0.5 },
    scissor = { 3, 4, 50, 60 },
  }
  local graphics = require("tests.support.FakeGraphics").new(origin)
  -- The renderer and recording collaborators share the injected graphics transform.
  local rendererModule = loadYesNoRenderer()
  local calls = {}
  local window = {
    drawStandardWindow = function(_, box)
      calls[#calls + 1] = {
        kind = "window",
        point = { graphics.transformPoint(box.x, box.y) },
        farPoint = { graphics.transformPoint(box.x + box.width, box.y + box.height) },
      }
    end,
    standardFramePalette = function()
      return { [1] = { r = 1, g = 2, b = 3 }, [2] = { r = 4, g = 5, b = 6 }, [15] = { r = 7, g = 8, b = 9 } }
    end,
    drawWindow = function()
      error("adapted window used for source presentation")
    end,
    framePalette = function()
      error("user palette used for source presentation")
    end,
  }
  local text = {
    drawText = function() end,
    drawTextWithPalette = function(_, value, x, y)
      calls[#calls + 1] = { kind = value, point = { graphics.transformPoint(x, y) } }
    end,
  }
  local renderer = rendererModule.new({ text = text, window = window, graphics = graphics })
  local layout = renderer:layout(statusValue, dualTopology(512, 384), nil)
  renderer:draw(statusValue, layout)
  Assert.equal(#calls, 4)
  Assert.deepEqual(calls[1].point, { 920, 248 })
  Assert.deepEqual(calls[1].farPoint, { 1016, 312 })
  Assert.deepEqual(
    { calls[1].farPoint[1] - calls[1].point[1], calls[1].farPoint[2] - calls[1].point[2] },
    { 96, 64 },
    "the logical window body uses the same 2x transform as its glyphs"
  )
  Assert.deepEqual(calls[2].point, { 920, 280 })
  Assert.deepEqual(calls[3].point, { 936, 248 })
  Assert.deepEqual(calls[4].point, { 936, 280 })
  Assert.deepEqual(graphics.transforms, { { "translate", 520, 40 }, { "scale", 2, 2 } })
  Assert.equal(graphics.pushDepth(), 0)
  Assert.equal(graphics.getCanvas(), origin.canvas)
  Assert.equal(graphics.getShader(), origin.shader)
  Assert.deepEqual({ graphics.getColor() }, origin.color)
  Assert.deepEqual({ graphics.getBlendMode() }, { origin.blendMode, origin.blendAlpha })
  Assert.deepEqual({ graphics.getDepthMode() }, { origin.depthMode, origin.depthWrite })
  Assert.equal(graphics.isWireframe(), origin.wireframe)
  Assert.equal(graphics.getMeshCullMode(), origin.cullMode)
  Assert.deepEqual({ graphics.getScissor() }, origin.scissor)
  renderer:release()
end

function T.constrained_single_display_scale_keeps_the_complete_menu_inside_its_host_rect()
  local renderer, graphics, windows, texts = testRenderer()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 80, height = 64 },
    safeRect = { x = 10, y = 12, width = 24, height = 16 },
    role = "world",
    touch = false,
  })
  local choice = status(1, 1)
  local bounds = { x = 10, y = 12, width = 24, height = 16 }
  local layout = renderer:layout(choice, topology, nil, { bounds = bounds, preferredScale = 1 })
  Assert.equal(layout.placement.scale, 24 / 88)
  Assert.deepEqual(layout.content, { x = 0, y = 0, width = 48, height = 32 })
  Assert.deepEqual(
    layout.placement.frame,
    { x = 10, y = 12 + 16 - 48 * layout.placement.scale, width = 24, height = 48 * layout.placement.scale }
  )
  renderer:draw(choice, layout)
  Assert.deepEqual(windows[1].box, { x = 0, y = 0, width = 48, height = 32 })
  Assert.deepEqual(texts[2].transformed, {
    texts[1].transformed[1] + 8 * layout.placement.scale,
    texts[1].transformed[2] - 16 * layout.placement.scale,
  })
  Assert.deepEqual(texts[3].transformed, {
    texts[2].transformed[1],
    texts[2].transformed[2] + 16 * layout.placement.scale,
  })
  Assert.equal(graphics.pushDepth(), 0)
  renderer:release()
end

function T.adapted_user_frame_fits_inside_constrained_and_portrait_safe_areas()
  local cases = {
    {
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 80, height = 64 },
        safeRect = { x = 10, y = 12, width = 24, height = 16 },
        role = "world",
        touch = false,
      }),
      bounds = { x = 10, y = 12, width = 24, height = 16 },
      preferredScale = 1,
      dialogue = nil,
    },
    {
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 360, height = 640 },
        safeRect = { x = 12, y = 24, width = 336, height = 592 },
        role = "world",
        touch = false,
      }),
      bounds = { x = 12, y = 24, width = 336, height = 592 },
      preferredScale = 1,
      dialogue = { x = 12, y = 300, width = 336, height = 160 },
    },
  }

  for _, case in ipairs(cases) do
    local renderer, _, windows, texts = testRenderer()
    local choice = status(1, 1)
    local layout = renderer:layout(choice, case.topology, case.dialogue, {
      bounds = case.bounds,
      preferredScale = case.preferredScale,
    })
    renderer:draw(choice, layout)

    local bounds = case.bounds
    local frame = windows[1]
    Assert.equal(frame.kind, "user")
    Assert.equal(#frame.tiles, #FieldDialogueTheme.frameTilePlacements({ x = 0, y = 0, width = 48, height = 32 }))
    for _, tile in ipairs(frame.tiles) do
      Assert.isTrue(tile.x >= bounds.x, "frame tile starts inside the host's left edge")
      Assert.isTrue(tile.y >= bounds.y, "frame tile starts inside the host's top edge")
      Assert.isTrue(tile.x + tile.width <= bounds.x + bounds.width, "frame tile ends inside the host's right edge")
      Assert.isTrue(tile.y + tile.height <= bounds.y + bounds.height, "frame tile ends inside the host's bottom edge")
    end
    Assert.deepEqual(texts[2].transformed, {
      frame.transformed[1] + 8 * layout.placement.scale,
      frame.transformed[2],
    }, "label placement remains tied to the canonical menu body")
    renderer:release()
  end
end

function T.graphics_state_is_restored_when_nested_menu_drawing_fails()
  local graphics = require("tests.support.FakeGraphics").new({
    canvas = {},
    shader = {},
    blendMode = "add",
    blendAlpha = "premultiplied",
    depthMode = "greater",
    depthWrite = false,
    wireframe = true,
    cullMode = "back",
    color = { 0.4, 0.3, 0.2, 0.1 },
    scissor = { 5, 6, 7, 8 },
  })
  local before = {
    canvas = graphics.getCanvas(),
    shader = graphics.getShader(),
    color = { graphics.getColor() },
    blend = { graphics.getBlendMode() },
    depth = { graphics.getDepthMode() },
    wireframe = graphics.isWireframe(),
    cull = graphics.getMeshCullMode(),
    scissor = { graphics.getScissor() },
  }
  local rendererModule = loadYesNoRenderer()
  local palette = { [1] = { r = 1, g = 2, b = 3 }, [2] = { r = 4, g = 5, b = 6 }, [15] = { r = 7, g = 8, b = 9 } }
  local renderer = rendererModule.new({
    graphics = graphics,
    window = {
      drawStandardWindow = function()
        error("injected window failure")
      end,
      standardFramePalette = function()
        return palette
      end,
      drawWindow = function() end,
      framePalette = function()
        return palette
      end,
    },
    text = { drawText = function() end, drawTextWithPalette = function() end },
  })
  local choice = status(0)
  local layout = renderer:layout(choice, dualTopology(), nil)
  local ok, err = pcall(renderer.draw, renderer, choice, layout)
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("injected window failure", 1, true) ~= nil)
  Assert.equal(graphics.pushDepth(), 0)
  Assert.equal(graphics.getCanvas(), before.canvas)
  Assert.equal(graphics.getShader(), before.shader)
  Assert.deepEqual({ graphics.getColor() }, before.color)
  Assert.deepEqual({ graphics.getBlendMode() }, before.blend)
  Assert.deepEqual({ graphics.getDepthMode() }, before.depth)
  Assert.equal(graphics.isWireframe(), before.wireframe)
  Assert.equal(graphics.getMeshCullMode(), before.cull)
  Assert.deepEqual({ graphics.getScissor() }, before.scissor)
  renderer:release()
end

function T.focus_indicator_draw_uses_the_focus_asset_without_black_tint()
  local graphics =
    require("tests.support.FakeGraphics").new({ imageSizes = { { 512, 224 }, { 512, 16 }, { 96, 128 } } })
  local text = FieldTextRenderer.new({
    cacheFs = FieldDialogueFixture.cacheWithFont(),
    graphics = graphics,
  })
  local palette = {}
  for slot = 0, 15 do
    palette[slot] = { r = slot, g = slot, b = slot }
  end
  text:drawFocusIndicator(0, 8, 16, palette)
  local draws = FieldDialogueFixture.focusDraws(graphics)
  Assert.equal(#draws, 4, "one mask for each source palette slot is drawn")
  for index, slot in ipairs({ 11, 12, 13, 14 }) do
    Assert.equal(draws[index].image, graphics.images[3], "focus rendering must use the focus-indicator asset")
    Assert.deepEqual(
      draws[index].color,
      { slot / 255, slot / 255, slot / 255, 1 },
      "focus rendering uses its owning palette without a black tint"
    )
  end
  text:release()
end

return GraphicsSmoke.suite(T)
