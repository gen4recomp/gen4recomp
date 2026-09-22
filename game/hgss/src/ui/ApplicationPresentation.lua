-- Per-open presentation snapshot and pointer lifetime for one
-- application. The session owns layout publication, classification
-- hysteresis, and one content pointer capture; leaf controllers own
-- selection, actions, and results. Candidates are built and validated
-- before they replace the published plan, so a resolver failure never
-- clears semantic state. Structural geometry/resolver changes invalidate
-- a held press and queue an ordered pointer_cancel; repeated equivalent
-- resolutions preserve capture. Render callbacks borrow their resources
-- and never release them.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")

---@class ApplicationPresentation.Capture
---@field kind string content press
---@field pointerId string
---@field pane table<string, unknown>? the captured content pane

---@class ApplicationPresentation
---@field _interfaces table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan> copied resolver set
---@field _plan ApplicationPlan? the published plan
---@field _configuration string? the last published classification
---@field _capture ApplicationPresentation.Capture? the one held content press
---@field _cancelled table<string, boolean> pointer ids whose remaining up must be dropped
---@field _pendingCancel string? pointer id owed a pointer_cancel before the next mapped batch
---@field _resolver (fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan)? the published plan's resolver
---@field _signature string? measurement signature behind the published plan
---@field _disposed boolean
local ApplicationPresentation = {}
ApplicationPresentation.__index = ApplicationPresentation

---@class ApplicationFrameGeometry
---@field placement LayoutGeometry.Placement
---@field contentBox LayoutGeometry.Rect

---@class ApplicationPlan
---@field panes { id: string, placement: LayoutGeometry.Placement, interactive: boolean }[]
---@field frames ApplicationFrameGeometry[]
---@field chrome { title: string, dismissible: boolean }? window identity drawn on visible frames only
---@field content table<string, unknown> application-owned logical geometry/payload
---@field inputKey string stable input-geometry identity
---@field render fun(resources: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan)
---@field mapInput fun(event: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan): table<string, unknown>?

local CASE_KEYS = { "dualDisplay", "nativeLike", "wide", "tall" }

---@param value unknown
---@return boolean
local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

---@param placement LayoutGeometry.Placement
---@param what string
local function assertCompletePlacement(placement, what)
  LayoutGeometry.validatePlacement(placement, what)
  assert(
    isFiniteNumber(placement.logicalWidth) and placement.logicalWidth > 0,
    what .. " needs finite positive logical dimensions"
  )
  assert(
    isFiniteNumber(placement.logicalHeight) and placement.logicalHeight > 0,
    what .. " needs finite positive logical dimensions"
  )
end

---@param plan ApplicationPlan
local function assertValidPlan(plan)
  assert(type(plan) == "table", "a resolver must return a complete plan")
  assert(type(plan.panes) == "table", "the plan needs its panes")
  local ids = {}
  for index, pane in ipairs(plan.panes) do
    assert(type(pane) == "table", "plan.panes[" .. index .. "] must be a record")
    assert(type(pane.id) == "string" and pane.id ~= "", "a pane needs its semantic id")
    assert(ids[pane.id] == nil, "duplicate pane id " .. pane.id)
    ids[pane.id] = true
    assert(type(pane.interactive) == "boolean", "a pane needs its interaction flag")
    assert(type(pane.placement) == "table", "a pane needs its placement")
    assertCompletePlacement(pane.placement, "pane placement")
  end
  assert(type(plan.frames) == "table", "the plan needs its frames")
  for index, frame in ipairs(plan.frames) do
    assert(type(frame) == "table", "plan.frames[" .. index .. "] must be a record")
    assert(type(frame.placement) == "table", "a frame needs its placement")
    assertCompletePlacement(frame.placement, "frame placement")
    assert(type(frame.contentBox) == "table", "a frame needs its content box")
    LayoutGeometry.rect(frame.contentBox, "frame.contentBox[" .. index .. "]")
  end
  if plan.chrome ~= nil then
    assert(type(plan.chrome) == "table", "plan chrome must be its window identity record")
    assert(type(plan.chrome.title) == "string" and plan.chrome.title ~= "", "plan chrome needs a nonempty window title")
    assert(type(plan.chrome.dismissible) == "boolean", "plan chrome needs its dismiss flag")
  end
  assert(type(plan.content) == "table", "the plan needs its content")
  assert(type(plan.inputKey) == "string", "the plan needs its input key")
  assert(type(plan.render) == "function", "the plan needs its render callback")
  assert(type(plan.mapInput) == "function", "the plan needs its input mapper")
  -- The retired schema leaves no reader: index through an untyped alias so
  -- the absence check itself introduces no legacy field reference.
  local untyped = plan --[[@as table<string, unknown>]]
  assert(untyped.window == nil, "static plans carry no window")
  assert(untyped.backgroundColor == nil, "static plans carry no settled background color")
  assert(untyped.coverage == nil, "the renamed fade coverage leaves no legacy coverage field")
