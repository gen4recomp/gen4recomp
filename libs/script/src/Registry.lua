-- Script resource registry : owns the vanilla base
-- definitions (generated transcripts plus overrides). The override layer
-- wins over the generated transcript; the composition layer folds the
-- winning base into the effective chain. The registry also stamps the
-- deterministic fingerprint used by save validation. Base layers may be
-- installed as deferred placeholders (installBaseDeferred) that decode
-- through an injected resource loader on first access, so a boot never
-- needs to decode the whole generated corpus; the warm-up pass can stash
-- per-resource fingerprint hashes (cacheScriptHash) that fingerprint()
-- consumes without decoding. The registry is sealed after load: the public
-- install surface raises once sealed, while the post-load machinery
-- (restoreFingerprint, cacheScriptHash, and the private `_load`
-- memoization) stays live. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.script.src.Sha256")

---@class Registry
---@field private _bases table<string, table<string, unknown>> id -> layer -> script
---@field private _version integer
---@field private _sealed boolean
---@field private _fingerprintCache table<string, unknown>|nil { version: integer, value: string }
---@field private _hashCache table<string, unknown>|nil { version: integer, values: table<string, table<string, string>> }
---@field private _loadResource fun(id: string, layer: string): table<string, unknown>|nil, unknown?|nil
local Registry = {}
Registry.__index = Registry

-- Sentinel for a base layer whose resource is not decoded yet.
local PENDING = {}

-- Vanilla base layers : the checked-in `data/scripts/overrides` layer
-- (every script named by the override manifest) sits above the generated
-- transcript. The effective base selection happens here so the composition
-- layer only ever sees one base definition.
local BASE_LAYERS = { builtin = 1, generated = 2, override = 3 }

local VANILLA_OWNER = { kind = "vanilla", id = "base", api = 1 }

---@param opts table<string, unknown>|nil { loadResource: fun(id: string, layer: string): table<string, unknown>|nil, unknown?|nil }
---@return Registry
function Registry.new(opts)
  opts = opts or {}
  return setmetatable({
    _bases = {},
    _version = 0,
    _sealed = false,
    _fingerprintCache = nil,
    _hashCache = nil,
    _loadResource = opts.loadResource,
  }, Registry)
end

-- Seal the registry after load: the public install surface raises from here
-- on, so cached compositions and the fingerprint memo can never describe
-- stale data. Sealing is one-way; the post-load machinery the composition
-- wires (restoreFingerprint, cacheScriptHash, and the private `_load`
-- memoization) is exempt.
function Registry:seal()
  self._sealed = true
end

---@param id string
function Registry:_assertMutable(id)
  if self._sealed then
    Errors.raise(
      ScriptErrors.SCRIPT_REGISTRY_SEALED,
      "the script registry is sealed; installs must happen before load finishes",
      { scriptId = id }
    )
  end
end

function Registry:_hasBase(id)
  return self._bases[id] ~= nil and next(self._bases[id]) ~= nil
end

-- Install a vanilla base definition. `layer` is "generated" or "override";
-- override wins over the generated transcript. Installing the same layer
-- twice is a hard duplicate error.
---@param id string
---@param script table<string, unknown>
---@param layer string
---@return table<string, unknown>
function Registry:installBase(id, script, layer)
  self:_assertMutable(id)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(type(script) == "table", "base script must be a table")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated or override")
  self:_installLayer(id, layer, script)
  return script
end

---@param id string
---@param script table<string, unknown>
function Registry:installBuiltin(id, script)
  self:_assertMutable(id)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(type(script) == "table", "base script must be a table")
  self:_installLayer(id, "builtin", script)
end

-- Record a base layer whose resource is not decoded yet; `base` resolves it
-- through the registry's resource loader on first access. Same duplicate
-- rules as installBase.
---@param id string
---@param layer string
function Registry:installBaseDeferred(id, layer)
  self:_assertMutable(id)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated or override")
  self:_installLayer(id, layer, PENDING)
end

function Registry:_installLayer(id, layer, value)
  local layers = self._bases[id]
  if layers == nil then
    layers = {}
    self._bases[id] = layers
  end
  if layers[layer] ~= nil then
    local context = { scriptId = id, layer = layer, owner = VANILLA_OWNER }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_DUPLICATE_ID, "duplicate base definition for " .. id, context)
  end
  layers[layer] = value
  self._version = self._version + 1
end

