-- Small pure predicates shared by the generated-cache readiness validators.
-- The current cache schema requires arrays to be contiguous 1-based sequences
-- (the shape LuaWriter emits) and sprite/bank ids to be non-negative integers;
-- a malformed artifact must fail readiness rather than degrade silently.

local Validate = {}

---@class Validate
---@field isArray fun(value: unknown): boolean
---@field isNonNegativeInteger fun(value: unknown): boolean
---@field isSha1Key fun(value: unknown): boolean
---@field isSha256Key fun(value: unknown): boolean

-- True when `value` is a contiguous 1-based array (LuaWriter's array shape).
-- Hash tables, zero-based tables, fractional keys, and holes are not arrays.
---@param value unknown
---@return boolean
function Validate.isArray(value)
  if type(value) ~= "table" then
    return false
  end
  local values = value
  local count = 0
  for key in pairs(values) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    if key > count then
      count = key
    end
  end
  for i = 1, count do
    if values[i] == nil then
      return false
    end
  end
  return true
end

-- True when `value` is an integer >= 0 (the identity domain of sprite and bank
-- ids in the derived caches).
---@param value unknown
---@return boolean
function Validate.isNonNegativeInteger(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

-- True when `value` is a content-address key: 40 lowercase hex characters
-- (sha1 shape). Audio sample keys are also file-path components, so only the
-- lowercase hex shape is ever valid.
---@param value unknown
---@return boolean
function Validate.isSha1Key(value)
  return type(value) == "string" and #value == 40 and value:match("^[0-9a-f]+$") ~= nil
end

-- True when `value` is a canonical resource hash: 64 lowercase hex
-- characters (sha256 shape, as ScriptCacheWriter publishes per decoded
-- script resource and the script index joins per entry).
---@param value unknown
---@return boolean
function Validate.isSha256Key(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

return Validate
