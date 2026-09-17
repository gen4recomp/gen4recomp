-- Graphics smoke for the generated-font Main Menu and save viewport clipping.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")

local T = {}

local CARD_TONE = { r = 123, g = 45, b = 67 }

local INTRO_WIDGETS = {
  "ball_open",
  "female",
  "gender_female",
  "gender_male",
  "male",
  "marill",
  "marill_appear",
  "naming_female",
  "naming_male",
  "oak",
  "shrink_female",
  "shrink_male",
}

local function introManifest()
  local widgets = {}
  for _, id in ipairs(INTRO_WIDGETS) do
    local path = "assets/generated/intro/" .. id .. ".png"
    widgets[id] = {
      image = path,
      width = 32,
      height = 32,
      anchor = { x = 16, y = 32 },
      sourceBounds = { x = 0, y = 0, width = 32, height = 32 },
      sampling = "nearest",
      provenance = { rule = "alpha-crop" },
      frames = {
        {
          image = path,
          width = 32,
          height = 32,
          duration = 4,
          element = "none",
          translateX = 0,
          translateY = 0,
          scaleX = 1,
          scaleY = 1,
          rotation = 0,
          anchor = { x = 16, y = 32 },
        },
      },
    }
  end
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    widgets[id].sourceCenter = { x = 160, y = 80 }
  end
  for _, id in ipairs({
    "ball_open",
    "marill_appear",
    "marill",
    "gender_male",
    "gender_female",
    "naming_male",
    "naming_female",
  }) do
    widgets[id].playMode = "forward"
    widgets[id].loopStartFrameIdx = 0
  end
  widgets.gender_male.sourceCenter = { x = 64, y = 104 }
  widgets.gender_female.sourceCenter = { x = 192, y = 104 }
  local manifest = {
    schemaVersion = IntroAssetCache.SCHEMA_VERSION,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = {
      image = "assets/generated/intro/background.png",
      width = 1,
      height = 192,
      sampling = "linear",
      provenance = { charMember = 0, screenMember = 3, paletteMember = 1 },
    },
    genderSelector = {
      defaultTone = { r = CARD_TONE.r, g = CARD_TONE.g, b = CARD_TONE.b },
      buttons = {
        male = { bounds = { x = 18, y = 25, width = 93, height = 148 } },
        female = { bounds = { x = 144, y = 25, width = 95, height = 148 } },
      },
    },
    widgets = widgets,
  }
  Assert.isTrue(IntroAssetCache.validateManifest(manifest), "the card face fixture must be a valid intro manifest")
  return manifest
end

local function renderer(scope, versionId)
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:writeLua(IntroAssetCache.manifestPath(), introManifest())
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cache }))
  return MainMenuRenderer.new({ text = text, cacheFs = cache, versionId = versionId or "heartgold" }), text
end

local function view(content, errorText)
  local card = {
    frame = { x = 16, y = 80, width = 128, height = 64 },
    body = { x = 16, y = 80, width = 72, height = 64 },
    overflow = { x = 96, y = 88, width = 40, height = 32 },
  }
  return {
    focusedId = "new-game",
    focus = { region = "global", actionId = "new-game" },
    globalActions = { { id = "new-game", kind = "new_game" } },
    saves = {},
    catalogError = errorText,
    layout = {
      viewport = { x = 0, y = 0, width = 160, height = 120 },
      global = {
        region = { x = 16, y = 32, width = 128, height = 40 },
        actions = { ["new-game"] = { x = 16, y = 32, width = 128, height = 40 } },
      },
      saves = {
        viewport = content,
        cards = { ["save-1"] = card },
        offset = 0,
      },
      catalogErrorRect = errorText and content or nil,
    },
  }
end

