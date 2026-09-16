-- The reusable Naming Screen composes generated source chrome instead of
-- hand-drawn rectangles: the opaque base first, the selected page overlay at
-- its canonical placement, then the host subject, the entered name, the
-- keyboard glyphs, and exactly one focus mark on the selected cell. Unknown
-- pages are programmer errors, never a silent fallback.

local Assert = require("tests.support.Assert")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")

local T = {}

local BASE_PATH = "assets/generated/field/ui/naming-screen-base.png"
local UPPER_PATH = "assets/generated/field/ui/naming-screen-page-upper.png"
local LOWER_PATH = "assets/generated/field/ui/naming-screen-page-lower.png"
local SYMBOLS_PATH = "assets/generated/field/ui/naming-screen-page-symbols.png"

local function manifest()
  return {
    namingScreen = {
      base = { asset = "hgss.naming_screen.base", image = BASE_PATH, width = 256, height = 192 },
      pages = {
        upper = { asset = "hgss.naming_screen.page_upper", image = UPPER_PATH, width = 256, height = 112 },
        lower = { asset = "hgss.naming_screen.page_lower", image = LOWER_PATH, width = 256, height = 112 },
        symbols = { asset = "hgss.naming_screen.page_symbols", image = SYMBOLS_PATH, width = 256, height = 112 },
      },
      placement = { x = 0, y = 80, width = 256, height = 112 },
    },
  }
end

