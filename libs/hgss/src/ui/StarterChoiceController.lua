-- Pure retail starter-choice state machine. It owns the three-ball cursor,
-- the unconfirmed/inspected/confirmed selection states, and the timed
-- application transitions between them (turntable rotation, camera zoom and
-- wait, zoom reversal, and the locking exit), while leaving geometry,
-- rendering, and device input mapping to its callers. Activation first
-- inspects the current ball, then starts the zoom path that settles into
-- confirmation, then locks the choice; cancellation only reverses an idle
-- confirmation back to inspection and never dismisses the application.
-- Left/right rotate one step while unconfirmed and idle; any input that
-- would conflict with an active transition is ignored exactly once, so
-- repeated edges during a transition can never double-advance or corrupt
-- the clocks. Pointer capture commits only on a matching release: tapping
-- the current ball advances, tapping another ball rotates toward it (or
-- backs out of confirmation), and tapping outside backs out of confirmation.
-- The transition length comes in through the constructor so generated timing
-- stays with the asset contract; the controller itself stays asset-free.

---@class StarterChoiceController
---@field _selection integer zero-based current ball
---@field _selectionState "null"|"inspect"|"confirm"
---@field _transition "idle"|"rotate"|"zoomIn"|"waitZoom"|"backOut"|"lockExit"|"done"
---@field _direction "left"|"right"|nil pending rotation direction while rotating
---@field _progress integer elapsed ticks in the active transition
---@field _ticks integer ticks per transition, supplied by the caller
---@field _done boolean the locking exit has settled
---@field _result { index: integer }|nil one-shot semantic result
---@field _pressed integer|nil pointer capture
local StarterChoiceController = {}
StarterChoiceController.__index = StarterChoiceController

local CANDIDATE_COUNT = 3

---@param value unknown
local function assertCandidateIndex(value)
  assert(
    type(value) == "number" and value == value and value == math.floor(value),
    "starter candidate index must be an integer"
  )
  assert(value >= 0 and value < CANDIDATE_COUNT, "starter candidate index is out of range")
end

---@param direction unknown
local function assertDirection(direction)
  assert(direction == "left" or direction == "right", "starter rotation names left or right")
end

---@class StarterChoiceController.Spec
---@field candidates string[] exactly three candidate display names
---@field initialCursor integer? zero-based starting candidate
---@field transitionTicks integer? ticks per transition, supplied by the caller

