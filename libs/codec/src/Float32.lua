-- Deterministic IEEE-754 binary32 conversion for generated binary assets.

local Float32 = {}

---@param value number
---@return integer
function Float32.bits(value)
  local neg = false
  if value ~= value then
    return 0x7FC00000
  end
  if value < 0 or (value == 0 and 1 / value == -math.huge) then
    neg = true
    value = -value
  end
  local sign = neg and 2147483648 or 0
  if value == math.huge then
    return sign + 255 * 8388608
  end
  if value == 0 then
    return sign
  end
  local mantissa, exponent = math.frexp(value)
  local biased = (exponent - 1) + 127
  local fraction = 0
  if biased <= 0 then
    fraction = math.floor(value / 2 ^ -149 + 0.5)
    biased = 0
    if fraction >= 8388608 then
      biased = 1
      fraction = fraction - 8388608
    end
  else
    fraction = math.floor((mantissa * 2 - 1) * 8388608 + 0.5)
    if fraction >= 8388608 then
      fraction = 0
      biased = biased + 1
    end
    if biased >= 255 then
      return sign + 255 * 8388608
    end
  end
  return math.floor(sign + biased * 8388608 + fraction)
end

return Float32
