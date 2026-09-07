-- Converts directional and semantic button edges into deterministic fixed-tick
-- snapshots. The most recently pressed held direction wins; each press edge is
-- consumed once so FieldPlayer can buffer it without depending on render
-- cadence. Action, Cancel, and Menu are semantic buttons: any number of
-- physical bindings collapse into one edge per tick, held state is separate
-- from the edge, and focus loss or a transition commit clears them.
-- Each semantic button tracks the physical sources that hold it down (opaque
-- identities such as "key:enter", "key:space", "gamepad:1:a" supplied by the
-- caller): a button stays down until the last source is released, and a
-- repeat press from an already-held source produces no new edge.

---@class FieldInput
---@field directions table<string, { sources: table<string, boolean>, order: integer }>
---@field directionSources table<string, string>
---@field nextOrder integer
---@field actionSources table<string, boolean>
---@field actionDown boolean
---@field actionPressed boolean
---@field cancelSources table<string, boolean>
---@field cancelDown boolean
---@field cancelPressed boolean
---@field menuSources table<string, boolean>
---@field menuDown boolean
---@field menuPressed boolean
---@field pressedDirection string?
---@field uiDirections table<string, { sources: table<string, boolean>, order: integer }>
---@field uiNextOrder integer
---@field uiPressedDirection string?
---@field uiRepeatStartedAt integer?
---@field uiRepeatLastAt integer?
---@field uiRepeatDelay integer
---@field uiRepeatInterval integer
---@field uiConfirmPressed boolean
---@field uiCancelPressed boolean
---@field uiPointerEvents table[]
---@field uiPointers table<string, { x: number, y: number, startX: number, startY: number, dragged: boolean }>
---@field stickDirections table<string, string?>
---@field stickAxes table<string, { x: number, y: number }>
---@field uiActive boolean
---@field uiStickPressThreshold number
---@field uiStickReleaseThreshold number
---@field uiTouchDragThreshold number
local FieldInput = {}
FieldInput.__index = FieldInput

FieldInput.UI_REPEAT_DELAY_TICKS = 18
FieldInput.UI_REPEAT_INTERVAL_TICKS = 4
FieldInput.STICK_PRESS_THRESHOLD = 0.6
FieldInput.STICK_RELEASE_THRESHOLD = 0.4
FieldInput.TOUCH_DRAG_THRESHOLD_PIXELS = 8

local VALID = { north = true, south = true, west = true, east = true }
local UI_DIRECTIONS = { up = true, down = true, left = true, right = true }
local TO_UI_DIRECTION = { north = "up", south = "down", west = "left", east = "right" }
local UI_TO_FIELD_DIRECTION = { up = "north", down = "south", left = "west", right = "east" }

---@param direction string
local function requireDirection(direction)
  assert(VALID[direction], "unknown field direction " .. tostring(direction))
end

---@param source string
local function requireSource(source)
  assert(type(source) == "string" and source ~= "", "physical button source identity required")
end

---@param value unknown
---@param name string
local function requireFiniteNumber(value, name)
  assert(
    type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
    name .. " must be finite"
  )
end

---@param direction string
local function requireUiDirection(direction)
  assert(UI_DIRECTIONS[direction], "unknown UI direction " .. tostring(direction))
end

---@param value unknown
---@param name string
local function requirePositiveInteger(value, name)
  assert(type(value) == "number" and value == math.floor(value) and value > 0, name .. " must be a positive integer")
end

---@param value unknown
---@param name string
local function requireNonNegativeInteger(value, name)
  assert(
    type(value) == "number" and value == math.floor(value) and value >= 0,
    name .. " must be a non-negative integer"
  )
end

---@param value unknown
---@param name string
local function requireUnitInterval(value, name)
  requireFiniteNumber(value, name)
  assert(value > 0 and value <= 1, name .. " must be in (0, 1]")
end

