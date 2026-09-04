-- The pure party-screen controller: view (inspect/switch/close) and select
-- (eligible-pick/cancel) modes over an injected immutable view. The view
-- arrives only through the injected model operation, swaps only through the
-- injected swap operation (view mode, exactly once per confirmed switch
-- with exactly one observed revision increment), and pointer input resolves
-- through the injected layout hit-test before sharing the keyboard/gamepad
-- confirm path. Results are one-shot semantic records ({kind="closed"} /
-- {kind="selected",slot} / {kind="cancelled"}) with no source sentinels.
-- Pure module: no love, no I/O.

---@class PartyScreenController
---@field _mode "view"|"select"
---@field _model PartyScreenController.Model
---@field _swap fun(a: integer, b: integer)?
---@field _resolveLayout fun(): table<string, unknown>
---@field _cancellable boolean
---@field _view PartyScreenController.View
---@field _observedRevision integer
---@field _action "browsing"|"action_choice"|"switch_destination"
---@field _cursorNode integer|"cancel"
---@field _switchSource integer?
---@field _actionSelection "switch"|"cancel"
---@field _result PartyScreenController.Result?
---@field _closed boolean
---@field _pressId string?
---@field _pressCapture PartyScreenPointerTarget?
local PartyScreenController = {}
PartyScreenController.__index = PartyScreenController

---@param node integer|string
---@return boolean
local function isSlotNode(node)
  return type(node) == "number"
end

-- A pointer capture: the hit-test target pressed down, compared against
-- the release target before anything activates.
---@class PartyScreenPointerTarget
---@field kind "slot"|"action"|"cancel"
---@field slot integer?
---@field action string?

-- Runs one hit-test through the injected layout function. The layout
-- table itself stays an injected boundary with no static contract.
---@param hitTest fun(x: number, y: number, actionsActive: boolean?): table<string, unknown>?
---@param x number
---@param y number
---@param actionsActive boolean
---@return table<string, unknown>?
local function hitTarget(hitTest, x, y, actionsActive)
  return hitTest(x, y, actionsActive)
end

-- Builds one pointer capture from a hit-test target. The capture outlives
-- the layout that produced it and carries only the compared fields.
---@param kind "slot"|"action"|"cancel"
---@param slot integer?
---@param action string?
---@return PartyScreenPointerTarget
local function captureTarget(kind, slot, action)
  return { kind = kind, slot = slot, action = action }
end

---@class PartyScreenController.View
---@field revision integer
---@field slots table[]

---@class PartyScreenController.Model
---@field refresh fun(): PartyScreenController.View

---@class PartyScreenController.Result
---@field kind "closed"|"selected"|"cancelled"
---@field slot integer?

---@class PartyScreenController.Options
---@field mode "view"|"select"
---@field initialSlot integer?
---@field allowCancel boolean?
---@field model PartyScreenController.Model
---@field swap fun(a: integer, b: integer)?
---@field resolveLayout fun(): table<string, unknown>

---@param opts PartyScreenController.Options
---@return PartyScreenController
function PartyScreenController.new(opts)
  assert(type(opts) == "table", "the party controller requires options")
  assert(opts.mode == "view" or opts.mode == "select", "the party controller requires a view or select mode")
  assert(
    type(opts.model) == "table" and type(opts.model.refresh) == "function",
    "the party controller needs a view model"
  )
  assert(type(opts.resolveLayout) == "function", "the party controller needs its layout resolver")
  if opts.mode == "view" then
    assert(type(opts.swap) == "function", "view mode swaps through the injected service operation")
  end
  if opts.initialSlot ~= nil then
    assert(
      type(opts.initialSlot) == "number"
        and opts.initialSlot % 1 == 0
        and opts.initialSlot >= 0
        and opts.initialSlot < 6,
      "the initial slot must be a party position in 0..5"
    )
  end
  local cancellable = opts.allowCancel
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "cancel permission must be a boolean")
  local self = setmetatable({
    _mode = opts.mode,
    _model = opts.model,
    _swap = opts.swap,
    _resolveLayout = opts.resolveLayout,
    _cancellable = cancellable,
    _action = "browsing",
    _cursorNode = 0,
    _switchSource = nil,
    _actionSelection = "switch",
    _result = nil,
    _closed = false,
    _pressId = nil,
    _pressCapture = nil,
  }, PartyScreenController)
  local view = self:_refresh()
  ---@type integer|string?
  local start = opts.initialSlot
  if start == nil or not self:_selectable(view, start) then
    start = self:_nearestSelectable(view, start)
  end
  if start == nil then
    error("the party screen has no selectable slot", 2)
  end
  self._cursorNode = start
  return self
end

