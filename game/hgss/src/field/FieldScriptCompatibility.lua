-- Owns the production field-script registry, task registry, and composition
-- construction shared by field execution and persisted-save validation.

local Composition = require("libs.script.src.Composition")
local Errors = require("libs.errors.src.Errors")
local RegistrySnapshot = require("libs.script.src.RegistrySnapshot")
local RegistryWarmup = require("libs.script.src.RegistryWarmup")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local HgssScript = require("libs.hgss.src.script.Composition")

---@class FieldScriptCompatibility
---@field registry Registry current production script registry
---@field registrySnapshotKey string|nil key the registry was built under
---@field registrySnapshotUsed boolean whether a matching snapshot supplied its fingerprint
---@field warmup RegistryWarmup|nil background registry warm-up after a snapshot miss
---@field composition Composition current production script composition
---@field taskRegistry TaskRegistry current production task registry
---@field registryFingerprint fun(self: FieldScriptCompatibility): string
local FieldScriptCompatibility = {}
FieldScriptCompatibility.__index = FieldScriptCompatibility

---@param opts { cacheFs: CacheFs, overrideFs: table<string, unknown> }
---@return FieldScriptCompatibility
function FieldScriptCompatibility.new(opts)
  assert(opts and opts.cacheFs and opts.overrideFs, "script compatibility requires filesystems")
  local builtins = HgssScript.builtins()
  local snapshot = RegistrySnapshot.load(opts.cacheFs, opts.overrideFs, builtins.contentHash)
  local fast = snapshot ~= nil and snapshot.fingerprint ~= nil
  local registry, activeSelection = ScriptLoader.buildRegistry(opts.cacheFs, opts.overrideFs, nil, {
    lazy = true,
    validateGenerated = not fast,
    builtins = builtins,
  })
  if snapshot ~= nil and snapshot.fingerprint ~= nil then
    registry:restoreFingerprint(snapshot.fingerprint)
  end
  local self = setmetatable({
    registry = registry,
    registrySnapshotKey = snapshot and snapshot.key or nil,
    registrySnapshotUsed = fast,
    warmup = nil,
    composition = Composition.new(registry),
    taskRegistry = HgssScript.registerTasks(TaskRegistry.new()),
  }, FieldScriptCompatibility) --[[@as FieldScriptCompatibility]]
  if not fast then
    self.warmup = RegistryWarmup.new({
      registry = registry,
      cacheFs = opts.cacheFs,
      overrideFs = opts.overrideFs,
      snapshotKey = snapshot and snapshot.key or nil,
      builtinContentHash = builtins.contentHash,
      selection = activeSelection,
    })
  end
  return self
end

---@return string
function FieldScriptCompatibility:registryFingerprint()
  if self.warmup ~= nil then
    local failure = self.warmup:finish()
    if failure ~= nil then
      Errors.raise(failure.code, failure.message, failure.context)
    end
  end
  return self.registry:fingerprint()
end

---@return table<string, unknown>
function FieldScriptCompatibility:validationOptions()
  local function resolveTask(taskType, version)
    return self.taskRegistry:resolve(taskType, version)
  end
  local function resolveComposition(scriptId)
    return self.composition:effective(scriptId)
  end
  return {
    expectedRegistryFingerprint = self:registryFingerprint(),
    expectedTaskFingerprint = self.taskRegistry:fingerprint(),
    resolveTask = resolveTask,
    resolveComposition = resolveComposition,
  }
end

return FieldScriptCompatibility