function T.cards_are_clipped_to_the_save_viewport_and_scissor_is_restored(scope)
  local content = { x = 16, y = 80, width = 128, height = 16 }
  local current = view(content)
  current.saves =
    { { id = "save-1", saveId = "save-1", playerName = "PLAYER", canContinue = true, playTimeLabel = "1:00" } }
  current.focus = { region = "saves", saveId = "save-1", lane = "body" }
  current.focusedId = "save-1"
  current.layout.global.actions["new-game"] = { x = 16, y = 32, width = 128, height = 40 }

  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  lg.setScissor(0, 0, 160, 120)
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current)

  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 0)
  Assert.equal(sy, 0)
  Assert.equal(sw, 160)
  Assert.equal(sh, 120)
  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local r, g, b = pixels:getPixel(20, 100)
  Assert.near(r, 0x33 / 255, 1 / 255)
  Assert.near(g, 0x27 / 255, 1 / 255)
  Assert.near(b, 0x11 / 255, 1 / 255)
end

function T.catalog_errors_are_drawn_inside_the_returned_error_rectangle(scope)
  local errorRect = { x = 16, y = 80, width = 128, height = 24 }
  local current = view(errorRect, "catalog unreadable")
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0.08, 0.1, 0.15, 1)
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current)
  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local foundErrorPixel = false
  for y = errorRect.y, errorRect.y + errorRect.height - 1 do
    for x = errorRect.x, errorRect.x + errorRect.width - 1 do
      local r, g, b, a = pixels:getPixel(x, y)
      if a > 0 and r > g and r > b then
        foundErrorPixel = true
      end
    end
  end
  Assert.isTrue(foundErrorPixel, "catalog error text must draw inside its returned rectangle")
end

function T.unavailable_catalog_rows_without_delete_actions_are_renderable(scope)
  local content = { x = 16, y = 80, width = 128, height = 40 }
  local current = view(content)
  current.saves = {
    { id = "unavailable-save-1", canContinue = false, errorSummary = "Save data unavailable" },
  }
  current.focus = { region = "saves", saveId = "unavailable-save-1", lane = "body" }
  current.focusedId = "unavailable-save-1"
  current.layout.saves.cards = {
    ["unavailable-save-1"] = {
      frame = { x = 16, y = 80, width = 128, height = 40 },
      body = { x = 16, y = 80, width = 128, height = 40 },
    },
  }
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current)
end

function T.focus_lanes_have_distinct_visual_regions(scope)
  local content = { x = 16, y = 80, width = 128, height = 40 }
  local current = view(content)
  current.saves =
    { { id = "save-1", saveId = "save-1", playerName = "PLAYER", canContinue = true, playTimeLabel = "1:00" } }
  current.layout.saves.cards["save-1"] = {
    frame = { x = 16, y = 80, width = 128, height = 64 },
    body = { x = 16, y = 80, width = 72, height = 64 },
    overflow = { x = 96, y = 88, width = 40, height = 32 },
  }
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  current.focus = { region = "saves", saveId = "save-1", lane = "body" }
  current.focusedId = "save-1"
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current)
  lg.setCanvas()
  local bodyFocused = scope:own(canvas:newImageData()):getPixel(18, 82)
  current.focus = { region = "saves", saveId = "save-1", lane = "overflow" }
  lg.setCanvas(canvas)
  menuRenderer:draw(current)
  lg.setCanvas()
  local overflowFocused = scope:own(canvas:newImageData()):getPixel(100, 92)
  Assert.isTrue(bodyFocused ~= overflowFocused, "body and overflow focus must render differently")
end

