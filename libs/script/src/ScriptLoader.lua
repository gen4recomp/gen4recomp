-- Script content loader for the game (the override system): installs the
-- generated transcript bases from the compiled script cache, then every
-- checked-in override listed in the override manifest (a file named
-- `<script-id>.lua` overrides the script with that id, or introduces the id
-- when no base exists, as with the curated Elm replacement). The manifest is
-- the single source of override filenames: no directory enumeration at
-- runtime. Override files are ordinary `return S.script { ... }` modules
-- executed in a restricted environment; the returned resource must carry the
-- exact id of its file and must validate strictly. The filesystem is
-- injected (`read`), so the loader is testable headless; the game passes an
-- io-backed repo filesystem for the override tree outside the LÖVE source
-- mount. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local ScriptCache = require("libs.assets.src.ScriptCache")
local Validate = require("libs.assets.src.Validate")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local Validator = require("libs.script.src.Validator")

local ScriptLoader = {}

-- The default restricted require for resource chunks: generated and override
-- modules may import gen4.script and nothing else. Callers that trust their
-- content may inject their own requireFn, but the default is an allowlist,
-- not the global require.
---@param name string
---@return unknown
local function defaultRequire(name)
  assert(name == "gen4.script", "script resource chunks may only require gen4.script")
  return require(name)
end

-- Load one Lua resource chunk (`return S.script { ... }`) in a restricted
-- environment that only provides `require`.
---@param content string
---@param chunkName string
---@param requireFn function
---@return table<string, unknown> resource
local function loadResourceChunk(content, chunkName, requireFn)
  local chunk, loadErr = loadstring(content, chunkName)
  if not chunk then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script module does not parse: " .. tostring(loadErr),
      { path = chunkName }
    )
  end
  chunk = chunk --[[@as function]]
  local env = { require = requireFn } --[[@as table]]
  setfenv(chunk, env)
  local ok, resource = pcall(chunk)
  if not ok then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script module failed to load: " .. tostring(resource),
      { path = chunkName }
    )
  end
  if type(resource) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_LOAD_FAILED, "script module must return a resource table", { path = chunkName })
  end
  return resource
end

-- Decode one generated script file from the compiled cache: read, parse, and
-- execute the restricted chunk, check the resource id against the entry, and
-- optionally validate the schema. Returns the resource, or nil plus an Errors
-- object on any failure.
---@param cacheFs table<string, unknown> CacheFs-shaped
---@param id string
---@param requireFn fun(name: string): unknown|nil defaults to the restricted gen4.script-only require
---@param opts table<string, unknown>|nil { validate: boolean? }
---@return table<string, unknown>|nil, Errors.Error?
function ScriptLoader.loadGenerated(cacheFs, id, requireFn, opts)
  requireFn = requireFn or defaultRequire
  opts = opts or {}
  local path = ScriptCache.scriptPath(id)
  local content = cacheFs:read(path)
  if content == nil then
    return nil,
      Errors.new(
        ScriptErrors.SCRIPT_LOAD_FAILED,
        "script cache resource is unavailable",
        { scriptId = id, path = path }
      )
  end
  local ok, resource = pcall(loadResourceChunk, content --[[@as string]], path, requireFn)
  if not ok then
    return nil, resource --[[@as Errors.Error]]
  end
  resource = resource --[[@as table]]
  if resource.id ~= id then
    return nil,
      Errors.new(
        ScriptErrors.SCRIPT_LOAD_FAILED,
        "script cache resource does not match its index entry",
        { scriptId = id, resourceId = resource.id }
      )
  end
  if opts.validate ~= false then
    local valid, validateErr = Validator.validate(resource)
    if not valid then
      return nil, validateErr
    end
  end
  return resource
end

-- Load every generated base from the compiled script cache: the index lists
-- the resources and each file is one `S.script` resource. A missing or
-- invalid base is a hard load error (the cache readiness check already gates
-- the build, so a mismatch here is a real fault). With `opts.lazy`, only the
-- layer presence is installed (installBaseDeferred): the resources decode
-- through the build's resource loader on first access, and
-- `opts.validateGenerated` (default true) gates per-load validation on that
-- path; the eager path validates every loaded resource under the same flag.
---@param registry table<string, unknown> Registry
---@param cacheFs table<string, unknown> CacheFs-shaped
---@param requireFn? fun(name: string): unknown
---@param opts table<string, unknown>|nil { lazy: boolean?, validateGenerated: boolean?, builtins: table<string, unknown>|nil }
function ScriptLoader.installGenerated(registry, cacheFs, requireFn, opts)
  requireFn = requireFn or defaultRequire
  opts = opts or {}
  local index, indexErr = cacheFs:loadLua(ScriptCache.indexPath())
  if not index then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script cache index is unavailable: " .. tostring(indexErr and indexErr.message or "?"),
      { path = ScriptCache.indexPath(), cause = indexErr and indexErr.context or nil }
    )
  end
  if type(index) ~= "table" or index.schema ~= ScriptCache.INDEX_SCHEMA then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script cache index has an unknown schema",
      { path = ScriptCache.indexPath(), schema = index and index.schema or nil }
    )
  end
  -- resources is the current schema's required array; a missing or malformed
  -- index must fail before any install, never become an empty registry. The
  -- rule matches the build-path readiness validator (ScriptCache.isReady).
  -- This checks only the index shape -- the per-resource files still decode
  -- lazily on the deferred path, so snapshot-hit validation avoidance is
  -- untouched.
  if not Validate.isArray(index.resources) then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script cache index resources are missing or malformed",
      { path = ScriptCache.indexPath() }
    )
  end
  for _, entry in ipairs(index.resources) do
    assert(type(entry.id) == "string" and entry.id ~= "", "script cache index entry id required")
    if opts.lazy then
      registry:installBaseDeferred(entry.id, "generated")
    else
      local resource, err = ScriptLoader.loadGenerated(cacheFs, entry.id, requireFn, {
        validate = opts.validateGenerated ~= false,
      })
      if resource == nil then
        local context = { scriptId = entry.id, cause = err and err.context or nil }
        ---@cast context Errors.Context
        Errors.raise(
          err and err.code or ScriptErrors.SCRIPT_LOAD_FAILED,
          err and err.message or "generated script failed to load",
          context
        )
      end
      registry:installBase(entry.id, resource, "generated")
    end
  end