end

---@param interfaces table<string, unknown>
---@return ApplicationPresentation
function ApplicationPresentation.new(interfaces)
  assert(type(interfaces) == "table", "the session requires its interface set")
  local copied = {}
  for _, key in ipairs(CASE_KEYS) do
    assert(type(interfaces[key]) == "function", "the interface set needs its " .. key .. " resolver")
    copied[key] = interfaces[key]
  end
  for key in pairs(interfaces) do
    local known = false
    for _, case in ipairs(CASE_KEYS) do
      if key == case then
        known = true
        break
      end
    end
    assert(known, "unknown interface case " .. tostring(key))
  end
  return setmetatable({
    _interfaces = copied,
    _plan = nil,
    _configuration = nil,
    _capture = nil,
    _cancelled = {},
    _pendingCancel = nil,
    _resolver = nil,
    _signature = nil,
    _disposed = false,
  }, ApplicationPresentation)
end

---@param placement LayoutGeometry.Placement
---@return string structural identity of one placement
local function placementIdentity(placement)
  local frame = placement.frame
  local origin = placement.origin or frame
  local clip = placement.clipRect or frame
  return table.concat({
    tostring(frame.x),
    tostring(frame.y),
    tostring(frame.width),
    tostring(frame.height),
    tostring(origin.x),
    tostring(origin.y),
    tostring(placement.scale),
    tostring(clip.x),
    tostring(clip.y),
    tostring(clip.width),
    tostring(clip.height),
  }, "|")
end