---@param options table<string, unknown>?
---@return FieldInput
function FieldInput.new(options)
  options = options or {}
  assert(type(options) == "table", "field input options must be a table")
  local uiRepeatDelay = options.uiRepeatDelay or FieldInput.UI_REPEAT_DELAY_TICKS
  local uiRepeatInterval = options.uiRepeatInterval or FieldInput.UI_REPEAT_INTERVAL_TICKS
  local uiStickPressThreshold = options.uiStickPressThreshold or FieldInput.STICK_PRESS_THRESHOLD
  local uiStickReleaseThreshold = options.uiStickReleaseThreshold or FieldInput.STICK_RELEASE_THRESHOLD
  local uiTouchDragThreshold = options.touchDragThreshold or FieldInput.TOUCH_DRAG_THRESHOLD_PIXELS
  requirePositiveInteger(uiRepeatDelay, "UI repeat delay")
  requirePositiveInteger(uiRepeatInterval, "UI repeat interval")
  requireUnitInterval(uiStickPressThreshold, "UI stick press threshold")
  requireUnitInterval(uiStickReleaseThreshold, "UI stick release threshold")
  assert(uiStickReleaseThreshold < uiStickPressThreshold, "UI stick release threshold must be below press threshold")
  requireFiniteNumber(uiTouchDragThreshold, "UI touch drag threshold")
  assert(uiTouchDragThreshold >= 0, "UI touch drag threshold must not be negative")
  return setmetatable({
    directions = {},
    directionSources = {},
    nextOrder = 0,
    actionSources = {},
    actionDown = false,
    actionPressed = false,
    cancelSources = {},
    cancelDown = false,
    cancelPressed = false,
    menuSources = {},
    menuDown = false,
    menuPressed = false,
    uiDirections = {},
    uiNextOrder = 0,
    uiRepeatDelay = uiRepeatDelay,
    uiRepeatInterval = uiRepeatInterval,
    uiPointerEvents = {},
    uiPointers = {},
    uiActive = false,
    stickDirections = {},
    stickAxes = {},
    uiStickPressThreshold = uiStickPressThreshold,
    uiStickReleaseThreshold = uiStickReleaseThreshold,
    uiTouchDragThreshold = uiTouchDragThreshold,
  }, FieldInput)
end

---@param direction string
---@param source string
function FieldInput:pressDirection(direction, source)
  requireDirection(direction)
  requireSource(source)
  local previous = self.directionSources[source]
  if previous == direction then
    return
  end
  if previous then
    self:releaseDirection(source)
  end
  self.directionSources[source] = direction
  local state = self.directions[direction]
  local wasHeld = state ~= nil
  if not state then
    state = { sources = {}, order = 0 }
    self.directions[direction] = state
  end
  self.nextOrder = self.nextOrder + 1
  state.sources[source] = true
  state.order = self.nextOrder
  if not wasHeld then
    self.pressedDirection = direction
  end
  self:_pressUi(TO_UI_DIRECTION[direction], source)
end

---@param source string
function FieldInput:releaseDirection(source)
  requireSource(source)
  local direction = self.directionSources[source]
  if not direction then
    return
  end
  self.directionSources[source] = nil
  local state = assert(self.directions[direction], "held direction state is missing")
  state.sources[source] = nil
  if not next(state.sources) then
    self.directions[direction] = nil
  end
  self:_releaseUi(TO_UI_DIRECTION[direction], source)
end

-- Non-host runtime helpers retain their simple cardinal API with local source
-- identities. Hardware callbacks use pressDirection/releaseDirection.
---@param direction string
function FieldInput:press(direction)
  requireDirection(direction)
  self:pressDirection(direction, "runtime:" .. direction)
end

---@param direction string
function FieldInput:release(direction)
  requireDirection(direction)
  self:releaseDirection("runtime:" .. direction)
end

---@param direction string
---@return boolean
function FieldInput:isHeld(direction)
  requireDirection(direction)
  return self.directions[direction] ~= nil
end

---@return string?
function FieldInput:heldDirection()
  local selected, selectedOrder
  for direction, state in pairs(self.directions) do
    if not selectedOrder or state.order > selectedOrder then
      selected, selectedOrder = direction, state.order
    end
  end
  return selected
end

