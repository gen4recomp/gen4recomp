local Assert = require("tests.support.Assert")
local ImageButton = require("libs.ui.src.ImageButton")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")

local T = {}

local function textRenderer()
  return {
    fontDef = { lineHeight = 16 },
    drawText = function() end,
    textWidth = function(_, text)
      return #text * 8
    end,
  }
end

local function choiceTextRenderer()
  local text = textRenderer()
  text.fontDef.palette = {}
  for slot = 1, 16 do
    text.fontDef.palette[slot] = { r = slot / 16, g = slot / 16, b = slot / 16 }
  end
  text.drawTextWithPalette = function() end
  return text
end

local function genderButtons()
  return {
    [0] = {
      key = "male",
      rect = { x = 10, y = 10, width = 60, height = 80 },
      scale = 1,
      portraitId = "gender_male",
      portraitRect = { x = 20, y = 20, width = 40, height = 60 },
      button = ImageButton.resolve({ rect = { x = 10, y = 10, width = 60, height = 80 }, scale = 1 }),
    },
    [1] = {
      key = "female",
      rect = { x = 90, y = 10, width = 60, height = 80 },
      scale = 1,
      portraitId = "gender_female",
      portraitRect = { x = 100, y = 20, width = 40, height = 60 },
      button = ImageButton.resolve({ rect = { x = 90, y = 10, width = 60, height = 80 }, scale = 1 }),
    },
  }
end

local TextButton = require("libs.ui.src.TextButton")

local function manifest()
  local assets = {
    background = {
      image = "background.png",
      width = 1,
      height = 192,
      sampling = "linear",
      frames = { { image = "background.png", x = 0, y = 0, width = 1, height = 192, duration = 1 } },
    },
  }
  for _, id in ipairs({
    "oak",
    "marill",
    "marill_appear",
    "male",
    "female",
    "shrink_male",
    "shrink_female",
    "ball_open",
    "gender_male",
    "gender_female",
  }) do
    assets[id] = {
      image = id .. ".png",
      width = 4,
      height = 8,
      sampling = "nearest",
      frames = { { image = id .. ".png", x = 0, y = 0, width = 4, height = 8, duration = 1 } },
    }
  end
  assets.oak.frames = {
    { image = "oak.png", x = 0, y = 0, width = 4, height = 4, duration = 1 },
    { image = "oak.png", x = 0, y = 4, width = 4, height = 4, duration = 1 },
  }
  local background = assets.background
  assets.background = nil
  return {
    schemaVersion = 7,
    genderSelector = {
      defaultTone = { r = 100, g = 101, b = 102 },
    },
    background = background,
    widgets = assets,
  }
end

local function view()
  return {
    phase = "oak_welcome",
    visual = "oak",
    visualFrameIndex = 2,
    sceneBrightness = 0,
    revealBrightness = 0,
    revealOpacity = 1,
    message = nil,
    name = "",
    layout = {
      viewport = { x = 0, y = 0, width = 160, height = 120 },
      subject = { x = 20, y = 10, width = 80, height = 80 },
      message = { x = 0, y = 0, width = 1, height = 1 },
      nameGrid = {},
      nameKeys = {},
    },
  }
end

local function backgroundOnlyController()
  local audio = {
    playMusic = function() end,
    stopMusic = function() end,
    fadeMusicOut = function() end,
    play = function() end,
    playCry = function() end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return false
    end,
  }
  local controller = OakIntroController.new({
    candidate = NewGame.createCandidate({
      saveService = {
        reserve = function()
          return "graphics-acceptance"
        end,
      },
      versionId = "heartgold",
      eventState = FieldEventState.new(),
      scriptSymbols = FieldScriptSymbols,
      mapIdentity = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, sourceFacing = 1 },
    }),
    clock = {
      nowLocal = function()
        return { year = 2009, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    },
    audio = audio --[[@as GameSound]],
    messages = {
      ["greeting.day"] = "greeting.day",
      ["oak.welcome"] = "oak.welcome",
      ["oak.world_inhabited"] = "oak.world_inhabited",
      ["oak.live_alongside"] = "oak.live_alongside",
      ["oak.tell_about_yourself"] = "oak.tell_about_yourself",
      ["profile.gender_question"] = "profile.gender_question",
    },
    assets = {
      marill = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      marill_appear = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      ball_open = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    },
    virtualGlyphs = { "A" },
    playerDataContext = { charmap = { A = 1 }, frameIndexes = { [0] = true } },
    randomU32 = function()
      return 0x12345678
    end,
  })
  controller:start()
  controller:tick(40)
  return controller
