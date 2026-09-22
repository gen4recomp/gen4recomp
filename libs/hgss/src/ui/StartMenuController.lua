-- The pure Start Menu controller: the final interactive action display,
-- selection, confirm/cancel, and touch/pointer interaction of the HGSS Start
-- Menu over the generated normal-position contract. It consumes the
-- runtime-composed final action list (the intersection of the source policy
-- with the registered destination applications; entries carry explicit
-- display positions 0..6) and the generated manifest interactive record (the
-- cancel/header hit rectangle plus the source anchor, label window, touch
-- hit rectangle, and ordered directional candidate lists per normal
-- position). The final list is never empty -- the menu factory returns nil
-- when no action is interactive -- so the controller's constructor guards
-- the real invariants (a non-empty list, display positions inside the normal
-- seven-position selector), and the selection always resolves. Directional
-- movement scans the generated ordered candidate lists and selects the
-- first currently visible candidate; pointer input resolves against the
-- generated hit rectangles. The controller is silent -- the branch does not
-- reproduce the source Start Menu effects (SEQ_SE_DP_WIN_OPEN/
-- SELECT and SEQ_SE_GS_GEARCANCEL); it never touches love and never names a
-- ROM sequence or member number. Pointer events carry canonical logical
-- coordinates (0..255 x 0..191); the layout host maps host coordinates
-- before feeding the controller, and the host drops unsupported pointer
-- scroll events. No application launches happen here: the controller records
-- the takeResult contract ({ kind = "close" } / { kind = "launch",
-- applicationId }) and the application host launches.

local FocusGraph = require("libs.ui.src.FocusGraph")

---@class StartMenuController
---@field _visibleActions table<integer, StartMenuController.Action> visible actions keyed by display position
---@field _selectedPosition integer the selected display position
---@field _result table<string, unknown>?
---@field _closed boolean
---@field _positions table<integer, StartMenuController.Position> the generated normal-position records keyed 0..6
---@field _cancelHitRect FieldDialogueTheme.Rect the generated cancel/header hit rectangle
---@field _pointerId string?
---@field _pointerDown { kind: "cancel"|"action"|"none", position: integer? }?
---@field _effect fun(sequence: string)? source UI sound effect boundary
local StartMenuController = {}
StartMenuController.__index = StartMenuController