end

-- Load one override file: `<id>.lua` returning an S.script resource whose id
-- must equal the file-derived id. Returns the resource.
---@param id string
---@param content string
---@param requireFn function
---@return table<string, unknown> resource
function ScriptLoader.loadOverride(id, content, requireFn)
  local resource = loadResourceChunk(content, ScriptOverrides.DIR .. "/" .. id .. ".lua", requireFn)
  if resource.id ~= id then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "override file " .. id .. ".lua defines script " .. tostring(resource.id),
      { scriptId = id, resourceId = resource.id }
    )
  end
  local okValidate, validateErr = Validator.validate(resource)
  if not okValidate then
    local context = { scriptId = id, cause = validateErr and validateErr.context or nil }
    ---@cast context Errors.Context
    Errors.raise(
      validateErr and validateErr.code or ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "override fails validation: " .. tostring(validateErr and validateErr.message or "?"),
      context
    )
  end
  return resource
end

-- Install every override named by the override manifest. Files are
-- `data/scripts/overrides/<id>.lua`; the manifest lists the exact ids (it is
-- regenerated with the overrides, so no directory enumeration happens at
-- runtime). The manifest is evaluated in the same restricted environment as
-- resource chunks. Returns the ids installed, sorted.
---@param registry table<string, unknown> Registry
---@param fs table<string, unknown> { read(path): string? }
---@param requireFn? fun(name: string): unknown
---@return string[]
function ScriptLoader.installOverrides(registry, fs, requireFn)
  requireFn = requireFn or defaultRequire
  local manifest, manifestErr = fs:read(ScriptOverrides.MANIFEST)
  if manifest == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "override manifest is unavailable: " .. tostring(manifestErr and manifestErr.message or "?"),
      { path = ScriptOverrides.MANIFEST }
    )
  end
  local ids = loadResourceChunk(manifest --[[@as string]], ScriptOverrides.MANIFEST, requireFn)
  table.sort(ids)
  local installed = {}
  for _, id in ipairs(ids) do
    assert(type(id) == "string" and id ~= "", "override manifest ids must be strings")
    local path = ScriptOverrides.DIR .. "/" .. id .. ".lua"
    local content = fs:read(path)
    if content == nil then
      Errors.raise(ScriptErrors.SCRIPT_LOAD_FAILED, "override file is unreadable: " .. path, { scriptId = id })
    end
    local resource = ScriptLoader.loadOverride(id, content --[[@as string]], requireFn)
    registry:installBase(id, resource, "override")
    installed[#installed + 1] = id
  end
  return installed
end

-- Build a registry from the script cache plus the override directory. `fs`
-- must expose the repo `data/scripts/overrides` directory; the game passes an
-- io-backed repo filesystem (RepoFs) reading the checkout tree. With
-- `opts.lazy` the generated layer installs as deferred placeholders that
-- decode on first access through a loader closure over `cacheFs`;
-- `opts.validateGenerated` (default true) gates per-load validation on the
-- lazy path and per-file validation on the eager path. The override layer is
-- always loaded and validated eagerly. The finished registry is sealed:
-- installs after load finish are rejected.
---@param cacheFs table<string, unknown> CacheFs-shaped
---@param fs table<string, unknown> directory-shaped filesystem for data/scripts/overrides
---@param requireFn function|nil defaults to the restricted gen4.script-only require
---@param opts table<string, unknown>|nil { lazy: boolean?, validateGenerated: boolean?, builtins: table<string, unknown>|nil }
---@return Registry registry
function ScriptLoader.buildRegistry(cacheFs, fs, requireFn, opts)
  opts = opts or {}
  requireFn = requireFn or defaultRequire
  local Registry = require("libs.script.src.Registry")
  local registry
  if opts.lazy then
    local function loadResource(id, _)
      local resource, err = ScriptLoader.loadGenerated(cacheFs, id, requireFn, {
        validate = opts.validateGenerated ~= false,
      })
      if resource == nil then
        local context = { scriptId = id, cause = err and err.context or nil }
        ---@cast context Errors.Context
        Errors.raise(
          err and err.code or ScriptErrors.SCRIPT_LOAD_FAILED,
          err and err.message or "generated script failed to load",
          context
        )
      end
      return resource
    end
    registry = Registry.new({
      loadResource = loadResource,
    })
  else
    registry = Registry.new()
  end
  if opts.builtins ~= nil then
    assert(type(opts.builtins.all) == "function", "script builtins require an all function")
    for id, script in pairs(opts.builtins.all()) do
      registry:installBuiltin(id, script)
    end
  end
  ScriptLoader.installGenerated(registry, cacheFs, requireFn, opts)
  ScriptLoader.installOverrides(registry, fs, requireFn)
  -- Load finished: the registry is sealed so cached compositions and the
  -- fingerprint memo can never describe stale data. The post-load machinery
  -- (restoreFingerprint, cacheScriptHash, on-demand decode) is exempt from
  -- the gate.
  registry:seal()
  return registry
end

return ScriptLoader
