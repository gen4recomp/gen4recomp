-- Persisted mons bucket. The normative g4-mons-save-v1 record carries the
-- catalog fingerprint, the exact generator state, and the party snapshot.
-- Capture copies live state into canonical records; restore rebuilds the
-- live party and generator against the current catalog. A bucket written
-- against different generated content fails with a fingerprint mismatch;
-- malformed buckets and failing mons fail with a save error that names the
-- zero-based mon slot. This module never touches the top-level save; the
-- game save injects it as a bucket validator.

local Errors = require("libs.errors.src.Errors")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")
local Party = require("libs.mons.src.Party")

---@alias MonsSave.Bucket { schema: string, catalogFingerprint: string, rng: { state: integer, calls: integer }, party: table<string, unknown> }
---@alias MonsSave.Context { catalog: MonCatalog, charmap: table<string, unknown>, games: table<string, unknown>, languages: table<string, unknown>, items: table<string, unknown>, balls: table<string, unknown> }
---@class MonsSave
local MonsSave = {}

MonsSave.SCHEMA = "g4-mons-save-v1"

---@generic T
---@param value T
---@return T
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param bucket MonsSave.Bucket
local function checkShape(bucket)
  if type(bucket) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket must be a record", {})
  end
  for key in pairs(bucket) do
    if key ~= "schema" and key ~= "catalogFingerprint" and key ~= "rng" and key ~= "party" then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket carries unknown field " .. tostring(key), {})
    end
  end
  if bucket.schema ~= MonsSave.SCHEMA then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket schema must be " .. MonsSave.SCHEMA, {})
  end
  if type(bucket.catalogFingerprint) ~= "string" or bucket.catalogFingerprint == "" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket requires a catalog fingerprint", {})
  end
  if type(bucket.rng) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket requires a generator record", {})
  end
  if type(bucket.party) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket requires a party snapshot", {})
  end
end

---@param fingerprint string
---@param seedU32 integer
---@return MonsSave.Bucket
function MonsSave.empty(fingerprint, seedU32)
  assert(type(fingerprint) == "string" and fingerprint ~= "", "mons empty requires a catalog fingerprint")
  assert(
    type(seedU32) == "number" and seedU32 % 1 == 0 and seedU32 >= 0 and seedU32 <= 0xFFFFFFFF,
    "mons empty requires an unsigned 32-bit seed"
  )
  local seed = seedU32
  if seed == 0 then
    seed = 1
  end
  return MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), fingerprint)
end

---@param partySnapshot table<string, unknown>
---@param rngCapture { state: integer, calls: integer }
---@param fingerprint string
---@return MonsSave.Bucket
function MonsSave.capture(partySnapshot, rngCapture, fingerprint)
  assert(type(partySnapshot) == "table", "mons capture requires a party snapshot")
  assert(type(rngCapture) == "table", "mons capture requires a generator capture")
  assert(type(fingerprint) == "string" and fingerprint ~= "", "mons capture requires a catalog fingerprint")
  local ok, failure = pcall(Lcrng.validate, rngCapture)
  if not ok then
    if Errors.is(failure) then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket generator record is malformed", {})
    end
    error(failure, 0)
  end
  return {
    schema = MonsSave.SCHEMA,
    catalogFingerprint = fingerprint,
    rng = copyValue(rngCapture),
    party = copyValue(partySnapshot),
  }
end

---@param bucket MonsSave.Bucket
---@param context MonsSave.Context
---@return boolean
function MonsSave.validate(bucket, context)
  assert(type(context) == "table", "mons validation requires a context")
  assert(context.catalog ~= nil, "mons validation requires a catalog")
  checkShape(bucket)
  local ok, failure = pcall(Lcrng.validate, bucket.rng)
  if not ok then
    if Errors.is(failure) then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket generator record is malformed", {})
    end
    error(failure, 0)
  end
  if bucket.catalogFingerprint ~= context.catalog:fingerprint() then
    MonsErrors.raise(
      MonsErrors.SAVE_FINGERPRINT_MISMATCH,
      "mons bucket was written against different generated content",
      {}
    )
  end
  local partyOk, partyFailure = pcall(Party.validate, bucket.party, context)
  if not partyOk then
    if type(bucket.party) == "table" and type(bucket.party.mons) == "table" then
      for index, mon in ipairs(bucket.party.mons) do
        local monOk, monFailure = pcall(Mon.validate, mon, context)
        if not monOk then
          if Errors.is(monFailure) then
            MonsErrors.raise(MonsErrors.SAVE_INVALID, "mons bucket mon is malformed", { slot = index - 1 })
          end
          error(monFailure, 0)
        end
      end
    end
    error(partyFailure, 0)
  end
  return true
end

---@param bucket MonsSave.Bucket
---@param context MonsSave.Context
---@return { party: Party, rng: Gen4Lcrng }
function MonsSave.restore(bucket, context)
  assert(type(context) == "table", "mons restore requires a context")
  MonsSave.validate(bucket, context)
  local party = Party.restore(bucket.party, context)
  local rng = Lcrng.restore(bucket.rng)
  return { party = party, rng = rng }
end

return MonsSave
