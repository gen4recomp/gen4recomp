-- Owns the persistent lifecycle that makes a destination map ready.

---@alias FieldMapEntryStage
---| "transition"
---| "transition_running"
---| "actors"
---| "load"
---| "load_running"
---| "load_resume_running"
---| "await_presentation"
---| "resume"
---| "resume_running"
---| "ready"

---@alias FieldMapEntryMode "full"|"connection"

---@class FieldMapEntryLifecycle
---@field hasLifecycle fun(self: FieldMapEntryLifecycle, lifecycle: string): boolean
---@field startLifecycle fun(self: FieldMapEntryLifecycle, lifecycle: string, tick: integer): boolean
---@field isLifecycleSettled fun(self: FieldMapEntryLifecycle): boolean|nil

---@class FieldMapEntryControllerOptions
---@field scriptScheduler table<string, unknown>
---@field initController FieldMapEntryLifecycle|nil
---@field enterMapActors fun()?
---@field autoAcknowledgePresentation boolean

---@class FieldMapEntryController
---@field private scriptScheduler table<string, unknown>
---@field private initController FieldMapEntryLifecycle|nil
---@field private enterMapActors fun()?
---@field private autoAcknowledgePresentation boolean
---@field private stageName FieldMapEntryStage?
---@field private mode FieldMapEntryMode|nil
---@field private connectionArrivalPending boolean
---@field private prePresentationResume boolean
local FieldMapEntryController = {}
FieldMapEntryController.__index = FieldMapEntryController

local HIDDEN_STAGES = {
  transition = true,
  transition_running = true,
  actors = true,
  load = true,
  load_running = true,
  load_resume_running = true,
}

---@param scheduler table<string, unknown>
---@return string?
local function foregroundEnvironmentId(scheduler)
  if scheduler.foregroundEnvironmentId then
    return scheduler:foregroundEnvironmentId()
  end
  return nil
end

---@param controller FieldMapEntryLifecycle
---@return boolean
local function lifecycleSettled(controller)
  if controller.isLifecycleSettled then
    return controller:isLifecycleSettled() == true
  end
  return true
end

---@param options unknown
---@return FieldMapEntryController
function FieldMapEntryController.new(options)
  assert(type(options) == "table", "map entry controller options required")
  ---@cast options FieldMapEntryControllerOptions
  assert(options.scriptScheduler, "map entry controller scheduler required")
  return setmetatable({
    scriptScheduler = options.scriptScheduler,
    initController = options.initController,
    enterMapActors = options.enterMapActors,
    autoAcknowledgePresentation = options.autoAcknowledgePresentation,
    stageName = nil,
    mode = nil,
    connectionArrivalPending = false,
    prePresentationResume = false,
  }, FieldMapEntryController)
end

---@param mode FieldMapEntryMode
function FieldMapEntryController:begin(mode)
  assert(mode == "full" or mode == "connection", "map entry mode required")
  assert(type(self.enterMapActors) == "function", "map actor entry capability required")
  assert(self.initController and self.initController.startLifecycle, "map lifecycle controller required")
  self.mode = mode
  self.stageName = "transition"
  self.connectionArrivalPending = mode == "connection"
  self.prePresentationResume = false
end

---@return FieldMapEntryStage?
function FieldMapEntryController:currentStage()
  return self.stageName
end

---@return boolean
function FieldMapEntryController:isActive()
  return self.stageName ~= nil
end

---@return boolean
function FieldMapEntryController:destinationWorldPresentable()
  if self.mode == "connection" then
    return true
  end
  return not HIDDEN_STAGES[self.stageName]
end

function FieldMapEntryController:acknowledgeDestinationPresentation()
  if self.stageName == "await_presentation" then
    self.stageName = "resume"
  end
end

---@return boolean
function FieldMapEntryController:takeConnectionArrival()
  if not self.connectionArrivalPending or self.stageName ~= nil then
    return false
  end
  self.connectionArrivalPending = false
  return true
end

---@param lifecycle string
---@return boolean
function FieldMapEntryController:hasLifecycle(lifecycle)
  return self.initController:hasLifecycle(lifecycle)
end

---@param lifecycle string
---@param tick integer
---@return boolean
function FieldMapEntryController:startLifecycle(lifecycle, tick)
  return self.initController:startLifecycle(lifecycle, tick)
end

---@param tick integer
---@return boolean consumed
function FieldMapEntryController:advance(tick)
  local stage = self.stageName
  if not stage then
    return false
  end
  if stage == "transition" then
    if foregroundEnvironmentId(self.scriptScheduler) ~= nil then
      return false
    end
    if self:hasLifecycle("on_transition") then
      if self:startLifecycle("on_transition", tick) then
        self.stageName = "transition_running"
      end
    else
      self.stageName = "actors"
    end
    return true
  elseif stage == "transition_running" then
    if foregroundEnvironmentId(self.scriptScheduler) ~= nil then
      return false
    end
    self.stageName = "actors"
    return true
  elseif stage == "actors" then
    self.enterMapActors()
    self.stageName = self.mode == "connection" and "ready" or "load"
    return true
  elseif stage == "load" then
    if foregroundEnvironmentId(self.scriptScheduler) ~= nil then
      return false
    end
    if self:hasLifecycle("on_load") then
      if self:startLifecycle("on_load", tick) then
        self.stageName = "load_running"
      end
    elseif self:hasLifecycle("on_resume") then
      if self:startLifecycle("on_resume", tick) then
        self.prePresentationResume = true
        self.stageName = "load_resume_running"
      end
    else
      self.stageName = "await_presentation"
    end
    return true
  elseif stage == "load_running" then
    if foregroundEnvironmentId(self.scriptScheduler) ~= nil or not lifecycleSettled(self.initController) then
      return false
    end
    self.stageName = "await_presentation"
    return true
  elseif stage == "load_resume_running" then
    if foregroundEnvironmentId(self.scriptScheduler) ~= nil or not lifecycleSettled(self.initController) then
      return false
    end
    self.stageName = "await_presentation"
    return true
  elseif stage == "await_presentation" then
    if self.autoAcknowledgePresentation then
      self:acknowledgeDestinationPresentation()
      return true
    end
    return false
  elseif stage == "resume" then
    if self.prePresentationResume then
      self.stageName = "ready"
      return true
    end
    if foregroundEnvironmentId(self.scriptScheduler) ~= nil then
      return false
    end
    if self:hasLifecycle("on_resume") then
      if self:startLifecycle("on_resume", tick) then
        self.stageName = "resume_running"
      end
    else
      self.stageName = "ready"
    end
    return true
  elseif stage == "resume_running" then
    if foregroundEnvironmentId(self.scriptScheduler) ~= nil then
      return false
    end
    self.stageName = "ready"
    return true
  elseif stage == "ready" then
    self.stageName = nil
    self.mode = nil
    return false
  end
  error("unknown map entry stage " .. tostring(stage))
end

return FieldMapEntryController
