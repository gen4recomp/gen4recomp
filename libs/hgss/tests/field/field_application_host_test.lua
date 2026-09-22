-- FieldApplicationHost contract tests: the one application modal owner the
-- field session steps. The host owns the transition phase machine (closed/
-- menu/fading_out/application/fading_in plus the terminal failed state), its
-- own fixed-tick fade counter (fadeAlpha), the Start Menu selection
-- remembered across a child-application round trip, the modal input lifetime
-- (beginUi once at open, clearUi once on final return, failure, or
-- disposal), and exactly-once disposal of the active controller on success,
-- cancellation, failure, reset, or runtime disposal. The Start Menu is not a
-- registry entry: the host builds it through its own required menuFactory
-- (the runtime's composition step), and the immutable application registry
-- dispatches child destinations only. Fakes are the registry/input/
-- controller boundaries; the host forwards normalized events to the menu
-- wrapper unchanged, so pointer mapping is the wrapper's contract.

local Assert = require("tests.support.Assert")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")

local T = {
  tests = {},
}

---@class FieldApplicationHostTest.Controller
---@field updateFixedCalls integer
---@field disposeCount integer
---@field cancelPointerCaptureCalls integer
---@field result table|nil
---@field receivedEvents table|nil
---@field rememberedActionId string|nil
---@field presentation table|nil
---@field updateFixed fun(self: FieldApplicationHostTest.Controller, uiInput: table)
---@field status fun(self: FieldApplicationHostTest.Controller): table
---@field takeResult fun(self: FieldApplicationHostTest.Controller): table|nil
---@field dispose fun(self: FieldApplicationHostTest.Controller)
---@field cancelPointerCapture fun(self: FieldApplicationHostTest.Controller)
---@class FieldApplicationHostTest.Registry
---@field create fun(self: FieldApplicationHostTest.Registry, id: string): FieldApplicationHostTest.Controller
---@field created string[]
---@field controllers table<string, FieldApplicationHostTest.Controller|fun(): FieldApplicationHostTest.Controller>
---@field menuControllers FieldApplicationHostTest.Controller[]
---@class FieldApplicationHostTest.Input
---@field beginUiTicks integer[]
---@field clearUiCalls integer
---@class FieldApplicationHostTest.PartialOptions
---@field registry FieldApplicationHostTest.Registry?
---@field menuFactory? fun(rememberedActionId: string?): FieldApplicationHostTest.Controller?
---@field input FieldApplicationHostTest.Input?

local function throws(fn)
  return Assert.throws(fn)
end

-- A minimal controller honoring the controller contract; the test drives its
-- result through takeResult.
local function fakeController(overrides)
  local controller = {
    updateFixedCalls = 0,
    disposeCount = 0,
    cancelPointerCaptureCalls = 0,
    result = nil,
    receivedEvents = nil,
  }
  function controller:updateFixed(uiInput)
    self.updateFixedCalls = self.updateFixedCalls + 1
    self.receivedEvents = uiInput
  end
  function controller:status()
    return { open = true }
  end
  function controller:takeResult()
    local result = self.result
    self.result = nil
    return result
  end
  function controller:dispose()
    self.disposeCount = self.disposeCount + 1
  end
  function controller:cancelPointerCapture()
    self.cancelPointerCaptureCalls = self.cancelPointerCaptureCalls + 1
  end
  for key, value in pairs(overrides or {}) do
    rawset(controller, key, value)
  end
  return controller --[[@as FieldApplicationHostTest.Controller]]
end

local function fakeRegistry()
  local registry = {
    created = {},
    controllers = {},
  }
  -- Stored entries are either factories (functions) or prebuilt controllers
  -- (returned as-is); create() takes only the application id.
  function registry:create(id)
    local stored = assert(self.controllers[id], "test registry has no controller for " .. id)
    self.created[#self.created + 1] = id
    if type(stored) == "function" then
      return stored()
    end
    return stored
  end
  return registry --[[@as FieldApplicationHostTest.Registry]]
end

local function fakeInput()
  local input = {
    beginUiTicks = {},
    clearUiCalls = 0,
  }
  function input:beginUi(tick)
    self.beginUiTicks[#self.beginUiTicks + 1] = tick
  end
  function input:clearUi()
    self.clearUiCalls = self.clearUiCalls + 1
  end
  return input --[[@as FieldApplicationHostTest.Input]]
end

---@param options FieldApplicationHostTest.PartialOptions
---@return FieldApplicationHost
local function newWithPartialOptions(options)
  return FieldApplicationHost.new(options --[[@as FieldApplicationHostOptions]])
end

-- The test fixture: a registry holding one destination and a menu factory
-- returning per-call controllers, plus the input. The factory body is
-- swappable so composition/rebuild failures can be injected. Controllers are
-- created lazily so each construction is observable.
local function fixture()
  local registry = fakeRegistry()
  local input = fakeInput()
  local factory = {
    fn = function(rememberedActionId)
      local controller = fakeController()
      controller.rememberedActionId = rememberedActionId
      registry.menuControllers = registry.menuControllers or {}
      registry.menuControllers[#registry.menuControllers + 1] = controller
      return controller
    end,
  }
  local host = FieldApplicationHost.new({
    registry = registry --[[@as FieldApplicationRegistry]],
    menuFactory = function(rememberedActionId)
      return factory.fn(rememberedActionId)
    end,
    input = input --[[@as FieldInput]],
    fieldAction = function() end,
  })
  return host, input, registry, factory
end

local function openMenu(host, input, registry)
  local opened = host:requestOpen(10)
  Assert.equal(opened, true, "an open with available actions must succeed")
  Assert.equal(input.beginUiTicks[1], 10)
  return registry.menuControllers[1]
end

function T.tests.successful_field_action_closes_the_menu_without_a_child_application()
  local calls = 0
  local host, input, registry = fixture()
  host._fieldAction = function(actionId)
    calls = calls + 1
    Assert.equal(actionId, "vanilla.save")
  end
  local menu = openMenu(host, input, registry)
  menu.result = { kind = "field_action", actionId = "vanilla.save" }
  host:updateFixed({ { type = "confirm" } })
  Assert.equal(calls, 1)
  Assert.equal(host:status().phase, "closed")
  Assert.equal(input.clearUiCalls, 1)
  Assert.equal(menu.disposeCount, 1)
  Assert.deepEqual(registry.created, {})
end

function T.tests.field_action_failure_releases_menu_ownership_and_surfaces_error()
  local host, input, registry = fixture()
  host._fieldAction = function()
    error("save failed")
  end
  local menu = openMenu(host, input, registry)
  menu.result = { kind = "field_action", actionId = "vanilla.save" }
  host:updateFixed({ { type = "confirm" } })
  Assert.equal(host:status().phase, "failed")
  Assert.isTrue(tostring(host:error()):find("save failed", 1, true) ~= nil)
  Assert.equal(input.clearUiCalls, 1)
  Assert.equal(menu.disposeCount, 1)
  Assert.deepEqual(registry.created, {})
end

function T.tests.construction_requires_the_registry_menu_factory_and_input()
  local registry = fakeRegistry()
  local input = fakeInput()
  local menuFactory = function() end
  throws(function()
    local partial = { registry = registry, input = input } ---@type any
    newWithPartialOptions(partial)
  end)
  throws(function()
    local partial = { registry = registry, menuFactory = menuFactory } ---@type any
    newWithPartialOptions(partial)
  end)
  throws(function()
    local partial = { menuFactory = menuFactory, input = input } ---@type any
    newWithPartialOptions(partial)
  end)
  throws(function()
    local partial = {} ---@type any
    newWithPartialOptions(partial)
  end)
end

function T.tests.starts_closed_with_no_fade_and_no_menu()
  local host, _, _ = fixture()
  local status = host:status()
  Assert.equal(status.phase, "closed")
  Assert.equal(status.fadeAlpha, 0)
  Assert.isNil(status.applicationId)
  Assert.isNil(status.menu)
  Assert.equal(host:isActive(), false)
end

function T.tests.open_constructs_the_menu_through_the_factory_and_begins_ui_once()
  local host, input, registry = fixture()
  local controller = openMenu(host, input, registry)
  Assert.equal(host:status().phase, "menu", "the menu phase is entered on the opening tick")
  Assert.equal(host:status().menu.open, true)
  Assert.equal(host:isActive(), true)
  Assert.equal(#registry.menuControllers, 1, "the menu factory constructs exactly one controller")
  Assert.isNil(registry.menuControllers[1].rememberedActionId, "a fresh open has no remembered selection")
  Assert.equal(controller.disposeCount, 0)
end

function T.tests.menu_input_is_live_on_the_first_step()
  local host, input, registry = fixture()
  local controller = openMenu(host, input, registry)
  host:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(host:status().phase, "menu")
  Assert.equal(controller.updateFixedCalls, 1)
  Assert.equal(controller.receivedEvents[1].type, "navigate")
end

function T.tests.launch_freezes_menu_input_then_fades_out_and_dispatches_the_destination()
  local host, input, registry = fixture()
  local menu = openMenu(host, input, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  host:updateFixed({ { type = "confirm" } })
  Assert.equal(host:status().phase, "fading_out")
  Assert.equal(host:status().fadeAlpha, 0)
  Assert.equal(host:status().applicationId, "trainer_card")
  -- The menu controller is not disposed until the fade hides the world, and
  -- it is not stepped during the fade (input is frozen; the two recorded
  -- steps are the arming tick and the launch tick).
  Assert.equal(menu.disposeCount, 0)
  Assert.equal(menu.updateFixedCalls, 2)
  local fadeTicks = FieldApplicationHost.FADE_TICKS
  for tick = 1, fadeTicks - 1 do
    host:updateFixed({ { type = "cancel" } })
    Assert.equal(host:status().phase, "fading_out")
    Assert.equal(host:status().fadeAlpha, tick / fadeTicks)
  end
  host:updateFixed({ { type = "cancel" } })
  Assert.equal(host:status().phase, "application")
  Assert.equal(host:status().fadeAlpha, 1)
  Assert.equal(menu.disposeCount, 1, "the menu controller is disposed exactly once at the fade-out end")
  Assert.deepEqual(registry.created, { "trainer_card" }, "the destination dispatches through the registry only")
  -- The destination is constructed on the fade-completion tick but receives
  -- no synthetic first update there: its first updateFixed arrives on the
  -- next tick with that tick's event list.
  Assert.equal(
    destination.updateFixedCalls,
    0,
    "the destination must not receive a synthetic first update in its construction tick"
  )
  host:updateFixed({ { type = "confirm" } })
  Assert.equal(destination.updateFixedCalls, 1, "the first real update arrives on the tick after construction")
  Assert.equal(destination.receivedEvents[1].type, "confirm", "the destination receives that tick's real events")
end

function T.tests.application_steps_the_destination_once_per_tick_until_close()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  Assert.equal(host:status().phase, "application")
  Assert.equal(destination.updateFixedCalls, 0, "construction itself never steps the destination")
  host:updateFixed({ { type = "cancel" } })
  Assert.equal(destination.receivedEvents[1].type, "cancel", "the destination receives the tick events")
  host:updateFixed({})
  Assert.equal(destination.updateFixedCalls, 2)
end

-- The renderer channel: during the application phase the host snapshot
-- exposes the destination's own presentation (status.application), and the
-- menu phase / fade phases expose no application surface even while the
-- destination id is known. FieldState chooses the renderer from this channel.
function T.tests.application_phase_exposes_the_destination_presentation_and_other_phases_do_not()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  Assert.equal(host:status().application, nil, "the menu phase presents no application surface")
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController({ presentation = { name = "GOLD", trainerId = 0 } })
  registry.controllers.trainer_card = destination
  host:updateFixed({})
  Assert.equal(host:status().application, nil, "the fade-out phase presents no application surface")
  for _ = 13, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  Assert.equal(host:status().phase, "application")
  Assert.deepEqual(
    host:status().application,
    destination:status(),
    "the application phase exposes the destination presentation"
  )
  destination.result = { kind = "close" }
  host:updateFixed({})
  Assert.equal(host:status().application, nil, "the fade-in after a close presents no application surface")
end

function T.tests.destination_close_disposes_exactly_once_and_fades_back_in()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  destination.result = { kind = "close" }
  host:updateFixed({ { type = "cancel" } })
  Assert.equal(destination.disposeCount, 1, "the returned destination is disposed exactly once")
  Assert.equal(host:status().phase, "fading_in")
  Assert.equal(host:status().fadeAlpha, 1)
  local fadeTicks = FieldApplicationHost.FADE_TICKS
  for tick = 1, fadeTicks - 1 do
    host:updateFixed({})
    Assert.equal(host:status().fadeAlpha, 1 - tick / fadeTicks)
  end
  host:updateFixed({})
  Assert.equal(host:status().fadeAlpha, 0)
  Assert.equal(host:status().phase, "menu")
  Assert.equal(destination.disposeCount, 1, "the destination is never disposed twice")
end

function T.tests.menu_rebuild_restores_the_remembered_selection_by_action_id()
  local host, input, registry = fixture()
  local menu = openMenu(host, input, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  destination.result = { kind = "close" }
  host:updateFixed({ { type = "cancel" } })
  for _ = 31, 30 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  Assert.equal(host:status().phase, "menu")
  Assert.equal(#registry.menuControllers, 2)
  Assert.equal(
    registry.menuControllers[2].rememberedActionId,
    "vanilla.trainer_card",
    "the rebuild passes the remembered action id to the menu factory"
  )
  Assert.equal(input.beginUiTicks[1], 10, "the input lifetime is begun exactly once")
  Assert.equal(input.beginUiTicks[2], nil, "the child round trip never nests beginUi")
  Assert.equal(input.clearUiCalls, 0, "ownership is retained across the child round trip")
end

function T.tests.menu_close_disposes_controller_and_releases_ownership_in_the_same_tick()
  local host, input, registry = fixture()
  local menu = openMenu(host, input, registry)
  host:updateFixed({})
  menu.result = { kind = "close" }
  host:updateFixed({ { type = "menu" } })
  Assert.equal(menu.disposeCount, 1, "the closing menu controller is disposed exactly once")
  Assert.equal(input.clearUiCalls, 1, "the final field return releases the modal input lifetime once")
  Assert.equal(host:status().phase, "closed", "no closing phase exists: the host returns to closed on the tick")
  Assert.equal(host:isActive(), false)
  Assert.equal(host:status().fadeAlpha, 0)
end

function T.tests.update_fixed_requires_an_active_host()
  local host, _, _ = fixture()
  throws(function()
    host:updateFixed({})
  end)
end

function T.tests.open_while_active_is_a_programming_invariant()
  local host = fixture()
  host:requestOpen(10)
  throws(function()
    host:requestOpen(11)
  end)
end

function T.tests.destination_factory_failure_after_fade_out_retains_the_error_and_releases_ownership()
  local host, input, registry = fixture()
  local menu = openMenu(host, input, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  registry.controllers.trainer_card = function()
    error("injected destination factory failure")
  end
  for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  Assert.equal(host:status().phase, "failed")
  Assert.isTrue(tostring(host:error()):find("injected destination factory failure", 1, true) ~= nil)
  Assert.equal(menu.disposeCount, 1, "the failed dispatch still disposes the menu controller exactly once")
  Assert.equal(input.clearUiCalls, 1, "the failed dispatch releases the modal input lifetime")
  Assert.isNil(host:status().applicationId, "the failed host clears the pending destination id")
  Assert.isNil(host:status().menu)
  Assert.isNil(host:status().application)
  Assert.equal(host:status().fadeAlpha, 0, "the failed host clears its fade state")
  Assert.equal(host:isActive(), true, "the failed host stays active so the world never resumes")
  host:updateFixed({})
  Assert.equal(host:status().phase, "failed", "the failed phase is terminal")
end

-- A fatal Start Menu composition failure must consume the tick that opened
-- it: the host has entered its terminal failed ownership state, so the open
-- returns true (tick consumed), never false (which would let the field
-- continue stepping the same tick). Nothing is acquired: no controller, no
-- input lifetime.
function T.tests.menu_composition_failure_at_open_consumes_the_tick()
  local host, input, _, factory = fixture()
  factory.fn = function()
    error("injected menu composition failure")
  end
  Assert.equal(host:requestOpen(10), true, "a fatal composition failure must report the tick as consumed")
  Assert.equal(host:status().phase, "failed")
  Assert.equal(input.beginUiTicks[1], nil, "a failed composition never begins the modal input lifetime")
  Assert.equal(input.clearUiCalls, 0)
  Assert.isTrue(tostring(host:error()):find("injected menu composition failure", 1, true) ~= nil)
  Assert.equal(host:isActive(), true, "the failed host stays active so the world never resumes")
end

-- A zero-action menu is not a first-class modal: the menu factory returns
-- nil to say "menu currently unavailable", and the open is a no-op -- the
-- host stays closed, nothing is constructed, no input lifetime begins, no
-- failure is recorded, and the field continues normally.
function T.tests.menu_factory_returning_nil_is_a_noop_open()
  local host, input, registry, factory = fixture()
  factory.fn = function()
    return nil
  end
  Assert.equal(host:requestOpen(10), false, "an unavailable menu must report that nothing opened")
  Assert.equal(host:status().phase, "closed", "a no-op open must leave the host closed")
  Assert.equal(host:status().menu, nil)
  Assert.equal(host:isActive(), false, "a no-op open must not own the tick")
  Assert.equal(host:error(), nil, "a no-op open must not record a failure")
  Assert.equal(input.beginUiTicks[1], nil, "a no-op open must not begin the modal input lifetime")
  Assert.equal(#(registry.menuControllers or {}), 0, "a no-op open must not construct a controller")
end

function T.tests.menu_rebuild_failure_after_return_is_retained_after_the_destination_disposal()
  local host, input, registry, factory = fixture()
  local menu = openMenu(host, input, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  destination.result = { kind = "close" }
  host:updateFixed({ { type = "cancel" } })
  Assert.equal(destination.disposeCount, 1)
  factory.fn = function()
    error("injected rebuild failure")
  end
  for _ = 31, 30 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  Assert.equal(host:status().phase, "failed")
  Assert.equal(destination.disposeCount, 1, "the returned destination is never disposed twice")
  Assert.equal(
    input.clearUiCalls,
    1,
    "the rebuild failure releases the modal input lifetime held across the round trip"
  )
  Assert.isTrue(tostring(host:error()):find("injected rebuild failure", 1, true) ~= nil)
end

-- When no action is interactive anymore after a child-application return,
-- the rebuild releases the modal lifetime and returns to the field instead
-- of presenting a blank menu: the child was already disposed exactly once
-- and the save boundary is restored.
function T.tests.menu_unavailable_at_rebuild_returns_to_the_field()
  local host, input, registry, factory = fixture()
  local menu = openMenu(host, input, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  destination.result = { kind = "close" }
  host:updateFixed({ { type = "cancel" } })
  Assert.equal(destination.disposeCount, 1)
  factory.fn = function()
    return nil
  end
  for _ = 31, 30 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  Assert.equal(host:status().phase, "closed", "an unavailable rebuild must return to the field")
  Assert.equal(host:isActive(), false)
  Assert.equal(destination.disposeCount, 1, "the returned destination is never disposed twice")
  Assert.equal(input.clearUiCalls, 1, "the modal input lifetime is released once on the field return")
  Assert.equal(host:error(), nil, "an unavailable rebuild must not record a failure")
  Assert.equal(host:status().fadeAlpha, 0, "the returned host must not keep fade state")
end

function T.tests.reopen_request_is_consumed_by_take_reopen_once()
  local host, input = fixture()
  host:requestReopen()
  Assert.equal(host:takeReopen(20), true)
  Assert.equal(input.beginUiTicks[1], 20)
  Assert.equal(host:takeReopen(21), false, "a consumed reopen request never opens twice")
  local second, secondInput = fixture()
  second:requestReopen()
  second:requestReopen()
  Assert.equal(second:takeReopen(22), true, "a repeated request is a single pending open")
  Assert.equal(secondInput.beginUiTicks[1], 22)
  Assert.equal(second:status().phase, "menu")
end

function T.tests.reopen_while_active_is_a_programming_invariant()
  local host = fixture()
  host:requestOpen(10)
  throws(function()
    host:requestReopen()
  end)
end

-- A reopen with no interactive actions is consumed as a no-op: the pending
-- request is cleared, nothing opens, and the host stays closed.
function T.tests.take_reopen_with_an_unavailable_menu_is_a_noop()
  local host, input, _, factory = fixture()
  factory.fn = function()
    return nil
  end
  host:requestReopen()
  Assert.equal(host:takeReopen(20), false, "an unavailable reopen must report that nothing opened")
  Assert.equal(host:status().phase, "closed")
  Assert.equal(input.beginUiTicks[1], nil)
  Assert.equal(host:takeReopen(21), false, "the consumed reopen request never opens twice")
end

-- A pending script reopen whose composition fails is also a tick consumer:
-- the request is cleared and the host enters its terminal failed state, so
-- takeReopen must report the tick as consumed, never as a no-op open.
function T.tests.take_reopen_with_a_failing_factory_consumes_the_tick()
  local host, input, _, factory = fixture()
  factory.fn = function()
    error("injected reopen composition failure")
  end
  host:requestReopen()
  Assert.equal(host:takeReopen(20), true, "a fatal reopen composition must report the tick as consumed")
  Assert.equal(host:status().phase, "failed")
  Assert.equal(host:isActive(), true)
  Assert.equal(input.beginUiTicks[1], nil, "a failed reopen never begins the modal input lifetime")
  Assert.isTrue(tostring(host:error()):find("injected reopen composition failure", 1, true) ~= nil)
end

-- The per-phase disposal matrix: runtime disposal in every phase releases
-- the active controller exactly once and the modal input lifetime once (the
-- failed phase already released both through the failure cleanup).
function T.tests.dispose_in_every_phase_releases_exactly_once()
  local cases = {
    { phase = "closed", controllers = 0, clears = 0 },
    { phase = "menu", controllers = 1, clears = 1 },
    { phase = "fading_out", controllers = 1, clears = 1 },
    { phase = "application", controllers = 1, clears = 1 },
    { phase = "fading_in", controllers = 0, clears = 1 },
    { phase = "failed", controllers = 0, clears = 1 },
  }
  for _, case in ipairs(cases) do
    local host, input, registry = fixture()
    local destination = fakeController()
    registry.controllers.trainer_card = destination
    if case.phase == "menu" then
      host:requestOpen(10)
    elseif case.phase == "fading_out" then
      host:requestOpen(10)
      host:updateFixed({})
      registry.menuControllers[1].result = {
        kind = "launch",
        applicationId = "trainer_card",
        actionId = "vanilla.trainer_card",
      }
      host:updateFixed({})
    elseif case.phase == "application" then
      host:requestOpen(10)
      host:updateFixed({})
      registry.menuControllers[1].result = {
        kind = "launch",
        applicationId = "trainer_card",
        actionId = "vanilla.trainer_card",
      }
      for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
        host:updateFixed({})
      end
    elseif case.phase == "fading_in" then
      host:requestOpen(10)
      host:updateFixed({})
      registry.menuControllers[1].result = {
        kind = "launch",
        applicationId = "trainer_card",
        actionId = "vanilla.trainer_card",
      }
      for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
        host:updateFixed({})
      end
      destination.result = { kind = "close" }
      host:updateFixed({ { type = "cancel" } })
    elseif case.phase == "failed" then
      host:requestOpen(10)
      host:updateFixed({})
      registry.menuControllers[1].result = {
        kind = "launch",
        applicationId = "trainer_card",
        actionId = "vanilla.trainer_card",
      }
      registry.controllers.trainer_card = function()
        error("injected failure")
      end
      for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
        host:updateFixed({})
      end
    end
    host:dispose()
    local menu = registry.menuControllers and registry.menuControllers[1]
    -- The menu is constructed in every non-closed phase; the failed phase
    -- already disposed it through the fade-out path.
    local menuDisposed = case.phase ~= "closed"
    local destinationDisposed = case.phase == "application" or case.phase == "fading_in"
    if menu then
      Assert.equal(menu.disposeCount, menuDisposed and 1 or 0, case.phase .. " must dispose the menu exactly once")
    end
    Assert.equal(
      destination.disposeCount,
      destinationDisposed and 1 or 0,
      case.phase .. " must dispose the destination exactly once"
    )
    Assert.equal(input.clearUiCalls, case.clears, case.phase .. " must release the input lifetime once")
    Assert.equal(host:status().phase, "closed")
    Assert.equal(host:isActive(), false)
    host:dispose()
    if menu then
      Assert.equal(menu.disposeCount <= 1, true, case.phase .. " dispose must be idempotent")
    end
    Assert.equal(destination.disposeCount <= 1, true, case.phase .. " dispose must be idempotent")
    Assert.equal(input.clearUiCalls, case.clears, case.phase .. " clearUi must stay exactly once")
  end
end

-- Disposal is total teardown for the queued script reopen too: the pending
-- request is independent host state, so a dispose from the closed phase must
-- still clear it. After requestReopen(); dispose(); the host is fully clean:
-- takeReopen must report nothing pending, never invoke the menu factory, and
-- never begin a modal input lifetime.
function T.tests.dispose_clears_a_queued_reopen()
  local host, input, registry = fixture()
  host:requestReopen()
  host:dispose()
  Assert.equal(host:takeReopen(20), false, "a disposed host must not open the queued reopen")
  Assert.equal(#(registry.menuControllers or {}), 0, "the menu factory must not run after disposal")
  Assert.equal(input.beginUiTicks[1], nil, "disposal must not begin a modal input lifetime")
  Assert.equal(input.clearUiCalls, 0, "a clean dispose must not clear an unheld lifetime")
  Assert.equal(host:status().phase, "closed", "disposal must leave the host closed")
  Assert.equal(host:isActive(), false)
  Assert.equal(host:error(), nil, "disposal must not retain a failure")
end

-- A repeated dispose is a no-op: the second call must not dispose the
-- already-released controller again or clear the already-released modal
-- input lifetime again.
function T.tests.dispose_twice_never_double_disposes_or_double_clears()
  local host, input, registry = fixture()
  local menu = openMenu(host, input, registry)
  host:dispose()
  host:dispose()
  Assert.equal(menu.disposeCount, 1, "two disposes dispose the controller exactly once")
  Assert.equal(input.clearUiCalls, 1, "two disposes clear the modal input lifetime exactly once")
  Assert.equal(host:status().phase, "closed")
  Assert.equal(host:isActive(), false)
  Assert.equal(host:error(), nil)
end

-- Focus-loss capture cancellation follows the live controller, not the phase
-- name: the open menu, the menu retained through fade-out, and a
-- destination exposing the optional method all receive exactly one
-- delegation; a controller without the capability and a closed host are
-- no-ops that change nothing.
function T.tests.cancel_delegates_to_the_live_controller_in_any_phase()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  host:cancelPointerCapture()
  Assert.equal(menu.cancelPointerCaptureCalls, 1, "focus loss delegates cancellation to the open menu")
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  host:updateFixed({})
  Assert.equal(host:status().phase, "fading_out")
  host:cancelPointerCapture()
  Assert.equal(menu.cancelPointerCaptureCalls, 2, "focus loss during fade-out still cancels the retained live menu")
  for _ = 1, FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  Assert.equal(host:status().phase, "application")
  host:cancelPointerCapture()
  Assert.equal(destination.cancelPointerCaptureCalls, 1, "focus loss delegates cancellation to the live destination")
  Assert.equal(host:status().phase, "application", "cancellation changes neither phase nor controller")
end

function T.tests.cancel_without_the_optional_capability_is_a_noop()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local keyboardOnly = fakeController()
  keyboardOnly.cancelPointerCapture = nil
  registry.controllers.trainer_card = keyboardOnly
  host:updateFixed({})
  for _ = 1, FieldApplicationHost.FADE_TICKS + 1 do
    host:updateFixed({})
  end
  Assert.equal(host:status().phase, "application")
  host:cancelPointerCapture()
  Assert.equal(host:status().phase, "application", "cancelling without the capability changes nothing")
end

function T.tests.cancel_on_a_closed_host_cancels_nothing()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  menu.result = { kind = "close" }
  host:updateFixed({})
  Assert.equal(host:status().phase, "closed")
  host:cancelPointerCapture()
  Assert.equal(menu.cancelPointerCaptureCalls, 0, "a closed host cancels nothing")
end

function T.tests.menu_controllers_receive_raw_normalized_events_unchanged()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  local batch = {
    { type = "pointer_down", pointerId = "p1", x = 64, y = 48 },
    { type = "pointer_move", pointerId = "p1", x = 400, y = 100 },
    { type = "pointer_up", pointerId = "p1", x = 64, y = 48 },
    { type = "pointer_scroll", pointerId = "p1", dx = 0, dy = -1 },
  }
  host:updateFixed(batch)
  local events = assert(menu.receivedEvents)
  Assert.equal(#events, 4, "the host forwards the whole normalized batch")
  Assert.equal(events[1].x, 64, "host coordinates reach the wrapper unmapped")
  Assert.equal(events[1].y, 48)
  Assert.equal(events[2].type, "pointer_move", "nothing is dropped outside a frame the host no longer owns")
  Assert.equal(events[4].type, "pointer_scroll", "scroll reaches the wrapper, which decides")
end

function T.tests.destination_controllers_receive_events_passthrough()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for _ = 1, FieldApplicationHost.FADE_TICKS + 1 do
    host:updateFixed({})
  end
  host:updateFixed({ { type = "cancel" }, { type = "pointer_down", pointerId = "p1", x = 0, y = 0 } })
  Assert.equal(destination.receivedEvents[1].type, "cancel")
  Assert.equal(destination.receivedEvents[2].type, "pointer_down", "destinations own their input policy")
end

function T.tests.a_destination_launch_result_is_a_programming_invariant()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed({})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for _ = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed({})
  end
  destination.result = { kind = "launch", applicationId = "pokedex" }
  throws(function()
    host:updateFixed({})
  end)
end

return T
