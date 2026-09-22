-- Graphics smoke for the generated-font Main Menu and save viewport clipping.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local T = {}

-- Interface-shaped plan around a computed or hand-built logical layout:
-- the placement is the single root transform the renderer consumes,
-- built through the real cover policy so tests never emulate fitting.
---@param layout table<string, unknown>
---@param width number host canvas width
---@param height number host canvas height
---@param pixelScale integer physical pixels per logical pixel
---@return ApplicationPlan
local function planFor(layout, width, height, pixelScale)
  local covered = PixelScale.cover({ x = 0, y = 0, width = width, height = height }, pixelScale, 1)
  return {
    panes = { { id = "content", placement = covered.placement, interactive = true } },
    frames = {},
    content = { layout = layout, hostBackgrounds = { { x = 0, y = 0, width = width, height = height } } },
    inputKey = "main-menu-graphics",
    render = function() end,
    mapInput = function() end,
  }
end

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
  menuRenderer:draw(current, planFor(current.layout, 160, 120, 1))

  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 0)
  Assert.equal(sy, 0)
  Assert.equal(sw, 160)
  Assert.equal(sh, 120)
  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  local r, g, b = pixels:getPixel(20, 100)
  Assert.near(r, 0xFF / 255, 1 / 255)
  Assert.near(g, 0xD6 / 255, 1 / 255)
  Assert.near(b, 0x94 / 255, 1 / 255)
end

