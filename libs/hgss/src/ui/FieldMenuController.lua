-- Pure field-menu state machine. It owns item selection, completion, and
-- pointer capture while leaving message resolution, layout, rendering, and
-- physical input mapping to its callers.

---@class FieldMenuController
---@field _items table<integer, FieldMenuController.Item>
---@field _itemCount integer
---@field _selectedIndex integer
---@field _cancellable boolean
---@field _cancelValue unknown
---@field _state "active"|"complete"
---@field _result unknown
---@field _cancelled boolean
---@field _pressedPointerItem integer?
---@field isActive fun(self: FieldMenuController): boolean
---@field focus fun(self: FieldMenuController, itemIndex: integer)
---@field confirm fun(self: FieldMenuController): unknown
---@field cancel fun(self: FieldMenuController): unknown
---@field hover fun(self: FieldMenuController, itemIndex: integer?)
---@field press fun(self: FieldMenuController, itemIndex: integer?)
---@field release fun(self: FieldMenuController, itemIndex: integer?): unknown
---@field status fun(self: FieldMenuController): FieldMenuController.Status

local FieldMenuController = {}
FieldMenuController.__index = FieldMenuController

---@param value unknown
---@param name string
local function assertInteger(value, name)
  assert(
    type(value) == "number"
      and value == value
      and value ~= math.huge
      and value ~= -math.huge
      and value == math.floor(value),
    name .. " must be a finite integer"
  )
end

---@param items table<string, unknown>
---@return table<integer, FieldMenuController.Item>, integer
local function copyItems(items)
  assert(type(items) == "table", "field menu requires an item list")
  local count = #items
  assert(count > 0, "field menu requires at least one item")

  local copied = {}
  for luaIndex = 1, count do
    local item = items[luaIndex]
    assert(type(item) == "table", "field menu item must be a table")
    assert(item.value ~= nil, "field menu item requires a result value")
    copied[luaIndex - 1] = {
      text = item.text,
      value = item.value,
      vanillaMetadata = item.vanillaMetadata,
      metadata = item.metadata,
    }
  end
  return copied, count
end

---@param self { _itemCount: integer }
---@param itemIndex integer?
local function assertItemIndex(self, itemIndex)
  if itemIndex == nil then
    return
  end
  assertInteger(itemIndex, "field menu item index")
  assert(itemIndex >= 0 and itemIndex < self._itemCount, "field menu item index is out of range")
end

---@class FieldMenuController.Spec
---@field items FieldMenuController.Item[]
---@field initialCursor integer?
---@field cancellable boolean?
---@field cancelValue unknown

---@class FieldMenuController.Item
---@field text unknown
---@field value unknown
---@field vanillaMetadata unknown?
---@field metadata unknown?

---@param spec FieldMenuController.Spec
---@return FieldMenuController
function FieldMenuController.new(spec)
  assert(type(spec) == "table", "field menu requires a specification")
  local items, itemCount = copyItems(spec.items)
  local initialCursor = spec.initialCursor
  if initialCursor == nil then
    initialCursor = 0
  end
  assertInteger(initialCursor, "field menu initial cursor")
  assert(initialCursor >= 0 and initialCursor < itemCount, "field menu initial cursor is out of range")
  assert(spec.cancellable == nil or type(spec.cancellable) == "boolean", "field menu cancellable must be a boolean")
  assert(spec.cancellable ~= true or spec.cancelValue ~= nil, "cancellable field menu requires a cancellation result")

  local controller = {
    _items = items,
    _itemCount = itemCount,
    _selectedIndex = initialCursor,
    _cancellable = spec.cancellable == true,
    _cancelValue = spec.cancelValue,
    _state = "active",
    _result = nil,
    _cancelled = false,
    _pressedPointerItem = nil,
  }
  ---@cast controller FieldMenuController
  return setmetatable(controller, FieldMenuController)
end

---@return boolean
function FieldMenuController:isActive()
  return self._state == "active"
end

---@param result unknown
---@param cancelled boolean
---@return unknown
function FieldMenuController:_complete(result, cancelled)
  assert(self._state == "active", "field menu is already complete")
  self._state = "complete"
  self._result = result
  self._cancelled = cancelled
  self._pressedPointerItem = nil
  return result
end

-- Layout resolves directional adjacency, then supplies the stable target item
-- index here. The controller deliberately has no knowledge of rows or columns.

---@param itemIndex integer
function FieldMenuController:focus(itemIndex)
  assertItemIndex(self, itemIndex)
  if self:isActive() then
    self._selectedIndex = assert(itemIndex)
  end
end

---@return unknown
function FieldMenuController:confirm()
  if not self:isActive() then
    return nil
  end
  return self:_complete(self._items[assert(self._selectedIndex)].value, false)
end

---@return unknown
function FieldMenuController:cancel()
  if not self:isActive() or not self._cancellable then
    return nil
  end
  return self:_complete(self._cancelValue, true)
end

-- Pointer hover changes logical focus but never activates an item.

---@param itemIndex integer?
function FieldMenuController:hover(itemIndex)
  if itemIndex ~= nil then
    self:focus(itemIndex)
  end
end

---@param itemIndex integer?
function FieldMenuController:press(itemIndex)
  assertItemIndex(self, itemIndex)
  if self:isActive() then
    self._pressedPointerItem = itemIndex
  end
end

-- A release commits only when it finishes on the originally pressed item.
-- Any mismatched or outside release discards the capture, preventing a drag
-- across rows from selecting its release target.

---@param itemIndex integer?
---@return unknown
function FieldMenuController:release(itemIndex)
  assertItemIndex(self, itemIndex)
  if not self:isActive() then
    return nil
  end
  local pressed = self._pressedPointerItem
  self._pressedPointerItem = nil
  if pressed == nil or pressed ~= itemIndex then
    return nil
  end
  self._selectedIndex = assert(pressed)
  return self:confirm()
end

---@class FieldMenuController.Status
---@field state "active"|"complete"
---@field selectedIndex integer
---@field result unknown
---@field cancelled boolean

---@return FieldMenuController.Status
function FieldMenuController:status()
  return {
    state = self._state,
    selectedIndex = assert(self._selectedIndex),
    result = self._result,
    cancelled = self._cancelled,
  }
end

return FieldMenuController
