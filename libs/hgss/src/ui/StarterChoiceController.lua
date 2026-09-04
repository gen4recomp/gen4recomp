-- Pure starter-choice state machine. It owns the three-candidate cursor,
-- the explicit yes/no confirmation substate, and the one-shot semantic
-- result, while leaving geometry, rendering, and device input mapping to
-- its callers. Selecting is non-cancellable: the story application cannot
-- be dismissed, and answering no returns to selection without touching the
-- candidate cursor. Pointer capture commits only on a matching release.

---@class StarterChoiceController.Result
---@field candidate integer zero-based confirmed candidate
---@field accepted boolean confirmation answer
---@class StarterChoiceController
---@field _candidateIndex integer zero-based highlighted candidate
---@field _mode "selecting"|"confirming"
---@field _confirmIndex integer 0 yes, 1 no
---@field _state "active"|"complete"
---@field _result StarterChoiceController.Result|nil one-shot semantic result
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

---@param value unknown
local function assertConfirmIndex(value)
  assert(
    type(value) == "number" and value == value and value == math.floor(value),
    "starter confirmation index must be an integer"
  )
  assert(value == 0 or value == 1, "starter confirmation index is out of range")
end

---@class StarterChoiceController.Spec
---@field candidates string[] exactly three candidate display names
---@field initialCursor integer? zero-based starting candidate

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
  return setmetatable({
    _candidateIndex = initialCursor,
    _mode = "selecting",
    _confirmIndex = 0,
    _state = "active",
    _result = nil,
    _pressed = nil,
  }, StarterChoiceController)
end

---@return boolean
function StarterChoiceController:isActive()
  return self._state == "active"
end

---@param itemIndex integer
function StarterChoiceController:focus(itemIndex)
  if self._mode == "confirming" then
    assertConfirmIndex(itemIndex)
  else
    assertCandidateIndex(itemIndex)
  end
  if not self:isActive() then
    return
  end
  if self._mode == "confirming" then
    self._confirmIndex = itemIndex
  else
    self._candidateIndex = itemIndex
  end
end

-- Confirming a candidate opens confirmation, never publication. Answering
-- yes completes with the highlighted candidate exactly once; answering no
-- returns to selection with the cursor preserved.
---@return StarterChoiceController.Result|nil
function StarterChoiceController:confirm()
  if not self:isActive() then
    return nil
  end
  if self._mode == "selecting" then
    self._mode = "confirming"
    self._confirmIndex = 0
    self._pressed = nil
    return nil
  end
  if self._confirmIndex == 0 then
    self._state = "complete"
    self._result = { candidate = self._candidateIndex, accepted = true }
    self._pressed = nil
    return { candidate = self._result.candidate, accepted = self._result.accepted }
  end
  self._mode = "selecting"
  self._pressed = nil
  return nil
end

-- Cancel never exits the story application: while selecting it is ignored,
-- while confirming it returns to selection.
---@return nil
function StarterChoiceController:cancel()
  if not self:isActive() then
    return nil
  end
  if self._mode == "confirming" then
    self._mode = "selecting"
    self._pressed = nil
  end
  return nil
end

-- Pointer hover changes logical focus but never activates.
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
    if self._mode == "confirming" then
      assertConfirmIndex(itemIndex)
    else
      assertCandidateIndex(itemIndex)
    end
  end
  if self:isActive() then
    self._pressed = itemIndex
  end
end

-- A release commits only when it finishes on the originally pressed item. A
-- matching release in selection opens confirmation; a matching release in
-- confirmation answers it. Any mismatch discards the capture.
---@param itemIndex integer?
---@return StarterChoiceController.Result|nil
function StarterChoiceController:release(itemIndex)
  if itemIndex ~= nil then
    if self._mode == "confirming" then
      assertConfirmIndex(itemIndex)
    else
      assertCandidateIndex(itemIndex)
    end
  end
  if not self:isActive() then
    return nil
  end
  local pressed = self._pressed
  self._pressed = nil
  if pressed == nil or pressed ~= itemIndex then
    return nil
  end
  if self._mode == "selecting" then
    self._candidateIndex = pressed
    self._mode = "confirming"
    self._confirmIndex = 0
    return nil
  end
  self._confirmIndex = pressed
  return self:confirm()
end

---@class StarterChoiceController.Status
---@field state "active"|"complete"
---@field mode "selecting"|"confirming"
---@field candidateIndex integer
---@field confirmIndex integer? yes/no cursor while confirming

---@return StarterChoiceController.Status
function StarterChoiceController:status()
  local status = {
    state = self._state,
    mode = self._mode,
    candidateIndex = self._candidateIndex,
  }
  if self._mode == "confirming" then
    status.confirmIndex = self._confirmIndex
  end
  return status
end

return StarterChoiceController
