-- Field-bag controller: pure browse navigation plus the inventory-local
-- action states. Browsing keeps the six-cell grid navigation over the
-- injected view model, pocket switching with per-pocket cursor memory, and
-- the constrained-topology description overlay. Confirming an item opens the
-- action menu built by the injected policy projection; nested toss quantity,
-- toss confirmation, and manual move-target states mutate only through the
-- injected semantic commands, exactly once per confirmation, with a
-- stale-selection check after every refresh so an external revision can
-- never redirect a pending mutation onto a different item. Every nested
-- cancel pops one level without mutation, and closing returns to the menu.
-- Selection and scroll live in the borrowed field cursor through its API
-- only; tab and cancel focus stay private. Pointer press/release capture
-- shares the keyboard confirm path, so a drag or a layout change can never
-- activate a moved target. Results are one-shot ({kind="closed"}) with no
-- renderer state and no love dependency.

local BagSave = require("libs.hgss.src.save.BagSave")

---@class BagControllerCommands semantic mutations bound to the live inventory service
---@field toss fun(itemKey: string, quantity: integer): boolean remove owned copies
---@field move fun(pocketKey: string, fromIndex: integer, toIndex: integer): boolean reorder by absolute pocket index
---@field register fun(itemKey: string): unknown claim a registration slot
---@field unregister fun(itemKey: string): boolean release a registration slot

---@class BagController
---@field _model { refresh: fun(): table<string, unknown> }
---@field _cursor BagCursor
---@field _resolveLayout fun(): table<string, unknown>
---@field _commands BagControllerCommands
---@field _resolveActions fun(view: table<string, unknown>): table<string, unknown>[]
---@field _view table<string, unknown>
---@field _observedRevision integer
---@field _focus "items"|"tabs"|"cancel"
---@field _overlay boolean
---@field _state "browsing"|"action_menu"|"toss_quantity"|"toss_confirm"|"move_select"
---@field _actions table<string, unknown>[]
---@field _selectedAction integer
---@field _actionItemKey string?
---@field _actionPocket string?
---@field _quantity integer
---@field _quantityMax integer
---@field _moveFromKey string?
---@field _moveFromPos integer
---@field _moveTarget integer
---@field _result { kind: string }?
---@field _closed boolean
---@field _pressId string?
---@field _pressCapture table<string, unknown>?
local BagController = {}
BagController.__index = BagController

---@class BagController.Options
---@field model { refresh: fun(): table<string, unknown> } the injected view projection
---@field cursor BagCursor the borrowed runtime-only field cursor
---@field resolveLayout fun(): table<string, unknown> the injected layout resolver
---@field commands BagControllerCommands semantic mutations bound to the live inventory service
---@field resolveActions fun(view: table<string, unknown>): table<string, unknown>[] the injected inventory-local menu projection over the refreshed view

---@param value unknown
---@param what string
---@return integer
local function checkQuantity(value, what)
  assert(type(value) == "number" and value % 1 == 0 and value >= 1, what .. " must be a positive integer")
  return value
end

---@param opts BagController.Options
---@return BagController
function BagController.new(opts)
  assert(type(opts) == "table", "the bag controller requires options")
  assert(
    type(opts.model) == "table" and type(opts.model.refresh) == "function",
    "the bag controller needs a view model"
  )
  assert(type(opts.cursor) == "table", "the bag controller needs the runtime bag cursor")
  assert(type(opts.resolveLayout) == "function", "the bag controller needs its layout resolver")
  assert(type(opts.commands) == "table", "the bag controller needs its mutation commands")
  assert(type(opts.commands.toss) == "function", "the bag controller needs its toss command")
  assert(type(opts.commands.move) == "function", "the bag controller needs its move command")
  assert(type(opts.commands.register) == "function", "the bag controller needs its register command")
  assert(type(opts.commands.unregister) == "function", "the bag controller needs its unregister command")
  assert(type(opts.resolveActions) == "function", "the bag controller needs its action policy")
  local self = setmetatable({
    _model = opts.model,
    _cursor = opts.cursor,
    _resolveLayout = opts.resolveLayout,
    _commands = opts.commands,
    _resolveActions = opts.resolveActions,
    _focus = "items",
    _overlay = false,
    _state = "browsing",
    _actions = {},
    _selectedAction = 0,
    _actionItemKey = nil,
    _actionPocket = nil,
    _quantity = 1,
    _quantityMax = 1,
    _moveFromKey = nil,
    _moveFromPos = 0,
    _moveTarget = 0,
    _result = nil,
    _closed = false,
    _pressId = nil,
    _pressCapture = nil,
  }, BagController)
  self._view = self:_refresh()
  self:_reconcile()
  return self
