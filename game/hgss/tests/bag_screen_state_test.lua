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
local FieldUiFixture = require("tests.support.FieldUiFixture")
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
  local function framingRecord(angleXDegrees, angleYDegrees, distance, modelY)
    return { angleXDegrees = angleXDegrees, angleYDegrees = angleYDegrees, distance = distance, modelY = modelY }
  end
  local function pocketRecords(base)
    local records = {}
    for index, pocket in ipairs(POCKETS) do
      records[pocket] = framingRecord(base + index, base + 2 * index, 100 + 10 * index, 5 + index)
    end
    return records
  end
  return {
    hero = {
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
      presentation = {
        framing = {
          transitionTicks = 7,
          baseline = { male = framingRecord(0, 0, 100, 5), female = framingRecord(1, 1, 110, 6) },
          byGender = { male = pocketRecords(10), female = pocketRecords(20) },
        },
      },
    },
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = {
        rect = { x = 192, y = 168, width = 64, height = 24 },
        textRect = { x = 192, y = 168, width = 56, height = 16 },
        labelRect = { x = 200, y = 168, width = 48, height = 16 },
      },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
        tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
        actionMenu = {
          slots = {
            { hitRect = { x = 8, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 8, y = 168, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 168, width = 80, height = 16 } },
          },
        },
        quantity = {
          controls = {
            { delta = 100, role = "increment", hitRect = { x = 0, y = 128, width = 32, height = 32 } },
            { delta = 10, role = "increment", hitRect = { x = 32, y = 128, width = 32, height = 32 } },
            { delta = 1, role = "increment", hitRect = { x = 64, y = 128, width = 32, height = 32 } },
            { delta = -100, role = "decrement", hitRect = { x = 0, y = 160, width = 32, height = 32 } },
            { delta = -10, role = "decrement", hitRect = { x = 32, y = 160, width = 32, height = 32 } },
            { delta = -1, role = "decrement", hitRect = { x = 64, y = 160, width = 32, height = 32 } },
          },
          pressTicks = 2,
          cancelHitRect = { x = 178, y = 168, width = 78, height = 24 },
          confirm = { hitRect = { x = 112, y = 160, width = 64, height = 32 } },
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

local function measurementFor(box)
  return {
    width = box.width,
    height = box.height,
    topology = box.topologyObject,
    pixelRatio = 1,
    signature = "bag-screen-state-test:" .. box.width .. "x" .. box.height,
  }
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
    monCatalog = {
      moveByNativeId = function()
        error("test catalog lookup is not exercised", 0)
      end,
    },
    cursor = BagCursor.new(),
    manifest = manifest(),
    uiManifest = FieldUiFixture.manifest(),
    heroGender = "male",
    measureDisplay = function()
      return measurementFor(box)
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

---@param state table<string, unknown> the wrapper under test
---@return table<string, unknown> the interactive pane placement
local function interactivePlacement(state)
  local plan = assert(state:status().presentation, "the status carries its presentation plan")
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      return pane.placement
    end
  end
  error("the plan carries its interactive pane", 0)
end

function T.status_carries_browse_state_layout_and_hero_facts()
  local options = composition()
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local status = state:status()
  Assert.isTrue(status.open)
  Assert.equal(status.pocket, "items")
  Assert.isNil(status.selected, "the default pocket starts empty")
  local plan = assert(status.presentation, "the status carries its presentation plan")
  Assert.equal(#plan.panes, 1, "the native-like composition shows only its interactive pane")
  Assert.equal(plan.content.heroVisible, false, "the native-like plan hides the hero pane")
  Assert.isNil(status.layout, "the migrated status carries no stale host layout")
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
  state:updateFixed({ { type = "navigate", direction = "up" } })
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().state, "toss_confirm", "confirming a quantity asks for confirmation")
  Assert.equal(bag:revision(), revision, "entering confirmation never mutates")
  state:updateFixed({ { type = "confirm" } })
  Assert.equal(state:status().state, "toss_ack", "accepting YES waits for a later acknowledgement")
  Assert.equal(bag:quantity("POTION"), 5, "accepting YES changes no quantities")
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.state, "browsing", "the acknowledgement returns to browsing")
  Assert.equal(bag:quantity("POTION"), 3, "the menu toss removes the picked copies")
  Assert.equal(bag:revision(), revision + 1, "one toss mutates exactly once")
  state:dispose()
end

function T.bag_screen_without_prompt_resources_is_a_composition_error()
  local options = composition()
  options.uiManifest = nil
  Assert.throws(function()
    BagScreenState.new(options)
  end)
end

function T.pointer_only_register_flows_through_the_live_service()
  local options, _, bag = composition()
  Assert.isTrue(bag:add("BICYCLE", 1), "setup stocks a registerable key item through the live service")
  local withButtons = manifest()
  options.manifest = withButtons
  options.cursor:setPocket("key_items")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = bag:revision()
  local function tapLogical(logicalX, logicalY)
    local placement = interactivePlacement(state)
    local frame = placement.frame
    local scale = placement.scale
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
  tapLogical(144, 144)
  local status = state:status()
  Assert.equal(status.state, "browsing", "the pointer registration returns to browsing")
  Assert.deepEqual(bag:registeredItems(), { "BICYCLE" }, "the pointer registration reaches the live service")
  Assert.equal(bag:revision(), revision + 1, "one pointer registration mutates exactly once")
  state:dispose()
end

local function cancelCenter(state)
  local placement = interactivePlacement(state)
  local cancelRect = manifest().interactive.cancel.rect
  return placement.frame.x + (cancelRect.x + cancelRect.width / 2) * placement.scale,
    placement.frame.y + (cancelRect.y + cancelRect.height / 2) * placement.scale
end

function T.fresh_equivalent_measurement_keeps_item_capture_across_ticks()
  local options, box = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = state:status().revision
  local function tapLogical(logicalX, logicalY)
    local placement = interactivePlacement(state)
    local frame, scale = placement.frame, placement.scale
    local x = frame.x + logicalX * scale
    local y = frame.y + logicalY * scale
    state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
    state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  end
  box.topologyObject = topology(512, 384)
  tapLogical(76, 56)
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
  local options, box = composition()
  box.width, box.height = 960, 540
  box.topologyObject = topology(960, 540)
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local widePlan = assert(state:status().presentation, "the wide composition publishes its plan")
  Assert.equal(#widePlan.panes, 2, "the wide composition pairs both panes")
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
  box.width, box.height = 1280, 720
  box.topologyObject = topology(1280, 720)
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
      panes = 2,
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
    { name = "wide", width = 1280, height = 720, panes = 2, topologyObject = topology(1280, 720) },
    { name = "tall", width = 600, height = 1000, panes = 2, topologyObject = topology(600, 1000) },
    {
      name = "native_like",
      width = 320,
      height = 240,
      panes = 1,
      topologyObject = topology(320, 240),
    },
  }
  for _, case in ipairs(cases) do
    local options, box = composition()
    box.width, box.height = case.width, case.height
    box.topologyObject = case.topologyObject
    local state = BagScreenState.new(options)
    state:updateFixed({})
    local casePlan = assert(state:status().presentation, "the " .. case.name .. " composition publishes its plan")
    Assert.equal(#casePlan.panes, case.panes, "the " .. case.name .. " composition keeps its arrangement")
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
  local placement = interactivePlacement(state)
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
  local placement = interactivePlacement(state)
  local frame = placement.frame
  local scale = placement.scale
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
  local resizedPlan = assert(after.presentation, "the resized status publishes its plan")
  Assert.equal(#resizedPlan.panes, 2, "the new geometry resolves its own pair")
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
      rect = { x = 0, y = 144, width = 256, height = 48 },
    },
    textRect = { x = 20, y = 144, width = 228, height = 40 },
  }
  local backgrounds = {}
  for _, state in ipairs({ "action", "quantity", "confirmation" }) do
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
  do
    local browse = {}
    for _, pocket in ipairs(POCKETS) do
      local variants = {}
      for count = 0, 6 do
        variants[count + 1] = {
          image = "test/bag/background-browse-" .. pocket .. "-" .. count .. ".png",
          width = 256,
          height = 192,
        }
      end
      browse[pocket] = variants
    end
    backgrounds.browse = browse
  end
  manifested.interactive.backgrounds = backgrounds
  local actionSlots = manifested.interactive.overlays.actionMenu.slots
  for index, slot in ipairs(actionSlots) do
    local x = index % 2 == 1 and 48 or 144
    local y = index <= 2 and 144 or 176
    slot.center = { x = x, y = y }
    slot.textRect = { x = x - 40, y = y - 8, width = 80, height = 16 }
  end
  manifested.interactive.overlays.actionMenu.face = {
    image = "test/bag/action-face.png",
    width = 96,
    height = 24,
  }
  manifested.interactive.overlays.quantity = {
    controls = {
      {
        delta = 100,
        role = "increment",
        center = { x = 16, y = 144 },
        hitRect = { x = 0, y = 128, width = 32, height = 32 },
      },
      {
        delta = 10,
        role = "increment",
        center = { x = 48, y = 144 },
        hitRect = { x = 32, y = 128, width = 32, height = 32 },
      },
      {
        delta = 1,
        role = "increment",
        center = { x = 80, y = 144 },
        hitRect = { x = 64, y = 128, width = 32, height = 32 },
      },
      {
        delta = -100,
        role = "decrement",
        center = { x = 16, y = 176 },
        hitRect = { x = 0, y = 160, width = 32, height = 32 },
      },
      {
        delta = -10,
        role = "decrement",
        center = { x = 48, y = 176 },
        hitRect = { x = 32, y = 160, width = 32, height = 32 },
      },
      {
        delta = -1,
        role = "decrement",
        center = { x = 80, y = 176 },
        hitRect = { x = 64, y = 160, width = 32, height = 32 },
      },
    },
    pressTicks = 2,
    confirm = {
      center = { x = 144, y = 176 },
      hitRect = { x = 112, y = 160, width = 64, height = 32 },
      visual = { image = "test/bag/quantity-confirm.png", width = 64, height = 24 },
    },
    cancelHitRect = { x = 178, y = 168, width = 78, height = 24 },
    visuals = {
      increment = {
        normal = { image = "test/bag/quantity-increment.png", width = 24, height = 24 },
        pressed = { image = "test/bag/quantity-increment-pressed.png", width = 24, height = 24 },
      },
      decrement = {
        normal = { image = "test/bag/quantity-decrement.png", width = 24, height = 24 },
        pressed = { image = "test/bag/quantity-decrement-pressed.png", width = 24, height = 24 },
      },
    },
  }
  local tabs = {}
  local strips = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
  end
  for _, pocket in ipairs(POCKETS) do
    strips[pocket] = {
      image = "test/bag/tabs-" .. pocket .. ".png",
      width = 256,
      height = 32,
    }
  end
  manifested.interactive.pocketTabs = {
    rects = tabs,
    strips = strips,
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
  for _, state in ipairs({ "action", "quantity", "confirmation" }) do
    for _, pocket in ipairs(POCKETS) do
      put("test/bag/background-" .. state .. "-" .. pocket .. ".png")
    end
  end
  for _, pocket in ipairs(POCKETS) do
    for count = 0, 6 do
      put("test/bag/background-browse-" .. pocket .. "-" .. count .. ".png")
    end
  end
  for _, pocket in ipairs(POCKETS) do
    put("test/bag/tabs-" .. pocket .. ".png")
  end
  put("test/bag/focus-tabs.png")
  put("test/bag/focus-items.png")
  put("test/bag/focus-cancel.png")
  put("test/bag/focus-actions.png")
  put("test/bag/action-face.png")
  put("test/bag/quantity-increment.png")
  put("test/bag/quantity-increment-pressed.png")
  put("test/bag/quantity-decrement.png")
  put("test/bag/quantity-decrement-pressed.png")
  put("test/bag/quantity-confirm.png")
  put("test/bag/registration-slot-1.png")
  put("test/bag/registration-slot-2.png")
  cache:write(FieldUiFixture.PROMPT_YES_NORMAL_PATH, FieldUiFixture.promptButtonBytes("yes_normal"))
  cache:write(FieldUiFixture.PROMPT_YES_SELECTED_PATH, FieldUiFixture.promptButtonBytes("yes_selected"))
  cache:write(FieldUiFixture.PROMPT_NO_NORMAL_PATH, FieldUiFixture.promptButtonBytes("no_normal"))
  cache:write(FieldUiFixture.PROMPT_NO_SELECTED_PATH, FieldUiFixture.promptButtonBytes("no_selected"))
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
  function spy:draw(_, _, _)
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
    if entry.quad == nil and entry.x == x and entry.y == y then
      return true
    end
  end
  return false
end

function T.production_bag_draws_pocket_specific_presentation()
  local manifested = composedManifest()
  local options, box = composition({ manifest = manifested })
  box.width, box.height = 1280, 720
  box.topologyObject = topology(1280, 720)
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local view = state:status()
  Assert.equal(view.pocket, "balls", "the composed status browses the selected pocket")
  local plan = assert(view.presentation, "the wide composition publishes its presentation plan")
  Assert.equal(#plan.panes, 2, "the wide composition pairs both panes")
  local graphics = FakeGraphics({})
  local content = composedText()
  local hero = composedHeroSpy()
  local draw = BagRenderer.new({
    cacheFs = seedComposedCache(),
    manifest = manifested,
    promptManifest = FieldUiFixture.manifest(),
    text = content,
    graphics = graphics,
    heroRenderer = hero,
  })
  local icons = composedIcons()
  draw:draw(view, assert(view.presentation, "the composed status carries its presentation plan"), { icons = icons })
  local ballsBackground = draw._images["background:browse:balls:2"]
  local medicineBackground = draw._images["background:browse:medicine:1"]
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
  draw:draw(menu, assert(menu.presentation, "the menu status carries its presentation plan"), { icons = icons })
  local actionFocus = manifested.interactive.focus.actions
  local actionNode = assert(tonumber(menu.actionNode), "the menu status carries its physical selection")
  local actionTarget = assert(actionFocus.targets[actionNode + 1], "the menu selection resolves a target")
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
  draw:draw(
    switched,
    assert(switched.presentation, "the switched status carries its presentation plan"),
    { icons = icons }
  )
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
  for _, key in ipairs({ "service", "cursor", "manifest", "heroGender", "measureDisplay" }) do
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

-- The application composition supplies the profile gender to the hero
-- presenter: each gender settles its own framing table after seven ticks.
function T.hero_framing_settles_to_the_profile_gender_record()
  for _, gender in ipairs({ "male", "female" }) do
    local options = composition({ heroGender = gender })
    local state = BagScreenState.new(options)
    for _ = 1, 7 do
      state:updateFixed({})
    end
    local hero = state:status().hero
    local framing = assert(hero.framing, "the composed hero status carries its interpolated framing")
    local expected = assert(
      options.manifest.hero.presentation.framing.byGender[gender].items,
      "the fixture carries the " .. gender .. " items framing"
    )
    Assert.near(framing.angleXDegrees, expected.angleXDegrees, 1e-9, gender .. " settles its own pitch")
    Assert.near(framing.angleYDegrees, expected.angleYDegrees, 1e-9, gender .. " settles its own yaw")
    Assert.near(framing.distance, expected.distance, 1e-9, gender .. " settles its own distance")
    Assert.near(framing.modelY, expected.modelY, 1e-9, gender .. " settles its own model height")
    state:dispose()
  end
end

-- The migrated contract publishes one shared presentation plan beside the
-- semantic snapshot: ordered panes with complete placements, canonical
-- logical content, a stable input key, and the matched render/input
-- callbacks. The stale host-specific layout record is gone.
function T.status_publishes_a_shared_presentation_plan_beside_semantics()
  local options = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local status = state:status()
  Assert.equal(selectedKey(status), "POKE_BALL", "setup selects the stocked ball")
  local plan = status.presentation
  Assert.isTrue(type(plan) == "table", "the bag status publishes its presentation plan beside its semantic snapshot")
  Assert.equal(type(plan.inputKey), "string", "the plan names its stable input geometry")
  Assert.isTrue(#plan.inputKey > 0, "the plan input key is nonempty")
  Assert.isTrue(type(plan.render) == "function", "the plan carries its render callback")
  Assert.isTrue(type(plan.mapInput) == "function", "the plan carries its input callback")
  Assert.isTrue(type(plan.panes) == "table", "the plan orders its panes")
  Assert.equal(#plan.panes, 1, "the native-like composition shows only its interactive pane")
  local pane = plan.panes[1]
  Assert.isTrue(pane.interactive, "the single native-like pane takes input")
  local placement = pane.placement
  Assert.isTrue(
    type(placement) == "table" and type(placement.frame) == "table" and type(placement.scale) == "number",
    "the pane carries its complete placement"
  )
  local content = plan.content
  Assert.isTrue(type(content) == "table", "the plan carries its canonical logical content")
  Assert.equal(content.heroVisible, false, "the native-like plan hides the hero pane")
  Assert.isTrue(type(content.descriptionFallback) == "table", "the lower-only plan keeps its description fallback")
  Assert.isNil(status.layout, "the migrated status carries no stale host layout")
  state:dispose()
end

-- Paired single-display panes share one integer pixel scale with no
-- synthetic gap, one frame around the common envelope, and exactly one
-- pane takes input.
function T.wide_pairs_share_one_integer_scale_with_no_gap()
  local options, box = composition()
  box.width, box.height = 1280, 720
  box.topologyObject = topology(1280, 720)
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local plan = state:status().presentation
  Assert.isTrue(type(plan) == "table", "the wide composition resolves through the shared plan")
  Assert.isTrue(type(plan.panes) == "table", "the wide plan orders its panes")
  Assert.equal(#plan.panes, 2, "the wide composition pairs both panes")
  local heroPane, interactivePane
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      interactivePane = pane
    else
      heroPane = pane
    end
  end
  Assert.isTrue(type(heroPane) == "table", "the wide pair carries its hero pane")
  Assert.isTrue(type(interactivePane) == "table", "the wide pair carries its interactive pane")
  local heroPlacement = heroPane.placement
  local wideInteraction = interactivePane.placement
  Assert.isTrue(
    type(heroPlacement) == "table" and type(wideInteraction) == "table",
    "both panes carry complete placements"
  )
  Assert.equal(heroPlacement.pixelScale, wideInteraction.pixelScale, "paired panes share one integer scale")
  Assert.equal(heroPlacement.pixelScale % 1, 0, "the shared paired scale stays integral")
  Assert.isTrue(
    heroPlacement.frame.x + heroPlacement.frame.width <= wideInteraction.frame.x,
    "the hero pane sits left of the interaction pane"
  )
  Assert.near(
    wideInteraction.frame.x - (heroPlacement.frame.x + heroPlacement.frame.width),
    0,
    1e-6,
    "paired panes touch with no synthetic gap"
  )
  Assert.equal(#plan.frames, 1, "the pair carries one frame around its envelope")
  Assert.isNil(state:status().layout, "the migrated status carries no stale host layout")
  state:dispose()
end

function T.tall_stacks_the_hero_above_the_interaction_pane()
  local options, box = composition()
  box.width, box.height = 600, 1000
  box.topologyObject = topology(600, 1000)
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local plan = state:status().presentation
  Assert.isTrue(type(plan) == "table", "the tall composition resolves through the shared plan")
  Assert.equal(#plan.panes, 2, "the tall composition pairs both panes")
  local heroPane, interactivePane
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      interactivePane = pane
    else
      heroPane = pane
    end
  end
  Assert.isTrue(type(heroPane) == "table", "the tall pair carries its hero pane")
  Assert.isTrue(type(interactivePane) == "table", "the tall pair carries its interactive pane")
  local heroPlacement = heroPane.placement
  local stackedInteraction = interactivePane.placement
  Assert.equal(heroPlacement.pixelScale, stackedInteraction.pixelScale, "stacked panes share one integer scale")
  Assert.isTrue(
    heroPlacement.frame.y + heroPlacement.frame.height <= stackedInteraction.frame.y,
    "the hero pane sits above the interaction pane"
  )
  Assert.near(
    stackedInteraction.frame.y - (heroPlacement.frame.y + heroPlacement.frame.height),
    0,
    1e-6,
    "stacked panes touch with no synthetic gap"
  )
  state:dispose()
end

-- Pointer input on the hero display pane never selects an item, while a
-- press fully outside every pane and frame dismisses terminally: only
-- the visible interactive pane maps pointer input to content.
function T.hero_tap_stays_inert_while_outside_tap_dismisses()
  local options, box = composition()
  box.width, box.height = 1280, 720
  box.topologyObject = topology(1280, 720)
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = state:status().revision
  local plan = state:status().presentation
  Assert.isTrue(type(plan) == "table", "the wide composition resolves through the shared plan")
  local heroPane, interactivePane
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      interactivePane = pane
    else
      heroPane = pane
    end
  end
  local heroFrame = heroPane.placement.frame
  local interactiveFrame = interactivePane.placement.frame
  local function tapHost(x, y)
    state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
    state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  end
  tapHost(heroFrame.x + heroFrame.width / 2, heroFrame.y + heroFrame.height / 2)
  local afterHero = state:status()
  Assert.equal(afterHero.state, "browsing", "a hero-pane tap never opens the action menu")
  Assert.equal(afterHero.revision, revision, "a hero-pane tap issues no inventory mutation")
  -- A press fully outside every pane and frame dismisses terminally
  -- through the existing close result instead of selecting anything.
  local frameRecord = assert(plan.frames, "the wide composition publishes its outer frame")[1]
  local outerFrame = assert(frameRecord.placement, "the frame carries its placement").frame
  local outsideX, outsideY = 5, 5
  local function insideOuter(x, y)
    return x >= outerFrame.x
      and x < outerFrame.x + outerFrame.width
      and y >= outerFrame.y
      and y < outerFrame.y + outerFrame.height
  end
  Assert.isTrue(outsideX < math.min(heroFrame.x, interactiveFrame.x), "the probe sits outside every pane")
  if insideOuter(outsideX, outsideY) then
    outsideX, outsideY = 1275, 715
  end
  Assert.isFalse(insideOuter(outsideX, outsideY), "the probe must clear the outer frame")
  tapHost(outsideX, outsideY)
  local afterOutside = state:status()
  Assert.isFalse(afterOutside.open, "an outside tap terminally closes the bag")
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "dismissal reports the existing close result")
  state:dispose()
end

-- A press held across a display-measurement change cancels through the
-- presentation session: the stale release cannot activate the target that
-- moved under the pointer, semantic state survives, and a fresh press on
-- Cancel still closes exactly once.
function T.held_press_across_a_measurement_change_cancels_through_the_session()
  local options, box = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = state:status().revision
  local plan = state:status().presentation
  Assert.isTrue(type(plan) == "table", "the held-press journey resolves through the shared plan")
  local pane = plan.panes[1]
  Assert.isTrue(type(pane) == "table" and pane.interactive, "the plan carries its interactive pane")
  local frame, scale = pane.placement.frame, pane.placement.scale
  local x = frame.x + 76 * scale
  local y = frame.y + 56 * scale
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  box.width, box.height = 390, 844
  box.topologyObject = topology(390, 844)
  state:updateFixed({})
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  local after = state:status()
  Assert.isTrue(after.open, "a release after a measurement change never leaves the application")
  Assert.equal(after.pocket, "balls", "the session preserves the pocket across the change")
  Assert.equal(selectedKey(after), "POKE_BALL", "the session preserves the selected item across the change")
  Assert.equal(after.revision, revision, "a stale release issues no inventory mutation")
  Assert.isNil(state:takeResult(), "a stale release reports no close")
  local fresh = after.presentation
  Assert.isTrue(type(fresh) == "table", "the session publishes its plan after the change")
  local freshPane
  for _, candidate in ipairs(fresh.panes) do
    if candidate.interactive then
      freshPane = candidate
    end
  end
  Assert.isTrue(type(freshPane) == "table", "the fresh plan carries its interactive pane")
  local freshFrame, freshScale = freshPane.placement.frame, freshPane.placement.scale
  local cancel = manifest().interactive.cancel.rect
  local cx = freshFrame.x + (cancel.x + cancel.width / 2) * freshScale
  local cy = freshFrame.y + (cancel.y + cancel.height / 2) * freshScale
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = cx, y = cy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = cx, y = cy } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "a fresh press on Cancel still closes the bag")
  Assert.isNil(state:takeResult(), "the close reports exactly once")
  state:dispose()
end

-- Capture cancellation forwards to the presentation session: a held press
-- dropped by the session never activates on release.
function T.capture_cancellation_forwards_to_the_presentation_session()
  local options = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = state:status().revision
  local plan = state:status().presentation
  Assert.isTrue(type(plan) == "table", "the cancellation journey resolves through the shared plan")
  local frame, scale = plan.panes[1].placement.frame, plan.panes[1].placement.scale
  local x = frame.x + 76 * scale
  local y = frame.y + 56 * scale
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  -- Capability probe through a permissive view: the session-owned method
  -- does not exist before migration, and the probe names exactly that.
  local cancel = (state --[[@as table<string, unknown>]]).cancelPointerCapture
  Assert.isTrue(type(cancel) == "function", "the bag wrapper forwards capture cancellation through its session")
  local cancelFn = cancel --[[@as fun(self: table<string, unknown>)]]
  cancelFn(state)
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  local after = state:status()
  Assert.equal(after.state, "browsing", "a cancelled press never opens the action menu")
  Assert.equal(after.revision, revision, "a cancelled press issues no inventory mutation")
  Assert.isNil(state:takeResult(), "a cancelled press reports no close")
  state:dispose()
end

-- Ordered pointer cancellation reaches the controller in batch order: the
-- press it cancels never activates a target.
function T.ordered_pointer_cancellation_reaches_the_controller_without_activation()
  local options = composition()
  options.cursor:setPocket("balls")
  local state = BagScreenState.new(options)
  state:updateFixed({})
  local revision = state:status().revision
  local plan = state:status().presentation
  Assert.isTrue(type(plan) == "table", "the cancellation journey resolves through the shared plan")
  local frame, scale = plan.panes[1].placement.frame, plan.panes[1].placement.scale
  local x = frame.x + 76 * scale
  local y = frame.y + 56 * scale
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  state:updateFixed({ { type = "pointer_cancel", pointerId = "touch:0" } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  local after = state:status()
  Assert.equal(after.state, "browsing", "a cancelled press never opens the action menu")
  Assert.equal(after.revision, revision, "a cancelled press issues no inventory mutation")
  Assert.isNil(state:takeResult(), "a cancelled press reports no close")
  state:dispose()
end

return { tests = T }