---@param spec StarterChoiceController.Spec
---@return StarterChoiceController
function StarterChoiceController.new(spec)
  assert(type(spec) == "table", "starter choice requires a specification")
  assert(type(spec.candidates) == "table" and #spec.candidates == 3, "starter choice requires exactly three candidates")
  local initialCursor = spec.initialCursor
  if initialCursor == nil then
    initialCursor = 0
  end
  assertCandidateIndex(initialCursor)
  local ticks = spec.transitionTicks
  if ticks == nil then
    -- Default for the pure-unit shape; production compositions supply the
    -- generated manifest value through this same input.
    ticks = 8
  end
  assert(
    type(ticks) == "number" and ticks == math.floor(ticks) and ticks >= 1,
    "starter transitions need a positive tick count"
  )
  return setmetatable({
    _selection = initialCursor,
    _selectionState = "null",
    _transition = "idle",
    _direction = nil,
    _progress = 0,
    _ticks = ticks,
    _done = false,
    _result = nil,
    _pressed = nil,
  }, StarterChoiceController)
end

---@return boolean
function StarterChoiceController:isActive()
  return not self._done
end

---@return boolean
function StarterChoiceController:isIdle()
  return self._transition == "idle"
end

---@param transition string
---@param direction "left"|"right"|nil
function StarterChoiceController:_begin(transition, direction)
  self._transition = transition
  self._direction = direction
  self._progress = 0
  self._pressed = nil
end

function StarterChoiceController:_settleIdle()
  self._transition = "idle"
  self._direction = nil
  self._progress = 0
  self._pressed = nil
end

-- One deterministic fixed tick. Each timed transition settles on its own:
-- rotation applies the pending step, the zoom path pauses through its wait
-- before reaching confirmation, reversal returns to inspection, and the
-- locking exit publishes the result exactly once.
function StarterChoiceController:update()
  local transition = self._transition
  if transition == "idle" or transition == "done" then
    return
  end
  self._progress = self._progress + 1
  if self._progress < self._ticks then
    return
  end
  if transition == "rotate" then
    local delta = self._direction == "right" and 1 or -1
    self._selection = (self._selection + delta) % CANDIDATE_COUNT
    self:_settleIdle()
  elseif transition == "zoomIn" then
    self._transition = "waitZoom"
    self._progress = 0
    self._pressed = nil
  elseif transition == "waitZoom" then
    self._selectionState = "confirm"
    self:_settleIdle()
  elseif transition == "backOut" then
    self._selectionState = "inspect"
    self:_settleIdle()
  elseif transition == "lockExit" then
    self._transition = "done"
    self._progress = 0
    self._pressed = nil
    self._done = true
    self._result = { index = self._selection }
  else
    error("unknown starter transition " .. tostring(transition), 0)
  end
end

-- Direct selection is an idle, unconfirmed affordance for hover and host
-- cursor sync; it never interrupts a transition or a confirmation.
---@param itemIndex integer
function StarterChoiceController:focus(itemIndex)
  assertCandidateIndex(itemIndex)
  if not self:isActive() or not self:isIdle() then
    return
  end
  if self._selectionState == "confirm" then
    return
  end
  self._selection = itemIndex
end

-- Activation advances the inspected path: first entering inspection, then
-- starting the zoom that settles into confirmation, then starting the
-- locking exit whose settlement reports. Never publishes synchronously.
---@return nil
function StarterChoiceController:confirm()
  if not self:isActive() or not self:isIdle() then
    return nil
  end
  if self._selectionState == "null" then
    self._selectionState = "inspect"
    self._pressed = nil
    return nil
  end
  if self._selectionState == "inspect" then
    self:_begin("zoomIn", nil)
    return nil
  end
  self:_begin("lockExit", nil)
  return nil
end

-- Cancellation never exits the application: outside confirmation it is
-- ignored, inside confirmation it reverses the zoom back to inspection.
---@return nil
function StarterChoiceController:cancel()
  if not self:isActive() or not self:isIdle() then
    return nil
  end
  if self._selectionState == "confirm" then
    self:_begin("backOut", nil)
  end
  return nil
end

-- Rotation steps the turntable one ball in the named direction once the
-- transition settles; confirmed and mid-transition input is ignored.
---@param direction "left"|"right"
---@return nil
function StarterChoiceController:move(direction)
  assertDirection(direction)
  if not self:isActive() or not self:isIdle() then
    return nil
  end
  if self._selectionState == "confirm" then
    return nil
  end
  self:_begin("rotate", direction)
  return nil
end

-- Pointer hover changes the idle, unconfirmed selection but never activates.
---@param itemIndex integer?
function StarterChoiceController:hover(itemIndex)
  if itemIndex == nil then
    return
  end
  self:focus(itemIndex)
end

---@param itemIndex integer?
function StarterChoiceController:press(itemIndex)
  if itemIndex ~= nil then
    assertCandidateIndex(itemIndex)
  end
  if self:isActive() and self:isIdle() then
    self._pressed = itemIndex
  else
    self._pressed = nil
  end
end

-- A release commits only when it finishes on the originally pressed ball.
-- The current ball advances along the activation path; another ball rotates
-- toward it, or backs out of confirmation; outside backs out of
-- confirmation and is ignored otherwise. Any mismatch discards the capture.
---@param itemIndex integer?
---@return nil
function StarterChoiceController:release(itemIndex)
  if itemIndex ~= nil then
    assertCandidateIndex(itemIndex)
  end
  if not self:isActive() or not self:isIdle() then
    self._pressed = nil
    return nil
  end
  local pressed = self._pressed
  self._pressed = nil
  if itemIndex == nil then
    if self._selectionState == "confirm" then
      self:_begin("backOut", nil)
    end
    return nil
  end
  if pressed == nil or pressed ~= itemIndex then
    return nil
  end
  if itemIndex == self._selection then
    return self:confirm()
  end
  if self._selectionState == "confirm" then
    self:_begin("backOut", nil)
    return nil
  end
  local delta = (itemIndex - self._selection) % CANDIDATE_COUNT
  if delta == 1 then
    self:_begin("rotate", "right")
  elseif delta == 2 then
    self:_begin("rotate", "left")
  end
  return nil
end

---@return { index: integer }|nil one-shot semantic result once the lock settles
function StarterChoiceController:result()
  return self._result
end

---@class StarterChoiceController.Snapshot
---@field selection integer zero-based current ball
---@field selectionState "null"|"inspect"|"confirm"
---@field transition "idle"|"rotate"|"zoomIn"|"waitZoom"|"backOut"|"lockExit"|"done"
---@field direction "left"|"right"|nil
---@field progress integer elapsed ticks in the active transition
---@field ticks integer ticks per transition
---@field done boolean
---@field result { index: integer }|nil once the lock settles

---@return StarterChoiceController.Snapshot
function StarterChoiceController:snapshot()
  local result = nil
  if self._result ~= nil then
    result = { index = self._result.index }
  end
  return {
    selection = self._selection,
    selectionState = self._selectionState,
    transition = self._transition,
    direction = self._direction,
    progress = self._progress,
    ticks = self._ticks,
    done = self._done,
    result = result,
  }
end

---@return StarterChoiceController.Snapshot
function StarterChoiceController:status()
  return self:snapshot()
end

return StarterChoiceController