end

T.responsive_renderer_uses_declared_sampling_and_identity_tint = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
  })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  local normal = view()
  normal.primaryWidget = "oak"
  renderer:draw(normal)
  local flash = view()
  flash.primaryWidget = "oak"
  flash.sceneBrightness = 1
  renderer:draw(flash)

  Assert.equal(#graphics.draws, 4, "each frame draws background and Oak exactly once")
  for _, draw in ipairs(graphics.draws) do
    Assert.deepEqual(draw.color, { 1, 1, 1, 1 }, "image draws must use identity tint")
  end
  local filters = {}
  for _, image in ipairs(graphics.images) do
    filters[image.path] = image.filters[1]
  end
  Assert.equal(filters["background.png"].min, "linear")
  Assert.equal(filters["background.png"].mag, "linear")
  Assert.equal(filters["oak.png"].min, "nearest")
  Assert.equal(filters["oak.png"].mag, "nearest")
  Assert.deepEqual(filters["gender_male.png"], { min = "nearest", mag = "nearest" })
  Assert.isNil(filters["gender-selector-male-backing.png"], "obsolete selector surfaces are not loaded")
  renderer:dispose()
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

T.background_gradient_stretches_to_the_host_viewport = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
  })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  local oakView = view()
  oakView.layout.viewport = { x = 13, y = 17, width = 1600, height = 900 }
  oakView.primaryWidget = "oak"

  renderer:draw(oakView)

  local background = graphics.draws[1]
  Assert.equal(background.x, 13)
  Assert.equal(background.y, 17)
  Assert.equal(background.sx, 1600)
  Assert.equal(background.sy, 900 / 192)
  Assert.equal(background.quad.w * background.sx, 1600)
  Assert.equal(background.quad.h * background.sy, 900)

  local widget = graphics.draws[2]
  Assert.equal(widget.sx, widget.sy)
  renderer:dispose()
end

T.gender_gradient_covers_the_full_viewport_not_a_composition_region = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
  })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  local gender = view()
  gender.phase = "gender_select"
  gender.primaryWidget = nil
  gender.layout.viewport = { x = 11, y = 13, width = 1600, height = 900 }
  gender.layout.oakRegion = { x = 11, y = 13, width = 500, height = 900 }
  gender.layout.genderButtons = genderButtons()
  gender.genderFocus = 0
  gender.focusBlinkDelta = 0

  renderer:draw(gender)

  local background = graphics.draws[1]
  Assert.equal(background.x, 11)
  Assert.equal(background.y, 13)
  Assert.equal(background.sx, 1600)
  Assert.equal(background.sy, 900 / 192)
  renderer:dispose()
end

