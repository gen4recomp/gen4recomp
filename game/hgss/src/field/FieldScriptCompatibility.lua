-- Owns the production field-script registry, task registry, and composition
-- construction shared by field execution and persisted-save validation.
-- The generated layer's hashes come from the published cache index (seeded
-- by the loader at the final mutation version), so fingerprint acquisition
-- reads no generated bodies and writes no snapshots: a hashless index is a
-- stale cache and fails fast instead of warming the corpus.

local Composition = require("libs.script.src.Composition")
local Errors = require("libs.errors.src.Errors")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptErrors = require("libs.script.src.errors")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local HgssScript = require("libs.hgss.src.script.Composition")
local Validate = require("libs.assets.src.Validate")

---@class FieldScriptCompatibility
---@field registry Registry current production script registry
---@field fingerprint string registry fingerprint acquired once at composition
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
  local registry, activeSelection = ScriptLoader.buildRegistry(opts.cacheFs, opts.overrideFs, nil, {
    lazy = true,
    builtins = builtins,
  })
  -- No hashless fallback: every generated entry must carry its published
  -- canonical hash, or the cache is stale and fails here instead of
  -- decoding the corpus or writing snapshots during play.
  local resources = activeSelection.index.resources
  if not Validate.isArray(resources) then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script cache index resources are missing or malformed",
      { path = ScriptCache.indexPath() }
    )
  end
  for _, entry in ipairs(resources) do
    if type(entry) ~= "table" or type(entry.id) ~= "string" or not Validate.isSha256Key(entry.resourceHash) then
      Errors.raise(ScriptErrors.SCRIPT_LOAD_FAILED, "script cache entry is missing its published hash", {
        scriptId = type(entry) == "table" and entry.id or nil,
      })
    end
  end
  local self = setmetatable({
    registry = registry,
    fingerprint = registry:fingerprint(),
    composition = Composition.new(registry),
    taskRegistry = HgssScript.registerTasks(TaskRegistry.new()),
  }, FieldScriptCompatibility) --[[@as FieldScriptCompatibility]]
  return self
end

---@return string
function FieldScriptCompatibility:registryFingerprint()
  return self.fingerprint
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