---@param plan ApplicationPlan
---@param resolver fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan
---@return string structural identity; table identity alone is irrelevant
local function planIdentity(plan, resolver)
  local parts = { tostring(resolver), tostring(plan.render), tostring(plan.mapInput), plan.inputKey }
  for _, pane in ipairs(plan.panes) do
    parts[#parts + 1] = pane.id .. ":" .. tostring(pane.interactive) .. ":" .. placementIdentity(pane.placement)
  end
  for index, frame in ipairs(plan.frames) do
    local box = frame.contentBox
    parts[#parts + 1] = "frame"
      .. index
      .. ":"
      .. placementIdentity(frame.placement)
      .. ":"
      .. table.concat({ tostring(box.x), tostring(box.y), tostring(box.width), tostring(box.height) }, ",")
  end
  local chrome = plan.chrome
  if chrome ~= nil then
    parts[#parts + 1] = "chrome:" .. chrome.title .. ":" .. tostring(chrome.dismissible)
  end
  return table.concat(parts, "#")
end

-- Resolves a complete plan against fresh host facts without advancing
-- gameplay: classify with hysteresis, build the context, run the selected
-- case function, validate the candidate before publishing. A geometry or
-- resolver change drops any held content capture and queues pointer_cancel
-- when a content press was held; resolver failure propagates with the
-- previous plan intact. Never copies GPU objects, never renders.
---@param measurement DisplayMeasurement
---@param view table<string, unknown> the current semantic snapshot for content
---@return ApplicationPlan
function ApplicationPresentation:resolve(measurement, view)
  assert(not self._disposed, "a disposed session resolves nothing")
  assert(type(measurement) == "table", "resolution requires fresh host facts")
  assert(type(view) == "table", "resolution requires the current semantic snapshot")
  local configuration = ApplicationLayout.classify(measurement, self._configuration)
  local selection = ApplicationLayout.selectSurfaces(measurement)
  local context = {
    measurement = measurement,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = self._interfaces.nativeLike,
  }
  local resolver =
    assert(self._interfaces[configuration], "the interface set needs its " .. configuration .. " resolver")
  local candidate = resolver(context, view)
  assertValidPlan(candidate)
  local previous = self._plan
  local capture = self._capture
  local identityChanged = previous ~= nil
    and planIdentity(candidate, resolver) ~= planIdentity(previous, self._resolver or resolver)
  local externalReflow = false
  if previous ~= nil then
    local signatureChanged = self._signature ~= nil and measurement.signature ~= self._signature
    local configurationChanged = self._configuration ~= nil and configuration ~= self._configuration
    local resolverChanged = self._resolver ~= nil and resolver ~= self._resolver
    externalReflow = signatureChanged or configurationChanged or resolverChanged
  end
  -- Any structural change drops the held content gesture. Equivalent
  -- resolves preserve content capture.
  if identityChanged or externalReflow then
    self._capture = nil
    if capture ~= nil and capture.kind == "content" then
      self._pendingCancel = capture.pointerId
    end
    self._cancelled = {}
  end
  self._plan = candidate
  self._configuration = configuration
  self._resolver = resolver
  self._signature = measurement.signature
  return candidate
end

---@return ApplicationPlan the published plan
function ApplicationPresentation:plan()
  return assert(self._plan, "the session publishes no plan before its first resolution")
end

---@param event table<string, unknown>
---@return table<string, unknown> a copy; the input batch is never mutated
local function copyEvent(event)
  local copy = {}
  for key, value in pairs(event) do
    copy[key] = value
  end
  return copy
end

-- Maps one ordered batch through the published plan: the topmost
-- interactive pane inverts once, the leaf mapper turns logical input into
-- app events, and capture/cancellation keep stale releases from
-- activating. pointer_cancel
-- bypasses the leaf mapper so an override cannot erase the contract.
---@param events table<string, unknown>[]
---@param view table<string, unknown>
---@return table<string, unknown>[]
function ApplicationPresentation:mapInput(events, view)
  assert(not self._disposed, "a disposed session maps nothing")
  local plan = self:plan()
  assert(type(events) == "table", "input mapping requires the event batch")
  local out = {}
  if self._pendingCancel ~= nil then
    out[#out + 1] = { type = "pointer_cancel", pointerId = self._pendingCancel }
    self._cancelled[self._pendingCancel] = true
    self._pendingCancel = nil
  end
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "input events need a type")
    local eventType = event.type
    if eventType == "pointer_cancel" then
      out[#out + 1] = copyEvent(event)
    elseif eventType == "pointer_down" and type(event.x) == "number" and type(event.y) == "number" then
      self:_mapDown(plan, view, event, out)
    elseif eventType == "pointer_down" then
      self:_mapOutsideDown(plan, view, event, out)
    elseif eventType == "pointer_move" and type(event.x) == "number" and type(event.y) == "number" then
      self:_mapMove(plan, view, event, out)
    elseif eventType == "pointer_up" and type(event.x) == "number" and type(event.y) == "number" then
      self:_mapUp(plan, view, event, out)
    elseif eventType == "pointer_up" then
      self:_dropUp(event)
    elseif eventType == "pointer_scroll" then
      local mapped = plan.mapInput(copyEvent(event), view, plan)
      if mapped ~= nil then
        out[#out + 1] = mapped
      end
    else
      out[#out + 1] = copyEvent(event)
    end
  end
  return out
end

---@param plan ApplicationPlan
---@param hostX number
---@param hostY number
---@return table<string, unknown>? pane the topmost interactive hit
---@return number? logicalX
---@return number? logicalY
local function hitPane(plan, hostX, hostY)
  for index = #plan.panes, 1, -1 do
    local pane = plan.panes[index]
    if pane.interactive then
      local x, y = LayoutGeometry.hostToLogical(pane.placement, hostX, hostY)
      if x ~= nil then
        return pane, x, y
      end
    end
  end
  return nil
end

---@param plan ApplicationPlan
---@param hostX number
---@param hostY number
---@return boolean true when the host point lands on a visible frame or pane
local function hitApplicationRegion(plan, hostX, hostY)
  for _, frame in ipairs(plan.frames) do
    if LayoutGeometry.hostToLogical(frame.placement, hostX, hostY) ~= nil then
      return true
    end
  end
  for _, pane in ipairs(plan.panes) do
    if LayoutGeometry.hostToLogical(pane.placement, hostX, hostY) ~= nil then
      return true
    end
  end
  return false
end

-- A press on a dismissible window's dismiss control maps the leaf's
-- terminal dismiss edge without acquiring content capture. Every other
-- border press stays inert interior; transparent chrome pixels never make
-- holes in frame ownership.
---@param plan ApplicationPlan
---@param hostX number
---@param hostY number
---@return boolean true when the host point lands on a dismissible dismiss control
local function hitDismissControl(plan, hostX, hostY)
  local chrome = plan.chrome
  if chrome == nil or chrome.dismissible ~= true or #plan.frames == 0 then
    return false
  end
  for _, frame in ipairs(plan.frames) do
    local contentBox = frame.contentBox
    if contentBox ~= nil then
      local logicalX, logicalY = LayoutGeometry.hostToLogical(frame.placement, hostX, hostY)
      if logicalX ~= nil and logicalY ~= nil then
        local dismiss = FieldDialogueTheme.applicationChromeGeometry(contentBox).dismiss
        if
          logicalX >= dismiss.x
          and logicalX <= dismiss.x + dismiss.width
          and logicalY >= dismiss.y
          and logicalY <= dismiss.y + dismiss.height
        then
          return true
        end
      end
    end
  end
  return false
end

---@param plan ApplicationPlan
---@param view table<string, unknown>
---@param event table<string, unknown>
---@param out table<string, unknown>[]
function ApplicationPresentation:_mapDown(plan, view, event, out)
  local pointerId = event.pointerId
  if self._capture ~= nil then
    return
  end
  if self._cancelled[pointerId] ~= nil then
    self._cancelled[pointerId] = nil
  end
  local pane, hitX, hitY = hitPane(plan, event.x, event.y)
  if pane == nil then
    if hitDismissControl(plan, event.x, event.y) then
      local mapped = plan.mapInput({ type = "dismiss", pointerId = pointerId }, view, plan)
      if mapped ~= nil then
        out[#out + 1] = mapped
      end
      return
    end
    -- Decorative frame borders and noninteractive panes are visible
    -- application interior: the press is consumed with no leaf event and
    -- no capture. Only a press outside every frame and pane reaches the
    -- leaf as outside.
    if hitApplicationRegion(plan, event.x, event.y) then
      return
    end
    local mapped = plan.mapInput({ type = "pointer_down", pointerId = pointerId, outside = true }, view, plan)
    if mapped ~= nil then
      out[#out + 1] = mapped
    end
    return
  end
  self._capture = { kind = "content", pointerId = pointerId, pane = pane }
  local logical = copyEvent(event)
  logical.x = hitX
  logical.y = hitY
  local mapped = plan.mapInput(logical, view, plan)
  if mapped ~= nil then
    out[#out + 1] = mapped
  end
end

---@param plan ApplicationPlan
---@param view table<string, unknown>
---@param event table<string, unknown>
---@param out table<string, unknown>[]
function ApplicationPresentation:_mapOutsideDown(plan, view, event, out)
  if self._capture ~= nil then
    return
  end
  local mapped = plan.mapInput({ type = "pointer_down", pointerId = event.pointerId, outside = true }, view, plan)
  if mapped ~= nil then
    out[#out + 1] = mapped
  end
end

---@param plan ApplicationPlan
---@param view table<string, unknown>
---@param event table<string, unknown>
---@param out table<string, unknown>[]
function ApplicationPresentation:_mapMove(plan, view, event, out)
  local capture = self._capture
  local pointerId = event.pointerId
  if capture ~= nil and capture.pointerId == pointerId then
    local pane = assert(capture.pane, "a content capture holds its pane")
    local x, y = LayoutGeometry.hostToLogical(pane.placement, event.x, event.y)
    if x == nil then
      out[#out + 1] = { type = "pointer_cancel", pointerId = pointerId }
      self._capture = nil
      self._cancelled[pointerId] = true
      return
    end
    local logical = copyEvent(event)
    logical.x = x
    logical.y = y
    local mapped = plan.mapInput(logical, view, plan)
    if mapped ~= nil then
      out[#out + 1] = mapped
    end
    return
  end
  if self._cancelled[pointerId] ~= nil then
    return
  end
  if capture ~= nil then
    return
  end
  local pane, hitX, hitY = hitPane(plan, event.x, event.y)
  if pane == nil then
    return
  end
  local logical = copyEvent(event)
  logical.x = hitX
  logical.y = hitY
  local mapped = plan.mapInput(logical, view, plan)
  if mapped ~= nil then
    out[#out + 1] = mapped
  end
end

---@param plan ApplicationPlan
---@param view table<string, unknown>
---@param event table<string, unknown>
---@param out table<string, unknown>[]
function ApplicationPresentation:_mapUp(plan, view, event, out)
  local capture = self._capture
  local pointerId = event.pointerId
  if capture ~= nil and capture.pointerId == pointerId then
    self._capture = nil
    local pane = assert(capture.pane, "a content capture holds its pane")
    local x, y = LayoutGeometry.hostToLogical(pane.placement, event.x, event.y)
    if x == nil then
      out[#out + 1] = { type = "pointer_cancel", pointerId = pointerId }
      self._cancelled[pointerId] = true
      return
    end
    local logical = copyEvent(event)
    logical.x = x
    logical.y = y
    local mapped = plan.mapInput(logical, view, plan)
    if mapped ~= nil then
      out[#out + 1] = mapped
    end
    return
  end
  self:_dropUp(event)
end

---@param event table<string, unknown>
function ApplicationPresentation:_dropUp(event)
  if self._cancelled[event.pointerId] ~= nil then
    self._cancelled[event.pointerId] = nil
  end
end

-- Invalidates any held press before a later release can activate
-- something: focus loss drops capture and queues cancellation for a held
-- content press. Physical input clearing stays with FieldInput.
function ApplicationPresentation:cancelPointers()
  local capture = self._capture
  self._capture = nil
  if capture ~= nil and capture.kind == "content" then
    self._pendingCancel = capture.pointerId
  end
end

-- Discards captures and the published plan exactly once.
function ApplicationPresentation:dispose()
  self._capture = nil
  self._cancelled = {}
  self._pendingCancel = nil
  self._plan = nil
  self._configuration = nil
  self._resolver = nil
  self._signature = nil
  self._disposed = true
end

-- Draws the published plan with borrowed graphics by invoking only the
-- leaf render callback. Fade coverage is transition metadata and never
-- paints here; settled pixels outside panes remain whatever the host
-- already rendered. Callback failures propagate with graphics state
-- restored.
---@param graphics love.graphics
---@param resources table<string, unknown> borrowed application resource record
---@param view table<string, unknown>
---@param plan ApplicationPlan
function ApplicationPresentation.draw(graphics, resources, view, plan)
  assert(type(graphics) == "table", "presentation drawing requires its graphics namespace")
  assert(type(resources) == "table", "presentation drawing requires its borrowed resources")
  assertValidPlan(plan)
  graphics.push("all")
  local ok, err = pcall(function()
    plan.render(resources, view, plan)
  end)
  graphics.pop()
  if not ok then
    error(err, 0)
  end
end

return ApplicationPresentation
