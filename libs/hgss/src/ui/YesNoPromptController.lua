-- Owns the semantic state of the reusable two-row choice prompt: the compact
-- button pair the source YesNoPrompt component presents. The prompt reports
-- one-shot semantic results ("yes"/"no") only; it never touches inventory,
-- messages, or consumer state. A latched choice stays unpublished through a
-- short confirmation blink before its result becomes visible. Either vertical
-- direction toggles the selection, confirm resolves the selected row, cancel
-- resolves "no", and a pointer press inside a button row resolves that row
-- immediately on the press. Button geometry derives from the
-- generated compact shape
-- dimensions plus the consumer's placement template; this module carries no
-- source archive, member, tile, palette, or background identities.

---@class YesNoPromptController
---@field _width integer
---@field _height integer
---@field _active boolean
---@field _selected string
---@field _buttons table<string, { x: integer, y: integer, width: integer, height: integer }>|nil
---@field _result string?
---@field _pending string?
---@field _confirmTimer integer
---@field _highlighted boolean
local YesNoPromptController = {}
YesNoPromptController.__index = YesNoPromptController

---@param compactShape { width: integer, height: integer, yes: FieldUiAssetCache.PromptRow, no: FieldUiAssetCache.PromptRow }
---@return YesNoPromptController
function YesNoPromptController.new(compactShape)
  assert(type(compactShape) == "table", "the two-row prompt requires its generated compact shape")
  assert(
    compactShape.width == 48 and compactShape.height == 32,
    "the two-row prompt requires the compact 48x32 button geometry"
  )
  for _, row in ipairs({ "yes", "no" }) do
    local states = compactShape[row]
    assert(
      type(states) == "table" and type(states.normal) == "table" and type(states.selected) == "table",
      "the two-row prompt requires normal and selected visuals for " .. row
    )
  end
  return setmetatable({
    _width = compactShape.width,
    _height = compactShape.height,
    _active = false,
    _selected = "yes",
    _buttons = nil,
    _result = nil,
    _pending = nil,
    _confirmTimer = 0,
    _highlighted = true,
  }, YesNoPromptController)
end

---@param template { x: integer, y: integer, shape: string, initialSelection: string }
function YesNoPromptController:open(template)
  assert(type(template) == "table", "the two-row prompt requires a placement template")
  assert(template.shape == "compact", "the two-row prompt supports only the compact shape")
  assert(
    type(template.x) == "number"
      and template.x % 1 == 0
      and template.x >= 0
      and type(template.y) == "number"
      and template.y % 1 == 0
      and template.y >= 0,
    "the two-row prompt placement must be non-negative integral source pixels"
  )
  assert(
    template.initialSelection == "yes" or template.initialSelection == "no",
    "the two-row prompt initial selection must be yes or no"
  )
  self._active = true
  self._selected = template.initialSelection
  self._buttons = {
    yes = { x = template.x, y = template.y, width = self._width, height = self._height },
    no = { x = template.x, y = template.y + self._height, width = self._width, height = self._height },
  }
  self._result = nil
  self._pending = nil
  self._confirmTimer = 0
  self._highlighted = true
end

local function contains(rect, x, y)
  return type(x) == "number"
    and type(y) == "number"
    and x >= rect.x
    and x < rect.x + rect.width
    and y >= rect.y
    and y < rect.y + rect.height
end

function YesNoPromptController:_rowAt(x, y)
  local buttons = assert(self._buttons, "the two-row prompt resolves pointer rows only while open")
  if contains(buttons.yes, x, y) then
    return "yes"
  end
  if contains(buttons.no, x, y) then
    return "no"
  end
  return nil
end

-- Records a resolved choice without publishing it: the confirmation
-- interval that follows decides when the semantic result becomes visible.
---@param choice string
function YesNoPromptController:_latchChoice(choice)
  self._selected = choice
  self._pending = choice
  self._confirmTimer = 0
  self._highlighted = true
end

-- Advances the confirmation blink one step. Pairs of highlighted updates
-- alternate with pairs of unhighlighted updates; the step that moves past
-- the last count keeps the result unpublished until the terminal update.
function YesNoPromptController:_advanceConfirmation()
  local timer = self._confirmTimer
  if timer % 4 < 2 then
    self._highlighted = true
  else
    self._highlighted = false
  end
  self._confirmTimer = timer + 1
end

---@param events table[]
function YesNoPromptController:updateFixed(events)
  assert(type(events) == "table", "the two-row prompt input must be an event list")
  if not self._active then
    return
  end
  if self._pending ~= nil then
    if self._confirmTimer >= 8 then
      self._result = self._pending
      self._pending = nil
    else
      self:_advanceConfirmation()
    end
    return
  end
  -- Semantic precedence for an idle prompt tick:
  -- valid in-row pointer_down > confirm > cancel > any vertical navigation.
  -- Scan first; mutate once after the scan.
  local touchedRow = nil
  local hasConfirm = false
  local hasCancel = false
  local hasVertical = false
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "two-row prompt events need a type")
    if event.type == "pointer_down" then
      if touchedRow == nil then
        local row = self:_rowAt(event.x, event.y)
        if row ~= nil then
          touchedRow = row
        end
      end
    elseif event.type == "confirm" then
      hasConfirm = true
    elseif event.type == "cancel" then
      hasCancel = true
    elseif event.type == "navigate" then
      if event.direction == "up" or event.direction == "down" then
        hasVertical = true
      end
    end
  end
  if touchedRow ~= nil then
    self:_latchChoice(touchedRow)
  elseif hasConfirm then
    self:_latchChoice(self._selected)
  elseif hasCancel then
    self:_latchChoice("no")
  elseif hasVertical then
    self._selected = self._selected == "yes" and "no" or "yes"
  end
end

---@return { active: boolean, selected: string?, selectionHighlighted: boolean?, buttons: { yes: { x: integer, y: integer, width: integer, height: integer }, no: { x: integer, y: integer, width: integer, height: integer } }? }
function YesNoPromptController:status()
  if not self._active then
    return { active = false }
  end
  local buttons = assert(self._buttons, "an open two-row prompt carries its button rows")
  return {
    active = true,
    selected = self._selected,
    selectionHighlighted = self._highlighted,
    buttons = {
      yes = { x = buttons.yes.x, y = buttons.yes.y, width = buttons.yes.width, height = buttons.yes.height },
      no = { x = buttons.no.x, y = buttons.no.y, width = buttons.no.width, height = buttons.no.height },
    },
  }
end

---@return string?
function YesNoPromptController:takeResult()
  if self._result == nil then
    return nil
  end
  local result = self._result
  self._result = nil
  return result
end

function YesNoPromptController:dispose()
  self._active = false
  self._selected = "yes"
  self._buttons = nil
  self._result = nil
  self._pending = nil
  self._confirmTimer = 0
  self._highlighted = true
end

return YesNoPromptController