-- Semantic Action: the first physical source down raises the button and emits
-- one press edge; a further source (or a repeat press of a held source) stays
-- silent until the button rises again -- the edge fires only on the zero-to-one
-- source transition.

---@param source string
function FieldInput:pressAction(source)
  requireSource(source)
  if self.actionSources[source] then
    return
  end
  local wasDown = next(self.actionSources) ~= nil
  self.actionSources[source] = true
  self.actionDown = true
  if not wasDown then
    self.actionPressed = true
    self.uiConfirmPressed = true
  end
end

---@param source string
function FieldInput:releaseAction(source)
  requireSource(source)
  self.actionSources[source] = nil
  if not next(self.actionSources) then
    self.actionDown = false
  end
end

---@param source string
function FieldInput:pressCancel(source)
  requireSource(source)
  if self.cancelSources[source] then
    return
  end
  local wasDown = next(self.cancelSources) ~= nil
  self.cancelSources[source] = true
  self.cancelDown = true
  if not wasDown then
    self.cancelPressed = true
    self.uiCancelPressed = true
  end
end

---@param source string
function FieldInput:releaseCancel(source)
  requireSource(source)
  self.cancelSources[source] = nil
  if not next(self.cancelSources) then
    self.cancelDown = false
  end
end

-- The semantic Menu button (the Start Menu open/close edge): the same
-- source-aware model as Action/Cancel. FieldState maps keyboard "m" and the
-- gamepad west face ("x") to it; the session checks the edge at the idle
-- field boundary and the application host translates a fresh press into the
-- menu-close semantics while the Start Menu owns the tick.

---@param source string
function FieldInput:pressMenu(source)
  requireSource(source)
  if self.menuSources[source] then
    return
  end
  local wasDown = next(self.menuSources) ~= nil
  self.menuSources[source] = true
  self.menuDown = true
  if not wasDown then
    self.menuPressed = true
  end
end

---@param source string
function FieldInput:releaseMenu(source)
  requireSource(source)
  self.menuSources[source] = nil
  if not next(self.menuSources) then
    self.menuDown = false
  end
end

-- Menu navigation has independent source tracking and repeat timing. Field
-- directions are its only production input; a modal owner decides which
-- snapshot to consume without making UI repeat a script concern.

---@param direction "up"|"down"|"left"|"right"
---@param source string
function FieldInput:_pressUi(direction, source)
  requireUiDirection(direction)
  requireSource(source)
  local state = self.uiDirections[direction]
  local wasHeld = state ~= nil
  if not state then
    state = { sources = {}, order = 0 }
    self.uiDirections[direction] = state
  end
  if state.sources[source] then
    return
  end
  state.sources[source] = true
  self.uiNextOrder = self.uiNextOrder + 1
  state.order = self.uiNextOrder
  if not wasHeld then
    self.uiPressedDirection = direction
  end
end

---@param direction "up"|"down"|"left"|"right"
---@param source string
function FieldInput:_releaseUi(direction, source)
  requireUiDirection(direction)
  requireSource(source)
  local state = self.uiDirections[direction]
  if not state then
    return
  end
  state.sources[source] = nil
  if not next(state.sources) then
    self.uiDirections[direction] = nil
  end
end

---@return string?
function FieldInput:heldUiDirection()
  local selected, selectedOrder
  for direction, state in pairs(self.uiDirections) do
    if not selectedOrder or state.order > selectedOrder then
      selected, selectedOrder = direction, state.order
    end
  end
  return selected
end

---@param source string
---@param x number
---@param y number
function FieldInput:setStick(source, x, y)
  requireSource(source)
  requireFiniteNumber(x, "UI stick x")
  requireFiniteNumber(y, "UI stick y")
  assert(math.abs(x) <= 1 and math.abs(y) <= 1, "UI stick axes must be in [-1, 1]")

  local previous = self.stickDirections[source]
  local magnitude = previous and self.uiStickReleaseThreshold or self.uiStickPressThreshold
  local direction
  if math.max(math.abs(x), math.abs(y)) >= magnitude then
    if math.abs(x) >= math.abs(y) then
      direction = x < 0 and "left" or "right"
    else
      direction = y < 0 and "up" or "down"
    end
  end
  if direction == previous then
    return
  end
  if previous then
    self:releaseDirection(source)
  end
  self.stickDirections[source] = direction
  if direction then
    self:pressDirection(UI_TO_FIELD_DIRECTION[direction], source)
  end