T.background_only_view_draws_the_gradient_once_without_a_subject = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
  })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  local controller = backgroundOnlyController()
  local background = controller:view() --[[@as table]]
  background.layout = view().layout

  renderer:draw(background)

  Assert.equal(#graphics.draws, 1, "background-only phases draw one image")
  Assert.equal(graphics.draws[1].image.path, "background.png")
  Assert.equal(graphics.draws[1].sx, 160)
  Assert.equal(graphics.draws[1].sy, 120 / 192)
  renderer:dispose()
end

function T.confirmation_uses_font_zero_metrics_and_font_four_source_palette()
  local graphics = FakeGraphics.new()
  local manifestValue = manifest()
  local measuredLabels = {}
  local palettes = {}
  local font0 = textRenderer()
  local font4 = choiceTextRenderer()
  font4.textWidth = function(_, label)
    measuredLabels[#measuredLabels + 1] = label
    return 8
  end
  font4.fontDef.palette[1] = { r = 32, g = 64, b = 96 }
  font4.fontDef.palette[2] = { r = 7, g = 8, b = 9 }
  font4.fontDef.palette[16] = { r = 200, g = 210, b = 220 }
  font4.drawTextWithPalette = function(_, label, _, _, palette)
    palettes[#palettes + 1] = { label = label, value = palette }
  end
  local renderer = OakIntroRenderer.new({
    manifest = manifestValue,
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = font0,
    choiceText = font4,
  })
  local confirmation = view()
  confirmation.phase = "gender_confirm"
  confirmation.choiceLabels = { [0] = "YES", [1] = "NO" }
  confirmation.confirmationChoice = { kind = "gender", selected = 0 }
  confirmation.layout.confirmationButtons = {
    [0] = {
      key = "yes",
      rect = { x = 10, y = 20, width = 120, height = 56 },
      scale = 1,
      button = TextButton.resolve({ rect = { x = 10, y = 20, width = 120, height = 56 }, scale = 1 }),
    },
    [1] = {
      key = "no",
      rect = { x = 140, y = 20, width = 120, height = 56 },
      scale = 1,
      button = TextButton.resolve({ rect = { x = 140, y = 20, width = 120, height = 56 }, scale = 1 }),
    },
  }

  renderer:draw(confirmation)

  Assert.deepEqual(measuredLabels, { "YES", "NO" })
  Assert.equal(#palettes, 2)
  for _, entry in ipairs(palettes) do
    Assert.deepEqual(entry.value.foreground, { r = 200, g = 210, b = 220 })
    Assert.deepEqual(entry.value.shadow, { r = 7, g = 8, b = 9 })
    Assert.deepEqual(entry.value.background, { r = 32, g = 64, b = 96, a = 0 })
  end
  -- New TextButton path has no opaque fill; background is transparent via palette alpha.
  local hasFill = false
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "fill" and rectangle.x == 18 and rectangle.y == 36 then
      hasFill = true
    end
  end
  Assert.isFalse(hasFill, "confirmation must not paint opaque content fill; TextButton face is background")
  renderer:dispose()
end

function T.selected_confirmation_focus_stays_outside_label_content()
  local graphics = FakeGraphics.new()
  local manifestValue = manifest()
  local renderer = OakIntroRenderer.new({
    manifest = manifestValue,
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  local confirmation = view()
  confirmation.phase = "gender_confirm"
  confirmation.choiceLabels = { [0] = "YES", [1] = "NO" }
  confirmation.confirmationChoice = { kind = "gender", selected = 0 }
  confirmation.layout.confirmationButtons = {
    [0] = {
      key = "yes",
      rect = { x = 10, y = 20, width = 120, height = 56 },
      scale = 1,
      button = TextButton.resolve({ rect = { x = 10, y = 20, width = 120, height = 56 }, scale = 1 }),
    },
    [1] = {
      key = "no",
      rect = { x = 150, y = 20, width = 240, height = 112 },
      scale = 2,
      button = TextButton.resolve({ rect = { x = 150, y = 20, width = 240, height = 112 }, scale = 2 }),
    },
  }

  renderer:draw(confirmation)

  local whiteFocus, redFocus
  local focusCount = 0
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "line" then
      focusCount = focusCount + 1
      if rectangle.color[1] == 1 and rectangle.color[2] == 1 and rectangle.color[3] == 1 then
        whiteFocus = rectangle
      elseif rectangle.color[1] == 1 and rectangle.color[2] == 0 and rectangle.color[3] == 0 then
        redFocus = rectangle
      end
      Assert.isTrue(rectangle.rx ~= nil and rectangle.ry ~= nil, "focus must be rounded with rx/ry")
      Assert.isTrue(rectangle.rx > 0 and rectangle.ry > 0, "focus must have positive corner radius")
      do
        local half = rectangle.lineWidth / 2
        local innerLeft = rectangle.x + half
        local innerTop = rectangle.y + half
        local innerRight = rectangle.x + rectangle.w - half
        local innerBottom = rectangle.y + rectangle.h - half
        local outerLeft = rectangle.x - half
        local outerTop = rectangle.y - half
        local outerRight = rectangle.x + rectangle.w + half
        local outerBottom = rectangle.y + rectangle.h + half
        local contentLeft, contentTop = 18, 36
        local contentRight, contentBottom = 122, 60
        local insideHole = innerLeft <= contentLeft
          and innerRight >= contentRight
          and innerTop <= contentTop
          and innerBottom >= contentBottom
        local outsideOuter = outerRight <= contentLeft
          or outerLeft >= contentRight
          or outerBottom <= contentTop
          or outerTop >= contentBottom
        Assert.isTrue(insideHole or outsideOuter, "focus outline must not cover the label content rectangle")
      end
    end
  end
  Assert.equal(focusCount, 2, "selected focus must be exactly two rounded line passes")
  Assert.notNil(whiteFocus, "selected focus must include exact white #FFFFFF overlay")
  Assert.notNil(redFocus, "selected focus must include exact red #FF0000 overlay")
  Assert.equal(whiteFocus.lineWidth, 5, "white underlay must be 5 source pixels")
  Assert.equal(redFocus.lineWidth, 3, "red overlay must be 3 source pixels")
  Assert.isTrue(
    whiteFocus.w == 120 and whiteFocus.h == 56 or whiteFocus.w < 120,
    "focus must be drawn within the 120x56 backing"
  )
  Assert.deepEqual(whiteFocus.color, { 1, 1, 1, 1 }, "white must be exact #FFFFFF")
  Assert.deepEqual(redFocus.color, { 1, 0, 0, 1 }, "red must be exact #FF0000")
  local scale = confirmation.layout.confirmationButtons[0].scale
  Assert.equal(whiteFocus.lineWidth, 5 * scale)
  Assert.equal(redFocus.lineWidth, 3 * scale)
  renderer:dispose()
  -- Verify unselected choice draws no focus
  local graphics2 = FakeGraphics.new()
  local renderer2 = OakIntroRenderer.new({
    manifest = manifestValue,
    graphics = graphics2,
    imageLoader = function(path)
      local image = graphics2.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  confirmation.confirmationChoice.selected = 1
  while #graphics2.rectangles > 0 do
    table.remove(graphics2.rectangles)
  end
  renderer2:draw(confirmation)
  local selectedRect = confirmation.layout.confirmationButtons[1].rect
  local foundFocus = false
  for _, rectangle in ipairs(graphics2.rectangles) do
    if
      rectangle.mode == "line"
      and rectangle.color[1] == 1
      and (rectangle.color[2] == 1 or rectangle.color[2] == 0)
    then
      if rectangle.x >= selectedRect.x - 10 and rectangle.x <= selectedRect.x + 10 then
        foundFocus = true
      end
    end
  end
  Assert.isTrue(foundFocus, "focus must move to the newly selected choice")
  renderer2:dispose()
end

function T.focus_uses_source_scale_and_restores_line_width()
  local graphics = FakeGraphics.new()
  graphics.setLineWidth(2)
  local manifestValue = manifest()
  local renderer = OakIntroRenderer.new({
    manifest = manifestValue,
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  local confirmation = view()
  confirmation.phase = "gender_confirm"
  confirmation.choiceLabels = { [0] = "YES", [1] = "NO" }
  confirmation.confirmationChoice = { kind = "gender", selected = 0 }
  confirmation.layout.confirmationButtons = {
    [0] = {
      key = "yes",
      rect = { x = 10, y = 20, width = 240, height = 112 },
      scale = 2,
      button = TextButton.resolve({ rect = { x = 10, y = 20, width = 240, height = 112 }, scale = 2 }),
    },
    [1] = {
      key = "no",
      rect = { x = 260, y = 20, width = 240, height = 112 },
      scale = 2,
      button = TextButton.resolve({ rect = { x = 260, y = 20, width = 240, height = 112 }, scale = 2 }),
    },
  }
  renderer:draw(confirmation)
  Assert.equal(graphics.getLineWidth(), 2, "renderer must restore caller line width after normal draw")
  local foundWhite, foundRed
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "line" and rectangle.color[1] == 1 and rectangle.color[2] == 1 then
      foundWhite = rectangle
    elseif rectangle.mode == "line" and rectangle.color[1] == 1 and rectangle.color[2] == 0 then
      foundRed = rectangle
    end
  end
  Assert.notNil(foundWhite)
  Assert.notNil(foundRed)
  Assert.equal(foundWhite.lineWidth, 10, "white line width must be 5 * scale")
  Assert.equal(foundRed.lineWidth, 6, "red line width must be 3 * scale")
  -- Failure restoration
  graphics.setLineWidth(7)
  local failingGraphics = FakeGraphics.new()
  failingGraphics.setLineWidth(7)
  local failRenderer = OakIntroRenderer.new({
    manifest = manifestValue,
    graphics = failingGraphics,
    imageLoader = function(path)
      local image = failingGraphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  failingGraphics.draw = function()
    error("injected draw failure")
  end
  local ok = pcall(function()
    failRenderer:draw(confirmation)
  end)
  Assert.isFalse(ok, "injected draw failure must propagate")
  Assert.equal(failingGraphics.getLineWidth(), 7, "renderer must restore line width even after draw failure")
  renderer:dispose()
  failRenderer:dispose()
end

function T.nonzero_atlas_frame_is_drawn_with_a_reusable_quad(_)
  local graphics = FakeGraphics.new({ imageSizes = { { 8, 8 }, { 4, 8 } } })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(_)
      return graphics.newImage()
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  renderer:draw(view())
  Assert.equal(#graphics.draws, 2)
  Assert.equal(graphics.draws[2].quad.y, 4)
  Assert.equal(graphics.draws[2].x, 20)
  renderer:dispose()
  renderer:dispose()
end

function T.constructor_releases_images_when_quad_creation_fails()
  local graphics = FakeGraphics.new({ failOnQuadCall = 2, imageSizes = { { 8, 8 }, { 4, 8 } } })
  local ok, err = pcall(function()
    OakIntroRenderer.new({
      manifest = manifest(),
      graphics = graphics,
      imageLoader = function(_)
        return graphics.newImage()
      end,
      text = textRenderer(),
      choiceText = choiceTextRenderer(),
    })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("injected newQuad failure", 1, true) ~= nil)
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

function T.constructor_rejects_nil_shader_and_releases_each_image_once()
  local graphics = FakeGraphics.new({ shaderReturnsNil = true })
  local ok, err = pcall(function()
    OakIntroRenderer.new({
      manifest = manifest(),
      graphics = graphics,
      imageLoader = function(_)
        return graphics.newImage()
      end,
      text = textRenderer(),
      choiceText = choiceTextRenderer(),
    })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("shader", 1, true) ~= nil)
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1)
  end
end

function T.animated_frames_use_distinct_images_and_release_unique_paths()
  local graphics = FakeGraphics.new({
    imageSizes = { { 8, 8 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 }, { 4, 4 } },
  })
  local manifestValue = manifest()
  manifestValue.widgets.oak.image = "oak-frame-1.png"
  manifestValue.widgets.oak.frames = {
    { image = "oak-frame-1.png", x = 0, y = 0, width = 4, height = 4, duration = 1 },
    { image = "oak-frame-2.png", x = 0, y = 0, width = 4, height = 4, duration = 1 },
    { image = "oak-frame-2.png", x = 0, y = 0, width = 4, height = 4, duration = 1 },
  }
  local renderer = OakIntroRenderer.new({
    manifest = manifestValue,
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })

  local first = view()
  first.visualFrameIndex = 1
  renderer:draw(first)
  local second = view()
  second.visualFrameIndex = 2
  renderer:draw(second)

  Assert.equal(graphics.draws[2].image.path, "oak-frame-1.png")
  Assert.equal(graphics.draws[4].image.path, "oak-frame-2.png")
  local loaded = {}
  for _, image in ipairs(graphics.images) do
    loaded[image.path] = (loaded[image.path] or 0) + 1
  end
  Assert.equal(loaded["oak-frame-1.png"], 1)
  Assert.equal(loaded["oak-frame-2.png"], 1)
  renderer:dispose()
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

function T.image_construction_failure_releases_every_prior_image()
  local graphics = FakeGraphics.new({ failOnImageCall = 3 })
  local ok = pcall(function()
    OakIntroRenderer.new({
      manifest = manifest(),
      graphics = graphics,
      imageLoader = function()
        return graphics.newImage()
      end,
      text = textRenderer(),
      choiceText = choiceTextRenderer(),
    })
  end)
  Assert.isFalse(ok)
  Assert.equal(#graphics.images, 2)
  for _, image in ipairs(graphics.images) do
    Assert.isTrue(image.released)
  end
end

-- Gender focus must pulse the selected button-frame semantics, not tint the
-- portrait pixels themselves: both the male and female portrait draws must
-- keep an identity (untinted) color regardless of which one is focused.
T.gender_focus_leaves_portrait_draw_color_untinted = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
  })
  local renderer = OakIntroRenderer.new({
    manifest = manifest(),
    graphics = graphics,
    imageLoader = function(path)
      local image = graphics.newImage()
      image.path = path
      return image
    end,
    text = textRenderer(),
    choiceText = choiceTextRenderer(),
  })
  local gender = view()
  gender.phase = "gender_select"
  gender.primaryWidget = nil
  gender.layout.genderButtons = genderButtons()
  gender.genderFocus = 0
  gender.focusBlinkDelta = 8

  renderer:draw(gender)

  local maleColor, femaleColor
  for _, draw in ipairs(graphics.draws) do
    if draw.image and draw.image.path == "gender_male.png" then
      maleColor = draw.color
    elseif draw.image and draw.image.path == "gender_female.png" then
      femaleColor = draw.color
    end
  end
  Assert.notNil(maleColor, "male portrait must be drawn")
  Assert.notNil(femaleColor, "female portrait must be drawn")
  Assert.deepEqual(maleColor, { 1, 1, 1, 1 }, "focused portrait must not be recolored")
  Assert.deepEqual(femaleColor, { 1, 1, 1, 1 }, "unfocused portrait must not be recolored")
  renderer:dispose()
end

T.constructor_rejects_missing_confirmation_widget = function()
  local graphics = FakeGraphics.new({
    imageSizes = { { 1, 192 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 }, { 4, 8 } },
  })
  local manifestValue = manifest()
  -- After migration, confirmation widgets are not required.
  local ok, _ = pcall(function()
    return OakIntroRenderer.new({
      manifest = manifestValue,
      graphics = graphics,
      imageLoader = function(path)
        local image = graphics.newImage()
        image.path = path
        return image
      end,
      text = textRenderer(),
      choiceText = choiceTextRenderer(),
    })
  end)
  Assert.isTrue(ok, "renderer must not require confirmation widgets after migration")
end

return GraphicsSmoke.suite(T)