-- The final interactive action list and the generated interactive record are
-- already validated by their producers, so the controller only guards its
-- own invariants: a non-empty list (the factory returns nil for a blank
-- menu) and display positions inside the normal seven-position selector.
---@param entries StartMenuController.Entry[]
---@param interactive StartMenuController.Interactive
---@return table<integer, StartMenuController.Action>, StartMenuController.Action[]
local function composeDisplay(entries, interactive)
  local positions = assert(interactive.positions, "the start menu requires the generated position records")
  local display = {}
  for _, entry in ipairs(entries) do
    local position = entry.displayPosition
    assert(
      type(position) == "number" and position % 1 == 0 and position >= 0 and position <= 6,
      "a start menu entry needs a display position inside the normal seven-position selector"
    )
    assert(positions[position] ~= nil, "start menu display position " .. tostring(position) .. " has no record")
    display[position] = {
      id = entry.id,
      targetApplication = entry.targetApplication,
      actionKind = entry.actionKind,
      position = position,
      enabled = entry.enabled ~= false, -- default to enabled if not specified
      sourcePresent = entry.sourcePresent,
      sourceEnabled = entry.sourceEnabled,
      implemented = entry.implemented,
      icon = entry.icon,
      label = entry.label,
    }
  end
  local ordered = {}
  for _, entry in ipairs(entries) do
    local action = assert(display[entry.displayPosition], "composed display must carry every entry position")
    ordered[#ordered + 1] = action
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
---@field enabled boolean whether the action can be activated (source-enabled and implementation-available)
---@field sourcePresent boolean source action was present in the source menu
---@field sourceEnabled boolean source policy enabled the action
---@field implemented boolean runtime has an implementation for the action
---@field icon integer? retail icon index for the renderer (present on icon-backed visual entries)
---@field label string? caller-resolved label for the renderer (nil until the caller resolves it)

---@class StartMenuController.Entry
---@field id string
---@field targetApplication string
---@field actionKind string?
---@field displayPosition integer
---@field enabled boolean?
---@field sourcePresent boolean?
---@field sourceEnabled boolean?
---@field implemented boolean?
---@field icon integer?
---@field label string?

---@class StartMenuController.Position
---@field anchor { x: integer, y: integer }
---@field labelWindow FieldDialogueTheme.Rect
---@field hitRect FieldDialogueTheme.Rect
---@field navigation { up: integer[], down: integer[], left: integer[], right: integer[] }

---@class StartMenuController.Interactive
---@field cancelHitRect FieldDialogueTheme.Rect
---@field positions table<integer, StartMenuController.Position>

-- opts.entries: the runtime-composed final interactive action list
-- (id / targetApplication / displayPosition), never empty.
-- opts.interactive: the generated manifest startMenu.interactive record
-- (cancelHitRect plus positions 0..6). opts.rememberedActionId: the
-- selection remembered across a child-application round trip.
---@param opts { entries: StartMenuController.Entry[], interactive: StartMenuController.Interactive, rememberedActionId?: string?, effect?: fun(sequence: string) }
---@return StartMenuController
function StartMenuController.new(opts)
  assert(type(opts) == "table", "the start menu controller requires options")
  assert(type(opts.entries) == "table" and #opts.entries >= 1, "a blank start menu is never constructed")
  assert(type(opts.interactive) == "table", "the start menu requires the generated interactive record")
  assert(type(opts.interactive.positions) == "table", "the start menu requires the generated normal-position records")
  assert(type(opts.interactive.cancelHitRect) == "table", "the start menu requires the generated cancel hit rectangle")
  local display, ordered = composeDisplay(opts.entries, opts.interactive)
  local self = setmetatable({
    _visibleActions = display,
    _selectedPosition = initialPosition(ordered, opts.rememberedActionId),
    _result = nil,
    _closed = false,
    _positions = opts.interactive.positions,
    _cancelHitRect = opts.interactive.cancelHitRect,
    _pointerId = nil,
    _pointerDown = nil,
    _effect = opts.effect,
  }, StartMenuController)
  return self
end

---@param rect FieldDialogueTheme.Rect
---@param x number
---@param y number
---@return boolean
local function contains(rect, x, y)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

-- The visible action position under a canonical logical point, or nil
-- outside every generated hit rectangle. Positions without a visible action
-- never resolve: hovering or pressing them changes nothing.
---@param positions table<integer, StartMenuController.Position>
---@param visibleActions table<integer, StartMenuController.Action>
---@param x number
---@param y number
---@return integer? position
local function positionAt(positions, visibleActions, x, y)
  for position = 0, 6 do
    local record = positions[position]
    if record ~= nil and visibleActions[position] ~= nil and contains(record.hitRect, x, y) then
      return position
    end
  end
  return nil
end

function StartMenuController:_selectPosition(position)
  assert(self._visibleActions[position] ~= nil, "cannot select an empty display position")
  self._selectedPosition = position
end

function StartMenuController:_moveSelection(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  local graph = {}
  for position in pairs(self._visibleActions) do
    local record =
      assert(self._positions[position], "start menu display position " .. tostring(position) .. " has no record")
    graph[position] = {
      up = assert(record.navigation.up, "start menu position navigation needs an up list"),
      down = assert(record.navigation.down, "start menu position navigation needs a down list"),
      left = assert(record.navigation.left, "start menu position navigation needs a left list"),
      right = assert(record.navigation.right, "start menu position navigation needs a right list"),
    }
  end
  local resolved = FocusGraph.move(graph, self._selectedPosition, direction)
  assert(type(resolved) == "number" and resolved % 1 == 0, "start menu focus resolves to a source position")
  ---@cast resolved integer
  self._selectedPosition = resolved
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
  -- A launch is not terminal to this snapshot: the field host retains
  -- the menu as its drawable background while the child owns input, so
  -- the menu stays open and presentable until the host disposes it.
  self._closed = false
end

function StartMenuController:_close()
  if self._effect then
    self._effect("SEQ_SE_GS_GEARCANCEL")
  end
  self._result = { kind = "close" }
  self._closed = true
end

-- One fixed tick: the tick's UI events are consumed. The events are the
-- FieldInput uiSnapshot shapes (navigate/confirm/cancel/pointer_down/
-- pointer_move/pointer_up) with pointer coordinates in canonical logical
-- space, plus the host-synthesized "menu" event: while the menu is active
-- the menu button has the same close semantics as HGSS X, and the
-- application host translates a fresh menu edge into it. A pointer_cancel
-- event absorbs at its exact batch position by releasing the held press
-- without moving selection or recording a result: geometry changes, focus
-- loss, and close invalidate captures through the presentation session,
-- and the controller must never activate something stale afterwards.
---@param uiInput table[]
function StartMenuController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the start menu input must be an event list")
  if self._closed then
    return
  end
  local positions = self._positions
  local cancelHitRect = self._cancelHitRect
  for _, event in ipairs(uiInput) do
    -- A terminal event (close, field action, or a successful activate)
    -- ends this tick's processing: later events must not overwrite the
    -- recorded result. A launch stays open for the retained background
    -- but still ends the batch, so a confirm before a cancel in one tick
    -- keeps the launch.
    if self._closed or self._result ~= nil then
      break
    end
    assert(type(event) == "table" and type(event.type) == "string", "start menu events need a type")
    if event.type == "navigate" then
      self:_moveSelection(event.direction)
    elseif event.type == "confirm" then
      self:_activate(self._selectedPosition)
    elseif event.type == "cancel" or event.type == "menu" then
      self:_close()
    elseif event.type == "dismiss" then
      self:_close()
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    elseif event.type == "pointer_move" then
      if self._pointerId == nil then
        local position = positionAt(positions, self._visibleActions, event.x, event.y)
        if position ~= nil then
          self:_selectPosition(position)
        end
      end
    elseif event.type == "pointer_down" then
      if self._pointerId == nil then
        assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
        self._pointerId = event.pointerId
        local position = positionAt(positions, self._visibleActions, event.x, event.y)
        if contains(cancelHitRect, event.x, event.y) then
          self._pointerDown = { kind = "cancel" }
        elseif position ~= nil then
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
          local upPosition = positionAt(positions, self._visibleActions, event.x, event.y)
          if down.kind == "cancel" and contains(cancelHitRect, event.x, event.y) then
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

-- The presentation snapshot: the selected source position plus the ordered
-- visible actions, or the closed marker alone. Fresh tables per call; the
-- caller may not mutate controller state through them.
---@return StartMenuController.OpenStatus|StartMenuController.ClosedStatus
function StartMenuController:status()
  if self._closed then
    return { open = false }
  end
  local actions = {}
  for position = 0, 6 do
    local action = self._visibleActions[position]
    if action then
      actions[#actions + 1] = {
        id = action.id,
        targetApplication = action.targetApplication,
        position = action.position,
        enabled = action.enabled,
        sourcePresent = action.sourcePresent,
        sourceEnabled = action.sourceEnabled,
        implemented = action.implemented,
        icon = action.icon,
        label = action.label,
      }
    end
  end
  return {
    open = true,
    actions = actions,
    selectedPosition = self._selectedPosition,
  }
end

-- The result contract: nil until a terminal event, then exactly one close,
-- child launch, or immediate field-action result.
---@return { kind: "close"|"launch"|"field_action", applicationId?: string, actionId?: string }?
function StartMenuController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil and result.kind ~= "launch" then
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
-- not activate a different post-layout position, so the application host
-- cancels an active pointer capture when the menu placement changes.
function StartMenuController:cancelPointerCapture()
  self._pointerId = nil
  self._pointerDown = nil
end

---@class StartMenuController.ClosedStatus
---@field open false

---@class StartMenuController.OpenStatus
---@field open true
---@field actions StartMenuController.Action[]
---@field selectedPosition integer

return StartMenuController
