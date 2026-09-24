-- Owns the semantic state of the field Yes/No command.

---@class FieldYesNoController
local FieldYesNoController = {}
FieldYesNoController.__index = FieldYesNoController

---@return FieldYesNoController
function FieldYesNoController.new()
  return setmetatable({ active = false, selectedIndex = 0, result = nil }, FieldYesNoController)
end

---@param request { yesText: string, noText: string, frameIndex: integer? }
function FieldYesNoController:open(request)
  assert(not self.active, "field yes/no choice is already active")
  assert(type(request) == "table", "field yes/no request is required")
  assert(type(request.yesText) == "string" and type(request.noText) == "string", "field yes/no labels are required")
  assert(
    request.frameIndex == nil
      or (type(request.frameIndex) == "number" and request.frameIndex % 1 == 0 and request.frameIndex >= 0),
    "field yes/no frame is invalid"
  )
  self.active = true
  self.selectedIndex = 0
  self.result = nil
  self.yesText = request.yesText
  self.noText = request.noText
  self.frameIndex = request.frameIndex
end

---@param input { pressedDirection: string?, pressedAction: boolean?, pressedCancel: boolean? }
function FieldYesNoController:handleInput(input)
  if not self.active then
    return
  end
  input = input or {}
  if input.pressedDirection == "up" or input.pressedDirection == "north" then
    self.selectedIndex = math.max(0, self.selectedIndex - 1)
  elseif input.pressedDirection == "down" or input.pressedDirection == "south" then
    self.selectedIndex = math.min(1, self.selectedIndex + 1)
  end
  if input.pressedCancel then
    self.result = { accepted = false }
  elseif input.pressedAction then
    self.result = { accepted = self.selectedIndex == 0 }
  end
end

---@return table<string, unknown>
function FieldYesNoController:status()
  return {
    active = self.active,
    selectedIndex = self.selectedIndex,
    yesText = self.yesText,
    noText = self.noText,
    frameIndex = self.frameIndex,
    result = self.result and { accepted = self.result.accepted } or nil,
  }
end

---@return { accepted: boolean }?
function FieldYesNoController:takeResult()
  if not self.result then
    return nil
  end
  local result = self.result
  self.result = nil
  return { accepted = result.accepted }
end

function FieldYesNoController:close()
  self.active = false
  self.result = nil
  self.yesText = nil
  self.noText = nil
  self.frameIndex = nil
end

return FieldYesNoController
