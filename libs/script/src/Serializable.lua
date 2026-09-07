-- Serializability contract for script data :
-- values are serializable when they are numbers, strings, booleans, or
-- tables of serializable values with number/string keys, with no functions,
-- userdata, threads, metatables, cycles, or non-finite numbers. The
-- validator and the raw-Lua result check share this single implementation so
-- "serializable" means the same thing everywhere. Pure domain module: no
-- love dependency.

local Serializable = {}

-- True when the value is serializable; `seen` tracks the current ancestry to
-- detect cycles.
---@param value unknown
---@param seen table<string, unknown>|nil
---@return boolean
function Serializable.is(value, seen)
  seen = seen or {}
  local ty = type(value)
  if ty == "table" then
    if getmetatable(value) ~= nil then
      return false
    end
    if seen[value] then
      return false
    end
    seen[value] = true
    for k, v in pairs(value) do
      if type(k) ~= "number" and type(k) ~= "string" then
        return false
      end
      if not Serializable.is(v, seen) then
        return false
      end
    end
    seen[value] = nil
    return true
  elseif ty == "number" then
    return value == value and value ~= math.huge and value ~= -math.huge
  end
  return ty == "string" or ty == "boolean"
end

return Serializable