end

---@return table<string, unknown>
function BagController:_refresh()
  local view = self._model.refresh()
  assert(type(view) == "table" and type(view.slots) == "table", "the bag view needs its pocket slots")
  assert(type(view.pocket) == "string", "the bag view needs its pocket key")
  self._view = view
  self._observedRevision = view.revision
  return view
end

---@return integer
function BagController:_count()
  return #assert(self._view.slots, "the bag view needs its pocket slots")
end

---@return string
function BagController:_pocket()
  return assert(self._view.pocket, "the bag view needs its pocket key")
end

-- The state the renderer and the pointer hit test observe: the description
-- overlay wins over every nested state, and the two overlays stay mutually
-- exclusive.
---@return string
function BagController:_visibleState()
  if self._overlay then
    return "description_overlay"
  end
  return self._state
end

-- Clamps the borrowed cursor to the current pocket so it never points past
-- the last occupied cell and the window always covers the selection.
function BagController:_reconcile()
  local pocket = self:_pocket()
  local count = self:_count()
  local cursor = self._cursor
  if count == 0 then
    cursor:setPosition(pocket, 0)
    cursor:setScroll(pocket, 0)
    return
  end
  if cursor:position(pocket) > count - 1 then
    cursor:setPosition(pocket, count - 1)
  end
  local start = cursor:scroll(pocket)
  if start > count - 1 then
    start = count - 1
  end
  cursor:setScroll(pocket, start - (start % 2))
  self:_ensureVisible()
end

-- Slides the window to cover the selected absolute index, one row at a
-- time, so every occupied slot stays reachable in exact item order.
function BagController:_ensureVisible()
  local pocket = self:_pocket()
  local cursor = self._cursor
  local selected = cursor:position(pocket)
  local start = cursor:scroll(pocket)
  while selected < start do
    start = start - 2
  end
  while selected >= start + 6 do
    start = start + 2
  end
  if start ~= cursor:scroll(pocket) then
    cursor:setScroll(pocket, start)
  end
end

-- Enters a pocket through the cursor API: the stored per-pocket offsets
-- return, clamped to whatever the pocket holds now, with grid focus.
---@param pocketKey string
function BagController:_enterPocket(pocketKey)
  self._cursor:setPocket(pocketKey)
  self:_refresh()
  self:_reconcile()
  self._focus = "items"
end

