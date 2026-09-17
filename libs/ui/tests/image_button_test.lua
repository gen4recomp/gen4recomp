local Assert = require("tests.support.Assert")

local T = {}

local function imageButtonModule()
  local ok, mod = pcall(require, "libs.ui.src.ImageButton")
  Assert.isTrue(ok, "ImageButton missing: " .. tostring(mod))
  return mod
end

local function rect(x, y, w, h)
  return { x = x, y = y, width = w, height = h }
end

local function graphicsFake()
  local state = { color = { 1, 1, 1, 1 }, lineWidth = 1 }
  local calls = { setColor = {}, rectangles = {}, polygons = {} }
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
      }
    end,
    polygon = function(mode, ...)
      calls.polygons[#calls.polygons + 1] =
        { mode = mode, points = { ... }, color = { state.color[1], state.color[2], state.color[3], state.color[4] } }
    end,
    getColor = function()
      return state.color[1], state.color[2], state.color[3], state.color[4]
    end,
    _calls = calls,
  }
  return g, calls
end

function T.selected_rim_exactly_replaces_unselected_rim()
  local ImageButton = imageButtonModule()
  local button = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1 })
  Assert.equal(button.rim.rect.width, 96)
  Assert.equal(button.face.rect.width, 90)
  local g1, calls1 = graphicsFake()
  local g2, calls2 = graphicsFake()
  local imageRect = { x = button.contentRect.x + 2, y = button.contentRect.y + 2, width = 10, height = 10 }
  ImageButton.draw(
    g1,
    button,
    { selected = false, colors = { face = { 0.5, 0.5, 0.5, 1 } }, imageRect = imageRect, drawImage = function() end }
  )
  ImageButton.draw(
    g2,
    button,
    { selected = true, colors = { face = { 0.5, 0.5, 0.5, 1 } }, imageRect = imageRect, drawImage = function() end }
  )
  Assert.near(calls1.setColor[2][1], 222 / 255)
  Assert.near(calls2.setColor[2][1], 1)
  Assert.equal(button.rim.rect.x, button.rect.x + 2)
  Assert.equal(button.rim.rect.y, button.rect.y + 2)
  Assert.equal(button.rim.cornerRadius, 6)
end

function T.canonical_geometry_and_content_is_face()
  local ImageButton = imageButtonModule()
  local button = ImageButton.resolve({ rect = rect(10, 20, 93, 148), scale = 1 })
  Assert.equal(button.border.cornerRadius, 8)
  Assert.equal(button.rim.cornerRadius, 6)
  Assert.equal(button.contentRect.x, button.face.rect.x)
  Assert.equal(button.contentRect.y, button.face.rect.y)
  Assert.equal(button.contentRect.width, button.face.rect.width)
  Assert.equal(button.contentRect.height, button.face.rect.height)
end

function T.same_rim_geometry_selection_changes_only_color()
  local ImageButton = imageButtonModule()
  local button = ImageButton.resolve({ rect = rect(0, 0, 80, 80), scale = 2 })
  local g1, c1 = graphicsFake()
  local g2, c2 = graphicsFake()
  local ir = { x = button.contentRect.x + 1, y = button.contentRect.y + 1, width = 20, height = 20 }
  ImageButton.draw(
    g1,
    button,
    { selected = false, colors = { face = { 1, 1, 1, 1 } }, imageRect = ir, drawImage = function() end }
  )
  ImageButton.draw(
    g2,
    button,
    { selected = true, colors = { face = { 1, 1, 1, 1 } }, imageRect = ir, drawImage = function() end }
  )
  Assert.equal(#c1.rectangles, #c2.rectangles)
  Assert.equal(#c1.polygons, #c2.polygons)
  Assert.equal(c1.polygons[1], nil, "no polygons for rounded")
  Assert.isTrue(#c1.rectangles >= 5, "rounded rectangles")
  Assert.equal(button.scale, 2)
end

function T.image_bounds_validation()
  local ImageButton = imageButtonModule()
  local button = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1 })
  local g, _ = graphicsFake()
  local contained = { x = button.contentRect.x, y = button.contentRect.y, width = 10, height = 10 }
  local called = 0
  ImageButton.draw(g, button, {
    selected = false,
    colors = { face = { 0, 0, 0, 1 } },
    imageRect = contained,
    drawImage = function()
      called = called + 1
    end,
  })
  Assert.equal(called, 1)
  local out = { x = button.contentRect.x - 1, y = button.contentRect.y, width = 10, height = 10 }
  Assert.throws(function()
    ImageButton.draw(
      g,
      button,
      { selected = false, colors = { face = { 0, 0, 0, 1 } }, imageRect = out, drawImage = function() end }
    )
  end)
  local tooBig =
    { x = button.contentRect.x, y = button.contentRect.y, width = button.contentRect.width + 1, height = 10 }
  Assert.throws(function()
    ImageButton.draw(
      g,
      button,
      { selected = false, colors = { face = { 0, 0, 0, 1 } }, imageRect = tooBig, drawImage = function() end }
    )
  end)
end

function T.color_overrides_and_unknown_keys_rejected()
  local ImageButton = imageButtonModule()
  local button = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1 })
  local g, calls = graphicsFake()
  local ir = { x = button.contentRect.x, y = button.contentRect.y, width = 5, height = 5 }
  ImageButton.draw(g, button, {
    selected = false,
    colors = { face = { 0.1, 0.2, 0.3, 1 }, border = { 0, 0, 0, 1 } },
    imageRect = ir,
    drawImage = function() end,
  })
  Assert.near(calls.setColor[1][1], 0)
  Assert.throws(function()
    ImageButton.draw(g, button, {
      selected = false,
      colors = { face = { 1, 1, 1, 1 }, unknown = { 1, 0, 0, 1 } },
      imageRect = ir,
      drawImage = function() end,
    })
  end)
  Assert.throws(function()
    ImageButton.draw(g, button, { selected = false, colors = {}, imageRect = ir, drawImage = function() end })
  end)