-- Decode a pending layer through the resource loader and memoize it in the
-- slot; the loader is wired at construction, so its absence is a programming
-- fault, and a loader failure is a hard load error.
---@param id string
---@param layer string
---@return table<string, unknown>
function Registry:_load(id, layer)
  local loader = assert(self._loadResource, "registry has no resource loader for deferred base " .. id)
  local resource, err = loader(id, layer)
  if resource == nil then
    local context = { scriptId = id, layer = layer, cause = err and err.context or nil }
    ---@cast context Errors.Context
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "deferred base is unavailable: " .. id .. " (" .. tostring(err and err.message or "?") .. ")",
      context
    )
  end
  ---@cast resource table<string, unknown>
  self._bases[id][layer] = resource
  return resource
end

-- The effective base resource: override over generated. A deferred layer
-- decodes on first access and is memoized.
---@param id string
---@return table<string, unknown>?
function Registry:base(id)
  local layers = self._bases[id]
  if not layers then
    return nil
  end
  local layer = layers.override and "override" or layers.generated and "generated" or layers.builtin and "builtin"
  if not layer then
    return nil
  end
  local script = layers[layer]
  if script == PENDING then
    script = self:_load(id, layer)
  end
  return script
end

-- All ids with any installed base, sorted.
---@return string[]
function Registry:ids()
  local out = {}
  for id, layers in pairs(self._bases) do
    if next(layers) ~= nil then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

-- A monotonic mutation counter; the composition cache keys on it.
---@return integer
function Registry:version()
  return self._version
end

-- Preload the fingerprint memo from a validated keyed snapshot: the key
-- proves the registry content is what the digest was computed from. Valid
-- only while the registry is unmutated; any later install bumps `_version`
-- and the memo is recomputed from live content.
---@param value string
function Registry:restoreFingerprint(value)
  assert(type(value) == "string" and value ~= "", "restored fingerprint must be a non-empty string")
  self._fingerprintCache = { version = self._version, value = value }
end

-- Stash one base layer's fingerprint hash so fingerprint() can assemble the
-- digest without decoding that resource. Keyed on the mutation version: any
-- later install invalidates the stash and fingerprint() recomputes live.
-- The hash must be exactly what fingerprint() would compute
-- (Sha256.hex(LuaWriter.encode(resource))).
---@param id string
---@param layer string
---@param hash string
function Registry:cacheScriptHash(id, layer, hash)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated or override")
  assert(type(hash) == "string" and #hash == 64, "script hash must be a 64-character hex digest")
  local cache = self._hashCache
  if cache == nil or cache.version ~= self._version then
    cache = { version = self._version, values = {} }
    self._hashCache = cache
  end
  local byLayer = cache.values[id]
  if byLayer == nil then
    byLayer = {}
    cache.values[id] = byLayer
  end
  byLayer[layer] = hash
end

-- Deterministic registry fingerprint over every base layer: ordering,
-- resource ids, and a content hash of each resource. The fingerprint
-- therefore changes when a script's executable content changes even when
-- its id does not. Saves record it; load rejects a mismatch. The registry is
-- immutable during gameplay, so the digest is memoized on the mutation
-- version; the game saves after every warp and on quit, and re-hashing the
-- full corpus each time made the autosave stall.
---@return string
function Registry:fingerprint()
  local cached = self._fingerprintCache
  if cached ~= nil and cached.version == self._version then
    return cached.value
  end
  local projection = {}
  local hashCache = self._hashCache
  local cachedValues
  if hashCache ~= nil and hashCache.version == self._version then
    cachedValues = hashCache.values
  end
  for _, id in ipairs(self:ids()) do
    local entry = { id = id, bases = {} }
    local byLayer = cachedValues and cachedValues[id] or nil
    for layer in pairs(self._bases[id] or {}) do
      local cachedHash = byLayer and byLayer[layer] or nil
      if cachedHash ~= nil then
        -- A stashed hash implies the resource was already decoded with its
        -- id checked at load time, so the layer id equals the script id.
        entry.bases[#entry.bases + 1] = { layer = layer, scriptId = id, scriptHash = cachedHash }
      else
        local script = self._bases[id][layer]
        if script == PENDING then
          script = self:_load(id, layer)
        end
        entry.bases[#entry.bases + 1] = {
          layer = layer,
          scriptId = script.id,
          scriptHash = Sha256.hex(LuaWriter.encode(script)),
        }
      end
    end
    table.sort(entry.bases, function(a, b)
      return a.layer < b.layer
    end)
    projection[#projection + 1] = entry
  end
  local value = Sha256.hex(LuaWriter.encode(projection))
  self._fingerprintCache = { version = self._version, value = value }
  return value
end

return Registry
