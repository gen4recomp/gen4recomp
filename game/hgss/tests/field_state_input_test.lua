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
local HgssInputBindings = require("game.hgss.src.HgssInputBindings")

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
    { runtime = { input = input, actionKeys = {}, cancelKeys = {}, menuKeys = { tab = true } } },
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

-- The field honors the shared physical binding authority: every manifest
-- action/cancel/menu alias drives field input, so centralizing the aliases
-- cannot silently drop a field key and the keypad Enter expansion flows.
-- Escape reaches cancel input instead of the host quit, and removed aliases
-- stay inert.
function T.shared_binding_aliases_drive_field_action_cancel_and_menu()
  local calls = {}
  local input = {}
  for _, name in ipairs({ "pressAction", "releaseAction", "pressCancel", "releaseCancel", "pressMenu", "releaseMenu" }) do
    input[name] = function(_, ...)
      calls[#calls + 1] = { name, ... }
    end
  end
  -- The menu copy API is part of the shared authority; fall back to the
  -- requested alias only so field routing stays observable either way.
  local menuKeys = HgssInputBindings.menuKeys ~= nil and HgssInputBindings.menuKeys() or { tab = true }
  local state = setmetatable({
    runtime = {
      input = input,
      actionKeys = HgssInputBindings.actionKeys(),
      cancelKeys = HgssInputBindings.cancelKeys(),
      menuKeys = menuKeys,
    },
  }, FieldState)

  -- Host quit is stubbed so the test observes input routing, not process exit.
  local quitCalls = 0
  local eventRef = love.event
  local quitRef = eventRef.quit
  eventRef.quit = function()
    quitCalls = quitCalls + 1
  end
  local ok, err = pcall(function()
    for _, key in ipairs({ "space", "return", "kpenter" }) do
      state:keypressed(key)
      state:keyreleased(key)
    end
    for _, key in ipairs({ "backspace", "delete", "escape" }) do
      state:keypressed(key)
      state:keyreleased(key)
    end
    state:keypressed("tab")
    state:keyreleased("tab")
    for _, key in ipairs({ "z", "x", "m" }) do
      state:keypressed(key)
      state:keyreleased(key)
    end
  end)
  eventRef.quit = quitRef
  Assert.isTrue(ok, "field key translation never raises: " .. tostring(err))

  Assert.equal(quitCalls, 0, "field Escape must reach cancel input, never the host quit")
  Assert.deepEqual(calls, {
    { "pressAction", "key:space" },
    { "releaseAction", "key:space" },
    { "pressAction", "key:return" },
    { "releaseAction", "key:return" },
    { "pressAction", "key:kpenter" },
    { "releaseAction", "key:kpenter" },
    { "pressCancel", "key:backspace" },
    { "releaseCancel", "key:backspace" },
    { "pressCancel", "key:delete" },
    { "releaseCancel", "key:delete" },
    { "pressCancel", "key:escape" },
    { "releaseCancel", "key:escape" },
    { "pressMenu", "key:tab" },
    { "releaseMenu", "key:tab" },
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
        },
      },
    },
    heroGender = "male",
    measureDisplay = function()
      return {
        width = box.width,
        height = box.height,
        topology = box.topologyObject,
        pixelRatio = 1,
        signature = "field-state-input-test:" .. box.width .. "x" .. box.height,
      }
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
  state:keypressed("tab")
  state:keyreleased("tab")
  state:gamepadpressed(joystick, "x")
  state:gamepadreleased(joystick, "x")
  Assert.deepEqual(calls, {
    { "pressMenu", "key:tab" },
    { "releaseMenu", "key:tab" },
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

function T.focus_loss_clears_physical_input_and_cancels_presentation_capture()
  local cleared, cancelled = 0, 0
  local state = setmetatable({
    runtime = {
      input = {
        clearAll = function()
          cleared = cleared + 1
        end,
      },
      applicationHost = {
        cancelPointerCapture = function()
          cancelled = cancelled + 1
        end,
      },
    },
  }, FieldState)
  state:focus(false)
  Assert.equal(cleared, 1, "blur clears held and edge state")
  Assert.equal(cancelled, 1, "blur delegates presentation capture cancellation")
  state:focus(true)
  Assert.equal(cleared, 1, "regaining focus clears nothing")
  Assert.equal(cancelled, 1, "regaining focus cancels nothing")
end

function T.update_refreshes_the_display_before_runtime_ticks()
  local DisplayContext = require("game.hgss.src.ui.DisplayContext")
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    role = "world",
    touch = false,
  })
  local displayContext = DisplayContext.new({
    graphics = {
      getDimensions = function()
        return 640, 480
      end,
      getDPIScale = function()
        return 1
      end,
    },
    topologyProvider = function()
      return topology
    end,
  })
  local updates, resizes = 0, {}
  local state = setmetatable({
    runtime = {
      update = function()
        updates = updates + 1
        Assert.equal(#resizes, 1, "the display refreshes before the first runtime tick")
      end,
      resizePresentation = function(_, width, height, measured)
        resizes[#resizes + 1] = { width, height, measured }
      end,
      starterChoice = nil,
    },
    displayContext = displayContext,
    actorPresentation = {
      sync = function() end,
    },
  }, FieldState)
  state:update(0.016)
  Assert.equal(updates, 1, "the runtime ticks after the refresh")
  Assert.equal(#resizes, 1, "one structural sync reaches the runtime")
  Assert.equal(resizes[1][1], 640, "the refresh measures the actual drawable")
  Assert.equal(resizes[1][2], 480, "the refresh measures the actual drawable")
  state:update(0.016)
  Assert.equal(#resizes, 1, "an unchanged display never re-syncs")
end

return { tests = T }
