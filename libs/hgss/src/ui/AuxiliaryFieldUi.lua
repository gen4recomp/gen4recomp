-- Logical auxiliary field UI visibility. It keeps script-visible transitions
-- deterministic even on platforms that have no auxiliary HUD to render.

---@class AuxiliaryFieldUi
---@field private _requested "shown"|"hidden"
---@field private _state "shown"|"showing"|"hidden"|"hiding"
local AuxiliaryFieldUi = {}
AuxiliaryFieldUi.__index = AuxiliaryFieldUi
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

local function validateRecord(record)
  if type(record) ~= "table" then
    Errors.raise(FieldErrors.AUXILIARY_UI_INVALID, "auxiliary UI state must be a table", {})
  end
  for key in pairs(record) do
    if key ~= "requested" and key ~= "state" then
      Errors.raise(FieldErrors.AUXILIARY_UI_INVALID, "auxiliary UI state contains an unknown field", { field = key })
    end
  end
  if record.requested ~= "shown" and record.requested ~= "hidden" then
    Errors.raise(FieldErrors.AUXILIARY_UI_INVALID, "auxiliary UI request is invalid", {})
  end
  if
    record.state ~= "shown"
    and record.state ~= "showing"
    and record.state ~= "hidden"
    and record.state ~= "hiding"
  then
    Errors.raise(FieldErrors.AUXILIARY_UI_INVALID, "auxiliary UI state is invalid", {})
  end
  if (record.requested == "shown") ~= (record.state == "shown" or record.state == "showing") then
    Errors.raise(FieldErrors.AUXILIARY_UI_INVALID, "auxiliary UI request and state disagree", {})
  end
  return { requested = record.requested, state = record.state }
end

---@param record unknown
---@return table<string, unknown>|nil, Errors.Error?
function AuxiliaryFieldUi.validate(record)
  local ok, result = pcall(validateRecord, record)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@return AuxiliaryFieldUi
function AuxiliaryFieldUi.new()
  return setmetatable({
    _requested = "shown",
    _state = "shown",
  }, AuxiliaryFieldUi)
end

---@return { requested: "shown"|"hidden", state: "shown"|"showing"|"hidden"|"hiding" }
function AuxiliaryFieldUi:capture()
  return self:status()
end

---@param record table<string, unknown>
---@return AuxiliaryFieldUi
function AuxiliaryFieldUi.restore(record)
  local valid, err = AuxiliaryFieldUi.validate(record)
  if not valid then
    local validationError = assert(err)
    Errors.raise(validationError.code, validationError.message, validationError.context)
  end
  local validated = assert(valid)
  return setmetatable({ _requested = validated.requested, _state = validated.state }, AuxiliaryFieldUi)
end

---@return { requested: "shown"|"hidden", state: "shown"|"showing"|"hidden"|"hiding" }
function AuxiliaryFieldUi:status()
  return { requested = self._requested, state = self._state }
end

-- Requests visibility. Hiding an already-hidden UI completes immediately;
-- showing deliberately creates a transition even from the shown state, which
-- preserves HGSS opcode 747's asynchronous script boundary.
---@param visible boolean
---@return boolean pending
function AuxiliaryFieldUi:requestVisible(visible)
  assert(type(visible) == "boolean", "auxiliary UI visibility must be boolean")
  if not visible and self._state == "hidden" then
    self._requested = "hidden"
    return false
  end
  self._requested = visible and "shown" or "hidden"
  self._state = visible and "showing" or "hiding"
  return true
end

-- Advances one fixed visibility transition. A presentation adapter may mirror
-- this state later; no renderer is required for the logical transition.
function AuxiliaryFieldUi:advance()
  if self._state == "showing" then
    self._state = "shown"
  elseif self._state == "hiding" then
    self._state = "hidden"
  end
end

return AuxiliaryFieldUi