function T.catalog_errors_are_drawn_inside_the_returned_error_rectangle(scope)
  local errorRect = { x = 16, y = 80, width = 128, height = 24 }
  local current = view(errorRect, "catalog unreadable")
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0.08, 0.1, 0.15, 1)
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current, planFor(current.layout, 160, 120, 1))
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
  menuRenderer:draw(current, planFor(current.layout, 160, 120, 1))
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
  menuRenderer:draw(current, planFor(current.layout, 160, 120, 1))
  lg.setCanvas()
  local bodyFocused = scope:own(canvas:newImageData()):getPixel(18, 82)
  current.focus = { region = "saves", saveId = "save-1", lane = "overflow" }
  lg.setCanvas(canvas)
  menuRenderer:draw(current, planFor(current.layout, 160, 120, 1))
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
  -- The logical viewport behind the desktop presentation: identical
  -- cards at unit scale, magnified by the 2x root placement below.
  local layout = MainMenuLayout.compute(globals, one, bodyFocus, 320, 240, 0, nil, nil, false)
  local density = planFor(layout, 640, 480, 2).panes[1].placement
  Assert.equal(density.pixelScale, 2)
  local card = assert(layout.saves.cards["save-1"])
  -- Card budget: 10px top inset plus the 16px heading plus three 16px
  -- profile rows plus the 10px bottom inset the renderer reserves.
  Assert.equal(card.frame.height, 84)
  local newGame = layout.global.actions["new-game"]
  Assert.equal(newGame.height, 36)
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
    return math.abs(r - 0xFF / 255) < 0.05 and math.abs(g - 0xD6 / 255) < 0.05 and math.abs(b - 0x94 / 255) < 0.05
  end

  local function isSelectedRed(r, g, b)
    return r > 0.9 and (r - g) > 0.5 and (r - b) > 0.5
  end

  local lg = love.graphics
  local emptyLayout = MainMenuLayout.compute(
    globals,
    {},
    { region = "global", actionId = "new-game" },
    320,
    240,
    0,
    nil,
    nil,
    false
  )
  local emptyCanvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(emptyCanvas)
  lg.clear(0, 0, 0, 0)
  local menuRenderer, _ = renderer(scope)
  local emptyPlan = planFor(emptyLayout, 640, 480, 2)
  menuRenderer:draw(composed(emptyLayout, { region = "global", actionId = "new-game" }, {}), emptyPlan)
  lg.setCanvas()
  local emptyPixels = scope:own(emptyCanvas:newImageData())
  local viewport = emptyLayout.saves.viewport
  for logicalY = viewport.y, math.min(viewport.y + 24, viewport.y + viewport.height - 1) do
    for logicalX = viewport.x, math.min(viewport.x + 120, viewport.x + viewport.width - 1) do
      local x, y = LayoutGeometry.logicalToHost(assert(emptyPlan.panes[1].placement), logicalX, logicalY)
      local r, g, b = emptyPixels:getPixel(x, y)
      Assert.isTrue(isBackground(r, g, b), "empty save viewport must not carry header copy at " .. x .. "," .. y)
    end
  end

  local plan = planFor(layout, 640, 480, 2)
  local canvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  menuRenderer:draw(composed(layout, bodyFocus, one), plan)
  lg.setCanvas()
  local bodyPixels = scope:own(canvas:newImageData())
  local placement = assert(plan.panes[1].placement)
  -- Probe depths stay host pixels: map each card origin once, then step
  -- the original host offsets into rim and chrome bands.
  local cardX, cardY = LayoutGeometry.logicalToHost(placement, card.frame.x, card.frame.y)
  local cardFarX, _ = LayoutGeometry.logicalToHost(placement, card.frame.x + card.frame.width, card.frame.y)
  local bodyRimX = cardX + math.floor((cardFarX - cardX) / 2)
  local bodyRimY = cardY + 5
  local overflow = assert(card.overflow)
  local overflowX, overflowY = LayoutGeometry.logicalToHost(placement, overflow.x, overflow.y)
  local overflowFarX, _ = LayoutGeometry.logicalToHost(placement, overflow.x + overflow.width, overflow.y)
  overflowX = overflowX + math.floor((overflowFarX - overflowX) / 2)
  overflowY = overflowY + 5
  local r, g, b = bodyPixels:getPixel(bodyRimX, bodyRimY)
  Assert.isTrue(isSelectedRed(r, g, b), "focused save body must carry the selected red rim")
  local or_, og, ob = bodyPixels:getPixel(overflowX, overflowY)
  Assert.isFalse(isSelectedRed(or_, og, ob), "unfocused overflow must stay neutral while the body is focused")

  local overflowFocus = { region = "saves", saveId = "save-1", lane = "overflow" }
  local overflowLayout = MainMenuLayout.compute(globals, one, overflowFocus, 320, 240, 0, nil, nil, false)
  local overflowCard = assert(overflowLayout.saves.cards["save-1"])
  local overflowControl = assert(overflowCard.overflow)
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  local overflowPlan = planFor(overflowLayout, 640, 480, 2)
  menuRenderer:draw(composed(overflowLayout, overflowFocus, one), overflowPlan)
  lg.setCanvas()
  local overflowPixels = scope:own(canvas:newImageData())
  local overflowPlacement = assert(overflowPlan.panes[1].placement)
  local frameX, frameY = LayoutGeometry.logicalToHost(overflowPlacement, overflowCard.frame.x, overflowCard.frame.y)
  local frameFarX, _ = LayoutGeometry.logicalToHost(
    overflowPlacement,
    overflowCard.frame.x + overflowCard.frame.width,
    overflowCard.frame.y
  )
  local controlX, controlY = LayoutGeometry.logicalToHost(overflowPlacement, overflowControl.x, overflowControl.y)
  local controlFarX, _ =
    LayoutGeometry.logicalToHost(overflowPlacement, overflowControl.x + overflowControl.width, overflowControl.y)
  local br, bg, bb = overflowPixels:getPixel(frameX + math.floor((frameFarX - frameX) / 2), frameY + 5)
  Assert.isFalse(isSelectedRed(br, bg, bb), "save body must return to neutral while overflow is focused")
  local cr, cg, cb = overflowPixels:getPixel(controlX + math.floor((controlFarX - controlX) / 2), controlY + 5)
  Assert.isTrue(isSelectedRed(cr, cg, cb), "focused overflow must carry its own selected red rim")
end