end

function T.invalid_scale_rejected()
  local ImageButton = imageButtonModule()
  Assert.throws(function()
    ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 0 })
  end)
end

function T.card_composes_generic_button_geometry_and_hit_testing()
  local ImageButton = imageButtonModule()
  local Button = require("libs.ui.src.Button")
  local card = ImageButton.resolve({ rect = rect(10, 20, 93, 148), scale = 1 })
  local generic = Button.resolve({
    rect = rect(10, 20, 93, 148),
    borderWidth = 2,
    rimWidth = 2,
    innerBorderWidth = 1,
    cornerRadius = 8,
    faceSplit = 0.5,
    contentInsetX = 0,
    contentInsetY = 0,
  })
  Assert.deepEqual(card.rect, generic.rect)
  Assert.deepEqual(card.contentRect, generic.contentRect)
  Assert.isTrue(Button.contains(card, 11, 21))
  Assert.isFalse(Button.contains(card, 9, 21))
end

function T.focus_changes_chrome_only_while_portrait_draws()
  local ImageButton = imageButtonModule()
  local button = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1 })
  local g1, calls1 = graphicsFake()
  local g2, calls2 = graphicsFake()
  local imageRect = { x = button.contentRect.x + 2, y = button.contentRect.y + 2, width = 10, height = 10 }
  local portraitsDrawn = 0
  local function drawPortrait()
    portraitsDrawn = portraitsDrawn + 1
  end
  ImageButton.draw(
    g1,
    button,
    { selected = false, colors = { face = { 0.5, 0.5, 0.5, 1 } }, imageRect = imageRect, drawImage = drawPortrait }
  )
  ImageButton.draw(
    g2,
    button,
    { selected = true, colors = { face = { 0.5, 0.5, 0.5, 1 } }, imageRect = imageRect, drawImage = drawPortrait }
  )
  Assert.equal(portraitsDrawn, 2)
  Assert.equal(#calls1.rectangles, #calls2.rectangles)
  Assert.near(calls1.setColor[2][2], 230 / 255)
  Assert.near(calls2.setColor[2][2], 58 / 255)
  Assert.near(calls2.setColor[2][3], 58 / 255)
end

function T.nested_card_layers_keep_positive_corner_radii()
  local ImageButton = imageButtonModule()
  local button = ImageButton.resolve({ rect = rect(10, 20, 93, 148), scale = 1 })
  Assert.equal(button.border.cornerRadius, 8)
  Assert.equal(button.rim.cornerRadius, 6)
  Assert.equal(button.innerBorder.cornerRadius, 4)
  Assert.equal(button.face.cornerRadius, 3)
  Assert.isTrue(button.border.cornerRadius > 0)
  Assert.isTrue(button.rim.cornerRadius > 0)
  Assert.isTrue(button.innerBorder.cornerRadius > 0)
  Assert.isTrue(button.face.cornerRadius > 0)
end

function T.callers_select_logical_radius_and_inner_border_width()
  local ImageButton = imageButtonModule()
  local at1 = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1, cornerRadius = 6, innerBorderWidth = 2 })
  Assert.equal(at1.border.cornerRadius, 6)
  Assert.equal(at1.rim.cornerRadius, 4)
  Assert.equal(at1.innerBorder.cornerRadius, 2)
  local at2 = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 2, cornerRadius = 6, innerBorderWidth = 2 })
  Assert.equal(at2.border.cornerRadius, 12)
  Assert.equal(at2.rim.cornerRadius, 8)
  Assert.equal(at2.innerBorder.cornerRadius, 4)
  local defaultButton = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1 })
  Assert.isTrue(
    at1.contentRect.x > defaultButton.contentRect.x,
    "a wider inner border must leave a smaller content rectangle"
  )
  Assert.equal(at1.contentRect.x - defaultButton.contentRect.x, 1)
end

function T.invalid_radius_and_inner_border_width_are_rejected()
  local ImageButton = imageButtonModule()
  Assert.throws(function()
    ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1, cornerRadius = -1 })
  end)
  Assert.throws(function()
    ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1, cornerRadius = "6" })
  end)
  Assert.throws(function()
    ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1, innerBorderWidth = 0 })
  end)
  Assert.throws(function()
    ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1, innerBorderWidth = -2 })
  end)
end

function T.omitted_options_keep_current_default_geometry()
  local ImageButton = imageButtonModule()
  local defaultButton = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1 })
  local explicitDefault =
    ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 1, cornerRadius = 8, innerBorderWidth = 1 })
  Assert.deepEqual(explicitDefault.rect, defaultButton.rect)
  Assert.deepEqual(explicitDefault.contentRect, defaultButton.contentRect)
  Assert.equal(explicitDefault.border.cornerRadius, 8)
  local scaled = ImageButton.resolve({ rect = rect(0, 0, 100, 100), scale = 2 })
  Assert.equal(scaled.border.cornerRadius, 16)
end

return { tests = T }