end

---@param source string
---@param axis "x"|"y"
---@param value number
function FieldInput:setStickAxis(source, axis, value)
  requireSource(source)
  assert(axis == "x" or axis == "y", "unknown stick axis " .. tostring(axis))
  requireFiniteNumber(value, "stick axis")
  assert(math.abs(value) <= 1, "stick axis must be in [-1, 1]")
  local axes = self.stickAxes[source] or { x = 0, y = 0 }
  self.stickAxes[source] = axes
  axes[axis] = value
  self:setStick(source, axes.x, axes.y)
end

---@param pointerId string
---@param x number
---@param y number
function FieldInput:pointerDown(pointerId, x, y)
  requireSource(pointerId)
  requireFiniteNumber(x, "pointer x")
  requireFiniteNumber(y, "pointer y")
  if not self.uiActive then
    return
  end
  self.uiPointers[pointerId] = { x = x, y = y, startX = x, startY = y, dragged = false }
  self.uiPointerEvents[#self.uiPointerEvents + 1] = { type = "pointer_down", pointerId = pointerId, x = x, y = y }
end

---@param pointerId string
---@param x number
---@param y number
function FieldInput:pointerMove(pointerId, x, y)
  requireSource(pointerId)
  requireFiniteNumber(x, "pointer x")
  requireFiniteNumber(y, "pointer y")
  if not self.uiActive then
    return
  end
  local pointer = self.uiPointers[pointerId]
  if pointer then
    pointer.x, pointer.y = x, y
    local dx, dy = x - pointer.startX, y - pointer.startY
    if dx * dx + dy * dy > self.uiTouchDragThreshold * self.uiTouchDragThreshold then
      pointer.dragged = true
    end
  end
  self.uiPointerEvents[#self.uiPointerEvents + 1] = { type = "pointer_move", pointerId = pointerId, x = x, y = y }
end

---@param pointerId string
---@param x number
---@param y number
function FieldInput:pointerUp(pointerId, x, y)
  requireSource(pointerId)
  requireFiniteNumber(x, "pointer x")
  requireFiniteNumber(y, "pointer y")
  if not self.uiActive then
    return
  end
  local pointer = self.uiPointers[pointerId]
  if not pointer then
    return
  end
  local dx, dy = x - pointer.startX, y - pointer.startY
  if dx * dx + dy * dy > self.uiTouchDragThreshold * self.uiTouchDragThreshold then
    pointer.dragged = true
  end
  self.uiPointers[pointerId] = nil
  self.uiPointerEvents[#self.uiPointerEvents + 1] = {
    type = "pointer_up",
    pointerId = pointerId,
    x = x,
    y = y,
    dragged = pointer.dragged,
  }
end

---@param pointerId string
---@param dx number
---@param dy number
function FieldInput:pointerScroll(pointerId, dx, dy)
  requireSource(pointerId)
  requireFiniteNumber(dx, "pointer scroll x")
  requireFiniteNumber(dy, "pointer scroll y")
  if self.uiActive then
    self.uiPointerEvents[#self.uiPointerEvents + 1] =
      { type = "pointer_scroll", pointerId = pointerId, dx = dx, dy = dy }
  end
end

-- Begins a modal UI lifetime without treating an already-held control as an
-- activation edge. The held direction is eligible to repeat after its normal
-- delay, so an opening menu neither jumps nor leaves a stuck control inert.

---@param tick integer
function FieldInput:beginUi(tick)
  requireNonNegativeInteger(tick, "UI tick")
  self.uiPressedDirection = nil
  self.uiConfirmPressed = nil
  self.uiCancelPressed = nil
  self.menuPressed = nil
  self.uiPointerEvents = {}
  self.uiPointers = {}
  self.uiActive = true
  self.uiRepeatStartedAt = tick
  self.uiRepeatLastAt = nil
end

---@param tick integer
---@return table[]
function FieldInput:uiSnapshot(tick)
  requireNonNegativeInteger(tick, "UI tick")
  local events = {}
  local direction = self.uiPressedDirection
  if direction then
    events[#events + 1] = { type = "navigate", direction = direction }
    self.uiRepeatStartedAt = tick
    self.uiRepeatLastAt = nil
  else
    direction = self:heldUiDirection()
    if not direction then
      self.uiRepeatStartedAt = nil
      self.uiRepeatLastAt = nil
    elseif self.uiRepeatStartedAt == nil then
      self.uiRepeatStartedAt = tick
    elseif
      tick - self.uiRepeatStartedAt >= self.uiRepeatDelay
      and (self.uiRepeatLastAt == nil or tick - self.uiRepeatLastAt >= self.uiRepeatInterval)
    then
      events[#events + 1] = { type = "navigate", direction = direction }
      self.uiRepeatLastAt = tick
    end
  end
  if self.uiConfirmPressed then
    events[#events + 1] = { type = "confirm" }
  end
  if self.uiCancelPressed then
    events[#events + 1] = { type = "cancel" }
  end
  for index = 1, #self.uiPointerEvents do
    events[#events + 1] = self.uiPointerEvents[index]
  end
  self.uiPressedDirection = nil
  self.uiConfirmPressed = nil
  self.uiCancelPressed = nil
  self.uiPointerEvents = {}
  return events
end

-- Closing a modal UI drops its queued physical events and pointer capture
-- without releasing the field's held movement controls.
function FieldInput:clearUi()
  self.uiPressedDirection = nil
  self.uiRepeatStartedAt = nil
  self.uiRepeatLastAt = nil
  self.uiConfirmPressed = nil
  self.uiCancelPressed = nil
  self.uiPointerEvents = {}
  self.uiPointers = {}
  self.uiActive = false
end

-- Snapshot consumes every edge exactly once per fixed tick; held state is
-- carried through so modal consumers can distinguish "held" from "pressed".

---@return FieldInput.Snapshot
function FieldInput:snapshot()
  local snapshot = {
    heldDirection = self:heldDirection(),
    actionDown = self.actionDown,
    cancelDown = self.cancelDown,
    menuDown = self.menuDown,
  }
  if self.pressedDirection then
    snapshot.pressedDirection = self.pressedDirection
  end
  if self.actionPressed then
    snapshot.actionPressed = true
  end
  if self.cancelPressed then
    snapshot.cancelPressed = true
  end
  if self.menuPressed then
    snapshot.menuPressed = true
  end
  self.pressedDirection = nil
  self.actionPressed = nil
  self.cancelPressed = nil
  self.menuPressed = nil
  return snapshot
end

-- Transition commits and dialogue closes must not leave a stale edge that a
-- later tick could act on; held state survives.
function FieldInput:clearEdges()
  self.pressedDirection = nil
  self.actionPressed = nil
  self.cancelPressed = nil
  self.menuPressed = nil
end

-- Focus loss clears held and edge state entirely, including every physical
-- button source so a stray release after refocus cannot mutate a cleared
-- button.
function FieldInput:clearAll()
  self:clearEdges()
  self.directions = {}
  self.directionSources = {}
  self.actionSources = {}
  self.actionDown = false
  self.cancelSources = {}
  self.cancelDown = false
  self.menuSources = {}
  self.menuDown = false
  self.uiDirections = {}
  self:clearUi()
  self.stickDirections = {}
  self.stickAxes = {}
end

-- One fixed-tick snapshot: held directions/buttons plus the consumed edges.

---@class FieldInput.Snapshot
---@field heldDirection string?
---@field pressedDirection string?
---@field actionDown boolean
---@field actionPressed boolean?
---@field cancelDown boolean
---@field cancelPressed boolean?
---@field menuDown boolean
---@field menuPressed boolean?

return FieldInput
