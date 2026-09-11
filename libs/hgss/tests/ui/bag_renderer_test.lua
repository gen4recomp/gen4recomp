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
  local slots = {}
  local rects = {
    { 32, 40 },
    { 160, 40 },
    { 32, 80 },
    { 160, 80 },
    { 32, 120 },
    { 160, 120 },
  }
  for index, origin in ipairs(rects) do
    slots[index] = {
      rect = { x = origin[1], y = origin[2], width = 88, height = 32 },
      iconCenter = { x = origin[1] + 16, y = origin[2] + 16 },
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
      backgrounds = {
        browse = { image = "bag/background-browse.png", width = 256, height = 192 },
        action = { image = "bag/background-action.png", width = 256, height = 192 },
        quantity = { image = "bag/background-quantity.png", width = 256, height = 192 },
        confirmation = { image = "bag/background-confirmation.png", width = 256, height = 192 },
      },
      pocketTabs = {
        rects = tabs,
        normal = {
          { image = "bag/tab-normal-1.png", width = 16, height = 16 },
          { image = "bag/tab-normal-2.png", width = 16, height = 16 },
          { image = "bag/tab-normal-3.png", width = 16, height = 16 },
          { image = "bag/tab-normal-4.png", width = 16, height = 16 },
          { image = "bag/tab-normal-5.png", width = 16, height = 16 },
          { image = "bag/tab-normal-6.png", width = 16, height = 16 },
          { image = "bag/tab-normal-7.png", width = 16, height = 16 },
          { image = "bag/tab-normal-8.png", width = 16, height = 16 },
        },
        selected = { image = "bag/tab-selected.png", width = 16, height = 16 },
      },
      itemSlots = {
        slots = slots,
        focus = { image = "bag/focus.png", width = 16, height = 16 },
        registration = {
          slot1 = { image = "bag/registration-slot-1.png", width = 40, height = 16 },
          slot2 = { image = "bag/registration-slot-2.png", width = 40, height = 16 },
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = { x = 192, y = 168, width = 56, height = 16 },
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
      widgets = {
        sourceStrip = {
          image = "bag/source-strip.png",
          width = 32,
          height = 16,
          placement = { x = 177, y = 14 },
          states = { browsing = false },
        },
      },
    },
  }
end

local function seedCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for _, path in ipairs({
    "bag/hero-male.png",
    "bag/hero-female.png",
    "bag/description.png",
    "bag/background-browse.png",
    "bag/background-action.png",
    "bag/background-quantity.png",
    "bag/background-confirmation.png",
    "bag/tab-normal-1.png",
    "bag/tab-normal-2.png",
    "bag/tab-normal-3.png",
    "bag/tab-normal-4.png",
    "bag/tab-normal-5.png",
    "bag/tab-normal-6.png",
    "bag/tab-normal-7.png",
    "bag/tab-normal-8.png",
    "bag/tab-selected.png",
    "bag/focus.png",
    "bag/source-strip.png",
    "bag/registration-slot-1.png",
    "bag/registration-slot-2.png",
  }) do
    cache:write(path, "png-bytes")
  end
  return cache
end

local function text()
  local printed = {}
  return {
    printed = printed,
    drawText = function(_, content, x, y)
      printed[#printed + 1] = { text = content, x = x, y = y }
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
    pocketName = "Balls",
    pockets = pockets(),
    slots = { slot("POTION", 5), slot("POKE_BALL", 3) },
    selectedAbsoluteIndex = 0,
    visibleStart = 0,
    visibleSlots = visibleSlots(),
    page = { current = 1, count = 1 },
    selected = slot("POTION", 5),
    heroGender = "male",
    hero = heroStatusRecord(),
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function layout(mode)
  local hero = nil
  if mode ~= "interactive_only" then
    hero = { frame = { x = 0, y = 0, width = 512, height = 384 }, scale = 2, logicalWidth = 256, logicalHeight = 192 }
  end
  return {
    mode = mode,
    hero = hero,
    interactive = {
      frame = { x = 0, y = 0, width = 512, height = 384 },
      scale = 2,
      logicalWidth = 256,
      logicalHeight = 192,
    },
    descriptionFallback = mode == "interactive_only" and { x = 0, y = 144, width = 256, height = 48 } or nil,
    interactiveHitTest = function()
      return nil
    end,
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

function T.closed_status_draws_nothing()
  local graphics = FakeGraphics({ color = { 0.2, 0.3, 0.4, 1 }, imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  draw:draw({ open = false }, layout("horizontal"), { icons = icons() })
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
  draw:draw(status(), layout("horizontal"), { icons = icons() })
  Assert.isTrue(#graphics.draws >= 8, "both panes compose backgrounds, tabs, icons, and cursors")
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

function T.semantic_v3_visuals_drive_tabs_focus_strip_and_state_backgrounds()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local calls = { quadFor = 0, dimensions = 0, keys = {} }
  local draw = BagRenderer.new({
    cacheFs = seedCache(),
    manifest = manifest(),
    text = text(),
    graphics = graphics,
    heroRenderer = heroSpy(nil),
  })
  draw:draw(status(), layout("horizontal"), { icons = icons(calls) })
  for index = 1, 8 do
    Assert.isTrue(wasDrawn(graphics, draw._images["tabNormal:" .. index]), "every normal tab visual is drawn")
  end
  Assert.isTrue(wasDrawn(graphics, draw._images.tabSelected), "the selected pocket visual is drawn")
  Assert.isTrue(wasDrawn(graphics, draw._images.sourceStrip), "the source strip visual is drawn")
  Assert.isTrue(wasDrawn(graphics, draw._images.focus), "the item focus visual is drawn")
  Assert.isTrue(wasDrawn(graphics, draw._images["background:browse"]), "browse uses one semantic background")
  Assert.equal(#graphics.rectangles, 0, "browse focus is not a primitive rectangle")
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
    draw:draw(record, layout("horizontal"), { icons = icons() })
    local key = state == "action_menu" and "action"
      or state == "toss_quantity" and "quantity"
      or state == "toss_confirm" and "confirmation"
      or "browse"
    Assert.isTrue(wasDrawn(graphics, draw._images["background:" .. key]), state .. " selects its semantic background")
  end
  draw:release()
end

function T.graphics_state_is_restored_after_semantic_draw()
  local graphics =
    FakeGraphics({ color = { 0.2, 0.3, 0.4, 1 }, scissor = { 1, 2, 300, 180 }, imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  draw:draw(status(), layout("horizontal"), { icons = icons() })
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
    draw:draw(record, layout("horizontal"), { icons = icons() })
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
  draw:draw(
    status({ slots = {}, visibleSlots = cells, selected = nil, selectedAbsoluteIndex = 0 }),
    layout("horizontal"),
    { icons = icons() }
  )
  for _, entry in ipairs(graphics.draws) do
    local quad = entry.quad
    Assert.isTrue(type(quad) ~= "table" or quad.key == nil, "empty cells draw no item icons")
  end
  Assert.isTrue(printedText(content, "BACK OUT"), "empty pockets keep the generated cancel affordance")
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
  draw:draw(status({ state = "description_overlay" }), layout("interactive_only"), { icons = icons() })
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
    draw:draw(record, layout(mode), { icons = icons() })
    snaps[#snaps + 1] = stateImages(graphics)
  end
  draw:release()
  return snaps
end

function T.action_menu_draws_generated_labels_and_never_raw_ids()
  for _, mode in ipairs({ "horizontal", "vertical" }) do
    local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
    local content = text()
    local draw = BagRenderer.new({
      cacheFs = seedCache(),
      manifest = manifest(),
      text = content,
      graphics = graphics,
      heroRenderer = heroSpy(nil),
    })
    draw:draw(actionStatus(), layout(mode), { icons = icons() })
    Assert.isTrue(printedText(content, "TRASH"), "the menu labels its toss action in " .. mode)
    Assert.isTrue(printedText(content, "MOVE"), "the menu labels its move action in " .. mode)
    Assert.isTrue(printedText(content, "BACK OUT"), "the menu labels its way out in " .. mode)
    Assert.isFalse(printedText(content, "toss"), "the raw toss id never reaches the screen in " .. mode)
    Assert.isFalse(printedText(content, "move"), "the raw move id never reaches the screen in " .. mode)
    Assert.isFalse(printedText(content, "cancel"), "the raw cancel id never reaches the screen in " .. mode)
    Assert.equal(#graphics.rectangles, 0, "source focus replaces generic menu frames in " .. mode)
    Assert.equal(fillCount(graphics), 0, "no generic fill covers the generated action screen in " .. mode)
    Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced in " .. mode)
    draw:release()
  end
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
    draw:draw(record, layout("horizontal"), { icons = icons() })
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
    draw:draw(actionStatus(), layout("horizontal"), { icons = icons() })
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
    draw:draw(actionStatus(), layout("horizontal"), { icons = icons() })
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
  draw:draw(status({ state = "toss_quantity", quantity = 2, quantityMax = 5 }), layout("vertical"), {
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
  draw:draw(status({ state = "toss_confirm", quantity = 2, quantityMax = 5 }), layout("vertical"), {
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
    draw:draw(record, layout(mode), { icons = icons() })
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
        layout(mode),
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
  local record = status({ state = "move_select", visibleStart = 2, visibleSlots = cells, moveTarget = 7 })
  draw:draw(record, layout("horizontal"), { icons = icons() })
  local highlight = false
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.mode == "line" and rectangle.x == 160 and rectangle.y == 120 then
      highlight = rectangle.w == 88 and rectangle.h == 32
    end
  end
  Assert.isFalse(highlight, "the target cell no longer uses a primitive highlight")
  Assert.equal(#graphics.rectangles, 0, "move selection uses the generated focus visual")
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
    draw:draw(status({ state = state, quantity = 2, quantityMax = 5, moveTarget = 1 }), layout("horizontal"), {
      icons = icons(),
    })
    draw:release()
    return graphics, content
  end
  local graphics, content = drawFor("toss_quantity")
  Assert.isTrue(textInRect(content, "-", buttons[1]), "the quantity state labels its decrement button")
  Assert.isTrue(textInRect(content, "+", buttons[2]), "the quantity state labels its increment button")
  Assert.isTrue(textInRect(content, "YES", buttons[3]), "the quantity state labels its confirm button")
  Assert.equal(#graphics.rectangles, 0, "quantity affordances use source presentation")
  Assert.equal(graphics.pushDepth(), 0, "the transform stack stays balanced")
  local confirmGraphics, confirmContent = drawFor("toss_confirm")
  Assert.isTrue(textInRect(confirmContent, "YES", buttons[3]), "the confirmation state labels its confirm button")
  Assert.equal(#confirmGraphics.rectangles, 0, "confirmation affordance uses source presentation")
  local moveGraphics, moveContent = drawFor("move_select")
  Assert.isTrue(textInRect(moveContent, "YES", buttons[3]), "move selection labels its confirm button")
  Assert.equal(#moveGraphics.rectangles, 0, "move confirm affordance uses source presentation")
end

function T.release_frees_images_exactly_once()
  local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES })
  local draw = renderer(graphics)
  Assert.isTrue(#graphics.images >= 20, "the renderer acquires every generated state image")
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
  local resolved = layout("horizontal")
  draw:draw(presentation, resolved, { icons = icons() })
  Assert.equal(#spy.draws, 1, "the hero pane delegates exactly one model draw")
  Assert.equal(spy.draws[1].gender, "male", "the model draw follows the presentation gender")
  Assert.equal(spy.draws[1].status.frame, 3, "the model draw follows the semantic frame")
  Assert.isTrue(spy.draws[1].placement == resolved.hero, "the model draw uses the hero placement")
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
  draw:draw(heroPresentation(), layout("interactive_only"), { icons = icons() })
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
    draw:draw(record, layout("horizontal"), { icons = icons() })
  end, "a registration slot outside 1, 2, or nil fails instead of borrowing a marker")
  draw:release()
end

function T.marker_acquisition_failure_releases_acquired_images_once()
  for _, failCall in ipairs({ 19, 20 }) do
    local graphics = FakeGraphics({ imageSizes = IMAGE_SIZES, failOnImageCall = failCall })
    Assert.throws(function()
      BagRenderer.new({
        cacheFs = seedCache(),
        manifest = manifest(),
        text = text(),
        graphics = graphics,
        heroRenderer = heroSpy(nil),
      })
    end, "a marker acquisition failure unwinds the images acquired before it")
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
  draw:draw(record, layout("horizontal"), { icons = icons() })
  local slots = manifest().interactive.itemSlots.slots
  local offset = manifest().interactive.itemSlots.registration.offset
  local function markerAt(x, y)
    local found = {}
    for _, entry in ipairs(graphics.draws) do
      if type(entry.image) == "table" and type(entry.quad) ~= "table" then
        if entry.quad == x and entry.x == y then
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

return { tests = T }