function T.save_selection_uses_large_integer_cards_with_fixed_new_game_and_cues(scope)
  local globals = { { id = "new-game", kind = "new_game" } }
  local one = {
    {
      id = "save-1",
      saveId = "save-1",
      playerName = "PLAYER",
      playTimeLabel = "1:00",
      canContinue = true,
      canDelete = true,
    },
  }
  local bodyFocus = { region = "saves", saveId = "save-1", lane = "body" }
  local layout = MainMenuLayout.compute(globals, one, bodyFocus, 640, 480, 0, nil, nil, false)
  Assert.equal(layout.uiScale, 2)
  Assert.equal(MainMenuLayout.compute(globals, one, bodyFocus, 320, 240, 0, nil, nil, false).uiScale, 1)
  Assert.equal(MainMenuLayout.compute(globals, one, bodyFocus, 1280, 720, 0, nil, nil, false).uiScale, 3)
  Assert.equal(MainMenuLayout.compute(globals, one, bodyFocus, 2560, 1440, 0, nil, nil, false).uiScale, 3)
  local card = assert(layout.saves.cards["save-1"])
  Assert.equal(card.frame.height, 72 * layout.uiScale)
  local newGame = layout.global.actions["new-game"]
  Assert.equal(newGame.height, 36 * layout.uiScale)
  Assert.isTrue(newGame.y >= layout.saves.viewport.y + layout.saves.viewport.height)

  local many = {}
  for index = 1, 8 do
    many[#many + 1] = {
      id = "save-" .. index,
      saveId = "save-" .. index,
      playerName = "PLAYER",
      playTimeLabel = "1:00",
      canContinue = true,
      canDelete = true,
    }
  end
  local bottom = MainMenuLayout.compute(
    globals,
    many,
    { region = "saves", saveId = "save-8", lane = "body" },
    640,
    480,
    0,
    nil,
    nil,
    false
  )
  Assert.notNil(bottom.saves.scrollIndicators)
  Assert.notNil(bottom.saves.scrollIndicators.up)
  Assert.isNil(bottom.saves.scrollIndicators.down)
  local top = MainMenuLayout.compute(
    globals,
    many,
    { region = "saves", saveId = "save-1", lane = "body" },
    640,
    480,
    0,
    nil,
    nil,
    false
  )
  Assert.notNil(top.saves.scrollIndicators.down)
  Assert.isNil(top.saves.scrollIndicators.up)

  local function composed(targetLayout, targetFocus, targetSaves)
    return {
      focusedId = targetFocus.saveId or targetFocus.actionId,
      focus = targetFocus,
      globalActions = globals,
      saves = targetSaves,
      catalogError = nil,
      layout = targetLayout,
    }
  end

  local function isBackground(r, g, b)
    return math.abs(r - 0x33 / 255) < 0.05 and math.abs(g - 0x27 / 255) < 0.05 and math.abs(b - 0x11 / 255) < 0.05
  end

  local function isSelectedRed(r, g, b)
    return r > 0.9 and (r - g) > 0.5 and (r - b) > 0.5
  end

  local lg = love.graphics
  local emptyLayout = MainMenuLayout.compute(
    globals,
    {},
    { region = "global", actionId = "new-game" },
    640,
    480,
    0,
    nil,
    nil,
    false
  )
  local emptyCanvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(emptyCanvas)
  lg.clear(0, 0, 0, 0)
  local menuRenderer, _ = renderer(scope)
  menuRenderer:draw(composed(emptyLayout, { region = "global", actionId = "new-game" }, {}))
  lg.setCanvas()
  local emptyPixels = scope:own(emptyCanvas:newImageData())
  local viewport = emptyLayout.saves.viewport
  for y = viewport.y, math.min(viewport.y + 24, viewport.y + viewport.height - 1) do
    for x = viewport.x, math.min(viewport.x + 120, viewport.x + viewport.width - 1) do
      local r, g, b = emptyPixels:getPixel(x, y)
      Assert.isTrue(isBackground(r, g, b), "empty save viewport must not carry header copy at " .. x .. "," .. y)
    end
  end

  local canvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  menuRenderer:draw(composed(layout, bodyFocus, one))
  lg.setCanvas()
  local bodyPixels = scope:own(canvas:newImageData())
  local bodyRimX = card.frame.x + math.floor(card.frame.width / 2)
  local bodyRimY = card.frame.y + 5
  local overflow = assert(card.overflow)
  local overflowX = overflow.x + math.floor(overflow.width / 2)
  local overflowY = overflow.y + 5
  local r, g, b = bodyPixels:getPixel(bodyRimX, bodyRimY)
  Assert.isTrue(isSelectedRed(r, g, b), "focused save body must carry the selected red rim")
  local or_, og, ob = bodyPixels:getPixel(overflowX, overflowY)
  Assert.isFalse(isSelectedRed(or_, og, ob), "unfocused overflow must stay neutral while the body is focused")

  local overflowFocus = { region = "saves", saveId = "save-1", lane = "overflow" }
  local overflowLayout = MainMenuLayout.compute(globals, one, overflowFocus, 640, 480, 0, nil, nil, false)
  local overflowCard = assert(overflowLayout.saves.cards["save-1"])
  local overflowControl = assert(overflowCard.overflow)
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  menuRenderer:draw(composed(overflowLayout, overflowFocus, one))
  lg.setCanvas()
  local overflowPixels = scope:own(canvas:newImageData())
  local br, bg, bb =
    overflowPixels:getPixel(overflowCard.frame.x + math.floor(overflowCard.frame.width / 2), overflowCard.frame.y + 5)
  Assert.isFalse(isSelectedRed(br, bg, bb), "save body must return to neutral while overflow is focused")
  local cr, cg, cb =
    overflowPixels:getPixel(overflowControl.x + math.floor(overflowControl.width / 2), overflowControl.y + 5)
  Assert.isTrue(isSelectedRed(cr, cg, cb), "focused overflow must carry its own selected red rim")
