-- SHA-1 helpers for content-addressed derived assets and dependency markers.
-- Uses love.data.hash when present (the compiler always runs under LÖVE, and
-- love.data is available even in the windowless test/headless configuration);
-- the module never requires love, matching the guarded-global pattern used by
-- CacheFs and MapAssetInspector. Pure otherwise.

local Errors = require("libs.errors.src.Errors")
local LuaWriter = require("libs.codec.src.LuaWriter")

local Hashing = {}

-- Lowercase 40-char hex SHA-1 of a byte string or LÖVE Data value.
function Hashing.sha1hex(bytes)
  local kind = type(bytes)
  assert(
    kind == "string" or ((kind == "table" or kind == "userdata") and type(bytes.getFFIPointer) == "function"),
    "sha1hex requires a string or Data value"
  )
  if not (love and love.data) then
    Errors.raise("HASHING_UNAVAILABLE", "love.data is required for SHA-1 hashing", {})
  end
  local raw = love.data.hash("sha1", bytes)
  return (raw:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

-- Deterministic hash of a Lua data value: serialize with sorted keys, then hash.
function Hashing.hashLua(value)
  return Hashing.sha1hex(LuaWriter.encode(value))
end

return Hashing
