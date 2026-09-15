-- FieldState translates every physical direction into FieldInput's single
-- source-aware cardinal input path.

local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagScreenState = require("game.hgss.src.field.BagScreenState")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function stateWithInput(calls)
  local input = {}
  for _, name in ipairs({
    "pressDirection",
    "releaseDirection",
    "setStickAxis",
    "pointerDown",
    "pointerMove",
    "pointerUp",
    "pointerScroll",
    "pressMenu",
    "releaseMenu",
  }) do
    input[name] = function(_, ...)
      calls[#calls + 1] = { name, ... }
    end
  end
  return setmetatable(
    { runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = { m = true } } },
    FieldState
  )
end

local joystick = {
  getID = function()
    return 7
  end,
}

function T.keyboard_dpad_stick_and_pointer_events_reach_the_unified_input()
  local calls = {}
  local state = stateWithInput(calls)

  state:keypressed("down")
  state:keyreleased("down")
  state:gamepadpressed(joystick, "dpup")
  state:gamepadreleased(joystick, "dpup")
  state:gamepadaxis(joystick, "leftx", -0.75)
  state:gamepadaxis(joystick, "lefty", 0.25)
  state:mousepressed(12, 34, 1)
  state:mousemoved(15, 36, 3, 2, false)
  state:mousereleased(15, 36, 1)
  state:wheelmoved(2, -3)
  state:touchpressed(9, 3, 4)
  state:touchmoved(9, 5, 6)
  state:touchreleased(9, 5, 6)

  Assert.deepEqual(calls, {
    { "pressDirection", "south", "key:down" },
    { "releaseDirection", "key:down" },
    { "pressDirection", "north", "gamepad:7:dpup" },
    { "releaseDirection", "gamepad:7:dpup" },
    { "setStickAxis", "gamepad:7:left", "x", -0.75 },
    { "setStickAxis", "gamepad:7:left", "y", 0.25 },
    { "pointerDown", "mouse:1", 12, 34 },
    { "pointerMove", "mouse:1", 15, 36 },
    { "pointerUp", "mouse:1", 15, 36 },
    { "pointerScroll", "mouse", 2, -3 },
    { "pointerDown", "touch:9", 3, 4 },
    { "pointerMove", "touch:9", 5, 6 },
    { "pointerUp", "touch:9", 5, 6 },
  })
end

function T.only_the_primary_mouse_button_drives_menu_pointer_activation()
  local calls = {}
  local state = stateWithInput(calls)

  state:mousepressed(12, 34, 2)
  state:mousemoved(15, 36, 3, 2, true)
  state:mousereleased(15, 36, 2)

  Assert.deepEqual(calls, {})
end

function T.releasing_one_of_two_keys_for_the_same_direction_releases_its_own_source()
  local calls = {}
  local state = stateWithInput(calls)

  state:keypressed("w")
  state:keypressed("up")
  state:keyreleased("w")

  Assert.deepEqual(calls, {
    { "pressDirection", "north", "key:w" },
    { "pressDirection", "north", "key:up" },
    { "releaseDirection", "key:w" },
  })
end

-- Release mirrors press: one physical key may drive several held semantic
-- states (Action, Cancel, Menu, and a direction all bound to one key), and
-- every matching binding releases, never just the first -- so an overlap can
-- never leave a held state stuck after the key is released.
function T.releasing_a_key_releases_every_semantic_state_it_pressed()
  local calls = {}
  local input = {}
  for _, name in ipairs({
    "pressAction",
    "releaseAction",
    "pressCancel",
    "releaseCancel",
    "pressMenu",
    "releaseMenu",
    "pressDirection",
    "releaseDirection",
  }) do
    input[name] = function(_, ...)
      calls[#calls + 1] = { name, ... }
    end
  end
  local state = setmetatable({
    runtime = {
      input = input,
      actionKeys = { w = true },
      cancelKeys = { w = true },
      menuKeys = { w = true },
    },
  }, FieldState)

  state:keypressed("w")
  state:keyreleased("w")

  Assert.deepEqual(calls, {
    { "pressAction", "key:w" },
    { "pressCancel", "key:w" },
    { "pressMenu", "key:w" },
    { "pressDirection", "north", "key:w" },
    { "releaseAction", "key:w" },
    { "releaseCancel", "key:w" },
    { "releaseMenu", "key:w" },
    { "releaseDirection", "key:w" },
  })
end

function T.focus_loss_discards_stale_stick_axes_before_refocus()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = {} } }, FieldState)

  state:gamepadaxis(joystick, "leftx", -0.75)
  state:focus(false)
  state:gamepadaxis(joystick, "lefty", 0.25)

  Assert.deepEqual(input:uiSnapshot(1), {})
