-- Shared source-operand normalization for script lowering handlers. Numeric
-- variable ranges follow the pinned pret/pokeheartgold
-- include/constants/vars.h definitions.
local Operands = {}

-- A variable-typed operand: symbols stay symbolic, numbers stay numbers.
---@param value unknown
---@return unknown
function Operands.operandValue(value)
  if type(value) == "table" then
    return value.raw
  end
  return value
end

-- Value-or-variable operand (ScriptGetVar semantics). The numeric ranges and
-- symbolic prefixes are grounded in the pinned vars.h definitions.
---@param value unknown
---@return unknown
function Operands.varRef(value)
  local raw = Operands.operandValue(value)
  if type(raw) == "number" then
    if (raw >= 0x4000 and raw < 0x4400) or (raw >= 0x8000 and raw < 0x8100) then
      return { value = "var", id = raw }
    end
    return raw
  end
  if raw:match("^VAR_") or raw:match("^SPECIAL_VAR_") then
    return { value = "var", id = raw }
  end
  return raw
end

return Operands
