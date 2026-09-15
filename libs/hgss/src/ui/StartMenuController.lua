-- The pure Start Menu controller: the final interactive action display,
-- selection, confirm/cancel, and touch/pointer slot interaction of the HGSS
-- Start Menu, plus the folded-in fixed-tick cursor animation. It consumes
-- the runtime-composed final action list (the intersection of the source
-- policy with the registered destination applications; display-array
-- positions follow StartMenu_BuildActionLists, src/start_menu.c at the
-- pinned decomp commit 008257708) and the generated manifest slot surface
-- (the 2x5 slot grid keyed by the source touch-menu ids: slot 1 is the
-- cancel region and touch ids 2..10 are display positions 0..8, StartMenu_
-- HandleTouchInput start_menu.c:613-659). The final list is never empty --
-- the menu factory returns nil when no action is interactive -- so the
-- controller's constructor guards the real invariants (a non-empty list, a
-- display position that fits the slot surface, cursor frames to animate),
-- and the selection always resolves. The controller is silent -- the branch
-- does not reproduce the source Start Menu effects (SEQ_SE_DP_WIN_OPEN/
-- SELECT and SEQ_SE_GS_GEARCANCEL); it never touches love and never names a
-- ROM sequence or member number. Pointer events carry canonical logical
-- coordinates (0..255 x 0..191); the layout host maps host coordinates
-- before feeding the controller, and the host drops unsupported pointer
-- scroll events. No application launches happen here: the controller records
-- the takeResult contract ({ kind = "close" } / { kind = "launch",
-- applicationId }) and the application host launches.

---@class StartMenuController
---@field _visibleActions table<integer, StartMenuController.Action> ordered display positions with entries
---@field _orderedPositions integer[] the visible display positions in ascending order
---@field _selectedPosition integer the selected display position
---@field _result table<string, unknown>?
---@field _closed boolean
---@field _cursorFrames { duration: integer }[] the manifest cursor frame durations
---@field _cursorFrameIndex integer zero-based index into _cursorFrames
---@field _cursorFrameTicks integer
---@field _slots table<integer, FieldDialogueTheme.Rect>
---@field _pointerId string?
---@field _pointerDown { kind: "cancel"|"action"|"none", position: integer? }?
---@field _effect fun(sequence: string)? source UI sound effect boundary
local StartMenuController = {}
StartMenuController.__index = StartMenuController

-- The cancel touch region is the manifest's slot 1 (the source touch menu id
-- 1); display position p occupies slot id p+2 (touch id p+2).
StartMenuController.CANCEL_SLOT_ID = 1

