-- Evaluates generated field-map initialization rules at the pre-input
-- boundary. The scheduler remains the sole owner of script execution.

---@class MapInitScriptController
---@field rules table<string, unknown>
---@field world table<string, unknown>
---@field scriptClient table<string, unknown>
---@field mapId integer|nil
---@field activeLifecycle string|nil
local MapInitScriptController = {}
MapInitScriptController.__index = MapInitScriptController

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

local EVENT_TYPES = {
  on_load = true,
  on_transition = true,
  on_resume = true,
}

local function invalid(mapId, group, groupIndex, message, ruleIndex)
  Errors.raise(FieldErrors.MAP_INIT_UNSUPPORTED_LIFECYCLE, message, {
    type = group and group.type,
    scriptId = group and group.scriptId,
    mapId = mapId,
    groupIndex = groupIndex,
    ruleIndex = ruleIndex,
  })
end

local function validScriptId(value)
  return type(value) == "string" and #value > 0
end

local function validU16(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0 and value <= 0xFFFF
end

local function validateRules(rules, mapId)
  for groupIndex, group in ipairs(rules) do
    if type(group) ~= "table" then
      invalid(mapId, group, groupIndex, "map init group must be a table")
    elseif EVENT_TYPES[group.type] then
      if not validScriptId(group.scriptId) then
        invalid(mapId, group, groupIndex, "map init event script is missing")
      end
    elseif group.type == "on_frame_eq" then
      if type(group.rules) ~= "table" then
        invalid(mapId, group, groupIndex, "map init frame rules are missing")
      end
      for ruleIndex, rule in ipairs(group.rules) do
        if
          type(rule) ~= "table"
          or not validU16(rule.variableId)
          or not validU16(rule.equals)
          or not validScriptId(rule.scriptId)
        then
          invalid(mapId, group, groupIndex, "map init frame rule is malformed", ruleIndex)
        end
      end
    else
      invalid(mapId, group, groupIndex, "map init lifecycle is not executable")
    end
  end
end

---@param opts table<string, unknown> { rules: table<string, unknown>, world: table<string, unknown>, scriptClient: table<string, unknown> }
---@return MapInitScriptController
function MapInitScriptController.new(opts)
  assert(opts and type(opts.rules) == "table", "map init rules required")
  assert(opts.world and opts.world.getVar, "map init world required")
  assert(opts.scriptClient and opts.scriptClient.startInitScript, "map init client required")
  validateRules(opts.rules, opts.mapId)
  return setmetatable({
    rules = opts.rules,
    world = opts.world,
    scriptClient = opts.scriptClient,
    mapId = opts.mapId,
    activeLifecycle = nil,
  }, MapInitScriptController)
end

function MapInitScriptController:setRules(rules, mapId)
  assert(type(rules) == "table", "map init rules required")
  validateRules(rules, mapId == nil and self.mapId or mapId)
  self.mapId = mapId == nil and self.mapId or mapId
  self.rules = rules
end

---@param lifecycle string
---@return boolean
function MapInitScriptController:hasLifecycle(lifecycle)
  assert(EVENT_TYPES[lifecycle], "unknown map lifecycle: " .. tostring(lifecycle))
  for _, group in ipairs(self.rules) do
    if group.type == lifecycle then
      return true
    end
  end
  return false
end

---@param lifecycle string
---@param tick integer
---@return boolean claimed
function MapInitScriptController:startLifecycle(lifecycle, tick)
  assert(EVENT_TYPES[lifecycle], "unknown map lifecycle: " .. tostring(lifecycle))
  for _, group in ipairs(self.rules) do
    if group.type == lifecycle then
      local started = self.scriptClient:startInitScript(group.scriptId, tick) == true
      if started then
        self.activeLifecycle = lifecycle
      end
      return started
    end
  end
  return false
end

---@return boolean
function MapInitScriptController:isLifecycleSettled()
  if self.activeLifecycle == nil then
    return true
  end
  if self.scriptClient:isInitLifecycleSettled() then
    self.activeLifecycle = nil
    return true
  end
  return false
end

function MapInitScriptController:evaluateFrame(tick)
  for _, group in ipairs(self.rules) do
    if group.type == "on_frame_eq" then
      for _, rule in ipairs(group.rules) do
        if self.world:getVar(rule.variableId) == rule.equals then
          return self.scriptClient:startInitScript(rule.scriptId, tick) == true
        end
      end
    end
  end
  return false
end

-- Kept as the frame-only entry point for the existing field test seam.
function MapInitScriptController:evaluate(tick)
  return self:evaluateFrame(tick)
end

return MapInitScriptController
