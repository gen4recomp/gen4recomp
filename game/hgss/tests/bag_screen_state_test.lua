-- Concrete field-bag application: the per-launch state the field
-- application host steps while the bag owns the tick. Covers the host
-- result contract, layout in status, resize capture cancellation with
-- preserved semantic selection, hero animation cadence, one-shot close,
-- idempotent disposal, and construction errors for missing capabilities.
-- Real inventory service, cursor, model, controller, layout, and hero
-- presenter; only the viewport/topology measurement is injected.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagScreenState = require("game.hgss.src.field.BagScreenState")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local function manifest()
  local tabs = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
  end
  local slots = {}
  local shapes = {
    { { 0, 32, 128, 42 }, { 48, 56 } },
    { { 128, 32, 128, 42 }, { 176, 56 } },
    { { 0, 74, 128, 44 }, { 48, 96 } },
    { { 128, 74, 128, 44 }, { 176, 96 } },
    { { 0, 118, 128, 36 }, { 48, 136 } },
    { { 128, 118, 128, 36 }, { 176, 136 } },
  }
  for index, shape in ipairs(shapes) do
    slots[index] = {
      rect = { x = shape[1][1], y = shape[1][2], width = shape[1][3], height = shape[1][4] },
      iconCenter = { x = shape[2][1], y = shape[2][2] },
    }
  end
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] =
      { pocket = pocket, pose = "pocket." .. pocket .. ".pose", pattern = "pocket." .. pocket .. ".pattern" }
  end
  return {
    hero = {
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
    },
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = {
        rect = { x = 192, y = 168, width = 64, height = 24 },
        textRect = { x = 192, y = 168, width = 56, height = 16 },
      },
      overlays = {
        descriptionFallback = { frame = { x = 0, y = 144, width = 256, height = 48 } },
        actionMenu = {
          buttons = {
            { x = 8, y = 136, width = 80, height = 16 },
            { x = 104, y = 136, width = 80, height = 16 },
            { x = 8, y = 168, width = 80, height = 16 },
            { x = 104, y = 168, width = 80, height = 16 },
          },
        },
      },
    },
  }
end

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
end

local function composition(overrides)
  overrides = overrides or {}
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:add("POKE_BALL", 3))
  Assert.isTrue(bag:add("GREAT_BALL", 2))
  local box = { width = 512, height = 384, topologyObject = topology(512, 384) }
  local options = {
    service = bag,
    cursor = BagCursor.new(),
    manifest = manifest(),
    heroGender = "male",
    measureViewport = function()
      return box.width, box.height
    end,
    measureTopology = function()
      return { topology = box.topologyObject }
    end,
  }
  for key, value in pairs(overrides) do
    options[key] = value
  end
  return options, box, bag
end

local function selectedKey(status)
  local selected = status.selected
  if selected == nil then
    return nil
  end
  return selected.item
end

function T.status_carries_browse_state_layout_and_hero_facts()
  local options = composition()
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local status = state:status()
  Assert.isTrue(status.open)
  Assert.equal(status.pocket, "items")
  Assert.isNil(status.selected, "the default pocket starts empty")
  Assert.equal(status.layout.mode, "horizontal")
  Assert.isTrue(status.layout.interactive.frame ~= nil, "the status carries its resolved layout")
  Assert.equal(status.heroGender, "male")
  Assert.equal(status.hero.pocket, "items", "the hero follows the browsed pocket")
  Assert.equal(status.hero.frame, 1, "one fixed tick advances one animation frame")
  state:dispose()
end

function T.browse_and_pocket_switch_flow_through_the_host_contract()
  local options, _, bag = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  Assert.equal(selectedKey(state:status()), "POKE_BALL")
  Assert.equal(bag:quantity("POKE_BALL"), 3)
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(selectedKey(state:status()), "GREAT_BALL", "directional input moves the selection")
  state:dispose()
end

function T.action_menu_registers_through_the_live_service()
  local options, _, bag = composition()
  Assert.isTrue(bag:add("BICYCLE", 1), "setup stocks a registerable key item through the live service")
  options.cursor:setPocket("key_items")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = bag:revision()
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.state, "action_menu", "confirming an item opens the action menu")
  state:updateFixed({ { type = "confirm" } })
  status = state:status()
  Assert.equal(status.state, "browsing", "committing the single offered action returns to browsing")
  Assert.deepEqual(bag:registeredItems(), { "BICYCLE" }, "the menu registration reaches the live service")
  Assert.equal(bag:revision(), revision + 1, "one registration mutates exactly once")
  state:dispose()
end

