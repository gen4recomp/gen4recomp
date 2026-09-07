-- Deterministic script RNG : the only random source the
-- scripting contract exposes. It is a pure-Lua Lehmer LCG (no bit library,
-- no love, never math.random), seeded from save/session state rather than
-- wall-clock time, and its state is serialized with the save so identical
-- fixed-tick input and save data produce identical rolls. Tests and coverage
-- inject a deterministic seed. Pure domain module: no love dependency.

local ScriptRng = {}
ScriptRng.__index = ScriptRng

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

ScriptRng.SCHEMA_NAME = "g4-script-rng-v1"

local MODULUS = 0x7FFFFFFF
local MULTIPLIER = 48271

local function isFiniteInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

---@class ScriptRngState
---@field _state integer
---@field _calls integer

-- Derive a nonzero seed deterministically from a string (e.g. a save or
-- session identity).
---@param seedText string|nil
---@return integer
function ScriptRng.deriveSeed(seedText)
  local seed = 0x2545F491
  if seedText ~= nil then
    for i = 1, #seedText do
      local byte = seedText:byte(i)
      seed = (seed * 33 + byte) % MODULUS
    end
  end
  if seed == 0 then
    seed = 1
  end
  return seed
end

-- Advance the LCG; the state is the serializable source of truth.
function ScriptRng:nextRaw()
  self._state = (self._state * MULTIPLIER) % MODULUS
  self._calls = self._calls + 1
  return self._state
end

-- Uniform integer in [0, maxExclusive).
---@param maxExclusive integer
---@return integer
function ScriptRng:nextInt(maxExclusive)
  assert(
    type(maxExclusive) == "number" and maxExclusive % 1 == 0 and maxExclusive > 0,
    "maxExclusive must be a positive integer"
  )
  return self:nextRaw() % maxExclusive
end

-- Uniform integer in [minInclusive, maxInclusive].
---@param minInclusive integer
---@param maxInclusive integer
---@return integer
function ScriptRng:range(minInclusive, maxInclusive)
  assert(
    type(minInclusive) == "number"
      and minInclusive % 1 == 0
      and type(maxInclusive) == "number"
      and maxInclusive % 1 == 0
      and minInclusive <= maxInclusive,
    "range bounds must be integers with min <= max"
  )
  local span = maxInclusive - minInclusive + 1
  return minInclusive + self:nextRaw() % span
end

-- True with probability numerator / denominator.
---@param numerator integer
---@param denominator integer
---@return boolean
function ScriptRng:chance(numerator, denominator)
  assert(
    type(numerator) == "number"
      and numerator % 1 == 0
      and type(denominator) == "number"
      and denominator % 1 == 0
      and denominator > 0
      and numerator >= 0
      and numerator <= denominator,
    "chance requires 0 <= numerator <= denominator with denominator > 0"
  )
  return self:nextRaw() % denominator < numerator
end

-- Serialized state for the save schema.
---@return table<string, unknown>
function ScriptRng:serialize()
  return { state = self._state, calls = self._calls }
end

---@param record unknown
---@return table<string, unknown>|nil, Errors.Error?
function ScriptRng.validate(record)
  if type(record) ~= "table" then
    return nil, Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "serialized rng state must be a table", {})
  end

  for key in pairs(record) do
    if key ~= "state" and key ~= "calls" then
      return nil, Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "serialized rng state has an unknown field", {})
    end
  end

  if not isFiniteInteger(record.state) or record.state < 1 or record.state >= MODULUS then
    return nil,
      Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "serialized rng state is outside the generator domain", {})
  end
  if not isFiniteInteger(record.calls) or record.calls < 0 then
    return nil,
      Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "serialized rng calls must be a non-negative integer", {})
  end
  return { state = record.state, calls = record.calls }
end

-- Create an RNG instance. `seed` may be a number or a string (derived).
---@param seed integer|string|nil
---@return table<string, unknown> rng
function ScriptRng.new(seed)
  local state
  if type(seed) == "string" then
    state = ScriptRng.deriveSeed(seed)
  elseif type(seed) == "number" then
    assert(seed % 1 == 0, "rng seed must be an integer")
    state = seed
  else
    state = ScriptRng.deriveSeed(nil)
  end
  if state <= 0 then
    state = 1
  end
  return setmetatable({
    _state = state,
    _calls = 0,
  }, ScriptRng)
end

-- Rebuild an RNG from serialized state.
---@param record table<string, unknown>
---@return table<string, unknown> rng
function ScriptRng.restore(record)
  local valid, err = ScriptRng.validate(record)
  if not valid then
    local validationError = assert(err)
    Errors.raise(validationError.code, validationError.message, validationError.context)
  end
  local validated = assert(valid)
  local rng = ScriptRng.new(validated.state)
  rng._calls = validated.calls
  return rng
end

return ScriptRng
