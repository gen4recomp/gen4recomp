-- Per-open presentation snapshot and pointer/window lifetime for one
-- application. The session owns layout publication, classification
-- hysteresis, one pointer capture, and the remembered drag position; leaf
-- controllers own selection, actions, and results. Candidates are built and
-- validated before they replace the published plan, so a resolver failure
-- never clears semantic state. Structural geometry/resolver changes
-- invalidate a held press and queue an ordered pointer_cancel; repeated
-- equivalent resolutions preserve capture. Render callbacks borrow their
-- resources and never release them.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")

---@class ApplicationPresentation.Capture
---@field kind string content press or header drag
---@field pointerId string
---@field pane table<string, unknown>? the captured content pane
---@field x number? last header drag host x
---@field y number? last header drag host y

---@class ApplicationPresentation
---@field _interfaces table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan> copied resolver set
---@field _windowState table<string, { x: number, y: number }> borrowed caller-owned normalized window memory
---@field _plan ApplicationPlan? the published plan
---@field _configuration string? the last published classification
---@field _capture ApplicationPresentation.Capture? the one held press or header drag
---@field _cancelled table<string, boolean> pointer ids whose remaining up must be dropped
---@field _pendingCancel string? pointer id owed a pointer_cancel before the next mapped batch
---@field _resolver (fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan)? the published plan's resolver
---@field _signature string? measurement signature behind the published plan
---@field _dragMoved boolean the active header capture moved its window since publication
---@field _windowUsable LayoutGeometry.Rect? usable region behind the current windowed geometry
---@field _disposed boolean
local ApplicationPresentation = {}
ApplicationPresentation.__index = ApplicationPresentation

---@class ApplicationPlan
---@field panes { id: string, placement: LayoutGeometry.Placement, interactive: boolean }[]
---@field content table<string, unknown> application-owned logical geometry/payload
---@field inputKey string stable input-geometry identity
---@field render fun(resources: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan)
---@field mapInput fun(event: table<string, unknown>, view: table<string, unknown>, plan: ApplicationPlan): table<string, unknown>?
---@field coverage LayoutGeometry.Rect[] owned host regions, empty for windows
---@field backgroundColor { r: number, g: number, b: number, a: number } explicit matte color
---@field window { outer: LayoutGeometry.Placement, body: LayoutGeometry.Placement, grabRect: LayoutGeometry.Rect }?

-- Private product chrome constants: opaque fills inside the window's own
-- outer placement, never a theme API.
local CHROME_FILL = { 0.08, 0.09, 0.12, 1 }
local CHROME_BORDER = { 0.45, 0.50, 0.55, 1 }
local CHROME_GRIP = { 0.80, 0.84, 0.88, 1 }

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
  assert(type(plan.content) == "table", "the plan needs its content")
  assert(type(plan.inputKey) == "string", "the plan needs its input key")
  assert(type(plan.render) == "function", "the plan needs its render callback")
  assert(type(plan.mapInput) == "function", "the plan needs its input mapper")
  assert(type(plan.coverage) == "table", "the plan needs its coverage")
  for index, rect in ipairs(plan.coverage) do
    LayoutGeometry.rect(rect, "plan.coverage[" .. index .. "]")
  end
  local background = assert(plan.backgroundColor, "the plan needs its background color")
  assert(type(background) == "table", "the plan background color must be a record")
  for _, key in ipairs({ "r", "g", "b", "a" }) do
    assert(type(background[key]) == "number", "the plan background color needs channel " .. key)
  end
  if plan.window ~= nil then
    assert(type(plan.window) == "table", "the plan window must be a record")
    assert(type(plan.window.outer) == "table", "the window needs its outer placement")
    assert(type(plan.window.body) == "table", "the window needs its body placement")
    assertCompletePlacement(plan.window.outer, "window outer placement")
    assertCompletePlacement(plan.window.body, "window body placement")
    LayoutGeometry.rect(plan.window.grabRect, "window.grabRect")
  end
end

---@param position unknown
---@return { x: number, y: number } normalized memory clamped to [0,1]
local function normalizeMemory(position)
  if type(position) ~= "table" then
    return { x = 0.5, y = 0.5 }
  end
  local function clamp(value)
    if type(value) ~= "number" or value ~= value then
      return 0.5
    end
    return math.max(0, math.min(1, value))
  end
  return { x = clamp(position.x), y = clamp(position.y) }
end

