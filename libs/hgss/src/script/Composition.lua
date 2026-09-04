-- HGSS script composition: supplies game semantics, built-in resources, and
-- gameplay task implementations to the generic script platform.

local BuiltinScripts = require("libs.hgss.src.script.BuiltinScripts")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

---@class HgssMovementPauseTask: TaskImplementation
---@field actorType string
local Composition = {}

local TASK_MODULES = {
  "libs.script.src.tasks.WaitTicksTask",
  "libs.script.src.tasks.ChildScriptTask",
  "libs.hgss.src.script.tasks.WaitInputTask",
  "libs.hgss.src.script.tasks.WaitInputOrTicksTask",
  "libs.hgss.src.script.tasks.WaitSignpostActionTask",
  "libs.hgss.src.script.tasks.TrainerTipsTask",
  "libs.hgss.src.script.tasks.WaitSignpostTask",
  "libs.hgss.src.script.tasks.SignTask",
  "libs.hgss.src.script.tasks.DialogueTask",
  "libs.hgss.src.script.tasks.MovementTask",
  "libs.hgss.src.script.tasks.MovementBarrierTask",
  "libs.hgss.src.script.tasks.MovementPauseTask",
  "libs.hgss.src.script.tasks.FadeTask",
  "libs.hgss.src.script.tasks.SoundWaitTask",
  "libs.hgss.src.script.tasks.MusicFadeTask",
  "libs.hgss.src.script.tasks.WarpTask",
  "libs.hgss.src.script.tasks.AskYesNoTask",
  "libs.hgss.src.script.tasks.AuxiliaryUiTask",
  "libs.hgss.src.script.tasks.ContextChoiceTask",
  "libs.hgss.src.script.tasks.MenuTask",
  "libs.hgss.src.script.tasks.ChooseStarterTask",
  "libs.hgss.src.script.tasks.PartySelectTask",
  "libs.hgss.src.script.tasks.ActorOscillationTask",
}

---@param registry TaskRegistry
---@return TaskRegistry
function Composition.registerTasks(registry)
  for _, moduleName in ipairs(TASK_MODULES) do
    local impl = require(moduleName)
    ---@cast impl TaskImplementation
    registry:register(impl.type, impl.version, impl)
  end
  local movementPause = require("libs.hgss.src.script.tasks.MovementPauseTask")
  ---@cast movementPause HgssMovementPauseTask
  registry:register(movementPause.actorType, movementPause.version, movementPause)
  return registry
end

---@return table<string, unknown>
function Composition.builtins()
  return BuiltinScripts
end

---@return table<string, unknown>
function Composition.semantics()
  return RuntimeValues
end

return Composition
