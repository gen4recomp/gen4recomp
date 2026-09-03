-- Growth-curve decoding contract for the mon catalog compiler. Members
-- carry 101 u32 cumulative experience values (levels 0..100); the compiler
-- emits levels 1..100 for runtime creation.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function compiler()
  return require("romdump.src.digest.MonCatalogCompiler")
end

local function u32le(value)
  local b0 = value % 256
  local b1 = math.floor(value / 256) % 256
  local b2 = math.floor(value / 65536) % 256
  local b3 = math.floor(value / 16777216) % 256
  return string.char(b0, b1, b2, b3)
end

local function member(values)
  local parts = {}
  for _, value in ipairs(values) do
    parts[#parts + 1] = u32le(value)
  end
  return table.concat(parts)
end

local function context()
  return { archive = "growth_tables", memberId = 0 }
end

function T.emits_levels_1_through_100()
  local Compile = compiler()
  -- Medium-fast cubes: level n holds n^3 with level 1 pinned at zero.
  local values = {}
  for level = 0, 100 do
    values[#values + 1] = level <= 1 and 0 or level * level * level
  end
  local curve = assert(Compile.decodeGrowth(member(values), context()))
  Assert.equal(#curve, 100)
  Assert.equal(curve[1], 0)
  Assert.equal(curve[2], 8)
  Assert.equal(curve[100], 1000000)
end

function T.rejects_members_with_an_unexpected_size()
  local Compile = compiler()
  local curve, err = Compile.decodeGrowth(string.rep("\0", 400), context())
  Assert.isNil(curve)
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "MON_GROWTH_BAD_SIZE")
  Assert.equal(assert(err).context.memberId, 0)
end

return { tests = T }
