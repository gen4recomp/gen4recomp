-- Test helper: encode a synthetic Nintendo DS backwards-LZ overlay stream
-- (the inverse of libs/nds/src/rom/OverlayCompression.lua::decode) so tests
-- can exercise real compressed-overlay decoding without a ROM. Only uniform
-- fill-byte content is supported: distance/length correctness does not
-- depend on the actual byte value being copied, which keeps the encoder
-- simple while still producing a byte-for-byte valid backwards-LZ stream.

local BackwardsLz = {}

local function u32le(n)
  n = n % 4294967296
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

-- tokens: array of { kind = "lit" } | { kind = "match", length=, displacement= }
-- in decode order (tokens[1] fills the last output byte).
local function encodeTokens(fillByte, tokens)
  local decodedLength = 0
  for _, t in ipairs(tokens) do
    decodedLength = decodedLength + (t.kind == "lit" and 1 or t.length)
  end

  local consumption = {}
  local i = 1
  while i <= #tokens do
    local groupLength = math.min(8, #tokens - i + 1)
    local flag = 0
    local groupBytes = {}
    for k = 0, groupLength - 1 do
      local t = tokens[i + k]
      local bit = math.floor(128 / (2 ^ k))
      if t.kind == "match" then
        flag = flag + bit
        local lengthNibble = t.length - 3
        local displacementField = t.displacement - 3
        local first = lengthNibble * 16 + math.floor(displacementField / 256)
        local second = displacementField % 256
        groupBytes[#groupBytes + 1] = string.char(first)
        groupBytes[#groupBytes + 1] = string.char(second)
      else
        groupBytes[#groupBytes + 1] = string.char(fillByte)
      end
    end
    consumption[#consumption + 1] = string.char(flag)
    for _, b in ipairs(groupBytes) do
      consumption[#consumption + 1] = b
    end
    i = i + groupLength
  end

  -- The decoder reads sourceOffset descending, so consumption[1] sits at the
  -- highest offset; the actual on-disk layout is the reverse.
  local layout = {}
  for k = #consumption, 1, -1 do
    layout[#layout + 1] = consumption[k]
  end
  local controlArea = table.concat(layout)
  local headerLength = 8
  local packedLength = #controlArea + 8
  local addedLength = decodedLength - packedLength
  local header = packedLength + headerLength * 16777216
  local footer = u32le(header) .. u32le(addedLength)
  return controlArea .. footer, decodedLength
end

-- Real compression: decoded length strictly greater than the compressed byte
-- string length. `fillByte` repeats for the entire decoded content.
---@param fillByte integer
---@param decodedLength integer at least 4
---@return string compressed
---@return integer decodedLength
function BackwardsLz.growing(fillByte, decodedLength)
  assert(decodedLength >= 4, "growing fixtures need at least 4 bytes")
  local tokens = { { kind = "lit" }, { kind = "lit" }, { kind = "lit" } }
  local remaining = decodedLength - 3
  while remaining > 0 do
    local length = math.min(18, remaining)
    if remaining - length > 0 and remaining - length < 3 then
      length = remaining - 3
    end
    tokens[#tokens + 1] = { kind = "match", length = length, displacement = 3 }
    remaining = remaining - length
  end
  return encodeTokens(fillByte, tokens)
end

-- A fixed non-growing fixture: decodes successfully, but decoded length
-- equals the compressed byte string length (33 bytes each way).
---@param fillByte integer
---@return string compressed
---@return integer decodedLength
function BackwardsLz.equalSized(fillByte)
  local tokens = { { kind = "lit" }, { kind = "lit" }, { kind = "lit" } }
  for _ = 1, 10 do
    tokens[#tokens + 1] = { kind = "match", length = 3, displacement = 3 }
  end
  return encodeTokens(fillByte, tokens)
end

-- Bytes that look like a compressed-overlay footer but fail to decode
-- (header length below the required minimum).
---@return string
function BackwardsLz.invalidFooter()
  return string.rep("\0", 8)
end

return BackwardsLz
