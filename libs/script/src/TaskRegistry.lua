-- Versioned script task registry : every task type is registered by a stable
-- name and major version; implementations supply `create`, `poll`, and
-- `validate`, and may supply `cancel`/`onComplete`. The scheduler routes task
-- creation and polling through this registry so save records can verify both
-- the type and the version on load, and so raw-Lua handlers can only ever
-- return a task type that is registered here. The deterministic fingerprint
-- covers every registered type and version; saves store it and reject a
-- mismatch. Pure domain module: no love dependency.
--
-- Any change to a task's serialized-state shape (what `validate` accepts and
-- what the save schema carries) requires a major version bump of that task
-- type: the fingerprint is a (type, version) projection, not an
-- implementation identity, so compatibility relies entirely on this manual
-- versioning.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.script.src.Sha256")

---@class TaskImplementation
---@field type string
---@field version integer
---@field create fun(spec: table<string, unknown>, ctx: table<string, unknown>): unknown
---@field poll fun(state: unknown, ctx: table<string, unknown>): table<string, unknown>
---@field validate fun(state: unknown): Errors.Error|nil
---@field cancel fun(state: unknown, reason: string, ctx: table<string, unknown>|nil)|nil
---@field onComplete fun(state: unknown, ctx: table<string, unknown>)|nil

---@class TaskRegistry
---@field private _byType table<string, table<integer, TaskImplementation>>
local TaskRegistry = {}
TaskRegistry.__index = TaskRegistry

---@return TaskRegistry
function TaskRegistry.new()
  return setmetatable({
    _byType = {},
  }, TaskRegistry)
end

-- Register a task implementation under a stable type name and major version.
-- Registering the same type and version twice is a programming invariant, as
-- is a fractional version (the version is the serialized-state shape's major
-- version, not a real number). `validate` is required; the optional
-- `cancel`/`onComplete` callbacks, when present, must be functions.
---@param taskType string
---@param version integer
---@param impl TaskImplementation
function TaskRegistry:register(taskType, version, impl)
  assert(type(taskType) == "string" and taskType ~= "", "task type required")
  assert(type(version) == "number", "task version required")
  assert(version == math.floor(version), "task version must be an integer")
  assert(type(impl) == "table" and type(impl.poll) == "function", "task implementation must supply poll")
  assert(type(impl.create) == "function", "task implementation must supply create")
  assert(type(impl.validate) == "function", "task implementation must supply validate")
  assert(impl.cancel == nil or type(impl.cancel) == "function", "task implementation must supply a function cancel")
  assert(
    impl.onComplete == nil or type(impl.onComplete) == "function",
    "task implementation must supply a function onComplete"
  )
  local versions = self._byType[taskType]
  if versions == nil then
    versions = {}
    self._byType[taskType] = versions
  end
  assert(versions[version] == nil, "task type " .. taskType .. " version " .. version .. " registered twice")
  versions[version] = impl
end

-- Resolve a task implementation; unknown types and versions are attributed
-- save errors, never silently skipped.
---@param taskType string
---@param version integer
---@return TaskImplementation|nil, Errors.Error|nil
function TaskRegistry:resolve(taskType, version)
  local versions = self._byType[taskType]
  if versions == nil then
    return nil,
      Errors.new(
        ScriptErrors.SCRIPT_TASK_VERSION_UNSUPPORTED,
        "no registered task type " .. tostring(taskType),
        { taskType = taskType }
      )
  end
  local impl = versions[version]
  if impl == nil then
    return nil,
      Errors.new(
        ScriptErrors.SCRIPT_TASK_VERSION_UNSUPPORTED,
        "task type " .. tostring(taskType) .. " has no version " .. tostring(version),
        { taskType = taskType, version = version }
      )
  end
  return impl
end

-- Resolve the current implementation of a task type for creation: the
-- highest registered major version, since a type can hold several save-shape
-- versions while creation always uses the newest. Unknown types are
-- attributed save errors, never silently skipped.
---@param taskType string
---@return TaskImplementation|nil, Errors.Error|nil
function TaskRegistry:resolveCurrent(taskType)
  local versions = self._byType[taskType]
  if versions == nil then
    return nil,
      Errors.new(
        ScriptErrors.SCRIPT_TASK_VERSION_UNSUPPORTED,
        "no registered task type " .. tostring(taskType),
        { taskType = taskType }
      )
  end
  local currentVersion = -math.huge
  for version in pairs(versions) do
    currentVersion = math.max(currentVersion, version)
  end
  ---@cast currentVersion integer
  return self:resolve(taskType, currentVersion)
end

-- Enumerate every registered task type, sorted by name (the order the
-- fingerprint projection uses).
---@return string[]
function TaskRegistry:types()
  local out = {}
  for taskType in pairs(self._byType) do
    out[#out + 1] = taskType
  end
  table.sort(out)
  return out
end

-- Deterministic fingerprint over every registered (type, version) pair; the
-- save schema stores it and load rejects a mismatch. Lookup
-- is order-independent, so the fingerprint is too: types are sorted by name.
---@return string
function TaskRegistry:fingerprint()
  local types = {}
  for taskType in pairs(self._byType) do
    types[#types + 1] = taskType
  end
  table.sort(types)
  local projection = {}
  for _, taskType in ipairs(types) do
    local versions = {}
    for version in pairs(self._byType[taskType]) do
      versions[#versions + 1] = version
    end
    table.sort(versions)
    projection[#projection + 1] = { type = taskType, versions = versions }
  end
  return Sha256.hex(LuaWriter.encode(projection))
end

return TaskRegistry
