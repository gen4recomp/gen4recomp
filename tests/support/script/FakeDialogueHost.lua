-- Fake dialogue host for script task tests: a deterministic text-box host
--  whose print progress advances through the script
-- scheduler's engine-owned async phase. The host records every call and
-- renders text-value descriptors for message bindings, so task tests can
-- assert exact host interaction sequences and save/load dialogue phase state.

---@class FakeDialogueHost
---@field open boolean
---@field printRemaining integer
---@field printTicks integer
---@field calls table[]
---@field player table|nil
local FakeDialogueHost = {}
FakeDialogueHost.__index = FakeDialogueHost

---@param opts table|nil { printTicks, player }
---@return FakeDialogueHost
function FakeDialogueHost.new(opts)
  opts = opts or {}
  return setmetatable({
    open = false,
    printRemaining = opts.printTicks or 2,
    printTicks = opts.printTicks or 2,
    calls = {},
    player = opts.player,
  }, FakeDialogueHost)
end

function FakeDialogueHost:_record(name, ...)
  self.calls[#self.calls + 1] = { name = name, args = { ... } }
end

function FakeDialogueHost:isOpen()
  return self.open
end

function FakeDialogueHost:openMessage(spec)
  self.open = true
  self:_record("openMessage", spec)
end

function FakeDialogueHost:startPrint(message, bindings, textArgs)
  self.printRemaining = self.printTicks
  self:_record("startPrint", message, bindings, textArgs)
end

-- Engine-owned async advance: the scheduler calls this before task polling,
-- so a print that completes this tick is observed by this tick's poll.
function FakeDialogueHost:advance()
  if self.printRemaining > 0 then
    self.printRemaining = self.printRemaining - 1
  end
end

function FakeDialogueHost:printProgress()
  local done = self.printRemaining <= 0
  return { pageIndex = 0, glyphIndex = done and 0 or 1, done = done }
end

function FakeDialogueHost:close(erase)
  self.open = false
  self:_record("close", erase)
end

function FakeDialogueHost:askYesNo()
  self.yesNoSelected = 0
  self.yesNoResult = nil
  self:_record("askYesNo")
end

function FakeDialogueHost:handleYesNoInput(input)
  if input.pressedDirection == "down" then
    self.yesNoSelected = math.min(1, self.yesNoSelected + 1)
  elseif input.pressedDirection == "up" then
    self.yesNoSelected = math.max(0, self.yesNoSelected - 1)
  end
  if input.pressedCancel then
    self.yesNoResult = { accepted = false }
  elseif input.pressedAction then
    self.yesNoResult = { accepted = self.yesNoSelected == 0 }
  end
end

function FakeDialogueHost:takeYesNoResult()
  local result = self.yesNoResult
  self.yesNoResult = nil
  return result
end

function FakeDialogueHost:closeYesNo()
  self:_record("closeYesNo")
end

function FakeDialogueHost:hold()
  self._record(self, "hold")
end

function FakeDialogueHost:showWaitingIcon()
  self:_record("showWaitingIcon")
end

function FakeDialogueHost:hideWaitingIcon()
  self:_record("hideWaitingIcon")
end

-- Render a text-value descriptor to its display string.
function FakeDialogueHost:resolveText(textValue)
  if type(textValue) ~= "table" or textValue.text == nil then
    return tostring(textValue)
  end
  local kind = textValue.text
  if kind == "player_name" then
    return self.player and self.player:name() or "Gold"
  elseif kind == "integer" then
    local value = textValue.value
    if type(value) == "table" and value.value == "local" then
      return "?" .. value.name
    end
    return tostring(value)
  end
  return tostring(kind)
end

return FakeDialogueHost
