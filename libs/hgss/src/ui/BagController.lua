-- Field-bag controller: pure browse navigation plus the inventory-local
-- action states. Browsing keeps the six-cell grid navigation over the
-- injected view model, pocket switching with per-pocket cursor memory, and
-- the constrained-topology description overlay. Confirming an item opens the
-- action menu built by the injected policy projection; the nested toss
-- quantity picker, the modal two-row confirmation prompt, its post-choice
-- acknowledgement, and manual move-target states mutate only through the
-- injected semantic commands, exactly once per acknowledgement, with a
-- stale-selection check after every refresh so an external revision can
-- never redirect a pending mutation onto a different item. Cancelling the
-- picker or rejecting the prompt returns straight to browsing without
-- mutation, and closing returns to the menu.
-- Occupied selection and scroll live in the borrowed field cursor through
-- its API only; browse focus is a private semantic node (a grid cell, a
-- pocket tab, or cancel) resolved through the shared focus graph, so empty
-- cells can own focus without inventing an item selection. Pointer
-- press/release capture shares the keyboard confirm path, so a drag or a
-- layout change can never activate a moved target. Modal confirmation input
-- belongs to the owned two-row prompt controller and its source geometry;
-- the Bag layout never names YES/NO targets. Results are one-shot
-- ({kind="closed"}) with no renderer state and no love dependency.

local BagSave = require("libs.hgss.src.save.BagSave")
local BagLayout = require("libs.hgss.src.ui.BagLayout")
local FocusGraph = require("libs.ui.src.FocusGraph")
local YesNoPromptController = require("libs.hgss.src.ui.YesNoPromptController")

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
---@field _focusNode string the private semantic browse focus node
---@field _lastSlot integer the most recent grid-cell focus, for tab/cancel return
---@field _overlay boolean
---@field _state "browsing"|"action_menu"|"toss_quantity"|"toss_confirm"|"toss_ack"|"move_select"
---@field _prompt YesNoPromptController the owned modal prompt for toss confirmation
---@field _tossPrompt { x: integer, y: integer, shape: string, initialSelection: string } the generated semantic prompt placement
---@field _actions table<string, unknown>[]
---@field _actionNode integer
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
---@field _quantityPressedControl integer?
---@field _quantityPressedTicks integer
local BagController = {}
BagController.__index = BagController

---@class BagController.Options
---@field model { refresh: fun(): table<string, unknown> } the injected view projection
---@field cursor BagCursor the borrowed runtime-only field cursor
---@field resolveLayout fun(): table<string, unknown> the injected layout resolver
---@field promptShape { width: integer, height: integer, yes: table<string, unknown>, no: table<string, unknown> } the validated compact prompt shape
---@field tossPrompt { x: integer, y: integer, shape: string, initialSelection: string } the generated semantic prompt placement
---@field commands BagControllerCommands semantic mutations bound to the live inventory service
---@field resolveActions fun(view: table<string, unknown>): table<string, unknown>[] the injected inventory-local menu projection over the refreshed view

---@param value unknown
---@param what string
---@return integer
local function checkQuantity(value, what)
  assert(type(value) == "number" and value % 1 == 0 and value >= 1, what .. " must be a positive integer")
  return value
end

-- Browse focus node identities. Grid cells name their absolute zero-based
-- cell index, tabs name their pocket key, and cancel is a singleton; the
-- strings double as focus-graph node ids.
local CANCEL_NODE = "cancel"

local ACTION_NEIGHBORS = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

---@param actions table<string, unknown>[]
local function validateActions(actions)
  local seen = {}
  for _, action in ipairs(actions) do
    assert(type(action) == "table", "dynamic actions are records")
    assert(type(action.id) == "string" and action.id ~= "cancel", "dynamic actions carry supported ids")
    assert(
      type(action.slot) == "number" and action.slot % 1 == 0 and action.slot >= 0 and action.slot <= 3,
      "dynamic actions carry a valid physical slot"
    )
    assert(not seen[action.slot], "dynamic action slots are unique")
    seen[action.slot] = true
  end
end

---@param absolute integer
---@return string
local function slotNode(absolute)
  return "slot:" .. tostring(absolute)
end

