-- The Naming Screen focus mark is a generated source visual, never a
-- procedural outline: the keyboard cursor draws at its stepped position on
-- glyph rows, and the matching home cursor variant draws on the home row. No
-- synthetic rectangle remains now that the generated visuals supply the
-- focus presentation.

local Assert = require("tests.support.Assert")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = { tests = {} }

local function namingManifest()
  return FieldUiFixture.namingSemanticsManifest()
end

local function imageLoader()
  return function(path)
    return { path = path, release = function() end }
  end
end

local function graphicsFake()
  local calls = { draws = {} }
  local graphics = {
    push = function() end,
    pop = function() end,
    translate = function() end,
    scale = function() end,
    setColor = function() end,
    rectangle = function()
      calls[#calls + 1] = { name = "rectangle" }
    end,
    draw = function(image, x, y)
      calls.draws[#calls.draws + 1] = { image = image, x = x, y = y }
    end,
  }
  return graphics, calls
end

local function textFake()
  return {
    drawText = function() end,
    textWidth = function(value)
      return #value * 8
    end,
  }
end

local function snapshot(cursor)
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "glyph", glyph = "A" }
    end
  end
  return {
    page = "upper",
    cursor = cursor,
    text = "",
    maxLength = 7,
    grid = grid,
    subject = { kind = "player", gender = 0 },
  }
end

local function drawsOf(calls, path)
  local found = {}
  for _, draw in ipairs(calls.draws) do
    if draw.image.path == path then
      found[#found + 1] = draw
    end
  end
  return found
end

function T.tests.keyboard_focus_draws_the_stepped_cursor_visual_without_outlines()
  local graphics, calls = graphicsFake()
  local manifest = namingManifest()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest,
    imageLoader = imageLoader(),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  renderer:draw(snapshot({ row = 3, column = 5 }), layout)
  renderer:dispose()

  for _, call in ipairs(calls) do
    Assert.isTrue(call.name ~= "rectangle", "source visuals supply the focus, so no outline remains")
  end
  local cursor = manifest.namingScreen.cursor.keyboard
  local found = drawsOf(calls, cursor.image)
  Assert.equal(#found, 1, "the keyboard cursor draws exactly once")
  Assert.deepEqual({ x = found[1].x, y = found[1].y }, {
    x = cursor.anchor.x + (5 - 1) * cursor.stepX + cursor.offset.x,
    y = cursor.anchor.y + (3 - 2) * cursor.stepY + cursor.offset.y,
  })
end

function T.tests.home_row_focus_draws_the_matching_cursor_variant()
  local graphics, calls = graphicsFake()
  local manifest = namingManifest()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest,
    imageLoader = imageLoader(),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  renderer:draw(snapshot({ row = 1, column = 9 }), layout)
  renderer:dispose()

  for _, call in ipairs(calls) do
    Assert.isTrue(call.name ~= "rectangle", "source visuals supply the focus, so no outline remains")
  end
  local variant = manifest.namingScreen.cursor.home.back
  local found = drawsOf(calls, variant.image)
  Assert.equal(#found, 1, "the Back home-cursor variant draws exactly once")
  Assert.deepEqual({ x = found[1].x, y = found[1].y }, {
    x = variant.anchor.x + variant.offset.x,
    y = variant.anchor.y + variant.offset.y,
  })
end

-- A loader failure partway through the expanded visual acquisition must
-- release every image acquired so far exactly once before the constructor
-- rethrows: partial acquisition never leaks.
function T.tests.failed_acquisition_releases_every_previously_acquired_image()
  local acquired = {}
  local calls = 0
  local loader = function(path)
    calls = calls + 1
    if calls == 5 then
      error("injected naming image failure", 0)
    end
    local image = { path = path, releases = 0 }
    image.release = function()
      image.releases = image.releases + 1
    end
    acquired[#acquired + 1] = image
    return image
  end
  local graphics = graphicsFake()
  local err = Assert.throws(function()
    NamingScreenRenderer.new({
      graphics = graphics,
      text = textFake(),
      drawSubject = function() end,
      manifest = namingManifest(),
      imageLoader = loader,
    })
  end)
  Assert.isTrue(tostring(err):find("injected naming image failure", 1, true) ~= nil, "rethrows the loader failure")
  Assert.equal(#acquired, 4, "four visuals were acquired before the failure")
  for _, image in ipairs(acquired) do
    Assert.equal(image.releases, 1, "acquired image " .. image.path .. " is released exactly once")
  end
end

return T
