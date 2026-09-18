local Assert = require("tests.support.Assert")

local T = {}

local function buttonModule()
  local ok, mod = pcall(require, "libs.ui.src.Button")
  Assert.isTrue(ok, "Button missing: " .. tostring(mod))
  return mod
end

local function rect(x, y, w, h)
  return { x = x, y = y, width = w, height = h }
end

local function spec(overrides)
  local result = {
    rect = rect(10, 20, 100, 60),
    borderWidth = 2,
    rimWidth = 3,
    innerBorderWidth = 1,
    cornerRadius = 6,
    faceSplit = 0.4,
    contentInsetX = 4,
    contentInsetY = 3,
  }
  for k, v in pairs(overrides or {}) do
    result[k] = v
  end
  return result
end

local function copyRect(v)
  return { x = v.x, y = v.y, width = v.width, height = v.height }
end

local function assertContained(inner, outer, label)
  Assert.isTrue(inner.x >= outer.x, label .. " start inside outer")
  Assert.isTrue(inner.y >= outer.y, label .. " start inside outer")
  Assert.isTrue(inner.x + inner.width <= outer.x + outer.width, label .. " end inside outer")
  Assert.isTrue(inner.y + inner.height <= outer.y + outer.height, label .. " end inside outer")
  Assert.isTrue(inner.width > 0, label .. " positive width")
  Assert.isTrue(inner.height > 0, label .. " positive height")
end

local function snapshot(b)
  return {
    rect = copyRect(b.rect),
    border = { rect = copyRect(b.border.rect), cornerRadius = b.border.cornerRadius },
    rim = { rect = copyRect(b.rim.rect), cornerRadius = b.rim.cornerRadius },
    innerBorder = { rect = copyRect(b.innerBorder.rect), cornerRadius = b.innerBorder.cornerRadius },
    face = { rect = copyRect(b.face.rect), cornerRadius = b.face.cornerRadius, splitY = b.face.splitY },
    contentRect = copyRect(b.contentRect),
  }
end

local function assertLayered(b)
  Assert.keySet(b, "border,contentRect,face,innerBorder,rect,rim")
  local layers = { "border", "rim", "innerBorder", "face" }
  local parent = b.rect
  local prev = math.huge
  for _, name in ipairs(layers) do
    local layer = b[name]
    Assert.keySet(layer, name == "face" and "cornerRadius,rect,splitY" or "cornerRadius,rect", name)
    assertContained(layer.rect, parent, name)
    Assert.isTrue(layer.cornerRadius >= 0, name .. " radius non-negative")
    Assert.isTrue(layer.cornerRadius <= prev, name .. " radius not grow inward")
    prev = layer.cornerRadius
    parent = layer.rect
  end
  Assert.isTrue(b.face.splitY > b.face.rect.y, "split below top")
  Assert.isTrue(b.face.splitY < b.face.rect.y + b.face.rect.height, "split above bottom")
  assertContained(b.contentRect, b.face.rect, "content")
end

function T.valid_specs_resolve_nested_geometry_without_mutating_inputs()
  local Button = buttonModule()
  local input = spec()
  local resolved = Button.resolve(input)
  local saved = snapshot(resolved)
  Assert.isTrue(resolved.rect ~= input.rect, "resolved rect copied")
  Assert.equal(resolved.rim.rect.x, input.rect.x + input.borderWidth)
  Assert.equal(resolved.innerBorder.rect.x, input.rect.x + input.borderWidth + input.rimWidth)
  Assert.equal(resolved.face.rect.x, input.rect.x + input.borderWidth + input.rimWidth + input.innerBorderWidth)
  Assert.equal(resolved.contentRect.x, resolved.face.rect.x + input.contentInsetX)
  Assert.equal(resolved.contentRect.y, resolved.face.rect.y + input.contentInsetY)
  Assert.equal(resolved.border.cornerRadius, 6)
  Assert.equal(resolved.rim.cornerRadius, 4)
  Assert.equal(resolved.innerBorder.cornerRadius, 1)
  Assert.equal(resolved.face.cornerRadius, 0)
  Assert.near(resolved.face.splitY, resolved.face.rect.y + resolved.face.rect.height * input.faceSplit)
  assertLayered(resolved)
  input.rect.x = 900
  input.borderWidth = 20
  Assert.deepEqual(resolved, saved)
end

function T.zero_width_layers_and_zero_corner_use_positive_rectangles()
  local Button = buttonModule()
  local resolved = Button.resolve(
    spec({ borderWidth = 0, rimWidth = 0, innerBorderWidth = 0, cornerRadius = 0, contentInsetX = 2, contentInsetY = 2 })
  )
  assertLayered(resolved)
  Assert.deepEqual(resolved.border.rect, resolved.rect)
  Assert.deepEqual(resolved.rim.rect, resolved.rect)
  Assert.deepEqual(resolved.innerBorder.rect, resolved.rect)
  Assert.equal(resolved.face.cornerRadius, 0)
end

function T.containment_is_half_open()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ rect = rect(10, 20, 30, 40), cornerRadius = 4 }))
  Assert.isTrue(Button.contains(resolved, 10, 20))
  Assert.isTrue(Button.contains(resolved, 10.5, 20.5))
  Assert.isTrue(Button.contains(resolved, 39.999, 59.999))
  Assert.isFalse(Button.contains(resolved, 40, 30))
  Assert.isFalse(Button.contains(resolved, 30, 60))
end