---@param pocketKey string
---@return string
local function tabNode(pocketKey)
  return "tab:" .. pocketKey
end

---@param node unknown
---@return integer?
local function parseSlot(node)
  if type(node) ~= "string" then
    return nil
  end
  local absolute = node:match("^slot:(%d+)$")
  if absolute == nil then
    return nil
  end
  return math.floor(assert(tonumber(absolute), "slot nodes carry a numeric cell"))
end

---@param node unknown
---@return string?
local function parseTab(node)
  if type(node) ~= "string" then
    return nil
  end
  local pocketKey = node:match("^tab:(.+)$")
  if pocketKey == nil then
    return nil
  end
  for _, known in ipairs(BagSave.POCKET_ORDER) do
    if known == pocketKey then
      return pocketKey
    end
  end
  return nil
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
  assert(type(opts.promptShape) == "table", "the bag controller needs its modal prompt shape")
  assert(type(opts.tossPrompt) == "table", "the bag controller needs its toss prompt template")
  -- The modal prompt is bound once and owned for the controller lifetime:
  -- opening the supplied template here proves a malformed placement fails
  -- construction instead of falling back to action slots, and disposing
  -- leaves no active prompt behind.
  local prompt = YesNoPromptController.new(opts.promptShape)
  prompt:open(opts.tossPrompt)
  prompt:dispose()
  local self = setmetatable({
    _model = opts.model,
    _cursor = opts.cursor,
    _resolveLayout = opts.resolveLayout,
    _commands = opts.commands,
    _resolveActions = opts.resolveActions,
    _focusNode = slotNode(0),
    _lastSlot = 0,
    _overlay = false,
    _state = "browsing",
    _actions = {},
    _actionNode = 4,
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
    _quantityPressedControl = nil,
    _quantityPressedTicks = 0,
    _prompt = prompt,
    _tossPrompt = opts.tossPrompt,
  }, BagController)
  self._view = self:_refresh()
  self:_reconcile()
  -- Browse focus starts on the top-left cell of the current visible window
  -- while the borrowed per-pocket scroll is left alone; an occupied start
  -- cell also becomes the borrowed selection.
  local pocket = self:_pocket()
  local start = self._cursor:scroll(pocket)
  self._focusNode = slotNode(start)
  self._lastSlot = start
  if start < self:_count() then
    self._cursor:setPosition(pocket, start)
    self:_refresh()
  end
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
-- return, clamped to whatever the pocket holds now. Focus stays with the
-- caller, so keyboard tab travel keeps tab focus while pointer activation
-- moves to the grid explicitly at its own call site. The remembered grid
-- cell follows the clamped per-pocket cursor position either way, so a
-- later vertical return from the tabs or Cancel lands on the remembered
-- selection instead of the window top-left diverging from it.
---@param pocketKey string
function BagController:_enterPocket(pocketKey)
  self._cursor:setPocket(pocketKey)
  self:_refresh()
  self:_reconcile()
  self._lastSlot = self._cursor:position(pocketKey)
  self:_normalizeFocus()
  -- Focus is caller-owned; do not mutate self._focusNode here.
end

-- The logical browse grid covers the six currently visible cells and
-- otherwise pads occupied items to a complete two-column row, so a
-- visible trailing cell can own focus without inventing inventory.
---@return integer
function BagController:_logicalSlotCount()
  local padded = math.max(6, math.ceil(self:_count() / 2) * 2)
  local start = assert(self._view.visibleStart, "the bag view needs its visible window start")
  return math.max(padded, start + 6)
end