function T.toss_flow_mutates_once_through_the_live_service()
  local options, _, bag = composition()
  options.cursor:setPocket("medicine")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = bag:revision()
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().state, "action_menu", "confirming an item opens the action menu")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().state, "toss_quantity", "confirming toss enters the quantity picker")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().state, "toss_confirm", "confirming a quantity asks for confirmation")
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.state, "browsing", "a committed toss returns to browsing")
  Assert.equal(bag:quantity("POTION"), 3, "the menu toss removes the picked copies")
  Assert.equal(bag:revision(), revision + 1, "one toss mutates exactly once")
  state:dispose()
end

function T.pointer_only_register_flows_through_the_live_service()
  local options, _, bag = composition()
  Assert.isTrue(bag:add("BICYCLE", 1), "setup stocks a registerable key item through the live service")
  local withButtons = manifest()
  withButtons.interactive.overlays.actionMenu = {
    buttons = {
      { x = 8, y = 136, width = 80, height = 16 },
      { x = 104, y = 136, width = 80, height = 16 },
      { x = 8, y = 168, width = 80, height = 16 },
      { x = 104, y = 168, width = 80, height = 16 },
    },
  }
  options.manifest = withButtons
  options.cursor:setPocket("key_items")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = bag:revision()
  local function tapLogical(logicalX, logicalY)
    local frame = state:status().layout.interactive.frame
    local scale = state:status().layout.interactive.scale
    local x = frame.x + logicalX * scale
    local y = frame.y + logicalY * scale
    state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
    state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  end
  tapLogical(76, 56)
  Assert.equal(
    state:status().state,
    "action_menu",
    "activating the selected cell opens the action menu by pointer alone"
  )
  Assert.equal(bag:revision(), revision, "opening the menu never mutates the inventory")
  tapLogical(48, 144)
  local status = state:status()
  Assert.equal(status.state, "browsing", "the pointer registration returns to browsing")
  Assert.deepEqual(bag:registeredItems(), { "BICYCLE" }, "the pointer registration reaches the live service")
  Assert.equal(bag:revision(), revision + 1, "one pointer registration mutates exactly once")
  state:dispose()
end

local function cancelCenter(state)
  local placement = state:status().layout.interactive
  local cancelRect = manifest().interactive.cancel.rect
  return placement.frame.x + (cancelRect.x + cancelRect.width / 2) * placement.scale,
    placement.frame.y + (cancelRect.y + cancelRect.height / 2) * placement.scale
end

function T.fallback_topology_keeps_item_capture_across_ticks()
  local options = composition({
    measureTopology = function()
      return {}
    end,
  })
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = state:status().revision
  local function tapLogical(logicalX, logicalY)
    local placement = state:status().layout.interactive
    local frame, scale = placement.frame, placement.scale
    local x = frame.x + logicalX * scale
    local y = frame.y + logicalY * scale
    state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
    state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  end
  tapLogical(76, 56)
  Assert.equal(
    state:status().state,
    "action_menu",
    "a press held across equivalent fallback topologies still activates its target"
  )
  Assert.equal(state:status().revision, revision, "opening the menu never mutates the inventory")
  state:dispose()
end

function T.wide_cancel_tap_closes_exactly_once()
  local options, box = composition({
    measureTopology = function()
      return {}
    end,
  })
  box.width, box.height = 960, 540
  local state = BagScreenState.new(options)
  state:updateFixed({})
  Assert.equal(state:status().layout.mode, "horizontal", "the wide composition keeps its side-by-side arrangement")
  local x, y = cancelCenter(state)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "press and release on Cancel closes the bag")
  Assert.isNil(state:takeResult(), "the close reports exactly once")
  Assert.isFalse(state:status().open, "the bag stays closed after the pointer dismissal")
  state:dispose()
end

function T.viewport_change_between_press_and_release_cancels_capture()
  local options, box = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local x, y = cancelCenter(state)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  box.width, box.height = 390, 844
  box.topologyObject = topology(390, 844)
  state:updateFixed({})
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  local after = state:status()
  Assert.isTrue(after.open, "a release after a real layout change never closes the bag")
  Assert.isNil(state:takeResult(), "a stale release reports no close")
  state:dispose()
end