function T.invalid_metrics_are_rejected()
  local Button = buttonModule()
  local function rejects(candidate)
    Assert.throws(function()
      Button.resolve(candidate)
    end)
  end
  for _, r in ipairs({ { x = "10", y = 20, width = 30, height = 40 }, { x = 10, y = 20, width = 0, height = 40 } }) do
    rejects(spec({ rect = r }))
  end
  for _, name in ipairs({
    "borderWidth",
    "rimWidth",
    "innerBorderWidth",
    "cornerRadius",
    "contentInsetX",
    "contentInsetY",
  }) do
    rejects(spec({ [name] = -1 }))
    rejects(spec({ [name] = math.huge }))
  end
  rejects(spec({ faceSplit = 0 }))
  rejects(spec({ faceSplit = 1 }))
  rejects(spec({ rect = rect(10, 20, 20, 10), cornerRadius = 6 }))
  rejects(spec({ rect = rect(10, 20, 10, 10), borderWidth = 2, rimWidth = 2, innerBorderWidth = 2 }))
  rejects(spec({ rect = rect(10, 20, 20, 20), cornerRadius = 20 }))
  -- Missing cornerRadius
  local s = spec()
  s.cornerRadius = nil
  rejects(s)
end

function T.draw_uses_rounded_rectangles_and_face_split()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ rect = rect(0, 0, 100, 60), cornerRadius = 4 }))
  local calls = {}
  local graphics = {
    setColor = function(r, g, b, a)
      calls[#calls + 1] = { kind = "setColor", color = { r, g, b, a } }
    end,
    rectangle = function(mode, x, y, w, h, rx, ry)
      calls[#calls + 1] = { kind = "rectangle", mode = mode, x = x, y = y, w = w, h = h, rx = rx, ry = ry }
    end,
  }
  local palette = {
    border = { 1, 0, 0, 1 },
    rim = { 0, 1, 0, 1 },
    innerBorder = { 0, 0, 1, 1 },
    faceTop = { 0.5, 0.5, 0.5, 1 },
    faceBottom = { 0.2, 0.2, 0.2, 1 },
  }
  Button.draw(graphics, resolved, palette)
  Assert.equal(calls[1].kind, "setColor")
  local rectCount = 0
  for _, c in ipairs(calls) do
    if c.kind == "rectangle" then
      rectCount = rectCount + 1
    end
  end
  Assert.isTrue(rectCount >= 5, "rounded rectangles for layers and face split")
  -- Rounded radii should be present
  for _, c in ipairs(calls) do
    if c.kind == "rectangle" and c.mode == "fill" then
      -- At least one fill with radius
      if c.rx ~= nil then
        Assert.isTrue(c.rx >= 0, "radius non-negative")
      end
    end
  end
end

function T.draw_paints_the_full_inner_border_before_the_split_face()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ rect = rect(0, 0, 100, 60), cornerRadius = 4 }))
  local paints = {}
  local current = { 0, 0, 0, 0 }
  local graphics = {
    setColor = function(r, g, b, a)
      current = { r, g, b, a }
    end,
    rectangle = function(_, x, y, w, h)
      paints[#paints + 1] = { color = { current[1], current[2], current[3], current[4] }, x = x, y = y, w = w, h = h }
    end,
  }
  local palette = {
    border = { 1, 0, 0, 1 },
    rim = { 0, 1, 0, 1 },
    innerBorder = { 0, 0, 1, 1 },
    faceTop = { 0.5, 0.5, 0.5, 1 },
    faceBottom = { 0.2, 0.2, 0.2, 1 },
  }
  Button.draw(graphics, resolved, palette)
  local inner = resolved.innerBorder.rect
  local fullInnerPaints = {}
  for _, p in ipairs(paints) do
    if p.x == inner.x and p.y == inner.y and p.w == inner.width and p.h == inner.height then
      fullInnerPaints[#fullInnerPaints + 1] = p
    end
  end
  Assert.equal(#fullInnerPaints, 1, "the full inner border rectangle is painted exactly once")
  Assert.deepEqual(fullInnerPaints[1].color, { 0, 0, 1, 1 }, "the full inner border uses the inner border role")
  local face = resolved.face.rect
  local fullFacePaints = 0
  local faceTopPaints = 0
  for _, p in ipairs(paints) do
    if p.x == face.x and p.y == face.y and p.w == face.width and p.h == face.height then
      Assert.deepEqual(p.color, { 0.2, 0.2, 0.2, 1 }, "the full face uses the face bottom role")
      fullFacePaints = fullFacePaints + 1
    elseif p.x == face.x and p.y == face.y and p.w == face.width then
      Assert.deepEqual(p.color, { 0.5, 0.5, 0.5, 1 }, "the face top portion keeps the face top role")
      faceTopPaints = faceTopPaints + 1
    end
  end
  Assert.equal(fullFacePaints, 1, "the full face rectangle is painted once")
  Assert.isTrue(faceTopPaints >= 1, "the face top tone remains visible")
end

function T.draw_with_zero_corner_uses_rectangles_without_radius()
  local Button = buttonModule()
  local resolved = Button.resolve(spec({ cornerRadius = 0 }))
  local primitives = {}
  local graphics = {
    setColor = function() end,
    rectangle = function(mode, _, _, _, _, rx, ry)
      primitives[#primitives + 1] = { mode = mode, rx = rx, ry = ry }
    end,
  }
  local palette = {
    border = { 1, 0, 0, 1 },
    rim = { 0, 1, 0, 1 },
    innerBorder = { 0, 0, 1, 1 },
    faceTop = { 0.5, 0.5, 0.5, 1 },
    faceBottom = { 0.2, 0.2, 0.2, 1 },
  }
  Button.draw(graphics, resolved, palette)
  for _, p in ipairs(primitives) do
    Assert.equal(p.mode, "fill")
    -- zero corner should not pass radius or passes nil/0
    Assert.isTrue(p.rx == nil or p.rx == 0, "zero corner uses plain rectangle")
  end
end

return { tests = T }