-- Builds the ephemeral browse graph over the current pocket, item count,
-- tab order, and remembered cell. Grid adjacency is absolute: same-row
-- siblings sideways (missing neighbors stay put, never wrap), two cells
-- vertically, the top row up to the active-pocket tab, and the last
-- logical row down to Cancel. Tabs wrap through the pocket order and
-- travel vertically back to the remembered cell, as does Cancel upward.
---@return table<string, table<string, string[]>>
function BagController:_browseGraph()
  local pocket = self:_pocket()
  local slotCount = self:_logicalSlotCount()
  local remembered = slotNode(self._lastSlot)
  local graph = {}
  for absolute = 0, slotCount - 1 do
    local id = slotNode(absolute)
    local left = absolute % 2 == 1 and { slotNode(absolute - 1) } or {}
    local right = absolute % 2 == 0 and absolute + 1 < slotCount and { slotNode(absolute + 1) } or {}
    local up = absolute - 2 >= 0 and { slotNode(absolute - 2) } or { tabNode(pocket) }
    local down = absolute + 2 < slotCount and { slotNode(absolute + 2) } or { CANCEL_NODE }
    graph[id] = { up = up, down = down, left = left, right = right }
  end
  local order = BagSave.POCKET_ORDER
  for position, pocketKey in ipairs(order) do
    local previous = order[((position - 2) % #order) + 1]
    local following = order[(position % #order) + 1]
    graph[tabNode(pocketKey)] = {
      left = { tabNode(previous) },
      right = { tabNode(following) },
      up = { remembered },
      down = { remembered },
    }
  end
  graph[CANCEL_NODE] = { up = { remembered }, down = {}, left = {}, right = {} }
  return graph
end

-- Repairs focus after an external revision shrank the logical grid: an
-- out-of-range cell falls back to the nearest valid one, and anything that
-- is no longer a browse node at all returns to the remembered cell. A
-- valid-but-empty cell is kept, so removal never steals a visible focus.
function BagController:_normalizeFocus()
  local slotCount = self:_logicalSlotCount()
  if self._lastSlot < 0 or self._lastSlot >= slotCount then
    self._lastSlot = math.max(slotCount - 1, 0)
  end
  local absolute = parseSlot(self._focusNode)
  if absolute ~= nil then
    if absolute < 0 or absolute >= slotCount then
      self._focusNode = slotNode(self._lastSlot)
    end
    return
  end
  if parseTab(self._focusNode) == nil and self._focusNode ~= CANCEL_NODE then
    self._focusNode = slotNode(self._lastSlot)
  end
end

-- While plain browsing, an outside revision may have filled the focused
-- cell without travelling through focus input. Carry the borrowed cursor
-- to the newly occupied focus so selection names the same item before any
-- consumer observes the refreshed view. Empty focus keeps no selection and
-- nested states keep their snapshotted item; neither is retargeted here.
function BagController:_reconcileBrowseSelection()
  if self._state ~= "browsing" or self._overlay then
    return
  end
  local absolute = parseSlot(self._focusNode)
  if absolute == nil or absolute >= self:_count() then
    return
  end
  local pocket = self:_pocket()
  if self._cursor:position(pocket) == absolute then
    return
  end
  self._cursor:setPosition(pocket, absolute)
  self:_ensureVisible()
  self:_refresh()
end

-- Focuses one absolute grid cell: the window slides in row steps until the
-- cell is visible, an occupied cell also becomes the borrowed selection,
-- and an empty cell leaves the borrowed cursor alone. Requests past the
-- logical grid clamp to its last cell, so a tap beyond the padded row can
-- never produce a node the graph does not know.
---@param absolute integer
function BagController:_focusSlot(absolute)
  local pocket = self:_pocket()
  local slotCount = self:_logicalSlotCount()
  local clamped = math.min(math.max(absolute, 0), slotCount - 1)
  self._focusNode = slotNode(clamped)
  self._lastSlot = clamped
  local cursor = self._cursor
  local start = cursor:scroll(pocket)
  while clamped < start do
    start = start - 2
  end
  while clamped >= start + 6 do
    start = start + 2
  end
  if start ~= cursor:scroll(pocket) then
    cursor:setScroll(pocket, start)
  end
  if clamped < self:_count() then
    cursor:setPosition(pocket, clamped)
  end
  self:_refresh()
end

-- Applies one resolved browse node and its side effects: grid cells focus
-- through the shared slot path, while tabs and Cancel only move focus.
---@param node string
function BagController:_applyFocusNode(node)
  local absolute = parseSlot(node)
  if absolute ~= nil then
    self:_focusSlot(absolute)
    return
  end
  assert(parseTab(node) ~= nil or node == CANCEL_NODE, "focus nodes stay inside the browse graph")
  self._focusNode = node
end

---@param direction string
function BagController:_move(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  self:_normalizeFocus()
  local target = FocusGraph.move(self:_browseGraph(), self._focusNode, direction)
  assert(type(target) == "string", "bag browse nodes are string ids")
  self:_applyFocusNode(target)
end

-- The focused absolute cell while plain browsing, or nil on tabs/Cancel.
-- This is focus identity, not item identity: it may name an empty cell.
---@return integer?
function BagController:_focusedSlotAbsolute()
  if self:_visibleState() ~= "browsing" then
    return nil
  end
  return parseSlot(self._focusNode)
end

-- The focused cell when it actually holds an item: the only browse focus
-- that may open the description or the action menu.
---@return integer?
function BagController:_focusedOccupiedAbsolute()
  local absolute = self:_focusedSlotAbsolute()
  if absolute == nil or absolute >= self:_count() then
    return nil
  end
  return absolute
end

-- Drops every nested action frame and returns to plain browsing. Mutations
-- never ride this path: callers refresh first and commit explicitly. The
-- owned prompt resets with the menu, so no capture or result survives the
-- return.
function BagController:_toBrowsing()
  self._prompt:dispose()
  self._state = "browsing"
  self._actions = {}
  self._actionNode = 4
  self._actionItemKey = nil
  self._actionPocket = nil
  self._quantity = 1
  self._quantityMax = 1
  self._quantityPressedControl = nil
  self._quantityPressedTicks = 0
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

---@return table<string, unknown>[]
function BagController:_currentActions()
  local actions = self._resolveActions(self._view)
  assert(type(actions) == "table", "the action policy returns dynamic actions")
  validateActions(actions)
  return actions
end

-- Confirming an item resolves the inventory-local menu for the refreshed
-- view and snapshots the semantic selection the nested states verify
-- against. Only an occupied focused cell may enter; an empty focus is a
-- no-op, never an error.
function BagController:_openActionMenu()
  local absolute = self:_focusedOccupiedAbsolute()
  if absolute == nil then
    return
  end
  local selected = self._view.slots[absolute + 1]
  if type(selected) ~= "table" or type(selected.item) ~= "string" then
    return
  end
  local actions = self:_currentActions()
  self._actions = actions
  self._actionNode = 4
  for _, action in ipairs(actions) do
    if action.slot < self._actionNode then
      self._actionNode = action.slot
    end
  end
  self._actionItemKey = selected.item
  self._actionPocket = self:_pocket()
  self._overlay = false
  self._state = "action_menu"
end

---@param node integer physical action node
function BagController:_chooseActionNode(node)
  assert(node >= 0 and node <= 4 and node % 1 == 0, "action focus is a physical node")
  -- An external revision may have moved the selection under the open menu:
  -- re-resolve onto the current selection instead of dispatching the
  -- snapshotted action at a ghost. An empty pocket simply closes the menu.
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    self:_openActionMenu()
    return
  end
  self._actions = self:_currentActions()
  if node == 4 then
    self:_toBrowsing()
    return
  end
  local action
  for _, candidate in ipairs(self._actions) do
    if candidate.slot == node then
      action = candidate
    end
  end
  if type(action) ~= "table" or type(action.id) ~= "string" then
    return
  end
  local id = action.id
  if id == "toss" then
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
function BagController:_moveAction(direction)
  assert(ACTION_NEIGHBORS[self._actionNode][direction], "unknown action direction")
  self._actionNode = ACTION_NEIGHBORS[self._actionNode][direction]
end

-- Enters the quantity picker for the snapshotted item, preselecting one
-- copy. The range always ends at the freshly observed owned quantity. A
-- lone owned copy skips the picker and confirms through the modal prompt
-- directly.
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
  if owned == 1 then
    self:_enterTossConfirm()
    return
  end
  self._state = "toss_quantity"
end

---@param direction string
function BagController:_adjustQuantity(direction)
  if direction == "up" then
    self._quantity = self._quantity == self._quantityMax and 1 or self._quantity + 1
  elseif direction == "down" then
    self._quantity = self._quantity == 1 and self._quantityMax or self._quantity - 1
  elseif direction == "left" then
    self._quantity = math.max(1, self._quantity - 10)
  elseif direction == "right" then
    self._quantity = math.min(self._quantityMax, self._quantity + 10)
  end
end

---@param delta integer
function BagController:_adjustQuantityByTouch(delta)
  assert(
    delta == -100 or delta == -10 or delta == -1 or delta == 1 or delta == 10 or delta == 100,
    "quantity touch deltas are source controls"
  )
  if delta > 0 then
    self._quantity = self._quantity == self._quantityMax and 1 or math.min(self._quantityMax, self._quantity + delta)
  else
    self._quantity = self._quantity == 1 and self._quantityMax or math.max(1, self._quantity + delta)
  end
end

function BagController:_clearQuantityPress()
  self._quantityPressedControl = nil
  self._quantityPressedTicks = 0
end

---@param controlIndex integer
function BagController:_pressQuantityControl(controlIndex)
  assert(controlIndex >= 0 and controlIndex <= 5 and controlIndex % 1 == 0, "quantity control index is physical")
  local layout = self._resolveLayout()
  local ticks = assert(layout.quantityPressTicks, "the quantity layout carries press ticks")
  assert(ticks > 0 and ticks % 1 == 0, "quantity press ticks are positive")
  self._quantityPressedControl = controlIndex
  self._quantityPressedTicks = ticks
end

-- Confirms the picked quantity into the modal confirmation state, clamping
-- to whatever the latest refresh still observes. A vanished selection
-- aborts instead of carrying a stale quantity forward. Opening the owned
-- prompt through the generated template starts it with YES selected.
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
  self:_clearQuantityPress()
  self._prompt:open(self._tossPrompt)
  self._state = "toss_confirm"
end

-- Consumes one modal prompt result after the tick-owned prompt step:
-- NO returns straight to browsing, YES waits for a later acknowledgement
-- in the post-choice state. Accepting YES never mutates; only the
-- acknowledgement input commits.
function BagController:_resolveTossPrompt()
  local result = self._prompt:takeResult()
  if result == nil then
    return
  end
  if result == "no" then
    self:_toBrowsing()
  elseif result == "yes" then
    self._prompt:dispose()
    self._state = "toss_ack"
  end
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
  self:_normalizeFocus()
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
    -- The moved item stays selected at its new position, and browse focus
    -- follows it there.
    self:_focusSlot(toIndex - 1)
  else
    self:_reconcile()
    self:_normalizeFocus()
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
  self:_normalizeFocus()
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
  self:_normalizeFocus()
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
    self._actions = self:_currentActions()
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
    self:_chooseActionNode(self._actionNode)
  elseif self._state == "toss_quantity" then
    self:_enterTossConfirm()
  elseif self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  elseif self._state == "move_select" then
    self:_commitMove()
  elseif self._focusNode == CANCEL_NODE then
    self._result = { kind = "closed" }
    self._closed = true
  elseif parseTab(self._focusNode) ~= nil then
    local candidate = assert(parseTab(self._focusNode), "tab focus carries a pocket")
    if candidate ~= self:_pocket() then
      self:_enterPocket(candidate)
    end
    -- Keep tab focus. A commits selection; it does not return to the item grid.
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
  elseif self._state == "toss_quantity" then
    self:_toBrowsing()
  elseif self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
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
  if self:_focusedOccupiedAbsolute() == nil then
    return
  end
  local layout = self._resolveLayout()
  if type(layout) == "table" and layout.heroVisible == false then
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
  -- Paging carries browse focus with the window to its top-left cell.
  self._focusNode = slotNode(cursor:scroll(pocket))
  self._lastSlot = cursor:scroll(pocket)
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
    and a.actionNode == b.actionNode
    and a.quantityControlIndex == b.quantityControlIndex
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
      assert(type(target.actionNode) == "number", "action targets name their physical node")
      self._actionNode = target.actionNode
      self:_chooseActionNode(target.actionNode)
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if state == "toss_quantity" then
    if target.kind == "quantity_delta" then
      local delta = assert(target.delta, "quantity targets carry their step")
      self:_adjustQuantityByTouch(delta)
      self:_pressQuantityControl(assert(target.quantityControlIndex, "quantity targets name their control"))
    elseif target.kind == "confirm" then
      self:_enterTossConfirm()
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
    end
    local view = self._view
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    self:_focusSlot(start)
    return
  end
  if target.kind == "item" then
    assert(type(target.visibleIndex) == "number", "item targets name their cell")
    local view = self._view
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    local absolute = start + target.visibleIndex
    if parseSlot(self._focusNode) == absolute then
      -- Activating the focused cell confirms through the shared path, so
      -- an empty focus stays a no-op instead of opening a ghost menu.
      self:_confirm()
    else
      self:_focusSlot(absolute)
    end
  end
end

-- A fresh press inside the interaction pane acknowledges the post-choice
-- state; anything outside it is not an acknowledgement.
---@param event table<string, unknown>
---@return boolean
local function pressInsidePane(event)
  return type(event.x) == "number"
    and type(event.y) == "number"
    and event.x >= 0
    and event.x < BagLayout.PANE_WIDTH
    and event.y >= 0
    and event.y < BagLayout.PANE_HEIGHT
end

---@param event table<string, unknown>
function BagController:_pointerDown(event)
  if self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  end
  if self._pressId ~= nil then
    return
  end
  assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
  self._pressId = event.pointerId
  local layout = self._resolveLayout()
  local hitTest = assert(layout.hitTest, "the bag layout must carry its hit test")
  local target = hitTest(event.x, event.y, self:_pointerState())
  if target == nil then
    self._pressCapture = nil
  else
    self._pressCapture = {
      kind = target.kind,
      pocket = target.pocket,
      visibleIndex = target.visibleIndex,
      actionNode = target.actionNode,
      quantityControlIndex = target.quantityControlIndex,
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
  local hitTest = assert(layout.hitTest, "the bag layout must carry its hit test")
  local target = hitTest(event.x, event.y, self:_pointerState())
  if target ~= nil and target.kind == "item" and not self._overlay then
    local view = self._view
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    assert(type(target.visibleIndex) == "number", "item targets name their cell")
    self:_focusSlot(start + target.visibleIndex)
  end
end

---@param event table<string, unknown>
function BagController:_pointerUp(event)
  if self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  end
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
  local hitTest = assert(layout.hitTest, "the bag layout must carry its hit test")
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
  if self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  end
  if self._state == "action_menu" then
    self:_moveAction(event.direction)
  elseif self._state == "toss_quantity" then
    self:_adjustQuantity(event.direction)
  elseif self._state == "move_select" then
    self:_moveTargetStep(event.direction)
  elseif self._state == "browsing" then
    self:_move(event.direction)
  end
end

-- Owns one fixed tick that begins with the modal prompt active: terminal
-- dismissal closes the bag without touching the prompt, otherwise the
-- tick advances the prompt exactly once and resolves its published result
-- once. This branch returns before the ordinary event loop, so opening
-- and terminal ticks never reuse their input as browse or acknowledgement
-- input.
---@param uiInput table[]
function BagController:_stepTossPrompt(uiInput)
  for _, event in ipairs(uiInput) do
    assert(type(event) == "table" and type(event.type) == "string", "bag events need a type")
    if event.type == "dismiss" then
      self._result = { kind = "closed" }
      self._closed = true
      return
    end
  end
  self._prompt:updateFixed(uiInput)
  self:_resolveTossPrompt()
end

-- Owns one fixed tick that begins in the post-choice acknowledgement
-- state: dismissal closes without mutation, A/B or a fresh in-pane press
-- commits exactly once, and anything else waits. The scan finishes before
-- any terminal action so batch position never decides the outcome, and
-- the caller returns before the ordinary loop so the newly entered
-- browsing state never sees this batch.
---@param uiInput table[]
function BagController:_stepTossAck(uiInput)
  local hasDismiss = false
  local hasAcknowledgement = false
  for _, event in ipairs(uiInput) do
    assert(type(event) == "table" and type(event.type) == "string", "bag events need a type")
    if event.type == "dismiss" then
      hasDismiss = true
    elseif event.type == "confirm" or event.type == "cancel" then
      hasAcknowledgement = true
    elseif event.type == "pointer_down" then
      if pressInsidePane(event) then
        hasAcknowledgement = true
      end
    elseif
      event.type == "navigate"
      or event.type == "menu"
      or event.type == "pointer_move"
      or event.type == "pointer_up"
      or event.type == "pointer_cancel"
      or event.type == "pointer_scroll"
    then
      -- Inert while waiting for acknowledgement.
    else
      error("unknown bag event type " .. tostring(event.type), 2)
    end
  end
  if hasDismiss then
    self._result = { kind = "closed" }
    self._closed = true
    return
  end
  if hasAcknowledgement then
    self:_commitToss()
  end
end

---@param uiInput table[]
function BagController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the bag input must be an event list")
  if self._closed then
    return
  end
  if self._quantityPressedTicks > 0 then
    self._quantityPressedTicks = self._quantityPressedTicks - 1
    if self._quantityPressedTicks == 0 then
      self:_clearQuantityPress()
    end
  end
  local previousRevision = self._observedRevision
  local view = self:_refresh()
  if view.revision ~= previousRevision then
    self:_reconcile()
  end
  self:_normalizeFocus()
  self:_reconcileBrowseSelection()
  if not self:_syncNested() then
    return
  end
  if self._state == "toss_confirm" then
    self:_stepTossPrompt(uiInput)
    return
  end
  if self._state == "toss_ack" then
    self:_stepTossAck(uiInput)
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
    elseif event.type == "dismiss" then
      -- Terminal outside dismissal: close immediately without unwinding
      -- nested action/toss/move/overlay state through _cancel.
      self._result = { kind = "closed" }
      self._closed = true
    elseif event.type == "menu" then
      self:_info()
    elseif event.type == "pointer_down" then
      self:_pointerDown(event)
    elseif event.type == "pointer_move" then
      self:_pointerMove(event)
    elseif event.type == "pointer_up" then
      self:_pointerUp(event)
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
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
  -- The legacy focus category and tab candidate derive from the semantic
  -- node; grid focus additionally publishes its absolute and visible cell
  -- so the renderer can frame an empty cell without an item selection.
  local focus = "items"
  local candidate = self:_pocket()
  local focusedAbsolute = parseSlot(self._focusNode)
  if focusedAbsolute ~= nil then
    focus = "items"
  elseif self._focusNode == CANCEL_NODE then
    focus = "cancel"
    focusedAbsolute = nil
  else
    focus = "tabs"
    focusedAbsolute = nil
    candidate = assert(parseTab(self._focusNode), "tab focus carries a pocket")
  end
  -- Browse selection follows the focused cell when it holds an item and is
  -- absent on an empty focus, even though the borrowed cursor keeps its
  -- last valid occupied position. Nested action states keep the occupied
  -- contract they snapshotted.
  local selected = view.selected
  local selectedAbsoluteIndex = view.selectedAbsoluteIndex
  ---@type integer?
  local focusedVisible = nil
  if focusedAbsolute ~= nil then
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    focusedVisible = focusedAbsolute - start
    if self:_visibleState() == "browsing" and focusedAbsolute >= self:_count() then
      selected = nil
      selectedAbsoluteIndex = nil
    end
  end
  local record = {
    open = true,
    state = self:_visibleState(),
    focus = focus,
    revision = view.revision,
    pocket = view.pocket,
    tabFocusPocket = candidate,
    pocketNativeId = view.pocketNativeId,
    pocketName = view.pocketName,
    pockets = view.pockets,
    slots = view.slots,
    selectedAbsoluteIndex = selectedAbsoluteIndex,
    visibleStart = view.visibleStart,
    visibleSlots = view.visibleSlots,
    page = view.page,
    selected = selected,
    focusedAbsoluteIndex = focusedAbsolute,
    focusedVisibleIndex = focusedVisible,
  }
  if self._state == "action_menu" and not self._overlay then
    record.actions = self._actions
    record.actionNode = self._actionNode
  elseif
    (self._state == "toss_quantity" or self._state == "toss_confirm" or self._state == "toss_ack")
    and not self._overlay
  then
    record.quantity = self._quantity
    record.quantityMax = self._quantityMax
    if self._state == "toss_quantity" and self._quantityPressedTicks > 0 then
      record.quantityPressedControl = self._quantityPressedControl
    end
    if self._state == "toss_confirm" then
      record.yesNoPrompt = self._prompt:status()
    end
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
  self:_clearQuantityPress()
  self._prompt:dispose()
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