function T.menu_player_copy_tracks_the_menu_scale(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local textDraws = 0
  local textProxy = {
    textWidth = function(_, value)
      return text:textWidth(value)
    end,
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
  local layout = MainMenuLayout.compute(globals, items, focus, 320, 240, 0, nil, nil, false)
  local plan = planFor(layout, 640, 480, 2)
  local menuScale = assert(plan.panes[1].placement.pixelScale, "the menu placement carries its integer scale")
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
  }, plan)
  local foundPromoted = false
  for _, transform in ipairs(graphics.transforms) do
    if transform[1] == "scale" then
      Assert.isTrue(
        transform[2] == math.floor(transform[2]) and transform[3] == math.floor(transform[3]),
        "menu text scaling must never be fractional"
      )
      if transform[2] == 3 and transform[3] == 3 then
        foundPromoted = true
      end
    end
  end
  Assert.isTrue(textDraws > 0, "the menu must draw principal copy through the generated font atlas")
  Assert.isFalse(foundPromoted, "desktop menu copy must track the menu scale instead of promoting it")
  local foundMenuScale = false
  for _, transform in ipairs(graphics.transforms) do
    if transform[1] == "scale" and transform[2] == menuScale and transform[3] == menuScale then
      foundMenuScale = true
    end
  end
  Assert.isTrue(foundMenuScale, "principal menu copy at the desktop baseline must render at the menu scale")
  Assert.equal(graphics.pushDepth(), 0, "text scaling must restore graphics transforms after each draw")
end

function T.card_faces_use_the_white_launcher_face(scope)
  local current = view({ x = 16, y = 80, width = 128, height = 16 })
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(160, 120))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  local menuRenderer = renderer(scope)
  menuRenderer:draw(current, planFor(current.layout, 160, 120, 1))
  lg.setCanvas()
  -- Inside the focused New Game card face, right of and below the label copy.
  local pixels = scope:own(canvas:newImageData())
  local r, g, b = pixels:getPixel(132, 64)
  Assert.near(r, 0xFB / 255, 2 / 255, "the card face must use the white launcher face red")
  Assert.near(g, 0xFB / 255, 2 / 255, "the card face must use the white launcher face green")
  Assert.near(b, 0xFB / 255, 2 / 255, "the card face must use the white launcher face blue")
end
function T.menu_text_uses_palette_path_at_identity_tint()
  local graphics = FakeGraphics.new()
  local plainCalls = {}
  local paletteCalls = {}
  local textDouble = {
    textWidth = function(_, value)
      return #value
    end,
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
  }, planFor(layout, 320, 240, 1))
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
  Assert.equal(button.border.cornerRadius, 6)
  Assert.equal(button.rim.cornerRadius, 5)
  Assert.equal(button.innerBorder.cornerRadius, 3)
  Assert.equal(button.face.cornerRadius, 2)
  local explicit = ImageButton.resolve({
    rect = { x = 16, y = 80, width = 128, height = 64 },
    scale = 1,
    cornerRadius = 6,
    innerBorderWidth = 2,
  })
  Assert.equal(explicit.border.cornerRadius, 6)
  Assert.equal(explicit.rim.cornerRadius, 5)
  Assert.equal(explicit.innerBorder.cornerRadius, 3)
  Assert.equal(explicit.face.cornerRadius, 1)
end
local function nearByte(actual, byte, tolerance)
  Assert.near(actual, byte / 255, (tolerance or 4) / 255)
end

function T.neutral_cards_keep_a_dark_exterior_with_a_full_cyan_inner_border(scope)
  local globals = { { id = "new-game", kind = "new_game" } }
  local saves = {
    {
      id = "save-1",
      saveId = "save-1",
      playerName = "PLAYER",
      playTimeLabel = "1:00",
      canContinue = true,
      canDelete = false,
    },
  }
  -- Focus the save body so the sampled New Game card renders its neutral
  -- chrome instead of the selected red rim.
  local focus = { region = "saves", saveId = "save-1", lane = "body" }
  local layout = MainMenuLayout.compute(globals, saves, focus, 320, 240, 0, nil, nil, false)
  local newGame = assert(layout.global.actions["new-game"])
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  local menuRenderer = renderer(scope, "soulsilver")
  local plan = planFor(layout, 640, 480, 2)
  local placement = assert(plan.panes[1].placement)
  menuRenderer:draw({
    focusedId = "save-1",
    focus = focus,
    globalActions = globals,
    saves = saves,
    catalogError = nil,
    layout = layout,
  }, plan)
  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  -- Sample through the root placement: map the card origin once, then
  -- step the original host-pixel depths into border, rim, inner and
  -- face bands at the desktop presentation scale.
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, newGame.x, newGame.y)
  local hostFarX, _ = LayoutGeometry.logicalToHost(placement, newGame.x + newGame.width, newGame.y)
  local function sample(dx, dy)
    return pixels:getPixel(hostX + dx, hostY + dy)
  end
  local cx = math.floor((hostFarX - hostX) / 2)
  -- At desktop scale the card insets double: 2px border, 4px rim, 4px inner border.
  local r, g, b = sample(cx, 1)
  nearByte(r, 0x30, 4)
  nearByte(g, 0x49, 4)
  nearByte(b, 0x61, 4)
  r, g, b = sample(cx, 4)
  nearByte(r, 0x30, 4)
  nearByte(g, 0x49, 4)
  nearByte(b, 0x61, 4)
  r, g, b = sample(cx, 8)
  nearByte(r, 0xA2, 4)
  nearByte(g, 0xE3, 4)
  nearByte(b, 0xDB, 4)
  local hostHeight = select(2, LayoutGeometry.logicalToHost(placement, newGame.x, newGame.y + newGame.height)) - hostY
  r, g, b = sample(cx, hostHeight - 8)
  nearByte(r, 0xA2, 4)
  nearByte(g, 0xE3, 4)
  nearByte(b, 0xDB, 4)
  r, g, b = sample(14, 14)
  nearByte(r, 0xFB, 4)
  nearByte(g, 0xFB, 4)
  nearByte(b, 0xFB, 4)
