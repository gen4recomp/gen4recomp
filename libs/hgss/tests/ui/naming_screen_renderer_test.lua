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
  local calls = { draws = {}, colors = {} }
  local graphics = {
    push = function() end,
    pop = function() end,
    translate = function() end,
    scale = function() end,
    setColor = function(r, g, b, a)
      calls.colors[#calls.colors + 1] = { r = r, g = g, b = b, a = a }
    end,
    rectangle = function()
      calls[#calls + 1] = { name = "rectangle" }
    end,
    newQuad = function(x, y, w, h, imgW, imgH)
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
    draw = function(image, quad, x, y)
      if type(quad) == "number" then
        quad, x, y = nil, quad, x
      end
      calls.draws[#calls.draws + 1] = { image = image, quad = quad, x = x, y = y }
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
    presentation = { subjectTick = 0, cursorTick = 0, glowAngle = 180 },
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
  local frame = cursor.frames[1]
  local found = drawsOf(calls, manifest.assets[frame.asset].image)
  Assert.equal(#found, 1, "the keyboard cursor draws exactly once")
  Assert.deepEqual({ x = found[1].x, y = found[1].y }, {
    x = cursor.origin.x + (5 - 1) * cursor.stepX + frame.offset.x,
    y = cursor.origin.y + (3 - 2) * cursor.stepY + frame.offset.y,
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
  local frame = variant.frames[1]
  local found = drawsOf(calls, manifest.assets[frame.asset].image)
  Assert.equal(#found, 1, "the Back home-cursor variant draws exactly once")
  Assert.deepEqual({ x = found[1].x, y = found[1].y }, {
    x = variant.anchor.x + frame.offset.x,
    y = variant.anchor.y + frame.offset.y,
  })
end

local function recordingGraphics(calls)
  return {
    push = function() end,
    pop = function() end,
    translate = function() end,
    scale = function() end,
    setColor = function(r, g, b, a)
      calls.colors[#calls.colors + 1] = { r = r, g = g, b = b, a = a }
    end,
    rectangle = function()
      calls[#calls + 1] = { name = "rectangle" }
    end,
    newQuad = function(x, y, w, h, imgW, imgH)
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
    draw = function(image, quad, x, y)
      if type(quad) == "number" then
        quad, x, y = nil, quad, x
      end
      calls.draws[#calls.draws + 1] = { image = image, quad = quad, x = x, y = y, colorIndex = #calls.colors }
    end,
  }
end

local function animatedFrameManifest()
  local manifest = namingManifest()
  local naming = manifest.namingScreen
  local function frameImage(id, path)
    manifest.assets[id] = { image = path, width = 16, height = 16 }
    return path
  end
  naming.playerSubjects.male.playMode = "forward_loop"
  naming.playerSubjects.male.loopStartFrameIdx = 0
  naming.playerSubjects.male.frames = {
    {
      asset = "hgss.naming_screen.subject_male_f0",
      image = frameImage("hgss.naming_screen.subject_male_f0", "subject-male-f0.png"),
      rect = { x = 0, y = 0, width = 16, height = 16 },
      offset = { x = 0, y = 0 },
      duration = 2,
    },
    {
      asset = "hgss.naming_screen.subject_male_f1",
      image = frameImage("hgss.naming_screen.subject_male_f1", "subject-male-f1.png"),
      rect = { x = 0, y = 0, width = 16, height = 16 },
      offset = { x = 0, y = 0 },
      duration = 1,
    },
  }
  naming.playerSubjects.female.playMode = "forward_loop"
  naming.playerSubjects.female.loopStartFrameIdx = 0
  naming.playerSubjects.female.frames = {
    {
      asset = "hgss.naming_screen.subject_female_f0",
      image = frameImage("hgss.naming_screen.subject_female_f0", "subject-female-f0.png"),
      rect = { x = 0, y = 0, width = 16, height = 16 },
      offset = { x = 0, y = 0 },
      duration = 1,
    },
  }
  local keyboard = naming.cursor.keyboard
  keyboard.playMode = "forward_loop"
  keyboard.loopStartFrameIdx = 0
  keyboard.pulseAsset = "hgss.naming_screen.cursor_keyboard_mask"
  frameImage("hgss.naming_screen.cursor_keyboard_mask", "cursor-keyboard-mask.png")
  keyboard.frames = {
    {
      asset = "hgss.naming_screen.cursor_keyboard_f0",
      image = frameImage("hgss.naming_screen.cursor_keyboard_f0", "cursor-keyboard-f0.png"),
      rect = { x = 0, y = 0, width = 16, height = 16 },
      pulseRect = { x = 0, y = 0, width = 16, height = 16 },
      offset = { x = 0, y = 0 },
      duration = 1,
    },
    {
      asset = "hgss.naming_screen.cursor_keyboard_f1",
      image = frameImage("hgss.naming_screen.cursor_keyboard_f1", "cursor-keyboard-f1.png"),
      rect = { x = 0, y = 0, width = 16, height = 16 },
      pulseRect = { x = 0, y = 0, width = 16, height = 16 },
      offset = { x = 0, y = 0 },
      duration = 1,
    },
  }
  return manifest
end

local function animatedSnapshot(overrides)
  overrides = overrides or {}
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "glyph", glyph = "A" }
    end
  end
  return {
    page = "upper",
    cursor = overrides.cursor or { row = 3, column = 5 },
    text = "",
    maxLength = 7,
    grid = grid,
    subject = overrides.subject or { kind = "player", gender = 0 },
    presentation = overrides.presentation or { subjectTick = 0, cursorTick = 0, glowAngle = 180 },
  }
end

local function drawnPaths(calls)
  local paths = {}
  for _, draw in ipairs(calls.draws) do
    local image = draw.image
    if type(image) == "table" and type(image.path) == "string" then
      paths[#paths + 1] = image.path
    end
  end
  return paths
end

local function contains(paths, wanted)
  for _, path in ipairs(paths) do
    if path == wanted then
      return true
    end
  end
  return false
end

function T.tests.player_subject_advances_through_generated_frames_by_presentation_tick()
  local calls = { draws = {}, colors = {} }
  local manifest = animatedFrameManifest()
  local renderer = NamingScreenRenderer.new({
    graphics = recordingGraphics(calls),
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest,
    imageLoader = imageLoader(),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  local function subjectPathsAt(tick)
    calls.draws = {}
    renderer:draw(animatedSnapshot({ presentation = { subjectTick = tick, cursorTick = 0, glowAngle = 180 } }), layout)
    return drawnPaths(calls)
  end
  Assert.isTrue(contains(subjectPathsAt(0), "subject-male-f0.png"), "tick 0 draws the first male frame")
  Assert.isTrue(contains(subjectPathsAt(1), "subject-male-f0.png"), "tick 1 holds the first male frame")
  Assert.isTrue(contains(subjectPathsAt(2), "subject-male-f1.png"), "tick 2 advances to the second male frame")
  Assert.isFalse(contains(subjectPathsAt(2), "subject-male-f0.png"), "tick 2 no longer draws the first male frame")
  Assert.isTrue(contains(subjectPathsAt(3), "subject-male-f0.png"), "tick 3 loops back to the first male frame")
  calls.draws = {}
  renderer:draw(
    animatedSnapshot({
      subject = { kind = "player", gender = 1 },
      presentation = { subjectTick = 2, cursorTick = 0, glowAngle = 180 },
    }),
    layout
  )
  Assert.isTrue(
    contains(drawnPaths(calls), "subject-female-f0.png"),
    "the female subject draws from its own generated sequence"
  )
  renderer:dispose()
end

function T.tests.reverse_subject_animation_traverses_generated_frames_backwards()
  local calls = { draws = {}, colors = {} }
  local manifest = animatedFrameManifest()
  local male = manifest.namingScreen.playerSubjects.male
  local renderer = NamingScreenRenderer.new({
    graphics = recordingGraphics(calls),
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest,
    imageLoader = imageLoader(),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  local function subjectPathsAt(tick)
    calls.draws = {}
    renderer:draw(animatedSnapshot({ presentation = { subjectTick = tick, cursorTick = 0, glowAngle = 180 } }), layout)
    return drawnPaths(calls)
  end
  male.playMode = "reverse"
  Assert.isTrue(contains(subjectPathsAt(0), "subject-male-f1.png"), "reverse tick 0 draws the last frame")
  Assert.isTrue(contains(subjectPathsAt(1), "subject-male-f0.png"), "reverse tick 1 steps back to the first frame")
  Assert.isTrue(contains(subjectPathsAt(2), "subject-male-f0.png"), "reverse tick 2 holds the first frame")
  Assert.isTrue(contains(subjectPathsAt(9), "subject-male-f0.png"), "reverse holds its last frame past the end")
  male.playMode = "reverse_loop"
  male.loopStartFrameIdx = 1
  Assert.isTrue(contains(subjectPathsAt(0), "subject-male-f1.png"), "reverse loop starts from the last frame")
  Assert.isTrue(contains(subjectPathsAt(1), "subject-male-f0.png"), "reverse loop steps back through the segment")
  Assert.isTrue(contains(subjectPathsAt(3), "subject-male-f1.png"), "reverse loop repeats its loop segment")
  renderer:dispose()
end

function T.tests.focus_cursor_tints_only_its_pulse_mask_and_follows_the_glow_angle()
  local calls = { draws = {}, colors = {} }
  local manifest = animatedFrameManifest()
  local renderer = NamingScreenRenderer.new({
    graphics = recordingGraphics(calls),
    text = textFake(),
    drawSubject = function() end,
    manifest = manifest,
    imageLoader = imageLoader(),
  })
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  local function drawCursorAt(tick, angle)
    calls.draws = {}
    calls.colors = {}
    renderer:draw(
      animatedSnapshot({ presentation = { subjectTick = 0, cursorTick = tick, glowAngle = angle } }),
      layout
    )
    return drawnPaths(calls)
  end
  local first = drawCursorAt(0, 180)
  Assert.isTrue(contains(first, "cursor-keyboard-f0.png"), "tick 0 draws the first cursor frame")
  Assert.isTrue(contains(first, "cursor-keyboard-mask.png"), "the cursor draws its pulse mask")
  local second = drawCursorAt(1, 180)
  Assert.isTrue(contains(second, "cursor-keyboard-f1.png"), "tick 1 advances the cursor frame")
  Assert.isTrue(contains(second, "cursor-keyboard-mask.png"), "the advanced cursor still draws its pulse mask")
  local tintedAt180 = drawCursorAt(0, 180)
  local colors180 = calls.colors
  drawCursorAt(0, 270)
  local colors270 = calls.colors
  Assert.isTrue(#colors180 > 0 and #colors270 > 0, "both glow angles tint the mask")
  local same = #colors180 == #colors270
  if same then
    for index, color in ipairs(colors180) do
      local other = colors270[index]
      same = color.r == other.r and color.g == other.g and color.b == other.b
      if not same then
        break
      end
    end
  end
  Assert.isFalse(same, "different glow angles produce different pulse tints")
  Assert.isTrue(
    contains(tintedAt180, "cursor-keyboard-f0.png"),
    "the cursor base frame still draws alongside its tinted mask"
  )
  renderer:dispose()
end

-- A quad failure after every image (including the pulse masks) was acquired
-- must still release all of them exactly once before the constructor
-- rethrows: late atlas failures never leak.
function T.tests.quad_failure_releases_all_acquired_images_including_masks()
  local FakeGraphics = require("tests.support.FakeGraphics")
  local graphics = FakeGraphics.new({ failOnQuadCall = 1 })
  local acquired = {}
  local loader = function(path)
    local image = { path = path, releases = 0 }
    image.release = function()
      image.releases = image.releases + 1
    end
    acquired[#acquired + 1] = image
    return image
  end
  local err = Assert.throws(function()
    NamingScreenRenderer.new({
      graphics = graphics,
      text = textFake(),
      drawSubject = function() end,
      manifest = namingManifest(),
      imageLoader = loader,
    })
  end)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil, "rethrows the quad failure")
  Assert.isTrue(#acquired > 10, "all animation and mask images were acquired before the quad failure")
  for _, image in ipairs(acquired) do
    Assert.equal(image.releases, 1, "acquired image " .. image.path .. " is released exactly once")
  end
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

-- The support backing must composite before the home controls it frames,
-- and the focus cursor must composite after the control it highlights, so
-- the upper controls stay visible above their backing.
function T.tests.support_backing_draws_before_home_controls_and_focus_draws_last()
  local graphics, calls = graphicsFake()
  local manifest = namingManifest()
  local naming = manifest.namingScreen
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

  local order = {}
  for index, draw in ipairs(calls.draws) do
    local path = type(draw.image) == "table" and draw.image.path or nil
    if path ~= nil and order[path] == nil then
      order[path] = index
    end
  end
  local backing = assert(order[naming.controls.backing.image], "the support backing draws")
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    local control = assert(order[naming.controls[id].image], "the " .. id .. " control draws")
    Assert.isTrue(backing < control, "the support backing draws before the " .. id .. " control")
  end
  local cursorAsset = naming.cursor.home.back.frames[1].asset
  local cursor = assert(order[manifest.assets[cursorAsset].image], "the home focus cursor draws")
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    Assert.isTrue(order[naming.controls[id].image] < cursor, "the focus cursor draws after the " .. id .. " control")
  end
end

return T