function T.cancel_center_closes_in_every_responsive_mode()
  local cases = {
    {
      name = "dual",
      width = 512,
      height = 384,
      mode = "dual",
      topologyObject = ScreenTopology.dualDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        touch = false,
        role = "world",
      }, {
        id = "sub",
        rect = { x = 256, y = 0, width = 256, height = 192 },
        touch = true,
        role = "auxiliary",
      }),
    },
    { name = "horizontal", width = 512, height = 384, mode = "horizontal", topologyObject = topology(512, 384) },
    { name = "vertical", width = 390, height = 844, mode = "vertical", topologyObject = topology(390, 844) },
    {
      name = "interactive_only",
      width = 320,
      height = 240,
      mode = "interactive_only",
      topologyObject = topology(320, 240),
    },
  }
  for _, case in ipairs(cases) do
    local options, box = composition()
    box.width, box.height = case.width, case.height
    box.topologyObject = case.topologyObject
    local state = BagScreenState.new(options)
    state:updateFixed({})
    Assert.equal(state:status().layout.mode, case.mode, "the " .. case.name .. " composition keeps its arrangement")
    local x, y = cancelCenter(state)
    state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
    state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
    Assert.deepEqual(
      state:takeResult(),
      { kind = "close" },
      "press and release on Cancel closes the bag in " .. case.name
    )
    Assert.isNil(state:takeResult(), "the close reports exactly once in " .. case.name)
    state:dispose()
  end
end

function T.safe_area_change_at_the_same_viewport_cancels_capture()
  local options, box = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local placement = state:status().layout.interactive
  local x = placement.frame.x + 76 * placement.scale
  local y = placement.frame.y + 56 * placement.scale
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  box.topologyObject = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    safeRect = { x = 0, y = 0, width = 400, height = 300 },
    touch = false,
    role = "world",
  })
  state:updateFixed({})
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  local after = state:status()
  Assert.equal(after.state, "browsing", "a stale release after a placement change never opens the menu")
  Assert.isNil(state:takeResult(), "a stale release reports no close")
  state:dispose()
end

function T.resize_cancels_capture_but_preserves_semantic_selection()
  local options, box = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local before = state:status()
  local frame = before.layout.interactive.frame
  local scale = before.layout.interactive.scale
  local x = frame.x + 76 * scale
  local y = frame.y + 56 * scale
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  box.width, box.height = 390, 844
  box.topologyObject = topology(390, 844)
  state:updateFixed({})
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  local after = state:status()
  Assert.isTrue(after.open, "a stale release never leaves the application")
  Assert.equal(after.pocket, "balls", "resizing preserves the pocket")
  Assert.equal(selectedKey(after), "POKE_BALL", "resizing preserves the selected item")
  Assert.equal(after.layout.mode, "vertical", "the new geometry resolves its own mode")
  state:dispose()
end

function T.close_maps_to_the_host_result_once()
  local options = composition()
  local state = BagScreenState.new(options)
  state:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "the host only accepts close results")
  Assert.isNil(state:takeResult(), "the host result reports exactly once")
  Assert.isFalse(state:status().open)
  state:dispose()
end

function T.dispose_discards_the_pending_close()
  local options = composition()
  local state = BagScreenState.new(options)
  state:updateFixed({ { type = "cancel" } })
  state:dispose()
  state:dispose()
  Assert.isNil(state:takeResult(), "disposal drops the pending result")
end

local BagRenderer = require("libs.hgss.src.ui.BagRenderer")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FakeGraphics = require("tests.support.FakeGraphics").new