end

function T.inset_actions_use_the_face_color_for_the_inner_border(scope)
  local globals = { { id = "new-game", kind = "new_game" } }
  local saves = {
    {
      id = "save-1",
      saveId = "save-1",
      playerName = "PLAYER",
      playTimeLabel = "1:00",
      canContinue = true,
      canDelete = true,
    },
  }
  local focus = { region = "global", actionId = "new-game" }
  local popup = { saveId = "save-1" }
  local layout = MainMenuLayout.compute(globals, saves, focus, 320, 240, 0, popup, nil, false)
  local delete = assert(layout.popup.actions.delete)
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  local menuRenderer = renderer(scope)
  local plan = planFor(layout, 640, 480, 2)
  menuRenderer:draw({
    focusedId = "new-game",
    focus = focus,
    globalActions = globals,
    saves = saves,
    catalogError = nil,
    popup = popup,
    layout = layout,
  }, plan)
  lg.setCanvas()
  local pixels = scope:own(canvas:newImageData())
  -- Bottom inner-border band of the inset delete action: below the label
  -- copy and centered horizontally so rounded corners never intrude.
  local cx = delete.x + math.floor(delete.width / 2)
  local placement = assert(plan.panes[1].placement)
  local r, g, b = pixels:getPixel(LayoutGeometry.logicalToHost(placement, cx, delete.y + delete.height - 8))
  nearByte(r, 0xFB, 4)
  nearByte(g, 0xFB, 4)
  nearByte(b, 0xFB, 4)
end

function T.version_backgrounds_use_the_bright_launcher_field(scope)
  local cases = {
    heartgold = { 0xFF, 0xD6, 0x94 },
    soulsilver = { 0x61, 0x61, 0xFB },
  }
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local expected = cases[versionId]
    local globals = { { id = "new-game", kind = "new_game" } }
    local focus = { region = "global", actionId = "new-game" }
    local layout = MainMenuLayout.compute(globals, {}, focus, 320, 240, 0, nil, nil, false)
    local newGame = assert(layout.global.actions["new-game"])
    local lg = love.graphics
    local canvas = scope:own(lg.newCanvas(640, 480))
    lg.setCanvas(canvas)
    lg.clear(0, 0, 0, 0)
    local menuRenderer = renderer(scope, versionId)
    local plan = planFor(layout, 640, 480, 2)
    local placement = assert(plan.panes[1].placement)
    menuRenderer:draw({
      focusedId = "new-game",
      focus = focus,
      globalActions = globals,
      saves = {},
      catalogError = nil,
      layout = layout,
    }, plan)
    lg.setCanvas()
    local pixels = scope:own(canvas:newImageData())
    local found = false
    for _, point in ipairs({ { 8, 8 }, { 632, 8 }, { 8, 472 }, { 632, 472 } }) do
      -- Candidate points are host pixels: invert to the logical card
      -- geometry before testing membership, then sample the host pixel.
      local logicalX, logicalY =
        assert(LayoutGeometry.hostToLogical(placement, point[1], point[2]), "background probes stay visible")
      local outside = logicalX < newGame.x
        or logicalX >= newGame.x + newGame.width
        or logicalY < newGame.y
        or logicalY >= newGame.y + newGame.height
      if outside then
        local r, g, b = pixels:getPixel(point[1], point[2])
        nearByte(r, expected[1], 4)
        nearByte(g, expected[2], 4)
        nearByte(b, expected[3], 4)
        found = true
      end
    end
    Assert.isTrue(found, "a launcher background pixel must be visible for " .. versionId)
  end