end

function T.menu_player_copy_renders_at_twice_the_generated_font_size(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local textDraws = 0
  local textProxy = {
    drawText = function(_, value, x, y)
      textDraws = textDraws + 1
      return text:drawText(value, x, y)
    end,
    drawTextWithPalette = function(_, value, x, y, palette)
      textDraws = textDraws + 1
      return text:drawTextWithPalette(value, x, y, palette)
    end,
  }
  local graphics = FakeGraphics.new()
  local globals = { { id = "new-game", kind = "new_game" } }
  local items = {
    {
      id = "save-1",
      saveId = "save-1",
      playerName = "PLAYER",
      playTimeLabel = "1:00",
      canContinue = true,
      canDelete = true,
    },
  }
  local focus = { region = "saves", saveId = "save-1", lane = "body" }
  local layout = MainMenuLayout.compute(globals, items, focus, 640, 480, 0, nil, nil, false)
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:writeLua(IntroAssetCache.manifestPath(), introManifest())
  local menuRenderer =
    MainMenuRenderer.new({ text = textProxy, graphics = graphics, cacheFs = cache, versionId = "heartgold" })
  menuRenderer:draw({
    focusedId = "save-1",
    focus = focus,
    globalActions = globals,
    saves = items,
    catalogError = nil,
    layout = layout,
  })
  local foundDouble = false
  for _, transform in ipairs(graphics.transforms) do
    if transform[1] == "scale" then
      Assert.isTrue(
        transform[2] == math.floor(transform[2]) and transform[3] == math.floor(transform[3]),
        "menu text scaling must never be fractional"
      )
      if transform[2] == 2 and transform[3] == 2 then
        foundDouble = true
      end
    end
  end
  Assert.isTrue(textDraws > 0, "the menu must draw principal copy through the generated font atlas")
  Assert.isTrue(foundDouble, "principal menu copy at the desktop baseline must render at twice the generated font size")
  Assert.equal(graphics.pushDepth(), 0, "text scaling must restore graphics transforms after each draw")
end

function T.card_faces_use_the_white_launcher_face(scope)
  local current = view({ x = 16, y = 80, width = 128, height = 16 })
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current)
  lg.setCanvas()
  -- Inside the focused New Game card face, right of and below the label copy.
  local pixels = scope:own(canvas:newImageData())
  local r, g, b = pixels:getPixel(132, 64)
  Assert.near(r, 1, 2 / 255, "the card face must use the white launcher face red")
  Assert.near(g, 1, 2 / 255, "the card face must use the white launcher face green")
  Assert.near(b, 1, 2 / 255, "the card face must use the white launcher face blue")