-- The final interactive action list and the manifest slot surface are
-- already validated by their producers, so the controller only guards its
-- own invariants: a non-empty list (the factory returns nil for a blank
-- menu), display positions that fit the slot surface, and cursor frames to
-- animate.
---@param entries table[]
---@param slotCount integer
---@return table<integer, StartMenuController.Action>, table[]
local function composeDisplay(entries, slotCount)
  -- The source display array: visible entries write their display position
  -- (later writes win -- special 9/10 overwrite positions 7/8). The array
  -- length is the action slot count (slots 2..n), so position p = slot p+2.
  local capacity = slotCount - 1
  local display = {}
  for _, entry in ipairs(entries) do
    local position = entry.displayPosition
    assert(
      type(position) == "number" and position % 1 == 0 and position >= 0,
      "a start menu entry needs an integral display position"
    )
    assert(position < capacity, "start menu display capacity exceeded at position " .. tostring(position))
    display[position] = {
      id = entry.id,
      targetApplication = entry.targetApplication,
      actionKind = entry.actionKind,
      position = position,
      slotId = position + StartMenuController.CANCEL_SLOT_ID + 1,
      enabled = entry.enabled ~= false, -- default to enabled if not specified
      sourcePresent = entry.sourcePresent,
      sourceEnabled = entry.sourceEnabled,
      implemented = entry.implemented,
    }
  end
  local ordered = {}
  for position = 0, capacity - 1 do
    if display[position] then
      ordered[#ordered + 1] = display[position]
    end
  end
  return display, ordered
end

-- Restores the remembered selection by action id; falls back to the first
-- action when the remembered id is no longer interactive.
---@param ordered StartMenuController.Action[]
---@param rememberedActionId string?
---@return integer position
local function initialPosition(ordered, rememberedActionId)
  if rememberedActionId ~= nil then
    for _, action in ipairs(ordered) do
      if action.id == rememberedActionId then
        return action.position
      end
    end
  end
  return assert(ordered[1], "an interactive start menu requires at least one action").position
end

---@class StartMenuController.Action
---@field id string
---@field targetApplication string
---@field actionKind string?
---@field position integer display position (0-based)
---@field slotId integer manifest slot id
---@field enabled boolean whether the action can be activated (source-enabled and implementation-available)
---@field sourcePresent boolean source action was present in the source menu
---@field sourceEnabled boolean source policy enabled the action
---@field implemented boolean runtime has an implementation for the action

---@class StartMenuController.Entry
---@field id string
---@field targetApplication string
---@field actionKind string?
---@field displayPosition integer
---@field sourcePresent boolean
---@field sourceEnabled boolean
---@field implemented boolean

-- opts.entries: the runtime-composed final interactive action list
-- (id / targetApplication / displayPosition), never empty. opts.slots: the
-- generated manifest startMenu.slots. opts.cursorFrames: the generated
-- manifest startMenu.cursor.frames. opts.rememberedActionId: the selection
-- remembered across a child-application round trip.
---@param opts { entries: StartMenuController.Entry[], slots: table<integer, FieldDialogueTheme.Rect>, cursorFrames: { duration: integer }[], rememberedActionId?: string?, effect?: fun(sequence: string) }
---@return StartMenuController
function StartMenuController.new(opts)
  assert(type(opts) == "table", "the start menu controller requires options")
  assert(type(opts.entries) == "table" and #opts.entries >= 1, "a blank start menu is never constructed")
  assert(type(opts.slots) == "table", "the start menu requires the manifest slot surface")
  assert(
    type(opts.cursorFrames) == "table" and #opts.cursorFrames >= 1,
    "the cursor animation requires manifest frames"
  )
  local display, ordered = composeDisplay(opts.entries, #opts.slots)
  local orderedPositions = {}
  for index, action in ipairs(ordered) do
    orderedPositions[index] = action.position
  end
  local self = setmetatable({
    _visibleActions = display,
    _orderedPositions = orderedPositions,
    _selectedPosition = initialPosition(ordered, opts.rememberedActionId),
    _result = nil,
    _closed = false,
    _cursorFrames = opts.cursorFrames,
    _cursorFrameIndex = 0,
    _cursorFrameTicks = 0,
    _slots = opts.slots,
    _pointerId = nil,
    _pointerDown = nil,
    _effect = opts.effect,
  }, StartMenuController)
  return self
end

---@param slot FieldDialogueTheme.Rect
---@param x number
---@param y number
---@return boolean
local function contains(slot, x, y)
  return x >= slot.x and y >= slot.y and x < slot.x + slot.width and y < slot.y + slot.height
end

-- The slot under a canonical logical point, or nil outside the grid.
---@param slots table<integer, FieldDialogueTheme.Rect>
---@param x number
---@param y number
---@return integer? slotId
local function slotAt(slots, x, y)
  for slotId, rect in pairs(slots) do
    if contains(rect, x, y) then
      return slotId
    end
  end
  return nil
end

---@param slotId integer?
---@return integer? position
local function positionOf(slotId)
  if slotId == nil or slotId <= StartMenuController.CANCEL_SLOT_ID then
    return nil
  end
  return slotId - StartMenuController.CANCEL_SLOT_ID - 1
end

-- One fixed tick of the cursor animation: the current manifest frame holds
-- for its duration, then the animation moves to the next frame and wraps.
function StartMenuController:_advanceCursor()
  local duration = self._cursorFrames[self._cursorFrameIndex + 1].duration
  self._cursorFrameTicks = self._cursorFrameTicks + 1
  if self._cursorFrameTicks >= duration then
    self._cursorFrameIndex = (self._cursorFrameIndex + 1) % #self._cursorFrames
    self._cursorFrameTicks = 0
  end
end

function StartMenuController:_selectPosition(position)
  assert(self._visibleActions[position] ~= nil, "cannot select an empty display position")
  self._selectedPosition = position
end

---@param position integer
---@return integer row
---@return integer column
local function sourceCoordinates(position)
  local slotId = position + StartMenuController.CANCEL_SLOT_ID + 1
  return math.floor((slotId - 1) / 2), (slotId - 1) % 2
end

---@param row integer
---@param column integer
---@return integer? position
local function sourcePosition(row, column)
  local position = row * 2 + column - 1
  if position < 0 then
    return nil
  end
  return position
end

function StartMenuController:_moveSelection(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  local row, column = sourceCoordinates(self._selectedPosition)
  if direction == "left" or direction == "right" then
    local targetColumn = 1 - column
    local targetPosition = sourcePosition(row, targetColumn)
    if targetPosition ~= nil and self._visibleActions[targetPosition] ~= nil then
      self:_selectPosition(targetPosition)
    end
    return
  end

  local rowCount = math.floor(#self._slots / 2)
  local step = direction == "up" and -1 or 1
  for distance = 1, rowCount - 1 do
    local targetRow = (row + step * distance) % rowCount
    local targetPosition = sourcePosition(targetRow, column)
    if targetPosition ~= nil and self._visibleActions[targetPosition] ~= nil then
      self:_selectPosition(targetPosition)
      return
    end
  end
end

-- Activation of the selected action. Disabled entries (enabled=false) are
-- a no-op; an enabled "application" entry produces a launch result carrying
-- the action id so the application host can restore the selection by id when
-- the child application returns. An enabled entry of any other kind has no
-- implemented routing -- the runtime must never compose enabled=true for one
-- -- so activating it is a programming fault, not a silent close.
function StartMenuController:_activate(position)
  local action = assert(self._visibleActions[position], "activation requires a visible action")
  if not action.enabled then
    return -- disabled entry is a no-op
  end
  if self._effect then
    self._effect("SEQ_SE_DP_SELECT")
  end
  if action.actionKind == "field_action" then
    self._result = { kind = "field_action", actionId = action.id }
    self._closed = true
    return
  end
  if action.actionKind ~= "application" then
    error("enabled start menu action has no implemented routing: " .. tostring(action.id), 2)
  end
  self._result = {
    kind = "launch",
    applicationId = action.targetApplication,
    actionId = action.id,
  }
  self._closed = true
end

function StartMenuController:_close()
  if self._effect then
    self._effect("SEQ_SE_GS_GEARCANCEL")
  end
  self._result = { kind = "close" }
  self._closed = true
end

-- One fixed tick: the cursor animation advances exactly once, then the
-- tick's UI events are consumed. The events are the FieldInput uiSnapshot
-- shapes (navigate/confirm/cancel/pointer_down/pointer_move/pointer_up)
-- with pointer coordinates in canonical logical space, plus the
-- host-synthesized "menu" event: while the menu is active the menu button
-- has the same close semantics as HGSS X, and the application host
-- translates a fresh menu edge into it.
---@param uiInput table[]
function StartMenuController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the start menu input must be an event list")
  if self._closed then
    return
  end
  self:_advanceCursor()
  local slots = self._slots
  for _, event in ipairs(uiInput) do
    -- A terminal event (close or a successful activate) ends this tick's
    -- processing: later events must not overwrite the recorded result.
    if self._closed then
      break
    end
    assert(type(event) == "table" and type(event.type) == "string", "start menu events need a type")
    if event.type == "navigate" then
      self:_moveSelection(event.direction)
    elseif event.type == "confirm" then
      self:_activate(self._selectedPosition)
    elseif event.type == "cancel" or event.type == "menu" then
      self:_close()
    elseif event.type == "pointer_move" then
      if self._pointerId == nil then
        local position = positionOf(slotAt(slots, event.x, event.y))
        if position ~= nil and self._visibleActions[position] ~= nil then
          self:_selectPosition(position)
        end
      end
    elseif event.type == "pointer_down" then
      if self._pointerId == nil then
        assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
        self._pointerId = event.pointerId
        local slotId = slotAt(slots, event.x, event.y)
        local position = positionOf(slotId)
        if slotId == StartMenuController.CANCEL_SLOT_ID then
          self._pointerDown = { kind = "cancel" }
        elseif position ~= nil and self._visibleActions[position] ~= nil then
          self:_selectPosition(position)
          self._pointerDown = { kind = "action", position = position }
        else
          self._pointerDown = { kind = "none" }
        end
      end
    elseif event.type == "pointer_up" then
      if event.pointerId == self._pointerId then
        local down = assert(self._pointerDown, "pointer up requires a capture")
        self._pointerId = nil
        self._pointerDown = nil
        if event.dragged ~= true then
          local upSlotId = slotAt(slots, event.x, event.y)
          local upPosition = positionOf(upSlotId)
          if down.kind == "cancel" and upSlotId == StartMenuController.CANCEL_SLOT_ID then
            self:_close()
          elseif down.kind == "action" and upPosition ~= nil and upPosition == down.position then
            self:_activate(upPosition)
          end
        end
      end
    else
      error("unknown start menu event type " .. tostring(event.type), 2)
    end
  end
end

-- The presentation snapshot: cursor slot/frame for the renderer plus the
-- ordered visible actions, or the closed marker alone. Fresh tables per
-- call; the caller may not mutate controller state through them.
---@return StartMenuController.OpenStatus|StartMenuController.ClosedStatus
function StartMenuController:status()
  if self._closed then
    return { open = false }
  end
  local actions = {}
  for position = 0, #self._slots - 2 do
    local action = self._visibleActions[position]
    if action then
      actions[#actions + 1] = {
        id = action.id,
        targetApplication = action.targetApplication,
        position = action.position,
        slotId = action.slotId,
        enabled = action.enabled,
        sourcePresent = action.sourcePresent,
        sourceEnabled = action.sourceEnabled,
        implemented = action.implemented,
      }
    end
  end
  return {
    open = true,
    actions = actions,
    cancelSlotId = StartMenuController.CANCEL_SLOT_ID,
    cursorSlotId = self._selectedPosition + StartMenuController.CANCEL_SLOT_ID + 1,
    cursorFrameIndex = self._cursorFrameIndex,
  }
end

-- The result contract: nil until a terminal event, then exactly one close,
-- child launch, or immediate field-action result.
---@return { kind: "close"|"launch"|"field_action", applicationId?: string, actionId?: string }?
function StartMenuController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil then
    self._closed = true
  end
  return result
end

-- Idempotent release of the logical lifetime: the host disposes the active
-- controller on success, cancellation, failure, reset, or runtime disposal.
-- A pending result is discarded (a launch never happens after disposal).
function StartMenuController:dispose()
  self._result = nil
  self._closed = true
end

-- The placement-change contract: a press held across a layout change must
-- not activate a different post-layout slot, so the application host cancels
-- an active pointer capture when the menu placement changes.
function StartMenuController:cancelPointerCapture()
  self._pointerId = nil
  self._pointerDown = nil
end

---@class StartMenuController.ClosedStatus
---@field open false

---@class StartMenuController.OpenStatus
---@field open true
---@field actions StartMenuController.Action[]
---@field cancelSlotId integer
---@field cursorSlotId integer
---@field cursorFrameIndex integer

return StartMenuController
