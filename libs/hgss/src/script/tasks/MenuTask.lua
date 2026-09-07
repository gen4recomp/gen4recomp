-- Menu task implementation : owns the serializable logical lifetime of one
-- script menu. Presentation hosts receive snapshots only; physical geometry
-- and render resources never enter the saved task state.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldMenuController = require("libs.hgss.src.ui.FieldMenuController")

local MenuTask = {}
local pointerCaptures = setmetatable({}, { __mode = "k" })

MenuTask.type = "menu"
MenuTask.version = 1

local function menuController(state)
  local definition = state.menuDefinition
  local controller = FieldMenuController.new({
    items = definition.items,
    initialCursor = state.selectedIndex,
    cancellable = definition.cancellable,
    cancelValue = definition.cancelValue,
  })
  local pressedPointerItem = pointerCaptures[state]
  if pressedPointerItem ~= nil then
    controller:press(pressedPointerItem)
  end
  return controller
end

local function copyStatus(state, controller)
  local status = controller:status()
  state.selectedIndex = status.selectedIndex
  if status.state == "complete" then
    pointerCaptures[state] = nil
  end
  return status
end

local function menuHost(ctx)
  local host = ctx.services.menu
  assert(
    type(host) == "table" and type(host.sync) == "function" and type(host.close) == "function",
    "menu task requires a menu host"
  )
  return host
end

local function close(state, ctx)
  if state.closed then
    return
  end
  menuHost(ctx):close(ctx.tick)
  state.closed = true
end

---@param spec table<string, unknown> { menu: FieldMenuController.Spec }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function MenuTask.create(spec, ctx)
  assert(type(spec) == "table" and type(spec.menu) == "table", "menu task requires a menu definition")
  local controller = FieldMenuController.new(spec.menu)
  local status = controller:status()
  menuHost(ctx)
  return {
    menuDefinition = spec.menu,
    selectedIndex = status.selectedIndex,
    closed = false,
  }
end

local function applyEvent(controller, state, event)
  assert(type(event) == "table" and type(event.type) == "string", "menu input event is invalid")
  if event.type == "focus" then
    controller:focus(event.itemIndex)
  elseif event.type == "confirm" then
    controller:confirm()
  elseif event.type == "cancel" then
    controller:cancel()
  elseif event.type == "pointer_move" then
    controller:hover(event.itemIndex)
  elseif event.type == "pointer_down" then
    controller:press(event.itemIndex)
    pointerCaptures[state] = event.itemIndex
  elseif event.type == "pointer_up" then
    controller:release(event.dragged and nil or event.itemIndex)
    pointerCaptures[state] = nil
  else
    assert(false, "unknown menu input event " .. event.type)
  end
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function MenuTask.poll(state, ctx)
  local controller = menuController(state)
  local input = ctx.input or {}
  local events = input.menuEvents or {}
  assert(type(events) == "table", "menu input events must be a table")
  for _, event in ipairs(events) do
    applyEvent(controller, state, event)
    if not controller:isActive() then
      break
    end
  end
  local status = copyStatus(state, controller)
  menuHost(ctx):sync(state, ctx.tick)
  if status.state ~= "complete" then
    return { complete = false, state = state }
  end
  close(state, ctx)
  return { complete = true, state = state, result = status.result }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function MenuTask.cancel(state, reason, ctx)
  state.cancelled = reason
  pointerCaptures[state] = nil
  if ctx ~= nil then
    close(state, ctx)
  end
end

---@param state unknown
---@return Errors.Error|nil
function MenuTask.validate(state)
  -- Restore validates the serialized state before reattaching it. Pointer
  -- capture is runtime-only, so that boundary always cancels a held gesture.
  pointerCaptures[state] = nil
  if type(state) ~= "table" or type(state.menuDefinition) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "menu task state must hold its menu definition", {})
  end
  if type(state.selectedIndex) ~= "number" or state.selectedIndex % 1 ~= 0 or state.selectedIndex < 0 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "menu task selected index is invalid", {})
  end
  if type(state.closed) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "menu task close state is invalid", {})
  end
  local ok, controller = pcall(menuController, state)
  if not ok then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "menu task menu definition is invalid", {})
  end
  if controller:status().selectedIndex ~= state.selectedIndex then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "menu task selected index is out of range", {})
  end
  return nil
end

return MenuTask
