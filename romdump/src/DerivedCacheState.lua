-- Per-version attestation of the last strictly successful derived-cache
-- build: the identity { schema, dump, producer, assetContract, scriptApi }
-- persisted at data/generated/build.lua under the version root. It is an
-- attestation, not a runtime asset; no runtime loader ever reads it. It
-- exists so --build-cache can answer "was the published cache produced by
-- this producer + contract for this dump?" without opening the ROM. publish
-- writes a temporary sibling and atomically replaces the live state, and the
-- state is only ever written after a fully strict build (no compile
-- exclusions) whose whole batch succeeded: CacheBuilder defers both the world
-- index and this attestation to the batch outcome, so the attestation never
-- vouches for a world index the batch left stale. invalidate removes the
-- attestation without touching the artifacts themselves.

local Hashing = require("romdump.src.digest.Hashing")

local DerivedCacheState = {}

-- Schema of the persisted state file itself; bump when its shape changes.
DerivedCacheState.schema = 1

-- Attestation path below the version root, kept out of every runtime asset
-- load.
DerivedCacheState.path = "data/generated/build.lua"

-- The current identity for the given raw inputs: the exact published raw-dump
-- marker, the producer source fingerprint, the shared asset-contract table,
-- and the gen4 script DSL API version.
---@param inputs { dump: string, producer: string, assetContract: table<string, unknown>, scriptApi: number }
---@return table<string, unknown>
function DerivedCacheState.current(inputs)
  assert(type(inputs.dump) == "string", "dump marker must be a string")
  assert(type(inputs.producer) == "string", "producer fingerprint must be a string")
  assert(type(inputs.assetContract) == "table", "asset contract must be a table")
  assert(type(inputs.scriptApi) == "number", "script API version must be a number")
  return {
    schema = DerivedCacheState.schema,
    dump = inputs.dump,
    producer = inputs.producer,
    assetContract = Hashing.hashLua(inputs.assetContract),
    scriptApi = inputs.scriptApi,
  }
end

-- True when the stored state (nil when missing or malformed) exactly matches
-- the current identity; any difference in any input invalidates.
---@param stored unknown
---@param identity table<string, unknown>
---@return boolean
function DerivedCacheState.matches(stored, identity)
  if type(stored) ~= "table" then
    return false
  end
  return Hashing.hashLua(stored) == Hashing.hashLua(identity)
end

-- Remove the successful-build attestation: stops the fast path from trusting
-- a state that no longer holds (identity mismatch or damaged artifacts).
-- Never touches the artifacts themselves.
---@param cacheFs table<string, unknown>
function DerivedCacheState.invalidate(cacheFs)
  cacheFs:remove(DerivedCacheState.path)
end

-- Atomically persist the identity: write a temporary sibling, then replace
-- the live state. A failed write or failed replace raises and leaves the
-- previous state (or its absence) in place.
---@param cacheFs table<string, unknown>
---@param identity table<string, unknown>
function DerivedCacheState.publish(cacheFs, identity)
  local staged = DerivedCacheState.path .. ".new"
  cacheFs:writeLua(staged, identity)
  cacheFs:replace(staged, DerivedCacheState.path)
end

return DerivedCacheState