local function graphicsFake()
  local calls = { draws = {}, rectangles = {}, colors = {} }
  local graphics = {
    push = function() end,
    pop = function() end,
    translate = function() end,
    scale = function() end,
    setColor = function(r, g, b, a)
      calls.colors[#calls.colors + 1] = { r, g, b, a }
    end,
    rectangle = function(mode, x, y, width, height)
      calls.rectangles[#calls.rectangles + 1] = { mode = mode, x = x, y = y, width = width, height = height }
    end,
    draw = function(image, x, y)
      calls.draws[#calls.draws + 1] = { image = image, x = x, y = y }
    end,
  }
  return graphics, calls
end

local function textFake()
  local calls = { texts = {} }
  local text = {
    drawText = function(_, value, x, y)
      calls.texts[#calls.texts + 1] = { value = value, x = x, y = y }
    end,
    textWidth = function(_, value)
      return #value * 8
    end,
  }
  return text, calls
end

local function imageLoaderFake(failOn)
  local calls = { loads = {}, images = {} }
  local loader = function(path)
    calls.loads[#calls.loads + 1] = path
    if failOn ~= nil and #calls.loads == failOn then
      error("injected image failure for " .. path, 0)
    end
    local image = { path = path, released = false, releaseCount = 0 }
    function image:release()
      self.released = true
      self.releaseCount = self.releaseCount + 1
    end
    calls.images[#calls.images + 1] = image
    return image
  end
  return loader, calls
end

local function snapshot(page, cursor)
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "glyph", glyph = "A" }
    end
  end
  return {
    page = page,
    cursor = cursor,
    text = "AB",
    maxLength = 7,
    grid = grid,
    subject = { kind = "player", gender = 0 },
  }
end

local function layout()
  return NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
end

function T.construction_requires_the_naming_chrome_contract()
  local graphics = graphicsFake()
  local text = textFake()
  Assert.throws(function()
    NamingScreenRenderer.new({ graphics = graphics, text = text, drawSubject = function() end })
  end, "a renderer without its naming manifest must fail at construction")
  local _, loads = imageLoaderFake()
  Assert.throws(function()
    NamingScreenRenderer.new({
      graphics = graphics,
      text = text,
      drawSubject = function() end,
      manifest = manifest(),
    })
  end, "a renderer without its generated image loader must fail at construction")
  Assert.equal(#loads.loads, 0, "a rejected construction acquires no images")
end

function T.construction_acquires_the_base_and_every_page()
  local graphics = graphicsFake()
  local loader, loads = imageLoaderFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest(),
    imageLoader = loader,
  })
  Assert.equal(#loads.loads, 4, "construction loads the base plus all three pages")
  local seen = {}
  for _, path in ipairs(loads.loads) do
    seen[path] = true
  end
  for _, path in ipairs({ BASE_PATH, UPPER_PATH, LOWER_PATH, SYMBOLS_PATH }) do
    Assert.isTrue(seen[path], "construction loads " .. path)
  end
  renderer:dispose()
  for _, image in ipairs(loads.images) do
    Assert.equal(image.releaseCount, 1, "dispose releases " .. image.path .. " exactly once")
  end
end

function T.construction_failure_releases_already_acquired_images()
  local loader, loads = imageLoaderFake(3)
  local err = Assert.throws(function()
    NamingScreenRenderer.new({
      graphics = graphicsFake(),
      text = textFake(),
      drawSubject = function() end,
      manifest = manifest(),
      imageLoader = loader,
    })
  end, "a mid-acquisition image failure must fail construction")
  Assert.isTrue(tostring(err):find("injected image failure", 1, true) ~= nil)
  Assert.equal(#loads.images, 2, "two images were acquired before the failure")
  for _, image in ipairs(loads.images) do
    Assert.isTrue(image.released, image.path .. " is released after the failed construction")
  end
end

function T.draw_composes_base_page_subject_text_and_a_single_focus_mark()
  local graphics, calls = graphicsFake()
  local text, textCalls = textFake()
  local loader, _ = imageLoaderFake()
  local seenSubject = {}
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = text,
    drawSubject = function(_, subject, rect)
      seenSubject[#seenSubject + 1] = { subject = subject, rect = rect }
    end,
    manifest = manifest(),
    imageLoader = loader,
  })
  local view = snapshot("lower", { row = 3, column = 5 })
  local layoutResult = layout()
  renderer:draw(view, layoutResult)

  Assert.isTrue(#calls.draws >= 2, "the base and the selected page are drawn as images")
  Assert.equal(calls.draws[1].image.path, BASE_PATH, "the base draws first")
  Assert.deepEqual({ x = calls.draws[1].x, y = calls.draws[1].y }, { x = 0, y = 0 })
  Assert.equal(calls.draws[2].image.path, LOWER_PATH, "the selected lower page draws over the base")
  Assert.deepEqual({ x = calls.draws[2].x, y = calls.draws[2].y }, { x = 0, y = 80 })

  for _, rect in ipairs(calls.rectangles) do
    Assert.isTrue(rect.mode ~= "fill", "source chrome supplies the pixels, so no synthetic fill remains")
  end
  local lines = {}
  for _, rect in ipairs(calls.rectangles) do
    if rect.mode == "line" then
      lines[#lines + 1] = rect
    end
  end
  Assert.equal(#lines, 1, "exactly one selected focus mark remains")
  Assert.deepEqual(
    { x = lines[1].x, y = lines[1].y, width = lines[1].width, height = lines[1].height },
    layoutResult.cells[3][5]
  )

  Assert.equal(#seenSubject, 1, "the host subject still draws through its callback")
  Assert.deepEqual(seenSubject[1].subject, view.subject)
  local entered = false
  for _, entry in ipairs(textCalls.texts) do
    if entry.value == "AB" then
      entered = true
    end
  end
  Assert.isTrue(entered, "the entered name still renders")
  Assert.isTrue(#textCalls.texts > 1, "keyboard glyphs still render")
  renderer:dispose()
end

function T.unknown_page_is_a_programmer_error()
  local loader = imageLoaderFake()
  local renderer = NamingScreenRenderer.new({
    graphics = graphicsFake(),
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest(),
    imageLoader = loader,
  })
  Assert.throws(function()
    renderer:draw(snapshot("digits", { row = 2, column = 1 }), layout())
  end, "an unknown page must fail instead of silently choosing a normal overlay")
  renderer:dispose()
end

return { tests = T }