end

function T.launcher_copy_scales_with_the_menu_and_preserves_player_casing(scope)
  local measure = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local function renderAt(logicalWidth, logicalHeight, hostScale, saves)
    local graphics = FakeGraphics.new()
    local draws = {}
    local textDouble = {
      textWidth = function(_, value)
        return measure:textWidth(value)
      end,
      drawTextWithPalette = function(_, value, x, y, _)
        -- Copy draws at logical coordinates under one root placement:
        -- record the logical point plus the active root scale.
        local s = 1
        for index = #graphics.transforms, 1, -1 do
          local entry = graphics.transforms[index]
          if entry[1] == "scale" then
            s = entry[2]
            break
          end
        end
        draws[#draws + 1] = { value = value, x = x, y = y, scale = s }
      end,
    }
    local cache = FieldUiFixture.cacheWithFontAndFrames()
    cache:writeLua(IntroAssetCache.manifestPath(), introManifest())
    local globals = { { id = "new-game", kind = "new_game" } }
    local focus = { region = "saves", saveId = saves[1].saveId or saves[1].id, lane = "body" }
    local layout = MainMenuLayout.compute(globals, saves, focus, logicalWidth, logicalHeight, 0, nil, nil, false)
    local menuRenderer =
      MainMenuRenderer.new({ text = textDouble, graphics = graphics, cacheFs = cache, versionId = "heartgold" })
    menuRenderer:draw({
      focusedId = focus.saveId,
      focus = focus,
      globalActions = globals,
      saves = saves,
      catalogError = nil,
      layout = layout,
    }, planFor(layout, logicalWidth * hostScale, logicalHeight * hostScale, hostScale))
    return draws, layout
  end
  local saves = {
    {
      id = "save-1",
      saveId = "save-1",
      playerName = "marc",
      playTimeLabel = "1:00",
      canContinue = true,
      canDelete = true,
    },
    {
      id = "save-2",
      saveId = "save-2",
      playerName = "Zo\195\169",
      playTimeLabel = "0:00",
      canContinue = true,
      canDelete = false,
    },
  }
  local draws, layout = renderAt(320, 240, 2, saves)
  Assert.isTrue(#draws >= 5, "the launcher must draw principal copy through the generated font path")
  local presentationLabels = {
    CONTINUE = true,
    ["NEW GAME"] = true,
    PLAYER = true,
    TIME = true,
    BADGES = true,
    ["..."] = true,
  }
  local seen = {}
  for _, draw in ipairs(draws) do
    seen[draw.value] = true
    Assert.equal(draw.scale, math.floor(draw.scale), "launcher text scaling stays integral")
    Assert.equal(draw.scale, 2, "launcher copy must track the menu scale: " .. draw.value)
  end
  for label in pairs(presentationLabels) do
    Assert.isTrue(seen[label], "the launcher must draw presentation copy: " .. label)
  end
  Assert.isTrue(seen["marc"], "a lowercase stored player name must draw with its casing preserved")
  Assert.isNil(seen["MARC"], "the stored player name must not be uppercased for presentation")
  Assert.isTrue(seen["1:00"], "the stored play time must draw exactly")
  Assert.isTrue(seen["0"], "the presentation badge count must draw")
  local foundPassthrough = false
  for _, draw in ipairs(draws) do
    if draw.value:find("\195\169") then
      foundPassthrough = true
    end
  end
  Assert.isTrue(foundPassthrough, "glyphs without ascii case pairs must pass through instead of being lost")
  Assert.equal(saves[1].playerName, "marc", "presentation copy must not mutate the saved player name")
  local newGame = assert(layout.global.actions["new-game"])
  local saveIndex = 0
  for _, draw in ipairs(draws) do
    local region
    if draw.value == "NEW GAME" then
      region = newGame
    else
      if draw.value == "CONTINUE" then
        saveIndex = saveIndex + 1
      end
      local card = assert(layout.saves.cards[saves[saveIndex].saveId], "save card is required")
      if draw.value == "..." then
        region = assert(card.overflow, "overflow card is required")
      else
        region = assert(card.frame, "save frame is required")
      end
    end
    local right = draw.x + measure:textWidth(draw.value)
    Assert.isTrue(
      draw.x >= region.x and right <= region.x + region.width,
      "launcher copy must stay inside its owning card: " .. draw.value
    )
  end
  local smallDraws = (function()
    local result = { renderAt(320, 240, 1, saves) }
    return result[1]
  end)()
  for _, draw in ipairs(smallDraws) do
    Assert.equal(draw.scale, 1, "the canonical small layout keeps single-scale text")
  end
end

function T.headings_and_chrome_magnify_together_across_integer_scales(scope)
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
  -- One logical layout: the presentation scale lives only in the plan
  -- placement, never in layout fields.
  local layout = MainMenuLayout.compute(globals, items, focus, 320, 240, 0, nil, nil, false)
  Assert.isNil(layout.uiScale, "the logical layout carries no presentation scale")

  local lg = love.graphics
  local function render(layoutArg, width, height, pixelScale)
    local canvas = scope:own(lg.newCanvas(width, height))
    lg.setCanvas(canvas)
    lg.clear(0, 0, 0, 0)
    local menuRenderer, _ = renderer(scope)
    menuRenderer:draw({
      focusedId = "save-1",
      focus = focus,
      globalActions = globals,
      saves = items,
      catalogError = nil,
      layout = layoutArg,
    }, planFor(layoutArg, width, height, pixelScale))
    lg.setCanvas()
    return scope:own(canvas:newImageData())
  end
  local smallPixels = render(layout, 320, 240, 1)
  local largePixels = render(layout, 640, 480, 2)

  local function isInk(data, x, y)
    local r, g, b, a = data:getPixel(x, y)
    if a < 0.5 then
      return false
    end
    return math.max(r, g, b) < 0.7
  end
  local function inkHeight(data, frame)
    local top, bottom = nil, nil
    for y = math.floor(frame.y), math.floor(frame.y + frame.height) - 1 do
      for x = math.floor(frame.x), math.floor(frame.x + frame.width) - 1 do
        if isInk(data, x, y) then
          if top == nil or y < top then
            top = y
          end
          if bottom == nil or y > bottom then
            bottom = y
          end
        end
      end
    end
    Assert.notNil(top, "the focused card must carry text ink")
    assert(top and bottom)
    return bottom - top + 1
  end
  local card = assert(layout.saves.cards["save-1"])
  local smallInk = inkHeight(smallPixels, card.frame)
  -- The doubled canvas carries host pixels: scale the logical frame once.
  local largeFrame =
    { x = card.frame.x * 2, y = card.frame.y * 2, width = card.frame.width * 2, height = card.frame.height * 2 }
  local largeInk = inkHeight(largePixels, largeFrame)
  Assert.equal(largeInk, smallInk * 2, "card text ink must magnify exactly with its card: one shared root scale")

  local function rimThickness(data, frame)
    local midY = math.floor(frame.y + frame.height / 2)
    local run = 0
    local best = 0
    for x = math.floor(frame.x), math.floor(frame.x + frame.width) - 1 do
      local r, g, b, a = data:getPixel(x, midY)
      local red = a > 0.5 and r > 0.9 and (r - g) > 0.5 and (r - b) > 0.5
      if red then
        run = run + 1
        best = math.max(best, run)
      else
        run = 0
      end
    end
    return best
  end
  local smallRim = rimThickness(smallPixels, card.frame)
  local largeRim = rimThickness(largePixels, largeFrame)
  Assert.isTrue(smallRim > 0, "the focused card must carry a measurable rim at unit scale")
  Assert.equal(largeRim, smallRim * 2, "card chrome must magnify exactly with its text")
end

return GraphicsSmoke.suite(T)
