-- The reusable Naming Screen draws from its generated semantic contract,
-- never from interaction geometry: keyboard glyphs center in the generated
-- 16px source text cells, the entered name advances 12px per glyph from its
-- fixed origin, controls/cursor/slots/player subject draw as generated OBJ
-- visuals at their source anchors plus frame offsets, and the player subject
-- comes from the manifest rather than the host subject callback. The host
-- callback stays the seam for non-player subjects only. Canonical and
-- integer-host layouts share one logical surface.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")

local T = {}

local GLYPH_WIDTHS = { W = 12, i = 4 }

local function textFake(calls)
  return {
    drawText = function(_, value, x, y)
      calls[#calls + 1] = { value = value, x = x, y = y }
    end,
    textWidth = function(_, value)
      local glyph = value ~= nil and value or _
      return GLYPH_WIDTHS[glyph] or 8
    end,
  }
end

local function imageLoaderFake(loaded)
  return function(path)
    loaded[#loaded + 1] = path
    local image = { path = path }
    function image:release() end
    return image
  end
end

local function blankGrid()
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "blank" }
    end
  end
  return grid
end

local function snapshot(options)
  local grid = blankGrid()
  for _, glyph in ipairs(options.glyphs or {}) do
    grid[glyph.row][glyph.column] = { kind = "glyph", glyph = glyph.value }
  end
  return {
    page = options.page or "upper",
    cursor = options.cursor or { row = 3, column = 5 },
    text = options.text or "",
    maxLength = options.maxLength or 7,
    grid = grid,
    subject = options.subject or { kind = "player", gender = 0 },
  }
end

local function drawAt(draws, path, x, y)
  local found = {}
  for _, draw in ipairs(draws) do
    if type(draw.image) == "table" and draw.image.path == path then
      if x == nil or (draw.x == x and draw.y == y) then
        found[#found + 1] = draw
      end
    end
  end
  return found
end

local function assertDrawnOnce(draws, path, x, y, what)
  local found = drawAt(draws, path, x, y)
  Assert.equal(#found, 1, what .. " draws exactly once")
  Assert.equal(found[1].x, x, what .. " x follows its source anchor plus frame offset")
  Assert.equal(found[1].y, y, what .. " y follows its source anchor plus frame offset")
end

local function textAt(calls, value)
  local found = {}
  for _, call in ipairs(calls) do
    if call.value == value then
      found[#found + 1] = call
    end
  end
  return found
end

function T.keyboard_and_name_text_follow_the_generated_window_geometry()
  local graphics = FakeGraphics.new()
  local textCalls = {}
  local manifest = FieldUiFixture.namingSemanticsManifest()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(textCalls),
    drawSubject = function() end,
    manifest = manifest,
    imageLoader = imageLoaderFake({}),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  -- Grid rows 2..6 are the glyph rows; the manifest carries the five source
  -- text rows for them, so grid row r draws from text row r - 1.
  renderer:draw(
    snapshot({
      text = "AB",
      glyphs = {
        { row = 2, column = 1, value = "W" },
        { row = 3, column = 5, value = "i" },
      },
    }),
    layout
  )
  renderer:dispose()

  local cells = assert(manifest.namingScreen.text.keyboard.cells)
  local wide = textAt(textCalls, "W")
  Assert.equal(#wide, 1, "the wide glyph draws once")
  Assert.equal(wide[1].x, cells[1][1].x + (cells[1][1].width - GLYPH_WIDTHS.W) / 2)
  Assert.equal(wide[1].y, cells[1][1].y)
  local narrow = textAt(textCalls, "i")
  Assert.equal(#narrow, 1, "the narrow glyph draws once")
  Assert.equal(narrow[1].x, cells[2][5].x + (cells[2][5].width - GLYPH_WIDTHS.i) / 2)
  Assert.equal(narrow[1].y, cells[2][5].y)
  -- The entered name advances one fixed slot per glyph from its origin;
  -- it is never centered as a whole string.
  local name = manifest.namingScreen.text.name
  local first = textAt(textCalls, "A")
  Assert.equal(#first, 1, "the first name glyph draws once")
  Assert.equal(first[1].x, name.x)
  Assert.equal(first[1].y, name.y)
  local second = textAt(textCalls, "B")
  Assert.equal(#second, 1, "the second name glyph draws once")
  Assert.equal(second[1].x, name.x + name.advanceX)
  Assert.equal(second[1].y, name.y)
  Assert.equal(#textAt(textCalls, "AB"), 0, "the name is placed per glyph, never as one centered string")
end

function T.source_object_layers_and_player_subject_render_from_the_manifest()
  local graphics = FakeGraphics.new()
  local textCalls = {}
  local loaded = {}
  local manifest = FieldUiFixture.namingSemanticsManifest()
  local subjects = {}
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(textCalls),
    drawSubject = function(_, subject, rect)
      subjects[#subjects + 1] = { subject = subject, rect = rect }
    end,
    manifest = manifest,
    imageLoader = imageLoaderFake(loaded),
  })
  local naming = manifest.namingScreen
  local seen = {}
  for _, path in ipairs(loaded) do
    seen[path] = true
  end
  for id, record in pairs({
    upper = naming.controls.upper,
    lower = naming.controls.lower,
    symbols = naming.controls.symbols,
    back = naming.controls.back,
    ok = naming.controls.ok,
    backing = naming.controls.backing,
    keyboardCursor = naming.cursor.keyboard,
    homeUpper = naming.cursor.home.upper,
    slotNormal = naming.entrySlots.normal,
    slotSelected = naming.entrySlots.selected,
    male = naming.playerSubjects.male,
    female = naming.playerSubjects.female,
  }) do
    Assert.isTrue(seen[record.image], "construction acquires the " .. id .. " visual")
  end

  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  renderer:draw(snapshot({ page = "upper", cursor = { row = 3, column = 5 }, text = "AB", maxLength = 3 }), layout)

  for id, record in pairs(naming.controls) do
    assertDrawnOnce(
      graphics.draws,
      record.image,
      record.anchor.x + record.offset.x,
      record.anchor.y + record.offset.y,
      "the " .. id .. " control"
    )
  end
  local cursor = naming.cursor.keyboard
  assertDrawnOnce(
    graphics.draws,
    cursor.image,
    cursor.anchor.x + (5 - 1) * cursor.stepX + cursor.offset.x,
    cursor.anchor.y + (3 - 2) * cursor.stepY + cursor.offset.y,
    "the keyboard cursor"
  )
  for index = 0, 2 do
    assertDrawnOnce(
      graphics.draws,
      naming.entrySlots.normal.image,
      naming.entrySlots.origin.x + index * naming.entrySlots.stepX,
      naming.entrySlots.origin.y,
      "entry slot " .. index
    )
  end
  -- Two glyphs are entered, so the third slot carries the selected visual.
  assertDrawnOnce(
    graphics.draws,
    naming.entrySlots.selected.image,
    naming.entrySlots.origin.x + 2 * naming.entrySlots.stepX,
    naming.entrySlots.origin.y,
    "the current entry slot"
  )
  local male = naming.playerSubjects.male
  assertDrawnOnce(
    graphics.draws,
    male.image,
    male.anchor.x + male.offset.x,
    male.anchor.y + male.offset.y,
    "the male player subject"
  )
  Assert.equal(#subjects, 0, "the player subject comes from the manifest, not the host callback")

  -- The host seam stays for non-player subjects.
  local pokemon = { kind = "pokemon", species = 25, form = 0 }
  renderer:draw(snapshot({ subject = pokemon }), layout)
  Assert.equal(#subjects, 1, "a pokemon subject still draws through the host callback")
  Assert.deepEqual(subjects[1].subject, pokemon)
  renderer:dispose()
end

function T.home_control_focus_uses_the_matching_cursor_variant()
  local graphics = FakeGraphics.new()
  local manifest = FieldUiFixture.namingSemanticsManifest()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake({}),
    drawSubject = function() end,
    manifest = manifest,
    imageLoader = imageLoaderFake({}),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  renderer:draw(snapshot({ cursor = { row = 1, column = 10, controlId = "back" } }), layout)
  renderer:dispose()

  local variant = manifest.namingScreen.cursor.home.back
  assertDrawnOnce(
    graphics.draws,
    variant.image,
    variant.anchor.x + variant.offset.x,
    variant.anchor.y + variant.offset.y,
    "the Back home-cursor variant"
  )
end

function T.canonical_and_integer_host_scales_share_one_logical_surface()
  local function render(viewport)
    local graphics = FakeGraphics.new()
    local textCalls = {}
    local renderer = NamingScreenRenderer.new({
      graphics = graphics,
      text = textFake(textCalls),
      drawSubject = function() end,
      manifest = FieldUiFixture.namingSemanticsManifest(),
      imageLoader = imageLoaderFake({}),
    })
    local layout = NamingScreenLayout.compute(viewport)
    renderer:draw(snapshot({ page = "lower", cursor = { row = 4, column = 7 }, text = "ABC", maxLength = 5 }), layout)
    renderer:dispose()
    return graphics.draws, textCalls
  end
  local canonicalDraws, canonicalTexts = render({ x = 0, y = 0, width = 256, height = 192 })
  local hostedDraws, hostedTexts = render({ x = 0, y = 0, width = 512, height = 384 })
  Assert.isTrue(#canonicalDraws > 4, "the canonical surface draws its source layers, not just chrome")
  Assert.equal(#hostedDraws, #canonicalDraws, "the integer host draws the same logical layers")
  for index, draw in ipairs(canonicalDraws) do
    local hosted = hostedDraws[index]
    Assert.equal(hosted.image.path, draw.image.path, "draw " .. index .. " keeps its visual across scales")
    Assert.equal(hosted.x, draw.x, "draw " .. index .. " keeps its logical x across scales")
    Assert.equal(hosted.y, draw.y, "draw " .. index .. " keeps its logical y across scales")
    Assert.equal(hosted.x, math.floor(hosted.x), "draw " .. index .. " x stays on an integer pixel")
    Assert.equal(hosted.y, math.floor(hosted.y), "draw " .. index .. " y stays on an integer pixel")
  end
  Assert.equal(#hostedTexts, #canonicalTexts, "both scales place the same text calls")
  for index, call in ipairs(canonicalTexts) do
    Assert.equal(hostedTexts[index].value, call.value, "text " .. index .. " keeps its content across scales")
    Assert.equal(hostedTexts[index].x, call.x, "text " .. index .. " keeps its logical x across scales")
    Assert.equal(hostedTexts[index].y, call.y, "text " .. index .. " keeps its logical y across scales")
  end
end

return GraphicsSmoke.suite(T)