---@param interfaces table<string, unknown>
---@param windowState table<string, unknown>?
---@return ApplicationPresentation
function ApplicationPresentation.new(interfaces, windowState)
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
  assert(type(windowState) == "table", "the session borrows its caller-owned window memory")
  windowState.wide = normalizeMemory(windowState.wide)
  windowState.tall = normalizeMemory(windowState.tall)
  return setmetatable({
    _interfaces = copied,
    _windowState = windowState,
    _plan = nil,
    _configuration = nil,
    _capture = nil,
    _cancelled = {},
    _pendingCancel = nil,
    _resolver = nil,
    _signature = nil,
    _dragMoved = false,
    _windowUsable = nil,
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
  if plan.window ~= nil then
    parts[#parts + 1] = "window:" .. placementIdentity(plan.window.outer)
    parts[#parts + 1] = placementIdentity(plan.window.body)
    local grab = plan.window.grabRect
    parts[#parts + 1] =
      table.concat({ tostring(grab.x), tostring(grab.y), tostring(grab.width), tostring(grab.height) }, ",")
  else
    parts[#parts + 1] = "fullscreen"
  end
  return table.concat(parts, "#")
end

---@param windowState table<string, { x: number, y: number }>
---@param configuration string
---@return { x: number, y: number } copied normalized position
local function copyWindowPosition(windowState, configuration)
  local entry = configuration == "tall" and windowState.tall or windowState.wide
  return { x = entry.x, y = entry.y }
end

-- Resolves a complete plan against fresh host facts without advancing
-- gameplay: classify with hysteresis, build the context, run the selected
-- case function, validate the candidate before publishing. A geometry or
-- resolver change drops any held capture and queues pointer_cancel when a
-- content press was held, except the session's own header-drag translation
-- under unchanged display facts; resolver failure propagates with the
-- previous plan and remembered position intact. Never copies GPU objects,
-- never renders.
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
    windowPosition = copyWindowPosition(self._windowState, configuration),
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
  -- A header drag survives only its own translated re-resolution: the
  -- session moved its window while the display facts, configuration, and
  -- resolver stayed put and the candidate still carries a window. Every
  -- other structural change drops the held gesture as before.
  local keepHeader = capture ~= nil
    and capture.kind == "header"
    and self._dragMoved == true
    and not externalReflow
    and candidate.window ~= nil
  if (identityChanged or externalReflow) and not keepHeader then
    self._capture = nil
    if capture ~= nil and capture.kind == "content" then
      self._pendingCancel = capture.pointerId
    end
    self._cancelled = {}
  end
  self._dragMoved = false
  self._plan = candidate
  self._configuration = configuration
  self._resolver = resolver
  self._signature = measurement.signature
  if candidate.window ~= nil then
    local usable = selection.primary.usableBounds
    self._windowUsable = usable and { x = usable.x, y = usable.y, width = usable.width, height = usable.height } or nil
  else
    self._windowUsable = nil
  end
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
-- activating. Header drags update only window memory. pointer_cancel
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
  if plan.window ~= nil and LayoutGeometry.containsPoint(plan.window.grabRect, event.x, event.y) then
    self._capture = { kind = "header", pointerId = pointerId, x = event.x, y = event.y }
    return
  end
  local pane, hitX, hitY = hitPane(plan, event.x, event.y)
  if pane == nil then
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
    if capture.kind == "header" then
      self:_dragHeader(event)
      return
    end
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
    if capture.kind == "header" then
      return
    end
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

---@param event table<string, unknown> header move in host coordinates
function ApplicationPresentation:_dragHeader(event)
  local capture = assert(self._capture, "a header drag holds its capture")
  local plan = self:plan()
  local window = assert(plan.window, "a header drag needs its window")
  local entry = self._configuration == "tall" and self._windowState.tall or self._windowState.wide
  local usable = self._windowUsable
  if usable == nil then
    capture.x = event.x
    capture.y = event.y
    return
  end
  local frame = window.outer.frame
  local travelX = usable.width - frame.width
  local travelY = usable.height - frame.height
  local beforeX, beforeY = entry.x, entry.y
  if travelX > 0 then
    entry.x = math.max(0, math.min(1, entry.x + (event.x - (capture.x or event.x)) / travelX))
  end
  if travelY > 0 then
    entry.y = math.max(0, math.min(1, entry.y + (event.y - (capture.y or event.y)) / travelY))
  end
  if entry.x ~= beforeX or entry.y ~= beforeY then
    self._dragMoved = true
  end
  capture.x = event.x
  capture.y = event.y
end

-- Invalidates any held press before a later release can activate
-- something: focus loss drops capture and queues cancellation for a held
-- content press. Physical input clearing stays with FieldInput.
function ApplicationPresentation:cancelPointers()
  local capture = self._capture
  self._capture = nil
  self._dragMoved = false
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
  self._dragMoved = false
  self._windowUsable = nil
  self._disposed = true
end

-- Draws the published plan with borrowed graphics: coverage matte first,
-- then the window chrome inside its own outer placement, then the chosen
-- render callback. Windows never clear the whole drawable. Callback
-- failures propagate with graphics state restored.
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
    local background = plan.backgroundColor
    graphics.setColor(background.r, background.g, background.b, background.a)
    for _, rect in ipairs(plan.coverage) do
      graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
    end
    if plan.window ~= nil then
      ApplicationPresentation._drawChrome(graphics, plan.window)
    end
    plan.render(resources, view, plan)
  end)
  graphics.pop()
  if not ok then
    error(err, 0)
  end
end

---@param graphics love.graphics
---@param window { outer: LayoutGeometry.Placement, body: LayoutGeometry.Placement, grabRect: LayoutGeometry.Rect }
function ApplicationPresentation._drawChrome(graphics, window)
  local LogicalSurface = require("libs.ui.src.LogicalSurface")
  LogicalSurface.draw(graphics, window.outer, function()
    local outer = window.outer
    local width = outer.logicalWidth
    local height = outer.logicalHeight
    graphics.setColor(CHROME_FILL[1], CHROME_FILL[2], CHROME_FILL[3], CHROME_FILL[4])
    graphics.rectangle("fill", 0, 0, width, height)
    graphics.setColor(CHROME_BORDER[1], CHROME_BORDER[2], CHROME_BORDER[3], CHROME_BORDER[4])
    graphics.rectangle("fill", 0, 0, width, 1)
    graphics.rectangle("fill", 0, height - 1, width, 1)
    graphics.rectangle("fill", 0, 0, 1, height)
    graphics.rectangle("fill", width - 1, 0, 1, height)
    graphics.setColor(CHROME_GRIP[1], CHROME_GRIP[2], CHROME_GRIP[3], CHROME_GRIP[4])
    graphics.rectangle("fill", 1 + (width - 2 - 16) / 2, 1 + (12 - 2) / 2, 16, 2)
  end)
end

return ApplicationPresentation