-- Production-composition manifest in the generated presentation shape: the
-- layout fields above plus pocket-aware backgrounds, normal tabs, and the
-- generated focus visuals/targets for the composed draw. No production
-- wiring changes.
local function composedManifest()
  local manifested = manifest()
  manifested.hero.background = {
    male = { image = "test/bag/hero-male.png", width = 256, height = 192 },
    female = { image = "test/bag/hero-female.png", width = 256, height = 192 },
  }
  manifested.hero.description = {
    frame = {
      image = "test/bag/description.png",
      alternateImage = "test/bag/description.png",
      rect = { x = 0, y = 144, width = 256, height = 48 },
    },
    textRect = { x = 20, y = 144, width = 228, height = 40 },
  }
  local backgrounds = {}
  for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
    local pockets = {}
    for _, pocket in ipairs(POCKETS) do
      pockets[pocket] = {
        image = "test/bag/background-" .. state .. "-" .. pocket .. ".png",
        width = 256,
        height = 192,
      }
    end
    backgrounds[state] = pockets
  end
  manifested.interactive.backgrounds = backgrounds
  local tabs = {}
  local normals = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
    normals[index + 1] = {
      image = "test/bag/tab-normal-" .. (index + 1) .. ".png",
      width = 16,
      height = 16,
      offset = { x = 3, y = -2 },
    }
  end
  manifested.interactive.pocketTabs = {
    rects = tabs,
    normal = normals,
  }
  manifested.interactive.focus = {
    tabs = {
      visual = { image = "test/bag/focus-tabs.png", width = 32, height = 32, offset = { x = -16, y = -16 } },
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
      visual = { image = "test/bag/focus-items.png", width = 96, height = 40, offset = { x = -48, y = -20 } },
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
      visual = { image = "test/bag/focus-cancel.png", width = 64, height = 24, offset = { x = -32, y = -12 } },
      target = { x = 224, y = 176 },
    },
    actions = {
      visual = { image = "test/bag/focus-actions.png", width = 96, height = 24, offset = { x = -48, y = -12 } },
      targets = {
        { x = 48, y = 144 },
        { x = 144, y = 144 },
        { x = 48, y = 176 },
        { x = 144, y = 176 },
      },
    },
  }
  manifested.interactive.itemSlots.registration = {
    slot1 = { image = "test/bag/registration-slot-1.png", width = 40, height = 16 },
    slot2 = { image = "test/bag/registration-slot-2.png", width = 40, height = 16 },
    offset = { x = 0, y = 16 },
  }
  manifested.interactive.text = {
    actions = {
      toss = "TOSS",
      move = "MOVE",
      register = "REGISTER",
      unregister = "DESELECT",
      cancel = "CANCEL",
      confirm = "YES",
    },
    movePrompt = {
      segments = { { kind = "text", value = "Move " }, { kind = "item" }, { kind = "text", value = "?" } },
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
  }
  local textRects = {
    { 32, 40, 88, 32 },
    { 160, 40, 88, 32 },
    { 32, 80, 88, 32 },
    { 160, 80, 88, 32 },
    { 32, 120, 88, 32 },
    { 160, 120, 88, 32 },
  }
  for index, slot in ipairs(manifested.interactive.itemSlots.slots) do
    local window = assert(textRects[index], "every composed cell needs its text window")
    slot.textRect = { x = window[1], y = window[2], width = window[3], height = window[4] }
    slot.nameAt = { x = 0, y = 0 }
    slot.quantityAt = { x = 48, y = 16 }
  end
  return manifested
end

local function seedComposedCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local function put(path)
    cache:write(path, "png-bytes")
  end
  put("test/bag/hero-male.png")
  put("test/bag/hero-female.png")
  put("test/bag/description.png")
  for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
    for _, pocket in ipairs(POCKETS) do
      put("test/bag/background-" .. state .. "-" .. pocket .. ".png")
    end
  end
  for index = 1, 8 do
    put("test/bag/tab-normal-" .. index .. ".png")
  end
  put("test/bag/focus-tabs.png")
  put("test/bag/focus-items.png")
  put("test/bag/focus-cancel.png")
  put("test/bag/focus-actions.png")
  put("test/bag/registration-slot-1.png")
  put("test/bag/registration-slot-2.png")
  return cache
end

local function composedText()
  local paletted = {}
  local palette = {}
  for index = 1, 16 do
    palette[index] = { r = (index * 37) % 256, g = (index * 91) % 256, b = (index * 53) % 256 }
  end
  local fake = { paletted = paletted, fontDef = { palette = palette } }
  function fake:drawText(content, x, y)
    paletted[#paletted + 1] = { text = content, x = x, y = y, plain = true }
  end
  function fake:drawTextWithPalette(content, x, y, paletteRecord)
    paletted[#paletted + 1] = { text = content, x = x, y = y, palette = paletteRecord }
  end
  function fake:textWidth(content)
    return #content * 8
  end
  return fake
end

local function composedIcons()
  return {
    image = function()
      return "atlas"
    end,
    quadFor = function(_, key)
      return { key = key }
    end,
    dimensions = function(_)
      return { width = 32, height = 32 }
    end,
  }
end

local function composedHeroSpy()
  local spy = { draws = 0, releaseCount = 0 }
  function spy:draw()
    self.draws = self.draws + 1
  end
  function spy:release()
    self.releaseCount = self.releaseCount + 1
  end
  return spy
end

local function wasDrawn(graphics, image)
  for _, entry in ipairs(graphics.draws) do
    if entry.image == image then
      return true
    end
  end
  return false
end

local function staticDrawnAt(graphics, x, y)
  for _, entry in ipairs(graphics.draws) do
    if type(entry.quad) ~= "table" and entry.quad == x and entry.x == y then
      return true
    end
  end
  return false
end

function T.production_bag_draws_pocket_specific_presentation()
  local manifested = composedManifest()
  local options = composition({ manifest = manifested })
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local view = state:status()
  Assert.equal(view.pocket, "balls", "the composed status browses the selected pocket")
  Assert.equal(view.layout.mode, "horizontal", "the wide composition keeps its arrangement")
  local graphics = FakeGraphics({})
  local content = composedText()
  local hero = composedHeroSpy()
  local draw = BagRenderer.new({
    cacheFs = seedComposedCache(),
    manifest = manifested,
    text = content,
    graphics = graphics,
    heroRenderer = hero,
  })
  local icons = composedIcons()
  draw:draw(view, assert(view.layout, "the composed status carries its resolved layout"), { icons = icons })
  local ballsBackground = draw._images["background:browse:balls"]
  local medicineBackground = draw._images["background:browse:medicine"]
  Assert.notNil(ballsBackground, "the balls background is bound")
  Assert.isTrue(wasDrawn(graphics, ballsBackground), "the open bag draws its pocket background")
  Assert.isFalse(wasDrawn(graphics, medicineBackground), "the open bag never borrows another pocket")
  Assert.equal(hero.draws, 1, "the composed draw delegates exactly one hero model draw")
  local itemFocus = manifested.interactive.focus.items
  local absolute = assert(tonumber(view.selectedAbsoluteIndex), "the composed status carries its selection index")
  local windowStart = assert(tonumber(view.visibleStart), "the composed status carries its window start")
  local cell = absolute - windowStart + 1
  local itemTarget = assert(itemFocus.targets[cell], "the composed selection resolves a visible target")
  local itemOffset = itemFocus.visual.offset or { x = 0, y = 0 }
  Assert.isTrue(
    staticDrawnAt(graphics, itemTarget.x + itemOffset.x, itemTarget.y + itemOffset.y),
    "the composed draw focuses the live selected cell"
  )
  Assert.equal(#graphics.rectangles, 0, "the composed draw emits no primitive focus")
  -- Confirming the selected item opens the live action menu; the redraw
  -- carries the generated action focus at the controller-selected target.
  state:updateFixed({ { type = "confirm" } })
  local menu = state:status()
  Assert.equal(menu.state, "action_menu", "confirming the composed selection opens the action menu")
  for key in pairs(graphics.draws) do
    graphics.draws[key] = nil
  end
  draw:draw(menu, assert(menu.layout, "the menu status carries its layout"), { icons = icons })
  local actionFocus = manifested.interactive.focus.actions
  local selectedAction = assert(tonumber(menu.selectedAction), "the menu status carries its selected action")
  local actionTarget = assert(actionFocus.targets[selectedAction + 1], "the menu selection resolves a target")
  local actionOffset = actionFocus.visual.offset or { x = 0, y = 0 }
  Assert.isTrue(
    staticDrawnAt(graphics, actionTarget.x + actionOffset.x, actionTarget.y + actionOffset.y),
    "the composed menu focuses the live selected action"
  )
  Assert.equal(#graphics.rectangles, 0, "the composed menu emits no primitive focus")
  -- Switching pockets through the live cursor re-resolves production status
  -- and the redraw follows with no missing-background fallback.
  options.cursor:setPocket("medicine")
  state:updateFixed({})
  local switched = state:status()
  Assert.equal(switched.pocket, "medicine", "the composed status follows the pocket switch")
  for key in pairs(graphics.draws) do
    graphics.draws[key] = nil
  end
  draw:draw(switched, assert(switched.layout, "the switched status carries its layout"), { icons = icons })
  Assert.isTrue(wasDrawn(graphics, medicineBackground), "the switched pocket draws its own background")
  Assert.isFalse(wasDrawn(graphics, ballsBackground), "the switched pocket never falls back to balls")
  Assert.equal(graphics.pushDepth(), 0, "the composed draws keep the transform stack balanced")
  draw:release()
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "every owned image releases exactly once")
  end
  Assert.equal(hero.releaseCount, 0, "the borrowed hero renderer stays owned by its composer")
  draw:release()
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "a second release stays a safe no-op")
  end
  state:dispose()
end

function T.missing_capabilities_fail_at_construction()
  local options = composition()
  for _, key in ipairs({ "service", "cursor", "manifest", "heroGender", "measureViewport", "measureTopology" }) do
    local broken = {}
    for optionKey, value in pairs(options) do
      broken[optionKey] = value
    end
    broken[key] = nil
    Assert.throws(function()
      ---@diagnostic disable-next-line: param-type-mismatch -- the removed capability is the invalid input under test
      BagScreenState.new(broken)
    end, "a bag launch without " .. key .. " is a construction error")
  end
end

return { tests = T }
