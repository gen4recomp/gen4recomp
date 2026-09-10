-- Background warm-up for the lazy registry: decodes every generated script
-- file (without validation, since per-use validation owns that surface) and
-- stashes its fingerprint hash in time slices, then assembles the registry
-- fingerprint, restores it as the memo, and publishes the keyed snapshot.
-- Runs only after a snapshot miss, so the boot never stalls and the first
-- save simply finishes whatever the background slices have not. Progress is
-- in-memory only: a hard kill discards it and the next boot restarts the
-- pass; the snapshot is written only at completion. Pure domain module: no
-- love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local RegistrySnapshot = require("libs.script.src.RegistrySnapshot")
local StorageErrors = require("libs.storage.src.errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.script.src.Sha256")

---@class RegistryWarmup
---@field private registry table<string, unknown> Registry
---@field private cacheFs table<string, unknown> CacheFs-shaped
---@field private overrideFs table<string, unknown> read-shaped filesystem for data/scripts/overrides
---@field private snapshotKey string|nil
---@field private requireFn fun(name: string): unknown
---@field private builtinContentHash fun(): string|nil
---@field private clock fun(): number
---@field private budget number
---@field private index table<string, unknown>|nil
---@field private selection table<string, unknown>|nil
---@field private cursor integer
---@field private complete boolean
---@field private failure Errors.Error|nil
local RegistryWarmup = {}
RegistryWarmup.__index = RegistryWarmup
RegistryWarmup.DEFAULT_BUDGET_SECONDS = 0.002

---@param opts table<string, unknown> { registry: table<string, unknown>, cacheFs: table<string, unknown>, overrideFs: table<string, unknown>, snapshotKey: string|nil, requireFn: fun(name: string): unknown|nil, builtinContentHash: fun(): string|nil, clock: fun(): number?, budget: number? }
---@return RegistryWarmup
function RegistryWarmup.new(opts)
  assert(opts and opts.registry and opts.cacheFs and opts.overrideFs, "warm-up requires the registry and filesystems")
  assert(
    opts.selection and opts.selection.generation and opts.selection.index,
    "warm-up requires a pinned script selection"
  )
  return setmetatable({
    registry = opts.registry,
    cacheFs = opts.cacheFs,
    overrideFs = opts.overrideFs,
    snapshotKey = opts.snapshotKey,
    requireFn = opts.requireFn,
    builtinContentHash = opts.builtinContentHash,
    clock = opts.clock or os.clock,
    budget = opts.budget or RegistryWarmup.DEFAULT_BUDGET_SECONDS,
    index = nil,
    selection = opts.selection,
    cursor = 0,
    complete = false,
    failure = nil,
  }, RegistryWarmup)
end

---@return boolean
function RegistryWarmup:isComplete()
  return self.complete
end

-- Process one generated script: decode without validation and stash its
-- fingerprint hash. Returns false when the pass ended (completed or failed).
---@return boolean
function RegistryWarmup:_step()
  local entries = assert(self.index, "warm-up index is unavailable")
  local cursor = self.cursor + 1
  self.cursor = cursor
  if cursor > #entries then
    self:_complete()
    return false
  end
  local entry = entries[cursor]
  assert(type(entry) == "table" and type(entry.id) == "string", "script cache index entry id required")
  local resource, err
  resource, err = ScriptLoader.loadGeneratedFrom(
    self.cacheFs,
    self.selection.generation,
    assert(entry.member),
    entry.id,
    self.requireFn,
    { validate = false }
  )
  if resource == nil then
    self.failure = err
      or Errors.new(ScriptErrors.SCRIPT_LOAD_FAILED, "generated script failed to decode: " .. entry.id, {
        scriptId = entry.id,
      })
    return false
  end
  self.registry:cacheScriptHash(entry.id, "generated", Sha256.hex(LuaWriter.encode(resource)))
  return true
end

-- Assemble the fingerprint from the stashed hashes, restore it as the memo,
-- and publish the snapshot while the world still matches the boot key.
function RegistryWarmup:_complete()
  local fingerprint = self.registry:fingerprint()
  self.registry:restoreFingerprint(fingerprint)
  if
    self.snapshotKey ~= nil
    and not RegistrySnapshot.save(self.cacheFs, self.overrideFs, fingerprint, self.snapshotKey, self.builtinContentHash)
  then
    Errors.raise(StorageErrors.CACHE_WRITE_FAILED, "could not publish registry snapshot", {
      path = RegistrySnapshot.FILE,
    })
  end
  self.complete = true
end

-- Run one time slice of the pass. No-op once the pass completed or failed.
function RegistryWarmup:update()
  if self.complete or self.failure ~= nil then
    return
  end
  if self.index == nil then
    local index = self.selection.index
    if type(index) ~= "table" or index.schema ~= ScriptCache.INDEX_SCHEMA or type(index.resources) ~= "table" then
      self.failure = Errors.new(
        ScriptErrors.SCRIPT_LOAD_FAILED,
        "script cache index is unavailable for warm-up",
        { path = ScriptCache.indexPath() }
      )
      return
    end
    self.index = index.resources
  end
  assert(self.index, "warm-up index is unavailable")
  local deadline = self.clock() + self.budget
  repeat
    local ok = self:_step()
    if not ok then
      return
    end
  until self.clock() >= deadline
end

-- Run the remaining work synchronously (the save path); a clean quit is the
-- guaranteed completion point. Returns the recorded failure, or nil when the
-- pass completed.
---@return Errors.Error|nil
function RegistryWarmup:finish()
  while not self.complete and self.failure == nil do
    self:update()
  end
  return self.failure
end

return RegistryWarmup
