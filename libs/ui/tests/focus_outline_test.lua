local Assert = require("tests.support.Assert")

local T = {}

local function focusModule()
  local ok, mod = pcall(require, "libs.ui.src.FocusOutline")
  Assert.isTrue(ok, "FocusOutline missing: " .. tostring(mod))
  return mod
end

local function recordingGraphics()
  local state = { color = { 1, 1, 1, 1 }, lineWidth = 1 }
  local calls = { setColor = {}, rectangles = {}, lineWidths = {} }
  local g = {
    setColor = function(r, g2, b, a)
      state.color = { r, g2, b, a }
      calls.setColor[#calls.setColor + 1] = { r, g2, b, a }
    end,
    rectangle = function(mode, x, y, w, h, rx, ry)
      calls.rectangles[#calls.rectangles + 1] = {
        mode = mode,
        x = x,
        y = y,
        w = w,
        h = h,
        rx = rx,
        ry = ry,
        color = { state.color[1], state.color[2], state.color[3], state.color[4] },
        lineWidth = state.lineWidth,
      }
    end,
    setLineWidth = function(w)
      state.lineWidth = w
      calls.lineWidths[#calls.lineWidths + 1] = w
    end,
    getLineWidth = function()
      return state.lineWidth
    end,
    _calls = calls,
    _state = state,
  }
  return g, calls
end

local function rect(x, y, w, h)
  return { x = x, y = y, width = w, height = h }
end

local function drawCount(calls)
  return #calls.rectangles
end

function T.draws_default_two_line_outline_with_exact_geometry()
  local FocusOutline = focusModule()
  local g, calls = recordingGraphics()
  g._state.lineWidth = 7
  FocusOutline.draw(g, rect(10, 20, 120, 56), { scale = 1 })
  Assert.equal(drawCount(calls), 2)
  local outer, inner = calls.rectangles[1], calls.rectangles[2]
  for _, r in ipairs({ outer, inner }) do
    Assert.equal(r.mode, "line")
    Assert.equal(r.x, 11)
    Assert.equal(r.y, 21)
    Assert.equal(r.w, 118)
    Assert.equal(r.h, 54)
    Assert.equal(r.rx, 0.5)
    Assert.equal(r.ry, 0.5)
  end
  Assert.deepEqual(outer.color, { 1, 1, 1, 1 })
  Assert.deepEqual(inner.color, { 1, 0, 0, 1 })
  Assert.equal(outer.lineWidth, 5)
  Assert.equal(inner.lineWidth, 3)
  Assert.deepEqual(calls.lineWidths, { 5, 3, 7 })
  Assert.equal(g._state.lineWidth, 7)
end

function T.scale_doubles_geometry_exactly()
  local FocusOutline = focusModule()
  local g1, calls1 = recordingGraphics()
  FocusOutline.draw(g1, rect(10, 20, 120, 56), { scale = 1 })
  local g2, calls2 = recordingGraphics()
  FocusOutline.draw(g2, rect(10, 20, 120, 56), { scale = 2 })
  Assert.equal(drawCount(calls2), 2)
  local outer, inner = calls2.rectangles[1], calls2.rectangles[2]
  for _, r in ipairs({ outer, inner }) do
    Assert.equal(r.mode, "line")
    Assert.equal(r.x, 12)
    Assert.equal(r.y, 22)
    Assert.equal(r.w, 116)
    Assert.equal(r.h, 52)
    Assert.equal(r.rx, 1)
    Assert.equal(r.ry, 1)
    Assert.equal(r.x, calls1.rectangles[1].x * 2 - 10)
  end
  Assert.equal(outer.lineWidth, 10)
  Assert.equal(inner.lineWidth, 6)
  Assert.deepEqual(outer.color, { 1, 1, 1, 1 })
  Assert.deepEqual(inner.color, { 1, 0, 0, 1 })
  Assert.equal(g2._state.lineWidth, 1)
end

function T.honors_color_overrides_and_alpha_default()
  local FocusOutline = focusModule()
  local g, calls = recordingGraphics()
  FocusOutline.draw(g, rect(0, 0, 120, 56), {
    scale = 1,
    outerColor = { 0, 0, 1 },
    innerColor = { 0, 1, 0, 0.5 },
  })
  Assert.equal(drawCount(calls), 2)
  Assert.deepEqual(calls.rectangles[1].color, { 0, 0, 1, 1 })
  Assert.deepEqual(calls.rectangles[2].color, { 0, 1, 0, 0.5 })
  Assert.equal(g._state.lineWidth, 1)
end

function T.repeated_draws_are_identical()
  local FocusOutline = focusModule()
  local g1, calls1 = recordingGraphics()
  FocusOutline.draw(g1, rect(4, 6, 80, 40), { scale = 1 })
  local g2, calls2 = recordingGraphics()
  FocusOutline.draw(g2, rect(4, 6, 80, 40), { scale = 1 })
  Assert.deepEqual(calls1.rectangles, calls2.rectangles)
  Assert.deepEqual(calls1.lineWidths, calls2.lineWidths)
end

function T.rejects_bad_scale()
  local FocusOutline = focusModule()
  local bad = { 0, -1, 0 / 0, math.huge, -math.huge, "1", nil }
  for _, scale in ipairs(bad) do
    local g, calls = recordingGraphics()
    Assert.throws(function()
      FocusOutline.draw(g, rect(0, 0, 120, 56), { scale = scale })
    end, "scale " .. tostring(scale) .. " must fail")
    Assert.equal(drawCount(calls), 0, "no drawing on bad scale " .. tostring(scale))
  end
  local g, calls = recordingGraphics()
  Assert.throws(function()
    FocusOutline.draw(g, rect(0, 0, 120, 56), nil)
  end, "missing spec must fail")
  Assert.equal(drawCount(calls), 0)
  local g2, calls2 = recordingGraphics()
  Assert.throws(function()
    FocusOutline.draw(g2, rect(0, 0, 120, 56), {})
  end, "missing scale must fail")
  Assert.equal(drawCount(calls2), 0)
end

function T.rejects_bad_rect()
  local FocusOutline = focusModule()
  local bad = {
    nil,
    {},
    { x = 0, y = 0, width = 0, height = 56 },
    { x = 0, y = 0, width = -4, height = 56 },
    { x = 0, y = 0, width = 120, height = 0 },
    { x = 0, y = 0, width = 120, height = -2 },
    { x = 0 / 0, y = 0, width = 120, height = 56 },
    { x = 0, y = math.huge, width = 120, height = 56 },
    { x = "0", y = 0, width = 120, height = 56 },
    { x = 0, y = 0, width = 120 },
  }
  for index, r in ipairs(bad) do
    local g, calls = recordingGraphics()
    Assert.throws(function()
      FocusOutline.draw(g, r, { scale = 1 })
    end, "rect case " .. tostring(index) .. " must fail")
    Assert.equal(drawCount(calls), 0, "no drawing on bad rect case " .. tostring(index))
  end
end

function T.rejects_bad_colors()
  local FocusOutline = focusModule()
  local bad = {
    { 1, 0 },
    { 1, 0, 0, 1, 0 },
    { 1, 0, 0 / 0, 1 },
    { math.huge, 0, 0, 1 },
    "red",
  }
  for index, color in ipairs(bad) do
    local g, calls = recordingGraphics()
    Assert.throws(function()
      FocusOutline.draw(g, rect(0, 0, 120, 56), { scale = 1, outerColor = color })
    end, "outer color case " .. tostring(index) .. " must fail")
    Assert.equal(drawCount(calls), 0)
    local g2, calls2 = recordingGraphics()
    Assert.throws(function()
      FocusOutline.draw(g2, rect(0, 0, 120, 56), { scale = 1, innerColor = color })
    end, "inner color case " .. tostring(index) .. " must fail")
    Assert.equal(drawCount(calls2), 0)
  end
end

function T.exposes_only_draw_and_requires_graphics_contract()
  local FocusOutline = focusModule()
  Assert.keySet(FocusOutline, "draw")
  local validRect = rect(0, 0, 120, 56)
  for _, key in ipairs({ "setColor", "getLineWidth", "setLineWidth", "rectangle" }) do
    local g, _ = recordingGraphics()
    g[key] = nil
    Assert.throws(function()
      FocusOutline.draw(g, validRect, { scale = 1 })
    end, "missing graphics " .. key .. " must fail")
  end
end

return { tests = T }
