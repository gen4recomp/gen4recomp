-- Bag renderer contracts, driven through an injected graphics namespace,
-- stub text/icons, and an in-memory cache so no GPU resource is created.
-- Covers pane composition order, occupied/empty cells, tab and cell cursor
-- placement, page and cancel labels, the constrained description overlay,
-- generated action/quantity/confirmation state presentation, semantic action
-- labels and contextual templates, the closed no-op, graphics-state
-- restoration, nearest filtering, and idempotent disposal. Text content
-- rides the presentation records and the generated semantic text record; the
-- fake graphics namespace records call structure, not glyphs.

local Assert = require("tests.support.Assert")
local BagRenderer = require("libs.hgss.src.ui.BagRenderer")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local FakeGraphics = require("tests.support.FakeGraphics").new

local T = {}

local IMAGE_SIZES = {}
for _ = 1, 20 do
  IMAGE_SIZES[#IMAGE_SIZES + 1] = { 256, 192 }
end

local function manifest()
  local tabs = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
  end
  local normals = {}
  for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
    normals[pocket] = {
      image = "bag/strip-" .. pocket .. ".png",
      width = 256,
      height = 32,
    }
  end
  local pockets = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }
  local backgrounds = {}
  for _, state in ipairs({ "action", "quantity", "confirmation" }) do
    local variants = {}
    for _, pocket in ipairs(pockets) do
      variants[pocket] = {
        image = "bag/background-" .. state .. "-" .. pocket .. ".png",
        width = 256,
        height = 192,
      }
    end
    backgrounds[state] = variants
  end
  do
    local browse = {}
    for _, pocket in ipairs(pockets) do
      local variants = {}
      for count = 0, 6 do
        variants[count + 1] = {
          image = "bag/background-browse-" .. pocket .. "-" .. count .. ".png",
          width = 256,
          height = 192,
        }
      end
      browse[pocket] = variants
    end
    backgrounds.browse = browse
  end
  local slots = {}
  local shapes = {
    { { 0, 32, 128, 42 }, { 32, 40, 88, 32 }, { 48, 56 } },
    { { 128, 32, 128, 42 }, { 160, 40, 88, 32 }, { 176, 56 } },
    { { 0, 74, 128, 44 }, { 32, 80, 88, 32 }, { 48, 96 } },
    { { 128, 74, 128, 44 }, { 160, 80, 88, 32 }, { 176, 96 } },
    { { 0, 118, 128, 36 }, { 32, 120, 88, 32 }, { 48, 136 } },
    { { 128, 118, 128, 36 }, { 160, 120, 88, 32 }, { 176, 136 } },
  }
  for index, shape in ipairs(shapes) do
    slots[index] = {
      rect = { x = shape[1][1], y = shape[1][2], width = shape[1][3], height = shape[1][4] },
      textRect = { x = shape[2][1], y = shape[2][2], width = shape[2][3], height = shape[2][4] },
      iconCenter = { x = shape[3][1], y = shape[3][2] },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    }
  end
  return {
    hero = {
      background = {
        male = { image = "bag/hero-male.png", width = 256, height = 192 },
        female = { image = "bag/hero-female.png", width = 256, height = 192 },
      },
      description = {
        frame = { image = "bag/description.png", rect = { x = 0, y = 144, width = 256, height = 48 } },
        textRect = { x = 20, y = 144, width = 236, height = 48 },
      },
    },
    interactive = {
      backgrounds = backgrounds,
      pocketTabs = {
        rects = tabs,
        strips = normals,
      },
      focus = {
        tabs = {
          visual = { image = "bag/focus-tabs.png", width = 32, height = 32, offset = { x = -16, y = -16 } },
          targets = {
            { x = 16, y = 16 },
            { x = 48, y = 16 },
            { x = 80, y = 16 },
            { x = 112, y = 16 },
            { x = 144, y = 16 },
            { x = 176, y = 16 },
            { x = 208, y = 16 },
            { x = 240, y = 16 },
          },
        },
        items = {
          visual = { image = "bag/focus-items.png", width = 96, height = 40, offset = { x = -48, y = -20 } },
          targets = {
            { x = 16, y = 48 },
            { x = 144, y = 48 },
            { x = 16, y = 88 },
            { x = 144, y = 88 },
            { x = 16, y = 128 },
            { x = 144, y = 128 },
          },
        },
        cancel = {
          visual = { image = "bag/focus-cancel.png", width = 64, height = 24, offset = { x = -32, y = -12 } },
          target = { x = 224, y = 176 },
        },
        actions = {
          visual = { image = "bag/focus-actions.png", width = 96, height = 24, offset = { x = -48, y = -12 } },
          targets = {
            { x = 48, y = 144 },
            { x = 144, y = 144 },
            { x = 48, y = 176 },
            { x = 144, y = 176 },
          },
        },
      },
      itemSlots = {
        slots = slots,
        registration = {
          slot1 = { image = "bag/registration-slot-1.png", width = 40, height = 16 },
          slot2 = { image = "bag/registration-slot-2.png", width = 40, height = 16 },
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = {
        rect = { x = 192, y = 168, width = 64, height = 24 },
        textRect = { x = 192, y = 168, width = 56, height = 16 },
        labelRect = { x = 200, y = 168, width = 48, height = 16 },
      },
      text = {
        actions = {
          toss = "TRASH",
          move = "MOVE",
          register = "REGISTER",
          unregister = "DESELECT",
          cancel = "BACK OUT",
          confirm = "YES",
        },
        movePrompt = {
          segments = { { kind = "text", value = "Move " }, { kind = "item" }, { kind = "text", value = "." } },
        },
        tossQuantity = {
          segments = { { kind = "text", value = "Toss " }, { kind = "item" }, { kind = "text", value = "?" } },
        },
        tossConfirm = {
          segments = {
            { kind = "text", value = "Toss " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "?" },
          },
        },
      },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
        actionMenu = {
          buttons = {
            { x = 8, y = 136, width = 80, height = 16 },
            { x = 104, y = 136, width = 80, height = 16 },
            { x = 8, y = 168, width = 80, height = 16 },
            { x = 104, y = 168, width = 80, height = 16 },
          },
        },
        quantity = {
          digits = {
            { x = 128, y = 112, width = 16, height = 24 },
            { x = 160, y = 112, width = 16, height = 24 },
            { x = 192, y = 112, width = 16, height = 24 },
          },
        },
      },
    },
  }
end

local function seedCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local paths = {
    "bag/hero-male.png",
    "bag/hero-female.png",
    "bag/description.png",
  }
  for _, state in ipairs({ "action", "quantity", "confirmation" }) do
    for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
      paths[#paths + 1] = "bag/background-" .. state .. "-" .. pocket .. ".png"
    end
  end
  for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
    for count = 0, 6 do
      paths[#paths + 1] = "bag/background-browse-" .. pocket .. "-" .. count .. ".png"
    end
  end
  for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
    paths[#paths + 1] = "bag/strip-" .. pocket .. ".png"
  end
  paths[#paths + 1] = "bag/focus-tabs.png"
  paths[#paths + 1] = "bag/focus-items.png"
  paths[#paths + 1] = "bag/focus-cancel.png"
  paths[#paths + 1] = "bag/focus-actions.png"
  paths[#paths + 1] = "bag/registration-slot-1.png"
  paths[#paths + 1] = "bag/registration-slot-2.png"
  for _, path in ipairs(paths) do
    cache:write(path, "png-bytes")
  end
  return cache
end

local function text()
  local printed = {}
  local palette = {}
  for index = 1, 16 do
    palette[index] = { r = 255, g = 255, b = 255 }
  end
  return {
    printed = printed,
    fontDef = { palette = palette },
    drawText = function(_, content, x, y)
      printed[#printed + 1] = { text = content, x = x, y = y }
    end,
    drawTextWithPalette = function(_, content, x, y, paletteRecord)
      printed[#printed + 1] = { text = content, x = x, y = y, palette = paletteRecord }
    end,
    textWidth = function(_, content)
      return #content * 8
    end,
  }
end

local function icons(calls)
  return {
    image = function()
      return "atlas"
    end,
    quadFor = function(_, key)
      if calls ~= nil then
        calls.quadFor = calls.quadFor + 1
        calls.keys[#calls.keys + 1] = key
      end
      return { key = key }
    end,
    dimensions = function(_)
      if calls ~= nil then
        calls.dimensions = calls.dimensions + 1
      end
      return { width = 32, height = 32 }
    end,
  }
end

local function wasDrawn(graphics, image)
  for _, entry in ipairs(graphics.draws) do
    if entry.image == image then
      return true
    end
  end
  return false
end

-- Static visual draws carry no quad: the fake normalizes draw(image, x, y)
-- to quad=nil, x, y. Every focus assertion below resolves its expected
-- position from the manifest record, never from production internals.
local function staticDrawnAt(graphics, x, y)
  for _, entry in ipairs(graphics.draws) do
    if entry.quad == nil and entry.x == x and entry.y == y then
      return true
    end
  end
  return false
end

local function staticDrawCount(graphics)
  local count = 0
  for _, entry in ipairs(graphics.draws) do
    if type(entry.quad) ~= "table" then
      count = count + 1
    end
  end
  return count
end

local function focusOrigin(focusClass, target)
  local offset = focusClass.visual.offset or { x = 0, y = 0 }
  local point = target or focusClass.target
  return point.x + offset.x, point.y + offset.y
end

-- In-memory cache that records every image path read during construction so
-- acquisition tests prove which generated visuals are bound without reading
-- production internals.
local function trackingCache(reads)
  local cache = seedCache()
  local wrapped = {}
  function wrapped:read(path)
    reads[#reads + 1] = path
    return cache:read(path)
  end
  function wrapped:write(path, data)
    return cache:write(path, data)
  end
  return wrapped
end

local function readPathsContaining(reads, needle)
  local found = {}
  for _, path in ipairs(reads) do
    if path:find(needle, 1, true) ~= nil then
      found[#found + 1] = path
    end
  end
  return found
end

local function slot(item, quantity)
  return {
    item = item,
    nativeId = 1,
    name = item,
    quantity = quantity or 1,
    description = item .. " description",
    icon = item,
  }
end

local function visibleSlots()
  local cells = {
    slot("POTION", 5),
    slot("POKE_BALL", 3),
  }
  for index = 3, 6 do
    cells[index] = { empty = true, visibleIndex = index - 1 }
  end
  return cells
end

local function pockets()
  local keys = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }
  local tabs = {}
  for index, key in ipairs(keys) do
    tabs[index] = { pocket = key, nativeId = index - 1, name = key }
  end
  return tabs
end

local function heroSpy(order)
  local spy = { draws = {}, releaseCount = 0 }
  function spy:draw(gender, heroStatus, heroPlacement)
    self.draws[#self.draws + 1] = { gender = gender, status = heroStatus, placement = heroPlacement }
    if order ~= nil then
      order[#order + 1] = "hero"
    end
  end
  function spy:release()
    self.releaseCount = self.releaseCount + 1
  end
  return spy
end

local function heroStatusRecord()
  return { pocket = "balls", pose = "pocket.balls.pose", pattern = "pocket.balls.pattern", frame = 3 }
end

local function status(overrides)
  local record = {
    open = true,
    state = "browsing",
    focus = "items",
    pocket = "balls",
    tabFocusPocket = "balls",
    pocketName = "Balls",
    pockets = pockets(),
    slots = { slot("POTION", 5), slot("POKE_BALL", 3) },
    selectedAbsoluteIndex = 0,
    visibleStart = 0,
    focusedAbsoluteIndex = 0,
    focusedVisibleIndex = 0,
    visibleSlots = visibleSlots(),
    page = { current = 1, count = 1 },
    selected = slot("POTION", 5),
    heroGender = "male",
    hero = heroStatusRecord(),
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  if record.tabFocusPocket == nil then
    record.tabFocusPocket = record.pocket
  end
  return record
end

local function placement()
  return {
    frame = { x = 0, y = 0, width = 512, height = 384 },
    origin = { x = 0, y = 0 },
    scale = 2,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = { x = 0, y = 0, width = 512, height = 384 },
    pixelScale = 2,
    pixelRatio = 1,
    visibleLogicalRect = { x = 0, y = 0, width = 256, height = 192 },
    crop = { left = 0, right = 0, top = 0, bottom = 0 },
  }
end

local function plan(heroVisible)
  local panes = {}
  if heroVisible then
    panes[#panes + 1] = { id = "hero", placement = placement(), interactive = false }
  end
  panes[#panes + 1] = { id = "interaction", placement = placement(), interactive = true }
  local fallback = nil
  local textRect = nil
  if not heroVisible then
    fallback = { x = 0, y = 144, width = 256, height = 48 }
    textRect = { x = 20, y = 144, width = 236, height = 48 }
  end
  return {
    panes = panes,
    content = {
      heroVisible = heroVisible,
      descriptionFallback = fallback,
      descriptionTextRect = textRect,
      hitTest = function()
        return nil
      end,
    },
    inputKey = "bag",
    render = function(_, _, _) end,
    mapInput = function()
      return nil
    end,
    coverage = {},
    backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
  }
end

local function renderer(graphics)
  return BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
end

local function printedText(content, needle)
  for _, entry in ipairs(content.printed) do
    if entry.text == needle then
      return true
    end
  end
  return false
end

local function printedAt(content, needle)
  for _, entry in ipairs(content.printed) do
    if entry.text == needle then
      return entry
    end
  end
  return nil
end

function T.closed_status_draws_nothing()
  local graphics = FakeGraphics({ color = { 0.2, 0.3, 0.4, 1 }, imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  draw:draw({ open = false }, plan(true), { icons = icons() })
  Assert.equal(#graphics.draws, 0, "a closed presentation draws no images")
  Assert.equal(#graphics.primitives, 0, "a closed presentation draws no primitives")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.two_pane_mode_draws_hero_and_interactive_content()
  local graphics = FakeGraphics({ color = { 0.2, 0.3, 0.4, 1 }, imageSizes = IMAGE_SIZES })
  local content = text()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status(), plan(true), { icons = icons() })
  Assert.isTrue(#graphics.draws >= 6, "both panes compose backgrounds, strip, icons, and cursors")
  Assert.isTrue(printedText(content, "POTION"), "occupied cells print their item name")
  Assert.isTrue(printedText(content, "x5"), "occupied cells print their quantity")
  Assert.isTrue(printedText(content, "BACK OUT"), "the generated cancel affordance prints its label")
  Assert.isTrue(printedText(content, "1/1"), "the page indicator prints its derived page")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  local red, green, blue, alpha = 0.2, 0.3, 0.4, 1
  local kept = { graphics.getColor() }
  Assert.deepEqual(kept, { red, green, blue, alpha }, "the draw restores the graphics color")
  for _, image in ipairs(graphics.images) do
    Assert.deepEqual(image.filters[1], { min = "nearest", mag = "nearest" }, "art keeps pixel-art filtering")
  end
  draw:release()
end

function T.page_indicator_prints_inside_its_manifest_rectangle()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status(), plan(true), { icons = icons() })
  local rect = manifested.interactive.pageIndicator.rect
  local entry = assert(printedAt(content, "1/1"), "the page indicator prints its derived page")
  Assert.isTrue(entry.x >= rect.x, "the page text starts inside its indicator rectangle")
  Assert.isTrue(entry.y >= rect.y, "the page text stays below the tab row")
  Assert.isTrue(entry.x < rect.x + rect.width, "the page text ends inside its indicator rectangle")
  Assert.isTrue(entry.y < rect.y + rect.height, "the page text stays inside its indicator rectangle")
  draw:release()
end

function T.semantic_visuals_drive_tabs_focus_and_state_backgrounds()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local calls = { quadFor = 0, dimensions = 0, keys = {} }
  local reads = {}
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = trackingCache(reads),
    manifest = manifested,
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local focusReads = readPathsContaining(reads, "focus-")
  table.sort(focusReads)
  Assert.deepEqual(
    focusReads,
    { "bag/focus-actions.png", "bag/focus-cancel.png", "bag/focus-items.png", "bag/focus-tabs.png" },
    "construction binds every generated focus visual exactly once"
  )
  Assert.equal(#readPathsContaining(reads, "highlight"), 0, "no retired tab highlight is ever acquired")
  draw:draw(status(), plan(true), { icons = icons(calls) })
  local ballsStrip = assert(draw._images["strip:balls"], "the current pocket strip is bound")
  Assert.isTrue(wasDrawn(graphics, ballsStrip), "browse draws its pocket-specific strip")
  for _, pocket in ipairs({ "items", "medicine", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
    Assert.isFalse(
      wasDrawn(graphics, draw._images["strip:" .. pocket]),
      "browse never borrows the " .. pocket .. " strip"
    )
  end
  Assert.isTrue(
    wasDrawn(graphics, draw._images["background:browse:balls:2"]),
    "browse uses the pocket-specific background"
  )
  Assert.equal(#graphics.rectangles, 0, "item focus never falls back to primitive outlines")
  local itemFocus = manifested.interactive.focus.items
  local focusX, focusY = focusOrigin(itemFocus, itemFocus.targets[1])
  Assert.isTrue(staticDrawnAt(graphics, focusX, focusY), "browse item focus lands on its generated target")
  Assert.equal(calls.quadFor, 2, "the renderer keeps the existing item icon lookup count")
  Assert.deepEqual(calls.keys, { "POTION", "POKE_BALL" }, "the renderer keeps the existing icon keys")

  for _, state in ipairs({ "action_menu", "toss_quantity", "toss_confirm", "move_select" }) do
    for key in pairs(graphics.draws) do
      graphics.draws[key] = nil
    end
    local record = status({ state = state, quantity = 2, quantityMax = 5, moveTarget = 1 })
    if state == "action_menu" then
      record.actions = { { id = "toss" }, { id = "cancel" } }
      record.selectedAction = 0
    end
    draw:draw(record, plan(true), { icons = icons() })
    local key = state == "action_menu" and "background:action:balls"
      or state == "toss_quantity" and "background:quantity:balls"
      or state == "toss_confirm" and "background:confirmation:balls"
      or "background:browse:balls:2"
    Assert.isTrue(wasDrawn(graphics, draw._images[key]), state .. " selects its pocket-specific background")
  end
  draw:release()
end

function T.browse_keeps_generated_chrome()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local reads = {}
  local draw = BagRenderer.new({
    cacheFs = trackingCache(reads),
    manifest = manifest(),
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status(), plan(true), { icons = icons() })
  Assert.isTrue(wasDrawn(graphics, draw._images["strip:balls"]), "browse draws its pocket-specific strip")
  Assert.equal(#readPathsContaining(reads, "highlight"), 0, "the selected pocket carries no synthetic highlight")
  Assert.isTrue(
    wasDrawn(graphics, draw._images["background:browse:balls:2"]),
    "browse uses its pocket-specific background"
  )
  Assert.isTrue(printedText(content, "BACK OUT"), "the generated cancel affordance prints its label")
  Assert.isTrue(printedText(content, "1/1"), "the page indicator prints its derived page")
  Assert.equal(#graphics.rectangles, 0, "browse chrome never falls back to primitive outlines")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.graphics_state_is_restored_after_semantic_draw()
  local graphics =
    FakeGraphics({ color = { 0.2, 0.3, 0.4, 1 }, scissor = { 1, 2, 300, 180 }, imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  draw:draw(status(), plan(true), { icons = icons() })
  Assert.deepEqual({ graphics.getScissor() }, { 1, 2, 300, 180 }, "the draw restores the caller scissor")
  Assert.deepEqual({ graphics.getColor() }, { 0.2, 0.3, 0.4, 1 }, "the draw restores the caller color")
  Assert.equal(graphics.pushDepth(), 0, "the draw restores the caller transform stack")
  draw:release()
end

function T.draw_failure_restores_the_pane_transform_stack()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  local record = status()
  record.visibleSlots[1].registrationSlot = 3
  Assert.throws(function()
    draw:draw(record, plan(true), { icons = icons() })
  end, "an invalid cell fails during pane composition")
  Assert.equal(graphics.pushDepth(), 0, "a failed pane draw restores every transform scope")
  draw:release()
end

function T.image_filter_failure_releases_the_new_image()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local newImage = graphics.newImage
  graphics.newImage = function(...)
    local image = newImage(...)
    image.setFilter = function()
      error("injected image filter failure")
    end
    return image
  end
  Assert.throws(function()
    renderer(graphics)
  end, "an image filter failure unwinds construction")
  Assert.equal(#graphics.images, 1, "the failed image was still created")
  Assert.equal(graphics.images[1].releaseCount, 1, "the failed image is released exactly once")
end

function T.empty_pockets_draw_no_icons_but_keep_navigation_labels()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local cells = {}
  for index = 1, 6 do
    cells[index] = { empty = true, visibleIndex = index - 1 }
  end
  local record = status({ slots = {}, visibleSlots = cells, selectedAbsoluteIndex = 0 })
  record.selected = nil
  draw:draw(record, plan(true), { icons = icons() })
  for _, entry in ipairs(graphics.draws) do
    local quad = entry.quad
    Assert.isTrue(type(quad) ~= "table" or quad.key == nil, "empty cells draw no item icons")
  end
  Assert.isTrue(printedText(content, "BACK OUT"), "empty pockets keep the generated cancel affordance")
  for key in pairs(graphics.draws) do
    graphics.draws[key] = nil
  end
  local manifested = manifest()
  local tabbed = status({ slots = {}, visibleSlots = cells, selectedAbsoluteIndex = 0, focus = "tabs" })
  tabbed.selected = nil
  draw:draw(tabbed, plan(true), { icons = icons() })
  local tabFocus = manifested.interactive.focus.tabs
  local tabX, tabY = focusOrigin(tabFocus, tabFocus.targets[3])
  Assert.isTrue(staticDrawnAt(graphics, tabX, tabY), "empty pockets still resolve tab focus")
  local itemFocus = manifested.interactive.focus.items
  for index, target in ipairs(itemFocus.targets) do
    local itemX, itemY = focusOrigin(itemFocus, target)
    Assert.isFalse(staticDrawnAt(graphics, itemX, itemY), "empty pockets draw no item focus at target " .. index)
  end
  Assert.equal(#graphics.rectangles, 0, "empty pockets emit no primitive focus")
  draw:release()
end

function T.constrained_overlay_draws_the_description_panel()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status({ state = "description_overlay" }), plan(false), { icons = icons() })
  local panel = false
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "fill" and rectangle.x == 0 and rectangle.y == 144 then
      panel = true
    end
  end
  Assert.isTrue(panel, "the overlay fills the canonical fallback frame")
  Assert.isTrue(printedText(content, "POTION"), "the overlay names the selected item")
  Assert.isTrue(printedText(content, "B Back"), "the overlay keeps its back hint")
  draw:release()
end

local function actionStatus(overrides)
  local record = status({
    state = "action_menu",
    actions = {
      { id = "toss", enabled = true },
      { id = "move", enabled = true },
      { id = "cancel", enabled = true },
    },
    selectedAction = 1,
  })
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function joinedText(content)
  local parts = {}
  for _, entry in ipairs(content.printed) do
    parts[#parts + 1] = entry.text
  end
  return table.concat(parts, "\n")
end

local function fillCount(graphics)
  local count = 0
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "fill" then
      count = count + 1
    end
  end
  return count
end

-- Background/state image draws only: table images drawn without a quad.
-- Icon and cursor draws carry quads and are excluded.
local function stateImages(graphics)
  local found = {}
  for _, entry in ipairs(graphics.draws) do
    if type(entry.image) == "table" and type(entry.quad) ~= "table" then
      found[#found + 1] = entry.image
    end
  end
  return found
end

local function sameImageSet(a, b)
  if #a ~= #b then
    return false
  end
  local seen = {}
  for _, image in ipairs(a) do
    seen[image] = (seen[image] or 0) + 1
  end
  for _, image in ipairs(b) do
    if (seen[image] or 0) == 0 then
      return false
    end
    seen[image] = seen[image] - 1
  end
  return true
end

-- Snapshots the state-image set for one state through a single shared
-- renderer, so image identity stays comparable across states.
local function snapshotImages(records, mode)
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local snaps = {}
  for _, record in ipairs(records) do
    for key in pairs(graphics.draws) do
      graphics.draws[key] = nil
    end
    draw:draw(record, plan(mode ~= "interactive_only"), { icons = icons() })
    snaps[#snaps + 1] = stateImages(graphics)
  end
  draw:release()
  return snaps
end

function T.action_menu_draws_generated_labels_and_never_raw_ids()
  for _, mode in ipairs({ "horizontal", "vertical" }) do
    local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
    local content = text()
    local manifested = manifest()
    local draw = BagRenderer.new({
      cacheFs = seedCache(),
      manifest = manifested,
      text = content,
      graphics = graphics,
      heroRenderer = heroSpy(nil),
    })
    draw:draw(actionStatus(), plan(mode ~= "interactive_only"), { icons = icons() })
    Assert.isTrue(printedText(content, "TRASH"), "the menu labels its toss action in " .. mode)
    Assert.isTrue(printedText(content, "MOVE"), "the menu labels its move action in " .. mode)
    Assert.isTrue(printedText(content, "BACK OUT"), "the menu labels its way out in " .. mode)
    Assert.isFalse(printedText(content, "toss"), "the raw toss id never reaches the screen in " .. mode)
    Assert.isFalse(printedText(content, "move"), "the raw move id never reaches the screen in " .. mode)
    Assert.isFalse(printedText(content, "cancel"), "the raw cancel id never reaches the screen in " .. mode)
    local actionFocus = manifested.interactive.focus.actions
    local selectedX, selectedY = focusOrigin(actionFocus, actionFocus.targets[2])
    Assert.isTrue(
      staticDrawnAt(graphics, selectedX, selectedY),
      "the action focus follows the selected action in " .. mode
    )
    for index, target in ipairs(actionFocus.targets) do
      if index ~= 2 then
        local otherX, otherY = focusOrigin(actionFocus, target)
        Assert.isFalse(
          staticDrawnAt(graphics, otherX, otherY),
          "no stale action focus remains at target " .. index .. " in " .. mode
        )
      end
    end
    Assert.equal(#graphics.rectangles, 0, "the action menu emits no primitive focus in " .. mode)
    Assert.equal(fillCount(graphics), 0, "no generic fill covers the generated action screen in " .. mode)
    Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced in " .. mode)
    draw:release()
  end
end

function T.action_focus_indexes_from_the_selected_action_without_clamping()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local actionFocus = manifested.interactive.focus.actions
  local lastX, lastY = focusOrigin(actionFocus, actionFocus.targets[4])
  local fullMenu = actionStatus({
    actions = { { id = "toss" }, { id = "move" }, { id = "register" }, { id = "cancel" } },
    selectedAction = 3,
  })
  draw:draw(fullMenu, plan(true), { icons = icons() })
  Assert.isTrue(staticDrawnAt(graphics, lastX, lastY), "the last action resolves to the fourth target")
  Assert.throws(function()
    draw:draw(actionStatus({ selectedAction = 4 }), plan(true), { icons = icons() })
  end, "an action selection outside the generated targets fails instead of clamping")
  draw:release()
end

function T.action_menu_resolves_register_and_unregister_labels_independently()
  for _, case in ipairs({
    { id = "register", label = "REGISTER" },
    { id = "unregister", label = "DESELECT" },
  }) do
    local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
    local content = text()
    local draw = BagRenderer.new({
      cacheFs = seedCache(),
      manifest = manifest(),
      text = content,
      graphics = graphics,
      heroRenderer = heroSpy(nil),
    })
    local record = actionStatus({
      actions = { { id = case.id, enabled = true }, { id = "cancel", enabled = true } },
      selectedAction = 0,
    })
    draw:draw(record, plan(true), { icons = icons() })
    Assert.isTrue(printedText(content, case.label), "the menu labels " .. case.id .. " independently")
    Assert.isFalse(printedText(content, case.id), "the raw " .. case.id .. " id never reaches the screen")
    draw:release()
  end
end

function T.action_menu_without_generated_labels_is_a_composition_error()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local broken = manifest()
  broken.interactive.text.actions.toss = nil
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = broken,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  Assert.throws(function()
    draw:draw(actionStatus(), plan(true), { icons = icons() })
  end, "an offered action without a generated label fails instead of printing its raw id")
  draw:release()
end

function T.action_menu_without_generated_buttons_is_a_composition_error()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local plain = manifest()
  plain.interactive.overlays.actionMenu = nil
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = plain,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  Assert.throws(function()
    draw:draw(actionStatus(), plan(true), { icons = icons() })
  end, "an action menu without generated button geometry fails instead of falling back to a list")
  draw:release()
end

function T.browse_and_action_states_composite_distinct_generated_backgrounds()
  local snaps = snapshotImages({ status(), actionStatus() }, "horizontal")
  Assert.isFalse(sameImageSet(snaps[1], snaps[2]), "browse and action states draw distinct generated layer stacks")
  Assert.isTrue(#snaps[1] >= 4, "the browse state composites its generated layers")
  Assert.isTrue(#snaps[2] >= 4, "the action state composites its generated layers")
end

function T.quantity_state_draws_generated_layers_digits_and_prompt()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status({ state = "toss_quantity", quantity = 2, quantityMax = 5 }), plan(true), {
    icons = icons(),
  })
  local joined = joinedText(content)
  Assert.isTrue(joined:find("Toss POTION?", 1, true) ~= nil, "the quantity state formats its generated prompt")
  Assert.isFalse(printedText(content, "x2"), "the quantity state never reuses the legacy amount panel text")
  local digits = manifest().interactive.overlays.quantity.digits
  local cell = digits[3]
  local digit = false
  for _, entry in ipairs(content.printed) do
    if
      entry.text == "2"
      and entry.x >= cell.x
      and entry.x <= cell.x + cell.width
      and entry.y >= cell.y
      and entry.y <= cell.y + cell.height
    then
      digit = true
    end
  end
  Assert.isTrue(digit, "the picked quantity renders inside the generated digit geometry")
  Assert.equal(fillCount(graphics), 0, "no generic fill covers the generated quantity layers")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.confirmation_state_draws_its_own_screen_and_prompt()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status({ state = "toss_confirm", quantity = 2, quantityMax = 5 }), plan(true), {
    icons = icons(),
  })
  local joined = joinedText(content)
  Assert.isTrue(joined:find("Toss 2 POTION?", 1, true) ~= nil, "the confirmation state formats item and quantity")
  Assert.isFalse(printedText(content, "x2"), "the confirmation state never reuses the legacy amount panel text")
  Assert.equal(fillCount(graphics), 0, "no generic fill covers the generated confirmation screen")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.quantity_and_confirmation_states_are_visually_distinct()
  local snaps = snapshotImages({
    status({ state = "toss_quantity", quantity = 2, quantityMax = 5 }),
    status({ state = "toss_confirm", quantity = 2, quantityMax = 5 }),
  }, "horizontal")
  Assert.isFalse(sameImageSet(snaps[1], snaps[2]), "quantity and confirmation composite distinct generated screens")
end

function T.move_state_communicates_the_generated_move_prompt()
  for _, mode in ipairs({ "horizontal", "vertical", "interactive_only" }) do
    local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
    local content = text()
    local draw = BagRenderer.new({
      cacheFs = seedCache(),
      manifest = manifest(),
      text = content,
      graphics = graphics,
      heroRenderer = heroSpy(nil),
    })
    local cells = {}
    for index = 1, 6 do
      cells[index] = slot("ITEM_" .. index, 1)
    end
    local record = status({ state = "move_select", visibleStart = 0, visibleSlots = cells, moveTarget = 1 })
    record.selected = slot("POTION", 5)
    draw:draw(record, plan(mode ~= "interactive_only"), { icons = icons() })
    local joined = joinedText(content)
    Assert.isTrue(joined:find("Move POTION.", 1, true) ~= nil, "the move prompt names the item in " .. mode)
    Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced in " .. mode)
    draw:release()
  end
end

function T.toss_states_communicate_their_prompts_in_every_topology()
  local cases = {
    { state = "toss_quantity", quantity = 2, expected = "Toss POTION?" },
    { state = "toss_confirm", quantity = 2, expected = "Toss 2 POTION?" },
  }
  for _, case in ipairs(cases) do
    for _, mode in ipairs({ "horizontal", "vertical", "interactive_only" }) do
      local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
      local content = text()
      local draw = BagRenderer.new({
        cacheFs = seedCache(),
        manifest = manifest(),
        text = content,
        graphics = graphics,
        heroRenderer = heroSpy(nil),
      })
      draw:draw(
        status({ state = case.state, quantity = case.quantity, quantityMax = 5 }),
        plan(mode ~= "interactive_only"),
        { icons = icons() }
      )
      local joined = joinedText(content)
      Assert.isTrue(joined:find(case.expected, 1, true) ~= nil, case.state .. " formats its prompt in " .. mode)
      Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced in " .. mode)
      draw:release()
    end
  end
end

function T.move_highlight_marks_the_target_across_a_page_boundary()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local cells = {}
  for index = 1, 6 do
    cells[index] = slot("ITEM_" .. index, 1)
  end
  local record = status({ state = "move_select", visibleStart = 2, visibleSlots = cells, moveTarget = 7 })
  draw:draw(record, plan(true), { icons = icons() })
  local highlight = false
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "line" and rectangle.x == 160 and rectangle.y == 120 then
      highlight = rectangle.w == 88 and rectangle.h == 32
    end
  end
  Assert.isFalse(highlight, "the target cell no longer uses a primitive highlight")
  Assert.equal(#graphics.rectangles, 0, "move selection uses the generated focus visual")
  local itemFocus = manifested.interactive.focus.items
  local targetX, targetY = focusOrigin(itemFocus, itemFocus.targets[6])
  Assert.isTrue(staticDrawnAt(graphics, targetX, targetY), "the move target carries the item focus visual")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

local function textInRect(content, needle, rect)
  for _, entry in ipairs(content.printed) do
    if
      entry.text == needle
      and entry.x >= rect.x
      and entry.x <= rect.x + rect.width
      and entry.y >= rect.y
      and entry.y <= rect.y + rect.height
    then
      return true
    end
  end
  return false
end

function T.nested_states_label_their_responsive_buttons()
  local buttons = manifest().interactive.overlays.actionMenu.buttons
  local function drawFor(state)
    local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
    local content = text()
    local draw = BagRenderer.new({
      cacheFs = seedCache(),
      manifest = manifest(),
      text = content,
      graphics = graphics,
      heroRenderer = heroSpy(nil),
    })
    draw:draw(status({ state = state, quantity = 2, quantityMax = 5, moveTarget = 1 }), plan(true), {
      icons = icons(),
    })
    draw:release()
    return graphics, content
  end
  local graphics, content = drawFor("toss_quantity")
  Assert.isTrue(textInRect(content, "-", buttons[1]), "the quantity state labels its decrement button")
  Assert.isTrue(textInRect(content, "+", buttons[2]), "the quantity state labels its increment button")
  Assert.isTrue(textInRect(content, "YES", buttons[3]), "the quantity state labels its confirm button")
  Assert.equal(#graphics.rectangles, 0, "nested states never fall back to primitive outlines")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  local confirmGraphics, confirmContent = drawFor("toss_confirm")
  Assert.isTrue(textInRect(confirmContent, "YES", buttons[3]), "the confirmation state labels its confirm button")
  Assert.equal(#confirmGraphics.rectangles, 0, "the confirmation state never falls back to primitive outlines")
  local moveGraphics, moveContent = drawFor("move_select")
  Assert.isTrue(textInRect(moveContent, "YES", buttons[3]), "move selection labels its confirm button")
  Assert.equal(#moveGraphics.rectangles, 0, "move selection never falls back to primitive outlines")
end

function T.release_frees_images_exactly_once()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  Assert.equal(#graphics.images, 97, "the renderer acquires every generated state, tab, focus, and marker image")
  draw:release()
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "every image releases exactly once")
  end
  draw:release()
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "a second release stays a safe no-op")
  end
end

local function heroPresentation(overrides)
  local record = status(overrides)
  record.hero = heroStatusRecord()
  return record
end
local function rendererWithHero(graphics, order)
  local spy = heroSpy(order)
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = spy,
  })
  return draw, spy
end

function T.construction_requires_the_borrowed_hero_model_renderer()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  Assert.throws(function()
    BagRenderer.new({ cacheFs = seedCache(), manifest = manifest(), text = text(), graphics = graphics })
  end, "the pane composer borrows its hero model renderer")
end

function T.hero_pane_delegates_the_model_draw_between_background_and_foreground()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local order = {}
  local originalDraw = graphics.draw
  graphics.draw = function(...)
    order[#order + 1] = "image"
    return originalDraw(...)
  end
  local draw, spy = rendererWithHero(graphics, order)
  local presentation = heroPresentation()
  local resolved = plan(true)
  draw:draw(presentation, resolved, { icons = icons() })
  Assert.equal(#spy.draws, 1, "the hero pane delegates exactly one model draw")
  Assert.equal(spy.draws[1].gender, "male", "the model draw follows the presentation gender")
  Assert.equal(spy.draws[1].status.frame, 3, "the model draw follows the semantic frame")
  local heroPlacement
  for _, pane in ipairs(resolved.panes) do
    if not pane.interactive then
      heroPlacement = pane.placement
    end
  end
  Assert.isTrue(spy.draws[1].placement == heroPlacement, "the model draw uses the hero placement")
  local heroAt = nil
  for index, entry in ipairs(order) do
    if entry == "hero" then
      heroAt = index
    end
  end
  Assert.notNil(heroAt, "the model draw composes between pane surfaces")
  Assert.isTrue(heroAt > 1, "the gender background composes beneath the model")
  Assert.isTrue(heroAt < #order, "the description foreground composes above the model")
  Assert.equal(presentation.hero.frame, 3, "the delegation never advances the semantic frame")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.single_pane_mode_never_delegates_the_model_draw()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw, spy = rendererWithHero(graphics, nil)
  draw:draw(heroPresentation(), plan(false), { icons = icons() })
  Assert.equal(#spy.draws, 0, "the single-pane mode draws no hero model")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.release_never_releases_the_borrowed_hero_model_renderer()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw, spy = rendererWithHero(graphics, nil)
  draw:release()
  draw:release()
  Assert.equal(spy.releaseCount, 0, "the borrowed collaborator stays owned by its composer")
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "the pane renderer still frees exactly its own images")
  end
end

function T.unknown_registration_slot_is_a_composition_error()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local record = status()
  record.visibleSlots[1].registrationSlot = 3
  Assert.throws(function()
    draw:draw(record, plan(true), { icons = icons() })
  end, "a registration slot outside 1, 2, or nil fails instead of borrowing a marker")
  draw:release()
end

function T.acquisition_failure_releases_every_image_acquired_before_it()
  local probe = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local bound = renderer(probe)
  local total = #probe.images
  bound:release()
  Assert.equal(total, 97, "setup binds every generated state, tab, focus, and marker image")
  for _, failCall in ipairs({ 1, total }) do
    local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES, failOnImageCall = failCall })
    Assert.throws(function()
      BagRenderer.new({
        cacheFs = seedCache(),
        manifest = manifest(),
        text = text(),
        graphics = graphics,
        heroRenderer = heroSpy(nil),
      })
    end, "an acquisition failure unwinds the images acquired before it")
    Assert.equal(#graphics.images, failCall - 1, "only the images before the failure exist")
    for _, image in ipairs(graphics.images) do
      Assert.equal(image.releaseCount, 1, "every acquired image releases exactly once")
    end
  end
end

function T.registration_markers_follow_live_service_slot_identities()
  local BagCursor = require("libs.hgss.src.items.BagCursor")
  local BagModel = require("libs.hgss.src.ui.BagModel")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local root = ItemFixture.buildAssetRoot()
  root.items.ITEM_5.selectable = true
  local catalog = ItemCatalog.new(root)
  local bag = HgssBagService.new({ catalog = catalog })
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.isTrue(bag:add("ITEM_5", 1))
  Assert.isTrue(bag:add("ITEM_23", 1), "setup stocks an unregistered key item in the same pocket")
  Assert.equal(bag:tryRegister("BICYCLE"), "slot1")
  Assert.equal(bag:tryRegister("ITEM_5"), "slot2")
  local cursor = BagCursor.new()
  cursor:setPocket("key_items")
  local view = BagModel.build(bag, cursor)
  local expectedByItem = {}
  for slotNumber, itemKey in ipairs(bag:registeredItems()) do
    expectedByItem[itemKey] = slotNumber
  end
  Assert.deepEqual(expectedByItem, { BICYCLE = 1, ITEM_5 = 2 }, "the live service orders two registrations")
  local cache = seedCache()
  cache:write("bag/registration-slot-1.png", "png-bytes")
  cache:write("bag/registration-slot-2.png", "png-bytes")
  local sizes = {}
  for _, size in ipairs(IMAGE_SIZES) do
    sizes[#sizes + 1] = size
  end
  sizes[#sizes + 1] = { 40, 16 }
  sizes[#sizes + 1] = { 40, 16 }
  local graphics = FakeGraphics({ imageSizes = sizes })
  local draw = BagRenderer.new({
    cacheFs = cache,
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local record = status({
    slots = view.slots,
    visibleSlots = view.visibleSlots,
    selected = view.selected,
    selectedAbsoluteIndex = view.selectedAbsoluteIndex,
    visibleStart = view.visibleStart,
    pocket = view.pocket,
  })
  draw:draw(record, plan(true), { icons = icons() })
  local slots = manifest().interactive.itemSlots.slots
  local offset = manifest().interactive.itemSlots.registration.offset
  local function markerAt(x, y)
    local found = {}
    for _, entry in ipairs(graphics.draws) do
      if type(entry.image) == "table" and type(entry.quad) ~= "table" then
        if entry.x == x and entry.y == y then
          found[#found + 1] = entry.image
        end
      end
    end
    return found
  end
  local firstRect = slots[1].rect
  local secondRect = slots[2].rect
  local thirdRect = slots[3].rect
  local firstMarks = markerAt(firstRect.x + offset.x, firstRect.y + offset.y)
  local secondMarks = markerAt(secondRect.x + offset.x, secondRect.y + offset.y)
  local thirdMarks = markerAt(thirdRect.x + offset.x, thirdRect.y + offset.y)
  Assert.equal(#firstMarks, 1, "the first registration draws its marker in its own cell")
  Assert.equal(#secondMarks, 1, "the second registration draws its marker in its own cell")
  Assert.isTrue(firstMarks[1] ~= secondMarks[1], "the two slots stay visually distinct")
  Assert.equal(#thirdMarks, 0, "an unregistered occupied cell draws no marker")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

-- Palette-aware text double: records plain and palette-driven calls
-- separately and carries a 16-entry field font palette with distinct colors
-- in every audited slot.
local function paletteText()
  local printed = {}
  local paletted = {}
  local palette = {}
  for index = 1, 16 do
    palette[index] = { r = (index * 37) % 256, g = (index * 91) % 256, b = (index * 53) % 256 }
  end
  local fake = {
    printed = printed,
    paletted = paletted,
    fontDef = { palette = palette },
  }
  function fake:drawText(content, x, y)
    printed[#printed + 1] = { text = content, x = x, y = y }
  end
  function fake:drawTextWithPalette(content, x, y, paletteRecord)
    paletted[#paletted + 1] = { text = content, x = x, y = y, palette = paletteRecord }
  end
  function fake:textWidth(content)
    return #content * 8
  end
  return fake
end

-- Expected palette record for zero-based field font slots, following the
-- existing renderer convention of byte-valued colors with a transparent
-- background role so generated pixels stay visible beneath glyph masks.
local function paletteRecord(content, foregroundSlot, shadowSlot)
  local entries = content.fontDef.palette
  local function byte(entry)
    return { r = entry.r, g = entry.g, b = entry.b }
  end
  local background = byte(entries[1])
  background.a = 0
  return {
    foreground = byte(entries[foregroundSlot + 1]),
    shadow = byte(entries[shadowSlot + 1]),
    background = background,
  }
end

local function palettedAt(content, needle)
  for _, entry in ipairs(content.paletted) do
    if entry.text == needle then
      return entry
    end
  end
  return nil
end

local function composedRenderer(graphics, content, reads)
  local manifested = manifest()
  local cache = reads == nil and seedCache() or trackingCache(reads)
  return BagRenderer.new({
    cacheFs = cache,
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  }),
    manifested
end

local function singlePane()
  return {
    panes = {
      {
        id = "interaction",
        placement = {
          frame = { x = 0, y = 0, width = 256, height = 192 },
          origin = { x = 0, y = 0 },
          scale = 1,
          logicalWidth = 256,
          logicalHeight = 192,
          clipRect = { x = 0, y = 0, width = 256, height = 192 },
          pixelScale = 1,
          pixelRatio = 1,
          visibleLogicalRect = { x = 0, y = 0, width = 256, height = 192 },
          crop = { left = 0, right = 0, top = 0, bottom = 0 },
        },
        interactive = true,
      },
    },
    content = {
      heroVisible = false,
      descriptionFallback = { x = 0, y = 144, width = 256, height = 48 },
      descriptionTextRect = { x = 20, y = 144, width = 236, height = 48 },
      hitTest = function()
        return nil
      end,
    },
    inputKey = "bag",
    render = function(_, _, _) end,
    mapInput = function()
      return nil
    end,
    coverage = {},
    backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
  }
end

function T.browse_selects_the_background_of_the_current_pocket()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw, manifested = composedRenderer(graphics, text(), nil)
  local itemsBackground = draw._images["background:browse:items:2"]
  local medicineBackground = draw._images["background:browse:medicine:2"]
  Assert.notNil(itemsBackground, "the items browse background is bound")
  Assert.notNil(medicineBackground, "the medicine browse background is bound")
  Assert.isTrue(itemsBackground ~= medicineBackground, "pocket variants are distinct bindings")
  draw:draw(status({ pocket = "items" }), singlePane(), { icons = icons() })
  Assert.isTrue(wasDrawn(graphics, itemsBackground), "the items pocket draws its own background")
  Assert.isFalse(wasDrawn(graphics, medicineBackground), "the items pocket never borrows the medicine background")
  for key in pairs(graphics.draws) do
    graphics.draws[key] = nil
  end
  draw:draw(status({ pocket = "medicine" }), singlePane(), { icons = icons() })
  Assert.isTrue(wasDrawn(graphics, medicineBackground), "the medicine pocket draws its own background")
  Assert.isFalse(wasDrawn(graphics, itemsBackground), "the medicine pocket never falls back to items")
  Assert.equal(manifested.interactive.backgrounds.browse.items[3].width, 256, "the pocket variant keeps pane size")
  draw:release()
end

function T.tabs_draw_at_source_anchors_with_focus_only_while_tabbed()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = text()
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local record = status({ pocket = "balls", focus = "tabs" })
  record.selected = nil
  draw:draw(record, singlePane(), { icons = icons() })
  -- Single-pane draws without selection: background, then the pocket strip,
  -- then the one tab focus visual. No item focus may appear.
  local visuals = {}
  for _, entry in ipairs(graphics.draws) do
    if type(entry.quad) ~= "table" then
      visuals[#visuals + 1] = entry
    end
  end
  Assert.equal(#visuals, 3, "one background, the pocket strip, and one tab focus are drawn")
  local tabFocus = manifested.interactive.focus.tabs
  local focusOffset = tabFocus.visual.offset or { x = 0, y = 0 }
  local target = tabFocus.targets[3]
  Assert.equal(visuals[3].x, target.x + focusOffset.x, "the tab focus applies its horizontal offset once")
  Assert.equal(visuals[3].y, target.y + focusOffset.y, "the tab focus applies its vertical offset once")
  local strip = assert(manifested.interactive.pocketTabs.strips.balls, "the balls strip is generated")
  Assert.isTrue(visuals[2].image == draw._images["strip:balls"], "the pocket strip draws at the strip origin")
  Assert.equal(visuals[2].x, 0, "the pocket strip draws at the canonical strip origin")
  Assert.equal(visuals[2].y, 0, "the pocket strip keeps the canonical strip height origin")
  Assert.equal(strip.width, 256, "the generated strip keeps the canonical strip width")
  Assert.equal(strip.height, 32, "the generated strip keeps the canonical strip height")
  Assert.equal(#graphics.rectangles, 0, "tab selection never uses a primitive outline")
  for key in pairs(graphics.draws) do
    graphics.draws[key] = nil
  end
  local unfocused = status({ pocket = "balls", focus = "items" })
  unfocused.selected = nil
  draw:draw(unfocused, singlePane(), { icons = icons() })
  Assert.equal(staticDrawCount(graphics), 3, "item focus leaves the tab row without its focus visual")
  Assert.isTrue(wasDrawn(graphics, draw._images["strip:balls"]), "item focus keeps the active pocket strip")
  Assert.isFalse(
    staticDrawnAt(graphics, target.x + focusOffset.x, target.y + focusOffset.y),
    "the tab focus follows semantic focus, not pocket identity"
  )
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.item_rows_use_split_text_geometry_with_unchanged_icons()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = paletteText()
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status({ pocket = "items" }), singlePane(), { icons = icons() })
  local first = manifested.interactive.itemSlots.slots[1]
  local iconDraw = nil
  for _, entry in ipairs(graphics.draws) do
    if type(entry.quad) == "table" and entry.quad.key == "POTION" then
      iconDraw = entry
    end
  end
  local icon = assert(iconDraw, "the occupied cell draws its icon")
  Assert.equal(icon.x, first.iconCenter.x - 16, "the icon stays centered at its source center")
  Assert.equal(icon.y, first.iconCenter.y - 16, "the icon keeps its vertical source center")
  local name = assert(palettedAt(content, "POTION"), "the item name prints through the palette path")
  Assert.equal(name.x, first.textRect.x + 0, "the name starts at the text window origin")
  Assert.equal(name.y, first.textRect.y + 0, "the name keeps the text window top")
  local quantity = assert(palettedAt(content, "x5"), "the quantity prints through the palette path")
  Assert.equal(quantity.x, first.textRect.x + 48, "the quantity uses its explicit anchor")
  Assert.equal(quantity.y, first.textRect.y + 16, "the quantity keeps its explicit vertical anchor")
  Assert.isTrue(first.rect.x + 38 ~= name.x, "the full control rect never contributes a text offset")
  local itemFocus = manifested.interactive.focus.items
  Assert.isTrue(
    icon.x ~= itemFocus.targets[1].x - 16 or icon.y ~= itemFocus.targets[1].y - 16,
    "the icon anchor never doubles as the movable focus target"
  )
  draw:release()
end

function T.item_focus_draws_the_generated_visual_at_the_visible_target()
  local reads = {}
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = trackingCache(reads),
    manifest = manifested,
    text = paletteText(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  Assert.equal(#readPathsContaining(reads, "focus"), 4, "every generated focus visual is acquired")
  -- The selection sits two pages in: absolute index 4 with window start 3
  -- must resolve to the second visible target, not the second slot rect.
  local cells = {}
  for index = 1, 6 do
    cells[index] = slot("ITEM_" .. index, 1)
  end
  draw:draw(
    status({
      pocket = "items",
      focus = "items",
      selectedAbsoluteIndex = 4,
      focusedAbsoluteIndex = 4,
      focusedVisibleIndex = 1,
      visibleStart = 3,
      visibleSlots = cells,
    }),
    plan(true),
    { icons = icons() }
  )
  local itemFocus = manifested.interactive.focus.items
  local focusX, focusY = focusOrigin(itemFocus, itemFocus.targets[2])
  Assert.isTrue(staticDrawnAt(graphics, focusX, focusY), "item focus lands on the visible window target")
  for index, target in ipairs(itemFocus.targets) do
    if index ~= 2 then
      local otherX, otherY = focusOrigin(itemFocus, target)
      Assert.isFalse(staticDrawnAt(graphics, otherX, otherY), "no stale focus remains at target " .. index)
    end
  end
  local firstRect = manifested.interactive.itemSlots.slots[1].rect
  Assert.isFalse(
    staticDrawnAt(graphics, firstRect.x + 1, firstRect.y + 1),
    "focus never insets around the full item control rect"
  )
  Assert.equal(#graphics.rectangles, 0, "item focus emits no primitive outline")
  local drawsBefore = #graphics.draws
  draw:release()
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "every owned image releases exactly once")
  end
  draw:release()
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "a second release stays a safe no-op")
  end
  Assert.equal(#graphics.draws, drawsBefore, "release draws nothing further")
end

function T.visible_strings_use_source_palette_roles()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = paletteText()
  local draw = composedRenderer(graphics, content, nil)
  draw:draw(status({ pocket = "items" }), singlePane(), { icons = icons() })
  Assert.equal(#content.printed, 0, "no audited string falls back to plain glyph output")
  local name = assert(palettedAt(content, "POTION"), "the item name prints through the palette path")
  Assert.deepEqual(name.palette, paletteRecord(content, 1, 2), "item names use the list roles")
  local quantity = assert(palettedAt(content, "x5"), "the quantity prints through the palette path")
  Assert.deepEqual(quantity.palette, paletteRecord(content, 1, 2), "quantities use the list roles")
  local page = assert(palettedAt(content, "1/1"), "the page indicator prints through the palette path")
  Assert.deepEqual(page.palette, paletteRecord(content, 15, 1), "the page indicator uses its source roles")
  local description =
    assert(palettedAt(content, "POTION description"), "the description prints through the palette path")
  Assert.deepEqual(description.palette, paletteRecord(content, 15, 14), "descriptions use the window roles")
  local cancel = assert(palettedAt(content, "BACK OUT"), "Cancel prints through the palette path")
  Assert.deepEqual(cancel.palette, paletteRecord(content, 15, 14), "Cancel uses the window roles")
  Assert.equal(description.palette.background.a, 0, "glyph backgrounds stay transparent over source pixels")
  draw:release()
end

function T.cancel_uses_background_chrome_and_its_text_window()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = paletteText()
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status({ pocket = "items" }), plan(true), { icons = icons() })
  Assert.equal(#graphics.rectangles, 0, "unfocused Cancel emits no primitive chrome")
  local cancelFocus = manifested.interactive.focus.cancel
  local unfocusedX, unfocusedY = focusOrigin(cancelFocus)
  Assert.isFalse(staticDrawnAt(graphics, unfocusedX, unfocusedY), "unfocused Cancel draws no focus visual")
  for key in pairs(graphics.draws) do
    graphics.draws[key] = nil
  end
  draw:draw(status({ pocket = "items", focus = "cancel" }), plan(true), { icons = icons() })
  Assert.isTrue(staticDrawnAt(graphics, unfocusedX, unfocusedY), "Cancel focus lands on its generated target")
  Assert.equal(#graphics.rectangles, 0, "focused Cancel emits no primitive outline")
  local cancel = manifested.interactive.cancel
  local label = assert(palettedAt(content, "BACK OUT"), "Cancel prints through the palette path")
  local width = content:textWidth("BACK OUT")
  Assert.equal(
    label.x,
    cancel.labelRect.x + (cancel.labelRect.width - width) / 2,
    "the Cancel label centers inside its source label area"
  )
  Assert.equal(label.y, cancel.labelRect.y, "the Cancel label keeps the source text-window top")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

-- Six visible cells with a contiguous occupied prefix of the given length;
-- retail Bag rows never interleave empty cells between occupied ones.
local function occupiedCells(count)
  local cells = {}
  for index = 1, 6 do
    if index <= count then
      cells[index] = slot("ITEM_" .. index, 1)
    else
      cells[index] = { empty = true, visibleIndex = index - 1 }
    end
  end
  return cells
end

function T.browse_background_follows_the_visible_occupied_count()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  for _, count in ipairs({ 0, 3, 6 }) do
    for key in pairs(graphics.draws) do
      graphics.draws[key] = nil
    end
    local record = status({ pocket = "items", visibleSlots = occupiedCells(count) })
    if count == 0 then
      record.selected = nil
    else
      record.selected = record.visibleSlots[1]
    end
    draw:draw(record, plan(true), { icons = icons() })
    local expected = draw._images["background:browse:items:" .. count]
    Assert.notNil(expected, "the count " .. count .. " browse variant is bound")
    Assert.isTrue(wasDrawn(graphics, expected), "the visible count " .. count .. " draws its own background")
    for _, other in ipairs({ 0, 1, 2, 3, 4, 5, 6 }) do
      if other ~= count then
        Assert.isFalse(
          wasDrawn(graphics, draw._images["background:browse:items:" .. other]),
          "the visible count " .. count .. " never borrows count " .. other
        )
      end
    end
  end
  local mixed = occupiedCells(3)
  mixed[2] = { empty = true, visibleIndex = 1 }
  mixed[3] = slot("ITEM_3", 1)
  Assert.throws(function()
    draw:draw(status({ pocket = "items", visibleSlots = mixed }), plan(true), { icons = icons() })
  end, "a non-contiguous visible window fails instead of guessing a count")
  Assert.equal(#graphics.rectangles, 0, "count chrome never falls back to primitive outlines")
  draw:release()
end

function T.tab_focus_draws_after_the_selected_strip()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local record = status({ pocket = "balls", focus = "tabs" })
  record.selected = nil
  draw:draw(record, singlePane(), { icons = icons() })
  local function drawIndex(image)
    for position, entry in ipairs(graphics.draws) do
      if entry.image == image then
        return position
      end
    end
    return nil
  end
  local focusAt = assert(drawIndex(draw._images["focus:tabs"]), "the tab focus draws while tabs are focused")
  local stripAt = assert(drawIndex(draw._images["strip:balls"]), "the pocket strip draws while tabs are focused")
  Assert.isTrue(stripAt < focusAt, "the foreground cursor draws after the pocket strip")
  Assert.equal(#graphics.rectangles, 0, "tab focus never falls back to primitive outlines")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.cancel_label_centers_inside_its_source_label_area()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = paletteText()
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status({ pocket = "items" }), plan(true), { icons = icons() })
  local label = assert(palettedAt(content, "BACK OUT"), "Cancel prints through the palette path")
  local width = content:textWidth("BACK OUT")
  local area = manifested.interactive.cancel.labelRect
  Assert.equal(label.x, area.x + (area.width - width) / 2, "the Cancel label centers inside its source label area")
  Assert.equal(label.y, area.y, "the Cancel label keeps the source text-window top")
  Assert.deepEqual(label.palette, paletteRecord(content, 15, 14), "Cancel uses the description window roles")
  Assert.equal(#graphics.rectangles, 0, "Cancel emits no primitive button face")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.browse_background_selects_each_partial_count()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  for _, count in ipairs({ 1, 2, 4, 5 }) do
    for key in pairs(graphics.draws) do
      graphics.draws[key] = nil
    end
    local record = status({ pocket = "balls", visibleSlots = occupiedCells(count) })
    record.selected = record.visibleSlots[1]
    draw:draw(record, plan(true), { icons = icons() })
    local expected = draw._images["background:browse:balls:" .. count]
    Assert.notNil(expected, "the count " .. count .. " browse variant is bound")
    Assert.isTrue(wasDrawn(graphics, expected), "the visible count " .. count .. " draws its own background")
    Assert.isFalse(
      wasDrawn(graphics, draw._images["background:browse:balls:" .. (count + 1)]),
      "the visible count " .. count .. " never borrows its neighbor variant"
    )
  end
  Assert.equal(#graphics.rectangles, 0, "count chrome never falls back to primitive outlines")
  draw:release()
end

function T.leading_empty_cell_fails_the_visible_count()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local cells = occupiedCells(0)
  cells[2] = slot("ITEM_2", 1)
  Assert.throws(function()
    draw:draw(status({ pocket = "items", visibleSlots = cells }), plan(true), { icons = icons() })
  end, "an empty first cell with occupied cells behind it fails instead of guessing a count")
  draw:release()
end

function T.normal_tab_draws_match_with_and_without_focus()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local function stripDraws(focus)
    for key in pairs(graphics.draws) do
      graphics.draws[key] = nil
    end
    local record = status({ pocket = "balls", focus = focus })
    record.selected = nil
    draw:draw(record, singlePane(), { icons = icons() })
    local found = {}
    for _, entry in ipairs(graphics.draws) do
      if entry.image == draw._images["strip:balls"] then
        found[#found + 1] = { quad = entry.quad, x = entry.x }
      end
    end
    return found
  end
  local focused = stripDraws("tabs")
  local unfocused = stripDraws("items")
  Assert.equal(#focused, 1, "the focused render draws the pocket strip once")
  Assert.equal(#unfocused, 1, "the unfocused render draws the pocket strip once")
  Assert.equal(focused[1].quad, unfocused[1].quad, "the pocket strip keeps its draw position")
  Assert.equal(focused[1].x, unfocused[1].x, "the pocket strip keeps its draw height")
  Assert.equal(#graphics.rectangles, 0, "tab focus never falls back to primitive outlines")
  draw:release()
end

function T.cancel_focus_draws_after_the_normal_tab_row()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status({ pocket = "items", focus = "cancel" }), singlePane(), { icons = icons() })
  local function drawIndex(image)
    for position, entry in ipairs(graphics.draws) do
      if entry.image == image then
        return position
      end
    end
    return nil
  end
  local cancelAt = assert(drawIndex(draw._images["focus:cancel"]), "Cancel focus draws while cancel is focused")
  local stripAt = assert(drawIndex(draw._images["strip:items"]), "the pocket strip draws while cancel is focused")
  Assert.isTrue(stripAt < cancelAt, "Cancel focus stays above the pocket strip")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

local STRIP_POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local function stripManifest()
  local manifested = manifest()
  local strips = {}
  for _, pocket in ipairs(STRIP_POCKETS) do
    strips[pocket] = { image = "bag/strip-" .. pocket .. ".png", width = 256, height = 32 }
  end
  manifested.interactive.pocketTabs = { rects = manifested.interactive.pocketTabs.rects, strips = strips }
  return manifested
end

local function seedStripCache()
  local cache = seedCache()
  for _, pocket in ipairs(STRIP_POCKETS) do
    cache:write("bag/strip-" .. pocket .. ".png", "png-bytes")
  end
  return cache
end

local function trackingStripCache(reads)
  local cache = seedStripCache()
  local wrapped = {}
  function wrapped:read(path)
    reads[#reads + 1] = path
    return cache:read(path)
  end
  function wrapped:write(path, data)
    return cache:write(path, data)
  end
  return wrapped
end

local function drawCount(graphics, image)
  local count = 0
  for _, entry in ipairs(graphics.draws) do
    if entry.image == image then
      count = count + 1
    end
  end
  return count
end

function T.browse_draws_the_committed_strip_before_tab_focus()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local reads = {}
  local manifested = stripManifest()
  local draw = BagRenderer.new({
    cacheFs = trackingStripCache(reads),
    manifest = manifested,
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local stripReads = readPathsContaining(reads, "strip-")
  table.sort(stripReads)
  local expectedStrips = {}
  for _, pocket in ipairs(STRIP_POCKETS) do
    expectedStrips[#expectedStrips + 1] = "bag/strip-" .. pocket .. ".png"
  end
  table.sort(expectedStrips)
  Assert.deepEqual(stripReads, expectedStrips, "construction binds every pocket strip exactly once")
  Assert.equal(#readPathsContaining(reads, "tab-normal-"), 0, "no retired per-tab normal visual is ever acquired")
  for key in pairs(draw._images) do
    Assert.isNil(key:find("tabNormal:", 1, true), "no retired per-tab normal binding survives: " .. key)
  end
  local function drawIndex(image)
    for position, entry in ipairs(graphics.draws) do
      if entry.image == image then
        return position
      end
    end
    return nil
  end
  local unfocused = status({ pocket = "balls", focus = "items" })
  unfocused.selected = nil
  draw:draw(unfocused, singlePane(), { icons = icons() })
  local ballsStrip = assert(draw._images["strip:balls"], "the balls strip is bound")
  Assert.equal(drawCount(graphics, ballsStrip), 1, "the current pocket strip draws exactly once per frame")
  Assert.isNil(drawIndex(draw._images["focus:tabs"]), "item focus draws no tab focus visual")
  for _, pocket in ipairs(STRIP_POCKETS) do
    if pocket ~= "balls" then
      Assert.isNil(drawIndex(draw._images["strip:" .. pocket]), "the unfocused pocket strip never draws")
    end
  end
  for key in pairs(graphics.draws) do
    graphics.draws[key] = nil
  end
  local focused = status({ pocket = "balls", focus = "tabs" })
  focused.selected = nil
  draw:draw(focused, singlePane(), { icons = icons() })
  local focusAt = assert(drawIndex(draw._images["focus:tabs"]), "the tab focus draws while tabs are focused")
  local stripAt = assert(drawIndex(ballsStrip), "the current pocket strip draws while tabs are focused")
  Assert.isTrue(stripAt < focusAt, "the foreground cursor draws after the pocket strip")
  Assert.equal(drawCount(graphics, ballsStrip), 1, "the focused frame still draws the strip exactly once")
  for key in pairs(graphics.draws) do
    graphics.draws[key] = nil
  end
  local switched = status({ pocket = "medicine", focus = "items" })
  switched.selected = nil
  draw:draw(switched, singlePane(), { icons = icons() })
  local medicineStrip = assert(draw._images["strip:medicine"], "the medicine strip is bound")
  Assert.equal(drawCount(graphics, medicineStrip), 1, "the switched pocket draws its own strip")
  Assert.isNil(drawIndex(ballsStrip), "the switched pocket never borrows the previous strip")
  Assert.equal(#graphics.rectangles, 0, "strip composition never falls back to primitive outlines")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "every owned image releases exactly once")
  end
end

function T.tabbed_strip_and_focus_resolve_from_separate_pockets()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local record = status({ pocket = "balls", focus = "tabs", tabFocusPocket = "medicine" })
  draw:draw(record, singlePane(), { icons = icons() })
  local ballsStrip = assert(draw._images["strip:balls"], "the committed pocket strip is bound")
  Assert.isTrue(wasDrawn(graphics, ballsStrip), "the committed pocket draws its own strip")
  for _, pocket in ipairs({ "items", "medicine", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
    Assert.isFalse(
      wasDrawn(graphics, draw._images["strip:" .. pocket]),
      "the committed strip never borrows the " .. pocket .. " strip"
    )
  end
  local tabFocus = manifested.interactive.focus.tabs
  local offset = tabFocus.visual.offset or { x = 0, y = 0 }
  local medicineTarget = assert(tabFocus.targets[2], "the candidate resolves its generated target")
  local ballsTarget = assert(tabFocus.targets[3], "the committed pocket resolves its generated target")
  local medicineX, medicineY = medicineTarget.x + offset.x, medicineTarget.y + offset.y
  local ballsX, ballsY = ballsTarget.x + offset.x, ballsTarget.y + offset.y
  Assert.isTrue(staticDrawnAt(graphics, medicineX, medicineY), "the tab focus follows the candidate target")
  Assert.isFalse(staticDrawnAt(graphics, ballsX, ballsY), "the tab focus never aliases the committed pocket")
  local function drawIndex(image)
    for position, entry in ipairs(graphics.draws) do
      if entry.image == image then
        return position
      end
    end
    return nil
  end
  local stripAt = assert(drawIndex(ballsStrip), "the committed strip draws while tabs are focused")
  local focusAt = assert(drawIndex(draw._images["focus:tabs"]), "the tab focus draws while tabs are focused")
  Assert.isTrue(stripAt < focusAt, "the foreground cursor draws after the pocket strip")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

function T.empty_focused_cell_draws_the_normal_item_focus_visual()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  local manifested = manifest()
  local cells = { slot("POTION", 5) }
  for index = 2, 6 do
    cells[index] = { empty = true, visibleIndex = index - 1 }
  end
  local presentation = status({
    pocket = "balls",
    slots = { slot("POTION", 5) },
    visibleSlots = cells,
    visibleStart = 0,
  })
  presentation.selected = nil
  presentation.selectedAbsoluteIndex = nil
  presentation.focusedAbsoluteIndex = 1
  presentation.focusedVisibleIndex = 1
  draw:draw(presentation, plan(true), { icons = icons() })
  local itemFocus = manifested.interactive.focus.items
  local focusX, focusY = focusOrigin(itemFocus, itemFocus.targets[2])
  Assert.isTrue(staticDrawnAt(graphics, focusX, focusY), "an empty focused cell draws the normal focus visual")
  for index, target in ipairs(itemFocus.targets) do
    if index ~= 2 then
      local otherX, otherY = focusOrigin(itemFocus, target)
      Assert.isFalse(staticDrawnAt(graphics, otherX, otherY), "no stale focus remains at target " .. index)
    end
  end
  Assert.equal(#graphics.rectangles, 0, "empty focus emits no primitive outline")
  draw:release()
end

function T.empty_pocket_focus_draws_on_the_first_cell_without_icons()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  local manifested = manifest()
  local cells = {}
  for index = 1, 6 do
    cells[index] = { empty = true, visibleIndex = index - 1 }
  end
  local presentation = status({ pocket = "items", slots = {}, visibleSlots = cells, visibleStart = 0 })
  presentation.selected = nil
  presentation.selectedAbsoluteIndex = nil
  presentation.focusedAbsoluteIndex = 0
  presentation.focusedVisibleIndex = 0
  draw:draw(presentation, plan(true), { icons = icons() })
  local itemFocus = manifested.interactive.focus.items
  local focusX, focusY = focusOrigin(itemFocus, itemFocus.targets[1])
  Assert.isTrue(staticDrawnAt(graphics, focusX, focusY), "the first empty cell draws the normal focus visual")
  draw:release()
end

-- Compact lower-only browsing shows the selected description through the
-- source Bag description frame and the generated fallback text rectangle,
-- with room for three 16 px lines. No invented fill/border may replace
-- the source art.
local function compactPlan(manifested)
  local fallback =
    assert(manifested.interactive.overlays.descriptionFallback, "the compact plan needs its generated fallback")
  local frame = assert(fallback.frame, "the compact plan needs its fallback frame")
  local textRect = assert(fallback.textRect, "the compact plan needs its fallback text rectangle")
  return {
    panes = {
      {
        id = "interaction",
        placement = placement(),
        interactive = true,
      },
    },
    content = {
      heroVisible = false,
      descriptionFallback = { x = frame.x, y = frame.y, width = frame.width, height = frame.height },
      descriptionTextRect = { x = textRect.x, y = textRect.y, width = textRect.width, height = textRect.height },
      hitTest = function()
        return nil
      end,
    },
    inputKey = "bag",
    render = function(_, _, _) end,
    mapInput = function()
      return nil
    end,
    coverage = {},
    backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
  }
end

local function threeLineSelection()
  local selected = slot("POTION", 5)
  selected.description = "first line\nsecond line\nthird line"
  return selected
end

function T.compact_browsing_description_uses_source_frame_and_three_lines()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local content = paletteText()
  local manifested = manifest()
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  local selected = threeLineSelection()
  local record = status({ state = "browsing", focus = "items", selected = selected })
  draw:draw(record, compactPlan(manifested), { icons = icons() })
  local frame = assert(draw._images["descriptionFrame"], "the source description frame is bound")
  Assert.isTrue(wasDrawn(graphics, frame), "the compact description draws the source frame visual")
  Assert.equal(#graphics.rectangles, 0, "the compact description never invents a fill/border rectangle")
  local textRect = manifested.interactive.overlays.descriptionFallback.textRect
  local first = assert(palettedAt(content, "first line"), "the first description line prints")
  local second = assert(palettedAt(content, "second line"), "the second description line prints")
  local third = assert(palettedAt(content, "third line"), "the third description line keeps its 16 px row")
  Assert.equal(first.x, textRect.x, "the first line starts at the generated text rectangle")
  Assert.equal(first.y, textRect.y, "the first line keeps the generated text top")
  Assert.equal(second.x, textRect.x, "the second line starts at the generated text rectangle")
  Assert.equal(second.y, textRect.y + 16, "the second line keeps its 16 px row")
  Assert.equal(third.x, textRect.x, "the third line starts at the generated text rectangle")
  Assert.equal(third.y, textRect.y + 32, "the third line keeps its 16 px row")
  Assert.deepEqual(third.palette, paletteRecord(content, 15, 14), "the third line uses the window roles")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  draw:release()
end

-- Ordinary compact descriptions follow item-grid focus ownership while
-- state-owned move/toss prompts keep their own visibility: tab/Cancel
-- focus hides the selected description, but prompt states still render.
function T.compact_browsing_description_follows_item_focus_while_prompts_persist()
  local manifested = manifest()
  local selected = threeLineSelection()
  local function drawWith(presentationRecord)
    local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
    local content = paletteText()
    local draw = BagRenderer.new({
      cacheFs = seedCache(),
      manifest = manifested,
      text = content,
      graphics = graphics,
      heroRenderer = heroSpy(nil),
    })
    draw:draw(presentationRecord, compactPlan(manifested), { icons = icons() })
    return graphics, content, draw
  end
  local function descriptionDrawn(content, graphics, draw)
    local frame = assert(draw._images["descriptionFrame"], "the source description frame is bound")
    return wasDrawn(graphics, frame) or palettedAt(content, "first line") ~= nil
  end
  do
    local graphics, content, draw = drawWith(status({ state = "browsing", focus = "tabs", selected = selected }))
    Assert.isFalse(descriptionDrawn(content, graphics, draw), "tab focus hides the ordinary compact description")
    Assert.equal(#graphics.rectangles, 0, "hidden descriptions leave no invented rectangle")
    draw:release()
  end
  do
    local graphics, content, draw = drawWith(status({ state = "browsing", focus = "cancel", selected = selected }))
    Assert.isFalse(descriptionDrawn(content, graphics, draw), "cancel focus hides the ordinary compact description")
    Assert.equal(#graphics.rectangles, 0, "hidden descriptions leave no invented rectangle")
    draw:release()
  end
  do
    local graphics, content, draw =
      drawWith(status({ state = "move_select", focus = "tabs", selected = selected, moveTarget = 1, visibleStart = 0 }))
    local joined = {}
    for _, entry in ipairs(content.paletted) do
      joined[#joined + 1] = entry.text
    end
    Assert.isTrue(
      table.concat(joined, "\n"):find("Move POTION.", 1, true) ~= nil,
      "the move prompt stays visible while item focus is elsewhere"
    )
    Assert.isTrue(
      wasDrawn(graphics, assert(draw._images["descriptionFrame"])),
      "the move prompt keeps the source frame"
    )
    draw:release()
  end
  do
    local graphics, content, draw =
      drawWith(status({ state = "toss_quantity", focus = "items", selected = selected, quantity = 2, quantityMax = 5 }))
    local joined = {}
    for _, entry in ipairs(content.paletted) do
      joined[#joined + 1] = entry.text
    end
    Assert.isTrue(
      table.concat(joined, "\n"):find("Toss POTION?", 1, true) ~= nil,
      "the toss prompt stays visible in its own state"
    )
    Assert.isTrue(
      wasDrawn(graphics, assert(draw._images["descriptionFrame"])),
      "the toss prompt keeps the source frame"
    )
    draw:release()
  end
  do
    local graphics, content, draw = drawWith(status({
      state = "toss_confirm",
      focus = "items",
      selected = selected,
      quantity = 2,
      quantityMax = 5,
    }))
    local joined = {}
    for _, entry in ipairs(content.paletted) do
      joined[#joined + 1] = entry.text
    end
    Assert.isTrue(
      table.concat(joined, "\n"):find("Toss 2 POTION?", 1, true) ~= nil,
      "the toss confirmation keeps item and quantity"
    )
    draw:release()
  end
end

return { tests = T }