end

function T.focus_loss_does_not_leave_a_keyboard_direction_stuck_after_refocus()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = {} } }, FieldState)

  state:keypressed("down")
  state:focus(false)
  state:keypressed("right")
  state:keyreleased("right")

  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, pressedDirection = "east", actionDown = false, cancelDown = false, menuDown = false }
  )
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.open_bag_stays_controllable_across_window_blur()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = {} } }, FieldState)

  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:add("POKE_BALL", 3))
  Assert.isTrue(bag:add("GREAT_BALL", 2))
  local box = {
    width = 512,
    height = 384,
    topologyObject = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      touch = false,
      role = "world",
    }),
  }
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
  local pockets = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }
  local heroStates = {}
  for _, pocket in ipairs(pockets) do
    heroStates[#heroStates + 1] =
      { pocket = pocket, pose = "pocket." .. pocket .. ".pose", pattern = "pocket." .. pocket .. ".pattern" }
  end
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local function framingRecord(angleXDegrees, angleYDegrees, distance, modelY)
    return { angleXDegrees = angleXDegrees, angleYDegrees = angleYDegrees, distance = distance, modelY = modelY }
  end
  local framingByGender = {}
  for _, gender in ipairs({ "male", "female" }) do
    local records = {}
    for index, pocket in ipairs(pockets) do
      records[pocket] = framingRecord(index, 2 * index, 100 + 10 * index, 5 + index)
    end
    framingByGender[gender] = records
  end
  local screen = BagScreenState.new({
    service = bag,
    cursor = cursor,
    manifest = {
      hero = {
        animations = {
          states = heroStates,
          material = { male = "bag.male.material", female = "bag.female.material" },
        },
        presentation = {
          framing = {
            transitionTicks = 7,
            baseline = { male = framingRecord(0, 0, 100, 5), female = framingRecord(1, 1, 110, 6) },
            byGender = framingByGender,
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
    },
    heroGender = "male",
    measureViewport = function()
      return box.width, box.height
    end,
    measureTopology = function()
      return { topology = box.topologyObject }
    end,
  })
  screen:updateFixed({})
  Assert.equal(screen:status().selected.item, "POKE_BALL", "setup browses the stocked pocket")

  input:beginUi(0)
  state:keypressed("down")
  state:focus(false)
  state:focus(true)
  Assert.deepEqual(input:uiSnapshot(1), {}, "stale pre-blur input must not replay after blur")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false },
    "blur clears the stale held direction"
  )
  state:keypressed("right")
  local events = input:uiSnapshot(2)
  Assert.deepEqual(events, { { type = "navigate", direction = "right" } }, "fresh input reaches the open bag")
  screen:updateFixed(events)
  Assert.equal(screen:status().selected.item, "GREAT_BALL", "the open bag answers fresh navigation after blur")
  state:keyreleased("right")
  screen:dispose()
end

function T.gamepad_dpad_and_left_stick_drive_normal_field_movement()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = {} } }, FieldState)

  state:gamepadpressed(joystick, "dpdown")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "south", pressedDirection = "south", actionDown = false, cancelDown = false, menuDown = false }
  )
  state:gamepadreleased(joystick, "dpdown")
  state:gamepadaxis(joystick, "leftx", -0.75)
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "west", pressedDirection = "west", actionDown = false, cancelDown = false, menuDown = false }
  )
end

function T.keyboard_menu_key_and_gamepad_west_face_drive_the_semantic_menu_button()
  local calls = {}
  local state = stateWithInput(calls)
  state:keypressed("m")
  state:keyreleased("m")
  state:gamepadpressed(joystick, "x")
  state:gamepadreleased(joystick, "x")
  Assert.deepEqual(calls, {
    { "pressMenu", "key:m" },
    { "releaseMenu", "key:m" },
    { "pressMenu", "gamepad:7:x" },
    { "releaseMenu", "gamepad:7:x" },
  })
end

function T.field_state_dispatches_using_the_runtime_menu_key_table()
  local calls = {}
  local state = stateWithInput(calls)
  state.runtime.menuKeys = { n = true }
  state:keypressed("m")
  state:keypressed("n")
  Assert.deepEqual(calls, {
    { "pressMenu", "key:n" },
  })
end

function T.menu_button_edges_reach_the_runtime_input_source_aware_model()
  local input = FieldInput.new()
  local state =
    setmetatable({ runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = { m = true } } }, FieldState)

  state:keypressed("m")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true, menuPressed = true }
  )
  state:keypressed("m")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true },
    "a repeat press of the held menu key produces no second edge"
  )
  state:keyreleased("m")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

return { tests = T }