---@param direction integer -1 for previous, 1 for next
function BagController:_switchPocket(direction)
  local order = BagSave.POCKET_ORDER
  local current = self._cursor:currentPocket()
  local index = 1
  for position, pocketKey in ipairs(order) do
    if pocketKey == current then
      index = position
      break
    end
  end
  local next = order[((index - 1 + direction) % #order) + 1]
  self:_enterPocket(next)
end

---@param absolute integer
function BagController:_select(absolute)
  local pocket = self:_pocket()
  self._cursor:setPosition(pocket, absolute)
  self:_ensureVisible()
  self:_refresh()
end

---@param direction string
function BagController:_move(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  local pocket = self:_pocket()
  local count = self:_count()
  local cursor = self._cursor
  if self._focus == "tabs" then
    if direction == "left" then
      self:_switchPocket(-1)
    elseif direction == "right" then
      self:_switchPocket(1)
    else
      self._focus = "items"
    end
    return
  end
  -- Cancel is a single bottom button with no horizontal neighbor: only up
  -- returns to the grid. Pocket switching lives on the grid edges and the
  -- tab strip, so horizontal input on Cancel must not walk the pocket back
  -- to where the browse came from.
  if self._focus == "cancel" then
    if direction == "up" then
      self._focus = "items"
    end
    return
  end
  local selected = count == 0 and 0 or cursor:position(pocket)
  if direction == "left" then
    if count > 0 and selected % 2 == 1 then
      self:_select(selected - 1)
    else
      self:_switchPocket(-1)
    end
  elseif direction == "right" then
    if count > 0 and selected % 2 == 0 and selected + 1 < count then
      self:_select(selected + 1)
    else
      self:_switchPocket(1)
    end
  elseif direction == "up" then
    if count > 0 and selected - 2 >= 0 then
      self:_select(selected - 2)
    else
      self._focus = "tabs"
    end
  else
    if count > 0 and selected + 2 < count then
      self:_select(selected + 2)
    else
      self._focus = "cancel"
    end
  end
end

-- Drops every nested action frame and returns to plain browsing. Mutations
-- never ride this path: callers refresh first and commit explicitly.
function BagController:_toBrowsing()
  self._state = "browsing"
  self._actions = {}
  self._selectedAction = 0
  self._actionItemKey = nil
  self._actionPocket = nil
  self._quantity = 1
  self._quantityMax = 1
  self._moveFromKey = nil
  self._moveFromPos = 0
  self._moveTarget = 0
end

-- The pending selection still names the same semantic item in the same
-- pocket after the latest refresh. An external revision that moved or
-- removed it aborts the pending mutation instead of redirecting it.
---@return boolean
function BagController:_selectionMatchesAction()
  local view = self._view
  if view.pocket ~= self._actionPocket then
    return false
  end
  local selected = view.selected
  if type(selected) ~= "table" then
    return false
  end
  return selected.item == self._actionItemKey
end

-- Confirming an item resolves the inventory-local menu for the refreshed
-- view and snapshots the semantic selection the nested states verify
-- against. An empty pocket has nothing to act on.
function BagController:_openActionMenu()
  if self._focus ~= "items" or self:_count() == 0 then
    return
  end
  local selected = self._view.selected
  if type(selected) ~= "table" or type(selected.item) ~= "string" then
    return
  end
  local actions = self._resolveActions(self._view)
  assert(type(actions) == "table" and #actions >= 1, "the action policy always offers a way out")
  self._actions = actions
  self._selectedAction = 0
  self._actionItemKey = selected.item
  self._actionPocket = self:_pocket()
  self._overlay = false
  self._state = "action_menu"
end

-- Returns to the action menu with freshly resolved actions, keeping the
-- previous menu position when the list still covers it.
function BagController:_toActionMenu()
  local actions = self._resolveActions(self._view)
  assert(type(actions) == "table" and #actions >= 1, "the action policy always offers a way out")
  self._actions = actions
  if self._selectedAction > #actions - 1 then
    self._selectedAction = 0
  end
  self._state = "action_menu"
end

---@param index integer zero-based action position
function BagController:_chooseActionIndex(index)
  -- An external revision may have moved the selection under the open menu:
  -- re-resolve onto the current selection instead of dispatching the
  -- snapshotted action at a ghost. An empty pocket simply closes the menu.
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    self:_openActionMenu()
    return
  end
  local action = self._actions[index + 1]
  if type(action) ~= "table" or type(action.id) ~= "string" then
    return
  end
  local id = action.id
  if id == "cancel" then
    self:_toBrowsing()
  elseif id == "toss" then
    self:_enterQuantity()
  elseif id == "move" then
    self:_enterMoveSelect()
  elseif id == "register" then
    self:_commitRegistration(true)
  elseif id == "unregister" then
    self:_commitRegistration(false)
  end
end

---@param direction string
function BagController:_cycleAction(direction)
  local count = #self._actions
  if count == 0 then
    return
  end
  if direction == "down" then
    self._selectedAction = (self._selectedAction + 1) % count
  elseif direction == "up" then
    self._selectedAction = (self._selectedAction - 1) % count
  end
end

-- Enters the quantity picker for the snapshotted item, preselecting one
-- copy. The range always ends at the freshly observed owned quantity.
function BagController:_enterQuantity()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  self._quantityMax = owned
  self._quantity = 1
  self._state = "toss_quantity"
end

---@param direction string
function BagController:_adjustQuantity(direction)
  if direction == "left" then
    self._quantity = math.max(1, self._quantity - 1)
  elseif direction == "right" then
    self._quantity = math.min(self._quantityMax, self._quantity + 1)
  end
end

-- Confirms the picked quantity into the confirmation state, clamping to
-- whatever the latest refresh still observes. A vanished selection aborts
-- instead of carrying a stale quantity forward.
function BagController:_enterTossConfirm()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  self._quantityMax = owned
  self._quantity = math.min(self._quantity, owned)
  self._state = "toss_confirm"
end

-- The single toss commit: exactly one service call for one confirmation.
-- A failure after the refresh shows the refreshed model instead of faking
-- success; either way the menu collapses back to browsing.
function BagController:_commitToss()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  local quantity = math.min(self._quantity, owned)
  self._commands.toss(assert(self._actionItemKey, "a toss commits its snapshotted item"), quantity)
  self:_refresh()
  self:_reconcile()
  self:_toBrowsing()
end

-- Enters manual move-target selection, capturing the moved item by semantic
-- key and absolute position. Navigation moves the insertion target through
-- the pocket's ordered items; the cursor follows so the window tracks it.
function BagController:_enterMoveSelect()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local pocket = self:_pocket()
  self._moveFromKey = self._actionItemKey
  self._moveFromPos = self._cursor:position(pocket)
  self._moveTarget = self._moveFromPos
  self._state = "move_select"
end

---@param target integer zero-based absolute index
function BagController:_setMoveTarget(target)
  local count = self:_count()
  if count == 0 then
    return
  end
  local clamped = math.min(math.max(target, 0), count - 1)
  local pocket = self:_pocket()
  self._cursor:setPosition(pocket, clamped)
  self:_ensureVisible()
  self:_refresh()
  self._moveTarget = self._cursor:position(pocket)
end

---@param direction string
function BagController:_moveTargetStep(direction)
  local delta = 0
  if direction == "left" then
    delta = -1
  elseif direction == "right" then
    delta = 1
  elseif direction == "up" then
    delta = -2
  elseif direction == "down" then
    delta = 2
  else
    return
  end
  self:_setMoveTarget(self._moveTarget + delta)
end

-- The single reorder commit, addressed by absolute pocket index so window
-- scroll never changes its meaning. The moved item stays selected at its
-- new absolute position; a stale source aborts without mutation.
function BagController:_commitMove()
  self:_refresh()
  local pocket = self:_pocket()
  local fromIndex = nil
  for index, slot in ipairs(assert(self._view.slots, "the bag view needs its pocket slots")) do
    if type(slot) == "table" and slot.item == self._moveFromKey then
      fromIndex = index
      break
    end
  end
  if fromIndex == nil then
    self:_reconcile()
    self:_toBrowsing()
    return
  end
  local count = self:_count()
  local toIndex = math.min(math.max(self._moveTarget + 1, 1), count)
  local moved = self._commands.move(pocket, fromIndex, toIndex)
  self:_refresh()
  if moved then
    self._cursor:setPosition(pocket, toIndex - 1)
    self:_ensureVisible()
    self:_refresh()
  else
    self:_reconcile()
  end
  self:_toBrowsing()
end

-- Cancelling a pending move restores the cursor the target tracking
-- borrowed, without touching the inventory.
function BagController:_cancelMove()
  local pocket = self:_pocket()
  self._cursor:setPosition(pocket, math.min(self._moveFromPos, math.max(self:_count() - 1, 0)))
  self:_ensureVisible()
  self:_refresh()
  self:_toBrowsing()
end

-- The single registration commit in either direction: the service owns the
-- two-slot decision, the refreshed model shows the shifted order, and the
-- menu collapses back to browsing.
---@param register boolean true for register, false for unregister
function BagController:_commitRegistration(register)
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local itemKey = assert(self._actionItemKey, "registration commits its snapshotted item")
  if register then
    self._commands.register(itemKey)
  else
    self._commands.unregister(itemKey)
  end
  self:_refresh()
  self:_reconcile()
  self:_toBrowsing()
end

-- Reconciles a nested state against the latest refresh: a selection the
-- outside world removed aborts the whole menu, and the picker range tracks
-- the observed quantity. Returns false when the caller must stop.
---@return boolean
function BagController:_syncNested()
  if self._state == "browsing" then
    return true
  end
  if self._state == "action_menu" then
    -- An outside revision that moved or removed the pending selection
    -- collapses the stale menu instead of offering a ghost's actions.
    if not self:_selectionMatchesAction() then
      self:_toBrowsing()
      return false
    end
    return true
  end
  if self._state == "move_select" then
    local found = false
    for _, slot in ipairs(assert(self._view.slots, "the bag view needs its pocket slots")) do
      if type(slot) == "table" and slot.item == self._moveFromKey then
        found = true
        break
      end
    end
    if not found then
      self:_toBrowsing()
      return false
    end
    return true
  end
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return false
  end
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  self._quantityMax = owned
  self._quantity = math.min(math.max(self._quantity, 1), owned)
  return true
end

function BagController:_confirm()
  if self._overlay then
    self._overlay = false
    return
  end
  if self._state == "action_menu" then
    self:_chooseActionIndex(self._selectedAction)
  elseif self._state == "toss_quantity" then
    self:_enterTossConfirm()
  elseif self._state == "toss_confirm" then
    self:_commitToss()
  elseif self._state == "move_select" then
    self:_commitMove()
  elseif self._focus == "cancel" then
    self._result = { kind = "closed" }
    self._closed = true
  elseif self._focus == "tabs" then
    self._focus = "items"
  else
    self:_openActionMenu()
  end
end

function BagController:_cancel()
  if self._overlay then
    self._overlay = false
    return
  end
  if self._state == "action_menu" then
    self:_toBrowsing()
  elseif self._state == "toss_quantity" or self._state == "toss_confirm" then
    self:_toActionMenu()
  elseif self._state == "move_select" then
    self:_cancelMove()
  else
    self._result = { kind = "closed" }
    self._closed = true
  end
end

-- The info action opens the selected-item description overlay, but only
-- where the hero pane cannot show it: the constrained interactive-only
-- topology. Everywhere else the description already has its pane. Nested
-- action states own the info key, so it never disturbs a pending menu.
function BagController:_info()
  if self._overlay then
    self._overlay = false
    return
  end
  if self._state ~= "browsing" then
    return
  end
  if self._focus ~= "items" or self:_count() == 0 then
    return
  end
  local layout = self._resolveLayout()
  if type(layout) == "table" and layout.mode == "interactive_only" then
    self._overlay = true
  end
end

---@param page integer -1 for previous, 1 for next
function BagController:_page(page)
  local count = self:_count()
  if count <= 6 then
    return
  end
  local pocket = self:_pocket()
  local cursor = self._cursor
  local start = cursor:scroll(pocket) + page * 6
  local maxStart = count - 1
  start = math.min(math.max(start, 0), maxStart)
  cursor:setScroll(pocket, start - (start % 2))
  cursor:setPosition(pocket, cursor:scroll(pocket))
  self:_ensureVisible()
  self:_refresh()
end

---@param a table<string, unknown>?
---@param b table<string, unknown>?
---@return boolean
local function sameTarget(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.kind == b.kind
    and a.pocket == b.pocket
    and a.visibleIndex == b.visibleIndex
    and a.actionIndex == b.actionIndex
    and a.delta == b.delta
end

---@return table<string, unknown>
function BagController:_pointerState()
  return {
    state = self:_visibleState(),
    visibleSlots = self._view.visibleSlots,
  }
end

-- Activates one hit-test target through the shared paths. In nested action
-- states the same geometric targets carry the nested meaning: action
-- buttons choose, grid cells steer the move target, and Cancel pops one
-- level exactly like the cancel key.
---@param target table<string, unknown>?
function BagController:_activate(target)
  if target == nil then
    return
  end
  local state = self:_visibleState()
  if state == "description_overlay" then
    if target.kind == "description" then
      self._overlay = false
    end
    return
  end
  if state == "action_menu" then
    if target.kind == "action" then
      assert(type(target.actionIndex) == "number", "action targets name their button")
      self:_chooseActionIndex(target.actionIndex)
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if state == "toss_quantity" then
    if target.kind == "quantity_delta" then
      local delta = assert(target.delta, "quantity targets carry their step")
      assert(delta == -1 or delta == 1, "quantity targets step one copy")
      if delta == -1 then
        self:_adjustQuantity("left")
      else
        self:_adjustQuantity("right")
      end
    elseif target.kind == "confirm" then
      self:_enterTossConfirm()
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if state == "toss_confirm" then
    if target.kind == "confirm" then
      self:_commitToss()
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if state == "move_select" then
    if target.kind == "item" then
      assert(type(target.visibleIndex) == "number", "item targets name their cell")
      local view = self._view
      local start = assert(view.visibleStart, "the bag view needs its window start")
      assert(type(start) == "number", "the bag view needs its window start")
      self:_setMoveTarget(start + target.visibleIndex)
    elseif target.kind == "confirm" then
      self:_commitMove()
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if target.kind == "description" then
    self._overlay = false
    return
  end
  if target.kind == "cancel" then
    self:_cancel()
    return
  end
  if target.kind == "pocket" then
    assert(type(target.pocket) == "string", "pocket targets name their pocket")
    if target.pocket ~= self:_pocket() then
      self:_enterPocket(target.pocket)
    else
      self._focus = "items"
    end
    return
  end
  if target.kind == "item" then
    assert(type(target.visibleIndex) == "number", "item targets name their cell")
    local view = self._view
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    local pocket = self:_pocket()
    local absolute = start + target.visibleIndex
    if self._focus == "items" and absolute == self._cursor:position(pocket) then
      self:_confirm()
    else
      self._focus = "items"
      self:_select(absolute)
    end
  end
end

---@param event table<string, unknown>
function BagController:_pointerDown(event)
  if self._pressId ~= nil then
    return
  end
  assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
  self._pressId = event.pointerId
  local layout = self._resolveLayout()
  local hitTest = assert(layout.interactiveHitTest, "the bag layout must carry its hit test")
  local target = hitTest(event.x, event.y, self:_pointerState())
  if target == nil then
    self._pressCapture = nil
  else
    self._pressCapture = {
      kind = target.kind,
      pocket = target.pocket,
      visibleIndex = target.visibleIndex,
      actionIndex = target.actionIndex,
      delta = target.delta,
    }
  end
end

---@param event table<string, unknown>
function BagController:_pointerMove(event)
  if self._pressId ~= nil then
    return
  end
  if self:_visibleState() ~= "browsing" or self._overlay then
    return
  end
  local layout = self._resolveLayout()
  local hitTest = assert(layout.interactiveHitTest, "the bag layout must carry its hit test")
  local target = hitTest(event.x, event.y, self:_pointerState())
  if target ~= nil and target.kind == "item" and not self._overlay then
    local view = self._view
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    assert(type(target.visibleIndex) == "number", "item targets name their cell")
    self._focus = "items"
    self:_select(start + target.visibleIndex)
  end
end

---@param event table<string, unknown>
function BagController:_pointerUp(event)
  if event.pointerId ~= self._pressId then
    return
  end
  local down = self._pressCapture
  self._pressId = nil
  self._pressCapture = nil
  if event.dragged == true then
    return
  end
  local layout = self._resolveLayout()
  local hitTest = assert(layout.interactiveHitTest, "the bag layout must carry its hit test")
  local up = hitTest(event.x, event.y, self:_pointerState())
  if sameTarget(down, up) then
    self:_activate(up)
  end
end

---@param event table<string, unknown>
function BagController:_handleNavigate(event)
  if self._overlay then
    return
  end
  if self._state == "action_menu" then
    self:_cycleAction(event.direction)
  elseif self._state == "toss_quantity" then
    self:_adjustQuantity(event.direction)
  elseif self._state == "move_select" then
    self:_moveTargetStep(event.direction)
  elseif self._state == "browsing" then
    self:_move(event.direction)
  end
end

---@param uiInput table[]
function BagController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the bag input must be an event list")
  if self._closed then
    return
  end
  local previousRevision = self._observedRevision
  local view = self:_refresh()
  if view.revision ~= previousRevision then
    self:_reconcile()
  end
  if not self:_syncNested() then
    return
  end
  for _, event in ipairs(uiInput) do
    if self._closed then
      break
    end
    assert(type(event) == "table" and type(event.type) == "string", "bag events need a type")
    if event.type == "navigate" then
      self:_handleNavigate(event)
    elseif event.type == "confirm" then
      self:_confirm()
    elseif event.type == "cancel" then
      self:_cancel()
    elseif event.type == "menu" then
      self:_info()
    elseif event.type == "pointer_down" then
      self:_pointerDown(event)
    elseif event.type == "pointer_move" then
      self:_pointerMove(event)
    elseif event.type == "pointer_up" then
      self:_pointerUp(event)
    elseif event.type == "pointer_scroll" then
      if self._state == "browsing" and not self._overlay and type(event.dy) == "number" and event.dy ~= 0 then
        self:_page(event.dy > 0 and 1 or -1)
      end
    else
      error("unknown bag event type " .. tostring(event.type), 2)
    end
  end
end

---@return table<string, unknown>
function BagController:status()
  if self._closed then
    return { open = false }
  end
  local view = self._view
  local record = {
    open = true,
    state = self:_visibleState(),
    focus = self._focus,
    revision = view.revision,
    pocket = view.pocket,
    pocketNativeId = view.pocketNativeId,
    pocketName = view.pocketName,
    pockets = view.pockets,
    slots = view.slots,
    selectedAbsoluteIndex = view.selectedAbsoluteIndex,
    visibleStart = view.visibleStart,
    visibleSlots = view.visibleSlots,
    page = view.page,
    selected = view.selected,
    layout = self._resolveLayout(),
  }
  if self._state == "action_menu" and not self._overlay then
    record.actions = self._actions
    record.selectedAction = self._selectedAction
  elseif (self._state == "toss_quantity" or self._state == "toss_confirm") and not self._overlay then
    record.quantity = self._quantity
    record.quantityMax = self._quantityMax
  elseif self._state == "move_select" and not self._overlay then
    record.moveTarget = self._moveTarget
  end
  return record
end

---@return { kind: "closed" }?
function BagController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil then
    self._closed = true
  end
  return result
end

function BagController:dispose()
  self._result = nil
  self._closed = true
end

-- A press held across a layout change must not activate a different
-- post-layout target, so placement changes cancel the pointer capture.
function BagController:cancelPointerCapture()
  self._pressId = nil
  self._pressCapture = nil
end

return BagController
