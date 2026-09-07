-- Effective script composition : resolves one public script
-- id to its winning base definition (override over generated, selected by
-- the registry) and compiles it into a single executable entry. The
-- effective result is cached per id and keyed on the registry mutation
-- version. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.script.src.Sha256")
local Compiler = require("libs.script.src.Compiler")

---@class Composition
---@field private _registry Registry
---@field private _compile fun(script: table<string, unknown>, opts: table<string, unknown>): table<string, unknown>
---@field private _cache table<string, { version: integer, result: unknown }>
local Composition = {}
Composition.__index = Composition

local VANILLA_OWNER = { kind = "vanilla", id = "base", api = 1 }

---@param registry Registry
---@param opts table<string, unknown>|nil
---@return Composition
function Composition.new(registry, opts)
  opts = opts or {}
  return setmetatable({
    _registry = registry,
    _compile = opts.compile or Compiler.compile,
    _cache = {},
  }, Composition)
end

-- Build the executable chain for one id. Returns nil when the id has no
-- base definition at all.
---@param id string
---@return table<string, unknown>|nil chain
function Composition:_resolve(id)
  local baseResource = self._registry:base(id)
  if baseResource == nil then
    return nil
  end
  local graph, err = self._compile(baseResource, { allowNext = false })
  if not graph then
    Errors.raise(
      err and err.code or ScriptErrors.SCRIPT_SCHEMA_INVALID,
      tostring(err and err.message or "base script failed to compile"),
      { scriptId = id, cause = err }
    )
  end
  local projection = {
    scriptId = id,
    { operation = "base", owner = VANILLA_OWNER, scriptId = baseResource.id, revision = graph.revision },
  }
  return {
    scriptId = id,
    revision = Sha256.hex(LuaWriter.encode(projection)),
    entries = {
      {
        operation = "base",
        owner = VANILLA_OWNER,
        script = baseResource,
        scriptId = baseResource.id,
        graphRevision = graph.revision,
        graph = graph,
      },
    },
  }
end

-- The effective composed chain for one public script id, or nil when the id
-- is unknown. Raises on load-time composition faults (uncompilable base).
-- Cached until the registry mutates.
---@param id string
---@return table<string, unknown>|nil
function Composition:effective(id)
  local cached = self._cache[id]
  local version = self._registry:version()
  if cached ~= nil and cached.version == version then
    return cached.result
  end
  local result = self:_resolve(id)
  self._cache[id] = { version = version, result = result }
  return result
end

return Composition
