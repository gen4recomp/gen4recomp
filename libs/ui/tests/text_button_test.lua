local Assert = require("tests.support.Assert")

local T = {}

local function textButtonModule()
  local ok, mod = pcall(require, "libs.ui.src.TextButton")
  Assert.isTrue(ok, "TextButton missing: " .. tostring(mod))
  return mod
end

local function rect(x, y, w, h)
  return { x = x, y = y, width = w, height = h }
end

local function recordingGraphics()
  local state = { color = { 1, 1, 1, 1 }, lineWidth = 1 }
  local calls = { setColor = {}, rectangles = {}, lineWidths = {}, transforms = {}, pushCount = 0, popCount = 0 }
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
    push = function()
      calls.pushCount = calls.pushCount + 1
    end,
    pop = function()
      calls.popCount = calls.popCount + 1
    end,
    translate = function(x, y)
      calls.transforms[#calls.transforms + 1] = { "translate", x, y }
    end,
    scale = function(x, y)
      calls.transforms[#calls.transforms + 1] = { "scale", x, y }
    end,
    getColor = function()
      return state.color[1], state.color[2], state.color[3], state.color[4]
    end,
    _calls = calls,
    _state = state,
  }
  return g, calls
end

function T.canonical_geometry_matches_yes_no_format()
  local TextButton = textButtonModule()
  local at1 = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  Assert.equal(at1.contentRect.x, 8)
  Assert.equal(at1.contentRect.y, 16)
  Assert.equal(at1.contentRect.width, 104)
  Assert.equal(at1.contentRect.height, 24)
  Assert.equal(at1.border.cornerRadius, 3)
  Assert.equal(at1.rim.cornerRadius, 1)
  Assert.equal(at1.face.cornerRadius, 0)
  local at2 = TextButton.resolve({ rect = rect(0, 0, 240, 112), scale = 2 })
  Assert.equal(at2.contentRect.width, 208)
  Assert.equal(at2.contentRect.height, 48)
  Assert.equal(at2.border.cornerRadius, 6)
end

function T.reference_dimensions_are_canonical()
  local TextButton = textButtonModule()
  Assert.equal(TextButton.REFERENCE_WIDTH, 120)
  Assert.equal(TextButton.REFERENCE_HEIGHT, 56)
end

function T.preserves_focus_and_supports_one_role_override()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(10, 20, 120, 56), scale = 1 })
  local g1, calls1 = recordingGraphics()
  local text1 = {
    measure = function()
      return 20
    end,
    lineHeight = 16,
    draw = function() end,
  }
  TextButton.draw(g1, button, { label = "Yes", selected = false, text = text1 })
  Assert.equal(#calls1.lineWidths, 1, "unselected restores line width once")
  Assert.equal(calls1.lineWidths[1], 1)
  Assert.equal(g1._state.lineWidth, 1)

  local g2, calls2 = recordingGraphics()
  local drawCalls = {}
  local text2 = {
    measure = function()
      return 20
    end,
    lineHeight = 16,
    draw = function(l, x, y)
      drawCalls[#drawCalls + 1] = { l, x, y }
    end,
  }
  TextButton.draw(g2, button, { label = "No", selected = true, text = text2 })
  -- Focus draws with widths 5 and 3, then restored to 1
  Assert.isTrue(calls2.lineWidths[1] == 5 or calls2.lineWidths[2] == 5, "focus outer width 5")
  Assert.equal(g2._state.lineWidth, 1)
  Assert.equal(#drawCalls, 1)
  -- Focus rectangles are same inset/radius for white and red.
  -- Last two line-mode rectangles should share geometry
  local lineRects = {}
  for _, r in ipairs(calls2.rectangles) do
    if r.mode == "line" then
      lineRects[#lineRects + 1] = r
    end
  end
  Assert.equal(#lineRects, 2)
  Assert.equal(lineRects[1].x, lineRects[2].x)
  Assert.equal(lineRects[1].y, lineRects[2].y)

  -- Override only faceTop
  local g3, calls3 = recordingGraphics()
  local text3 = {
    measure = function()
      return 20
    end,
    lineHeight = 16,
    draw = function() end,
  }
  TextButton.draw(g3, button, { label = "Yes", selected = true, text = text3, colors = { faceTop = { 0, 0, 1, 1 } } })
  Assert.equal(calls3.setColor[6][3], 1)
  Assert.equal(calls3.setColor[1][1], 66 / 255)
end

function T.text_is_centered_and_callback_invoked_once()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  local drawPositions = {}
  local text = {
    measure = function()
      return 40
    end,
    lineHeight = 16,
    draw = function(_, x, y)
      drawPositions[#drawPositions + 1] = { x = x, y = y }
    end,
  }
  TextButton.draw(g, button, { label = "Yes", selected = false, text = text })
  Assert.equal(#drawPositions, 1)
  -- Content source is 104x24. Centered within content => (104-40)/2, (24-16)/2
  local expectedX = (104 - 40) / 2
  local expectedY = (24 - 16) / 2
  Assert.near(drawPositions[1].x, expectedX)
  Assert.near(drawPositions[1].y, expectedY)
  Assert.equal(g._calls.pushCount, 1)
  Assert.equal(g._calls.popCount, 1)
  Assert.equal(#g._calls.transforms, 2)
  Assert.equal(g._calls.transforms[1][1], "translate")
  Assert.equal(g._calls.transforms[2][1], "scale")
  Assert.equal(g._calls.transforms[1][2], button.contentRect.x)
  Assert.equal(g._calls.transforms[1][3], button.contentRect.y)
  Assert.equal(g._calls.transforms[2][2], 1)
end

function T.unknown_color_keys_are_rejected()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  local text = {
    measure = function()
      return 10
    end,
    lineHeight = 16,
    draw = function() end,
  }
  Assert.throws(function()
    TextButton.draw(g, button, { label = "Yes", selected = false, text = text, colors = { unknown = { 1, 0, 0, 1 } } })
  end)
end

function T.invalid_scale_and_non_fitting_label_are_rejected()
  local TextButton = textButtonModule()
  Assert.throws(function()
    TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 0 })
  end)
  Assert.throws(function()
    TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = -1 })
  end)
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  Assert.throws(function()
    TextButton.draw(g, button, {
      label = "Yes",
      selected = false,
      text = {
        measure = function()
          return 200
        end,
        lineHeight = 16,
        draw = function() end,
      },
    })
  end)
  Assert.throws(function()
    TextButton.draw(g, button, {
      label = "Yes",
      selected = false,
      text = {
        measure = function()
          return 10
        end,
        lineHeight = 100,
        draw = function() end,
      },
    })
  end)
end

function T.callback_failure_restores_transform_stack_and_line_width()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  g._state.lineWidth = 7
  local text = {
    measure = function()
      return 10
    end,
    lineHeight = 16,
    draw = function()
      error("boom")
    end,
  }
  Assert.throws(function()
    TextButton.draw(g, button, { label = "Yes", selected = true, text = text })
  end)
  Assert.equal(g._calls.pushCount, g._calls.popCount)
  Assert.equal(g._state.lineWidth, 7)
end

function T.label_fit_is_invariant_under_host_scale()
  local TextButton = textButtonModule()
  local scales = { 0.5, 1, 2 }
  local fittingWidth = 50
  local fittingHeight = 16
  local oversizedWidth = 200
  local oversizedHeight = 100
  for _, scale in ipairs(scales) do
    local size = 120 * scale
    -- Use REFERENCE_HEIGHT scaling proportionally
    local h = 56 * scale
    local button = TextButton.resolve({ rect = rect(0, 0, size, h), scale = scale })
    -- Fitting width/height should succeed at every scale
    local g, _ = recordingGraphics()
    local drawCount = 0
    local textFits = {
      measure = function()
        return fittingWidth
      end,
      lineHeight = fittingHeight,
      draw = function()
        drawCount = drawCount + 1
      end,
    }
    TextButton.draw(g, button, { label = "Yes", selected = false, text = textFits })
    Assert.equal(drawCount, 1, "fitting draws once at scale " .. tostring(scale))
    Assert.equal(g._calls.pushCount, 1, "push once at scale " .. tostring(scale))
    Assert.equal(g._calls.popCount, 1, "pop once at scale " .. tostring(scale))

    -- Oversized width should fail at every scale
    local g2, _ = recordingGraphics()
    Assert.throws(function()
      TextButton.draw(g2, button, {
        label = "Yes",
        selected = false,
        text = {
          measure = function()
            return oversizedWidth
          end,
          lineHeight = fittingHeight,
          draw = function() end,
        },
      })
    end, "oversized width rejected at scale " .. tostring(scale))

    -- Oversized height should fail at every scale
    local g3, _ = recordingGraphics()
    Assert.throws(function()
      TextButton.draw(g3, button, {
        label = "Yes",
        selected = false,
        text = {
          measure = function()
            return fittingWidth
          end,
          lineHeight = oversizedHeight,
          draw = function() end,
        },
      })
    end, "oversized height rejected at scale " .. tostring(scale))
  end
end

function T.restores_line_width_and_transform_on_success()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(5, 10, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  g._state.lineWidth = 9
  local text = {
    measure = function()
      return 20
    end,
    lineHeight = 16,
    draw = function() end,
  }
  TextButton.draw(g, button, { label = "Yes", selected = true, text = text })
  Assert.equal(g._state.lineWidth, 9, "line width restored after success")
  Assert.equal(g._calls.pushCount, 1)
  Assert.equal(g._calls.popCount, 1)
  -- Exactly one scale and one translate
  local scaleCount = 0
  local translateCount = 0
  for _, t in ipairs(g._calls.transforms) do
    if t[1] == "scale" then
      scaleCount = scaleCount + 1
      Assert.equal(t[2], 1)
    elseif t[1] == "translate" then
      translateCount = translateCount + 1
    end
  end
  Assert.equal(scaleCount, 1)
  Assert.equal(translateCount, 1)
end

function T.restores_line_width_on_unselected_success()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g, _ = recordingGraphics()
  g._state.lineWidth = 4
  local text = {
    measure = function()
      return 10
    end,
    lineHeight = 16,
    draw = function() end,
  }
  TextButton.draw(g, button, { label = "Hi", selected = false, text = text })
  Assert.equal(g._state.lineWidth, 4)
  Assert.equal(g._calls.pushCount, g._calls.popCount)
end

function T.requires_graphics_contract()
  local TextButton = textButtonModule()
  local button = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local text = {
    measure = function()
      return 10
    end,
    lineHeight = 16,
    draw = function() end,
  }
  for _, key in ipairs({ "getLineWidth", "setLineWidth", "push", "pop", "translate", "scale" }) do
    local g, _ = recordingGraphics()
    g[key] = nil
    Assert.throws(function()
      TextButton.draw(g, button, { label = "Yes", selected = false, text = text })
    end, "missing " .. key .. " should fail")
  end
end

function T.face_divider_is_source_pixel_chrome()
  local TextButton = textButtonModule()
  local function findDivider(calls, button)
    local innerRect = assert(assert(button.innerBorder).rect)
    local expectedX, expectedW = innerRect.x, innerRect.width
    local expectedH = 2 * button.scale
    local expectedY = assert(button.face).splitY - button.scale
    local innerR, innerG, innerB = 25 / 255, 189 / 255, 197 / 255
    for _, r in ipairs(calls.rectangles) do
      if r.mode == "fill" and r.w == expectedW and r.h == expectedH and r.x == expectedX and r.y == expectedY then
        if
          math.abs(r.color[1] - innerR) < 1e-6
          and math.abs(r.color[2] - innerG) < 1e-6
          and math.abs(r.color[3] - innerB) < 1e-6
        then
          return r
        end
      end
    end
    return nil
  end
  local function textAdapter()
    return {
      measure = function()
        return 10
      end,
      lineHeight = 16,
      draw = function() end,
    }
  end
  -- scale 1 unselected
  local button1 = TextButton.resolve({ rect = rect(0, 0, 120, 56), scale = 1 })
  local g1, calls1 = recordingGraphics()
  TextButton.draw(g1, button1, { label = "Yes", selected = false, text = textAdapter() })
  local divider1 = findDivider(calls1, button1)
  Assert.notNil(divider1, "scale 1 divider must be present at face split with innerBorder color")
  assert(divider1)
  Assert.equal(divider1.w, button1.innerBorder.rect.width)
  Assert.equal(divider1.h, 2)
  Assert.equal(divider1.x, button1.innerBorder.rect.x)
  Assert.equal(divider1.y, button1.face.splitY - 1)
  Assert.equal(
    divider1.y + divider1.h,
    button1.face.splitY + 1,
    "divider must straddle the split by one scale each way across the full inner width"
  )
  -- The source inner border stops at the midway point: no intermediate-color
  -- fill may extend past the divider's bottom edge into the dark half. The
  -- ring's top portion ends exactly at the split; only the divider reaches
  -- one scale below it.
  local innerR2, innerG2, innerB2 = 25 / 255, 189 / 255, 197 / 255
  local function isInner(color)
    return math.abs(color[1] - innerR2) < 1e-6
      and math.abs(color[2] - innerG2) < 1e-6
      and math.abs(color[3] - innerB2) < 1e-6
  end
  for _, r in ipairs(calls1.rectangles) do
    if r.mode == "fill" and isInner(r.color) then
      Assert.isTrue(r.y + r.h <= button1.face.splitY + 1 + 1e-9, "intermediate must stop at the divider bottom edge")
    end
  end
  -- The intermediate ring portion terminates exactly at the split.
  local ringTopFound = false
  for _, r in ipairs(calls1.rectangles) do
    if
      r.mode == "fill"
      and isInner(r.color)
      and r.x == button1.innerBorder.rect.x
      and r.y == button1.innerBorder.rect.y
      and r.w == button1.innerBorder.rect.width
    then
      Assert.equal(r.y + r.h, button1.face.splitY, "the intermediate ring must stop at the midway point")
      ringTopFound = true
    end
  end
  Assert.isTrue(ringTopFound, "the intermediate ring top portion must be present down to the split")
  -- unselected must not emit focus line widths beyond the final restore
  Assert.equal(#calls1.lineWidths, 1, "unselected divider must not add line width changes")
  Assert.equal(calls1.lineWidths[1], 1)
  -- scale 2 unselected
  local button2 = TextButton.resolve({ rect = rect(0, 0, 240, 112), scale = 2 })
  local g2, calls2 = recordingGraphics()
  TextButton.draw(g2, button2, { label = "Yes", selected = false, text = textAdapter() })
  local divider2 = findDivider(calls2, button2)
  Assert.notNil(divider2, "scale 2 divider must be present and scaled")
  assert(divider2)
  Assert.equal(divider2.h, 4)
  Assert.equal(divider2.w, button2.innerBorder.rect.width)
  Assert.equal(divider2.x, button2.innerBorder.rect.x)
  Assert.equal(divider2.y, button2.face.splitY - 2)
  -- selected retains divider plus focus
  local g3, calls3 = recordingGraphics()
  TextButton.draw(g3, button1, { label = "Yes", selected = true, text = textAdapter() })
  local divider3 = findDivider(calls3, button1)
  Assert.notNil(divider3, "selected button must still have divider")
  assert(divider3)
  local lineRects = {}
  for _, r in ipairs(calls3.rectangles) do
    if r.mode == "line" then
      lineRects[#lineRects + 1] = r
    end
  end
  Assert.equal(#lineRects, 2, "selected focus still draws two line rects")
  -- divider color must be innerBorder, not face colors
  local faceTopR, faceTopG, faceTopB = 49 / 255, 222 / 255, 230 / 255
  Assert.isTrue(
    math.abs(divider1.color[1] - faceTopR) > 1e-6
      or math.abs(divider1.color[2] - faceTopG) > 1e-6
      or math.abs(divider1.color[3] - faceTopB) > 1e-6,
    "divider must not use faceTop color"
  )
end

return { tests = T }