---@return PartyScreenController.View
function PartyScreenController:_refresh()
  local view = self._model.refresh()
  assert(type(view) == "table" and type(view.slots) == "table", "the party view needs six slot records")
  assert(#view.slots == 6, "the party view needs six slot records")
  self._view = view
  self._observedRevision = view.revision
  return view
end

---@param view PartyScreenController.View
---@param node integer|string
---@return boolean
function PartyScreenController:_selectable(view, node)
  if node == "cancel" then
    return self._cancellable
  end
  if not isSlotNode(node) then
    return false
  end
  local record = view.slots[node + 1]
  if record == nil or not record.occupied then
    return false
  end
  if self._mode == "select" and not record.eligible then
    return false
  end
  return true
end

---@param view PartyScreenController.View
---@param from integer|string?
---@return integer|string?
function PartyScreenController:_nearestSelectable(view, from)
  local start = 0
  if type(from) == "number" then
    start = from
  end
  for offset = 0, 5 do
    local candidate = (start + offset) % 6
    if self:_selectable(view, candidate) then
      return candidate
    end
  end
  if self._cancellable then
    return "cancel"
  end
  return nil
end

---@return boolean
function PartyScreenController:cancellable()
  return self._cancellable
end

-- Walks one direction across the layout neighbors, skipping unselectable
-- nodes, so directional input never strands the cursor on an empty or
-- ineligible slot.
---@param direction string
function PartyScreenController:_move(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  if self._action == "action_choice" then
    if direction == "up" or direction == "down" then
      self._actionSelection = self._actionSelection == "switch" and "cancel" or "switch"
    end
    return
  end
  if self._action ~= "browsing" and self._action ~= "switch_destination" then
    return
  end
  local layout = assert(self._resolveLayout(), "the party layout is required for navigation")
  local neighbors = layout.neighbors
  assert(type(neighbors) == "table", "the party layout must carry directional neighbors")
  local seen = { [self._cursorNode] = true }
  local node = self._cursorNode
  for _ = 1, 8 do
    local links = neighbors[node]
    local next = type(links) == "table" and links[direction] or nil
    if next == nil or seen[next] then
      return
    end
    seen[next] = true
    if self:_selectable(self._view, next) then
      self._cursorNode = next
      return
    end
    node = next
  end
end

function PartyScreenController:_doSwap(source, destination)
  assert(self._mode == "view", "only view mode reorders the party")
  local swap = assert(self._swap, "view mode requires the swap operation")
  local before = self._observedRevision
  swap(source, destination)
  local view = self:_refresh()
  assert(view.revision == before + 1, "a confirmed switch observes exactly one party revision increment")
  self._action = "browsing"
  self._switchSource = nil
  self._cursorNode = destination
end

function PartyScreenController:_confirm()
  local node = self._cursorNode
  if self._mode == "select" then
    if node == "cancel" then
      if self._cancellable then
        self._result = { kind = "cancelled" }
        self._closed = true
      end
      return
    end
    if self:_selectable(self._view, node) then
      assert(isSlotNode(node), "selection completes on party slots only")
      ---@cast node integer
      self._result = { kind = "selected", slot = node }
      self._closed = true
    end
    return
  end
  if self._action == "browsing" then
    if node == "cancel" then
      self._result = { kind = "closed" }
      self._closed = true
    elseif self:_selectable(self._view, node) then
      self._action = "action_choice"
      self._actionSelection = "switch"
    end
    return
  end
  if self._action == "action_choice" then
    if self._actionSelection == "switch" then
      assert(isSlotNode(node), "a switch starts from a party slot")
      ---@cast node integer
      self._switchSource = node
      self._action = "switch_destination"
    else
      self._action = "browsing"
    end
    return
  end
  if self._action == "switch_destination" then
    local source = assert(self._switchSource, "a pending switch needs its source")
    if node == "cancel" or node == source then
      self._action = "browsing"
      self._switchSource = nil
      return
    end
    if self:_selectable(self._view, node) then
      assert(isSlotNode(node), "a switch destination is a party slot")
      self:_doSwap(source, node)
    end
  end
end

function PartyScreenController:_cancel()
  if self._mode == "select" then
    if self._cancellable then
      self._result = { kind = "cancelled" }
      self._closed = true
    end
    return
  end
  if self._action == "browsing" then
    self._result = { kind = "closed" }
    self._closed = true
    return
  end
  self._action = "browsing"
  self._switchSource = nil
end

---@param a table<string, unknown>?
---@param b table<string, unknown>?
---@return boolean
local function sameTarget(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.kind == b.kind and a.slot == b.slot and a.action == b.action
end

-- Activates one hit-test target through the shared confirm path: slots
-- move the cursor then confirm, action rows select then confirm, and the
-- cancel affordance cancels.
---@param target table<string, unknown>?
function PartyScreenController:_activate(target)
  if target == nil then
    return
  end
  if target.kind == "cancel" then
    self:_cancel()
    return
  end
  if target.kind == "action" then
    if self._action == "action_choice" and (target.action == "switch" or target.action == "cancel") then
      self._actionSelection = target.action
      self:_confirm()
    end
    return
  end
  if target.kind == "slot" and isSlotNode(target.slot) then
    if self:_selectable(self._view, target.slot) then
      self._cursorNode = target.slot
      self:_confirm()
    end
  end
end

---@param event table<string, unknown>
function PartyScreenController:_pointerDown(event)
  if self._pressId ~= nil then
    return
  end
  assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
  self._pressId = event.pointerId
  local layout = assert(self._resolveLayout(), "the party layout is required for pointer input")
  local hit = hitTarget(layout.hitTest, event.x, event.y, self._action == "action_choice")
  if hit == nil then
    self._pressCapture = nil
  else
    self._pressCapture = captureTarget(hit.kind, hit.slot, hit.action)
  end
end

---@param event table<string, unknown>
function PartyScreenController:_pointerMove(event)
  if self._pressId ~= nil then
    return
  end
  local layout = assert(self._resolveLayout(), "the party layout is required for pointer input")
  local target = hitTarget(layout.hitTest, event.x, event.y, self._action == "action_choice")
  if target ~= nil and target.kind == "slot" and isSlotNode(target.slot) then
    if self:_selectable(self._view, target.slot) then
      self._cursorNode = target.slot
    end
  elseif target ~= nil and target.kind == "action" and self._action == "action_choice" then
    if target.action == "switch" or target.action == "cancel" then
      self._actionSelection = target.action
    end
  end
end

---@param event table<string, unknown>
function PartyScreenController:_pointerUp(event)
  if event.pointerId ~= self._pressId then
    return
  end
  local down = self._pressCapture
  self._pressId = nil
  self._pressCapture = nil
  if event.dragged == true then
    return
  end
  local layout = assert(self._resolveLayout(), "the party layout is required for pointer input")
  local up = hitTarget(layout.hitTest, event.x, event.y, self._action == "action_choice")
  if sameTarget(down, up) then
    self:_activate(up)
  end
end

-- One fixed tick over the tick's UI events (navigate/confirm/cancel plus
-- pointer_down/pointer_move/pointer_up in layout coordinates). A terminal
-- event ends the tick: later events never overwrite the recorded result,
-- and a completed controller ignores further input.
---@param uiInput table[]
function PartyScreenController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the party input must be an event list")
  if self._closed then
    return
  end
  local previousRevision = self._observedRevision
  local view = self:_refresh()
  if view.revision ~= previousRevision then
    -- Reconcile a cursor the party change may have invalidated without
    -- inventing a mon: keep a still-selectable cursor, else the nearest one.
    if not self:_selectable(view, self._cursorNode) then
      local reconciled = self:_nearestSelectable(view, self._cursorNode)
      if reconciled ~= nil then
        self._cursorNode = reconciled
      end
    end
  end
  for _, event in ipairs(uiInput) do
    if self._closed then
      break
    end
    assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
    if event.type == "navigate" then
      self:_move(event.direction)
    elseif event.type == "confirm" then
      self:_confirm()
    elseif event.type == "cancel" then
      self:_cancel()
    elseif event.type == "pointer_down" then
      self:_pointerDown(event)
    elseif event.type == "pointer_move" then
      self:_pointerMove(event)
    elseif event.type == "pointer_up" then
      self:_pointerUp(event)
    elseif event.type == "menu" or event.type == "pointer_scroll" then
      -- A child application's own input policy applies: the synthesized
      -- menu edge and scroll events never drive the party screen.
    else
      error("unknown party event type " .. tostring(event.type), 2)
    end
  end
end

-- The presentation snapshot: mode, sub-state, cursor, pending switch, and
-- the current immutable view. The view is the model's own fresh record
-- (rebuilt on every refresh); callers must not mutate it.
---@class PartyScreenController.Status
---@field open boolean
---@field mode "view"|"select"?
---@field action "browsing"|"action_choice"|"switch_destination"?
---@field cursorNode integer|"cancel"?
---@field switchSource integer?
---@field actionSelection "switch"|"cancel"?
---@field view PartyScreenController.View?
---@field cancellable boolean?
---@field layout PartyScreenLayoutResolved? resolved layout injected by the application state for hit testing and rendering
---@return PartyScreenController.Status
function PartyScreenController:status()
  if self._closed then
    return { open = false }
  end
  return {
    open = true,
    mode = self._mode,
    action = self._action,
    cursorNode = self._cursorNode,
    switchSource = self._switchSource,
    actionSelection = self._action == "action_choice" and self._actionSelection or nil,
    view = self._view,
    cancellable = self._cancellable,
  }
end

-- The one-shot result contract: nil until a terminal event, then exactly
-- one semantic record.
---@return { kind: "closed"|"selected"|"cancelled", slot?: integer }?
function PartyScreenController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil then
    self._closed = true
  end
  return result
end

-- Idempotent release of the logical lifetime: a pending result is
-- discarded and no completion is reported after disposal.
function PartyScreenController:dispose()
  self._result = nil
  self._closed = true
end

-- A press held across a layout change must not activate a different
-- post-layout target, so placement changes cancel the pointer capture.
function PartyScreenController:cancelPointerCapture()
  self._pressId = nil
  self._pressCapture = nil
end

return PartyScreenController