end
function T.menu_text_uses_palette_path_at_identity_tint()
  local graphics = FakeGraphics.new()
  local plainCalls = {}
  local paletteCalls = {}
  local textDouble = {
    drawText = function(_, value, x, y)
      local r, g, b, a = graphics.getColor()
      plainCalls[#plainCalls + 1] = { text = value, x = x, y = y, color = { r, g, b, a } }
    end,
    drawTextWithPalette = function(_, value, x, y, palette)
      local r, g, b, a = graphics.getColor()
      paletteCalls[#paletteCalls + 1] = { text = value, x = x, y = y, palette = palette, color = { r, g, b, a } }
    end,
  }
  local cache = {
    loadLua = function()
      return introManifest()
    end,
  }
  local menuRenderer =
    MainMenuRenderer.new({ text = textDouble, graphics = graphics, cacheFs = cache, versionId = "heartgold" })
  local globals = { { id = "new-game", kind = "new_game" } }
  local items = {
    {
      id = "save-1",
      saveId = "save-1",
      playerName = "PLAYER",
      playTimeLabel = "1:00",
      canContinue = true,
      canDelete = true,
    },
    {
      id = "save-2",
      saveId = "save-2",
      errorSummary = "Save data unavailable",
      canContinue = false,
      canDelete = false,
    },
  }
  local focus = { region = "saves", saveId = "save-1", lane = "body" }
  local layout = MainMenuLayout.compute(globals, items, focus, 320, 240, 0, nil, nil, false)
  menuRenderer:draw({
    focusedId = "save-1",
    focus = focus,
    globalActions = globals,
    saves = items,
    catalogError = nil,
    layout = layout,
  })
  Assert.isTrue(#paletteCalls > 0, "menu copy must draw through the palette path")
  Assert.equal(#plainCalls, 0, "menu copy must not use tinted plain text draws")
  for _, call in ipairs(paletteCalls) do
    Assert.deepEqual(call.color, { 1, 1, 1, 1 }, "palette text must draw at identity tint")
    Assert.notNil(call.palette.foreground, "palette text needs a foreground role color")
    Assert.notNil(call.palette.shadow, "palette text needs a shadow role color")
    Assert.notNil(call.palette.background, "palette text needs a background entry")
  end
  local r, g, b, a = graphics.getColor()
  Assert.deepEqual({ r, g, b, a }, { 1, 1, 1, 1 }, "menu drawing must leave graphics color at identity")
end

function T.card_chrome_keeps_rounded_nested_corners()
  local ImageButton = require("libs.ui.src.ImageButton")
  local button = ImageButton.resolve({ rect = { x = 16, y = 80, width = 128, height = 64 }, scale = 1 })
  Assert.equal(button.border.cornerRadius, 8)
  Assert.equal(button.rim.cornerRadius, 6)
  Assert.equal(button.innerBorder.cornerRadius, 4)
  Assert.equal(button.face.cornerRadius, 3)
  local explicit = ImageButton.resolve({
    rect = { x = 16, y = 80, width = 128, height = 64 },
    scale = 1,
    cornerRadius = 6,
    innerBorderWidth = 2,
  })
  Assert.equal(explicit.border.cornerRadius, 6)
  Assert.equal(explicit.rim.cornerRadius, 4)
  Assert.equal(explicit.innerBorder.cornerRadius, 2)
  Assert.equal(explicit.face.cornerRadius, 0)
end
return GraphicsSmoke.suite(T)
