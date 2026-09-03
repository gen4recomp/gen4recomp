-- Personal-record decoding contract for the mon catalog compiler.
-- Fixture layout mirrors pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- include/pokemon_types_def.h BASE_STATS: six base stats, two types, catch
-- rate, base experience, a packed u16 EV yield word, two held items,
-- gender/egg-cycle/friendship/growth fields, two egg groups, two u8
-- abilities, the Great Marsh rate, packed color/flip metadata, two reserved
-- bytes, and four TM/HM compatibility words. The producer verifies every
-- offset against the pinned decomp; the ROM fidelity suite anchors real values.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function compiler()
  return require("romdump.src.digest.MonCatalogCompiler")
end

local function u16le(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

-- Builds a synthetic 0x2C personal member from named fields.
---@class PersonalFixtureFields
---@field stats integer[]?
---@field type1 integer?
---@field type2 integer?
---@field catchRate integer?
---@field baseExp integer?
---@field evYield table<string, integer>?
---@field itemCommon integer?
---@field itemRare integer?
---@field genderRatio integer?
---@field eggCycles integer?
---@field baseFriendship integer?
---@field growthCurve integer?
---@field eggGroup1 integer?
---@field eggGroup2 integer?
---@field ability1 integer?
---@field ability2 integer?
---@field marshRate integer?
---@field tmhm string?
---@field color integer?
---@field flip boolean?
---@param fields PersonalFixtureFields
---@return string member
local function buildPersonal(fields)
  local bytes = {}
  local stats = fields.stats or { 0, 0, 0, 0, 0, 0 }
  for _, stat in ipairs(stats) do
    bytes[#bytes + 1] = string.char(stat)
  end
  bytes[#bytes + 1] = string.char(fields.type1 or 0)
  bytes[#bytes + 1] = string.char(fields.type2 or 0)
  bytes[#bytes + 1] = string.char(fields.catchRate or 0)
  bytes[#bytes + 1] = string.char(fields.baseExp or 0)
  local ev = 0
  local evStats = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }
  local evYield = fields.evYield or {}
  for index, stat in ipairs(evStats) do
    ev = ev + ((evYield[stat] or 0) * (4 ^ (index - 1)))
  end
  bytes[#bytes + 1] = u16le(ev)
  bytes[#bytes + 1] = u16le(fields.itemCommon or 0)
  bytes[#bytes + 1] = u16le(fields.itemRare or 0)
  bytes[#bytes + 1] = string.char(fields.genderRatio or 0)
  bytes[#bytes + 1] = string.char(fields.eggCycles or 0)
  bytes[#bytes + 1] = string.char(fields.baseFriendship or 0)
  bytes[#bytes + 1] = string.char(fields.growthCurve or 0)
  bytes[#bytes + 1] = string.char(fields.eggGroup1 or 0)
  bytes[#bytes + 1] = string.char(fields.eggGroup2 or 0)
  assert((fields.ability1 or 0) < 256 and (fields.ability2 or 0) < 256, "abilities are u8")
  bytes[#bytes + 1] = string.char(fields.ability1 or 0)
  bytes[#bytes + 1] = string.char(fields.ability2 or 0)
  bytes[#bytes + 1] = string.char(fields.marshRate or 0)
  bytes[#bytes + 1] = string.char((fields.color or 0) + (fields.flip and 128 or 0))
  bytes[#bytes + 1] = string.char(0)
  bytes[#bytes + 1] = string.char(0)
  local tmhm = fields.tmhm or string.rep("\0", 16)
  assert(#tmhm == 16, "tmhm compatibility block must be 16 bytes")
  bytes[#bytes + 1] = tmhm
  local member = table.concat(bytes)
  assert(#member == 0x2C, "personal member must be 0x2C bytes")
  return member
end

local function context()
  return { archive = "personal", memberId = 152 }
end

function T.decodes_every_base_stat_and_scalar_field()
  local Compile = compiler()
  local record = assert(Compile.decodePersonal(
    buildPersonal({
      stats = { 45, 49, 65, 45, 65, 65 },
      type1 = 12,
      type2 = 12,
      catchRate = 45,
      baseExp = 64,
      genderRatio = 31,
      eggCycles = 20,
      baseFriendship = 70,
      growthCurve = 4,
      eggGroup1 = 1,
      eggGroup2 = 7,
      ability1 = 65,
      ability2 = 102,
      itemCommon = 0,
      itemRare = 0,
      color = 3,
      flip = false,
    }),
    context()
  ))
  Assert.equal(record.baseStats.hp, 45)
  Assert.equal(record.baseStats.attack, 49)
  Assert.equal(record.baseStats.defense, 65)
  Assert.equal(record.baseStats.speed, 45)
  Assert.equal(record.baseStats.specialAttack, 65)
  Assert.equal(record.baseStats.specialDefense, 65)
  Assert.equal(record.catchRate, 45)
  Assert.equal(record.baseExpYield, 64)
  Assert.equal(record.genderRatio, 31)
  Assert.equal(record.eggCycles, 20)
  Assert.equal(record.baseFriendship, 70)
  Assert.equal(record.color, 3)
  Assert.equal(record.flip, false)
end

function T.decodes_ev_yield_bitfields_per_stat()
  local Compile = compiler()
  local record = assert(Compile.decodePersonal(
    buildPersonal({
      evYield = { hp = 0, attack = 1, defense = 2, speed = 3, specialAttack = 1, specialDefense = 0 },
    }),
    context()
  ))
  Assert.equal(record.evYield.hp, 0)
  Assert.equal(record.evYield.attack, 1)
  Assert.equal(record.evYield.defense, 2)
  Assert.equal(record.evYield.speed, 3)
  Assert.equal(record.evYield.specialAttack, 1)
  Assert.equal(record.evYield.specialDefense, 0)
end

function T.decodes_tmhm_compatibility_bits_in_source_order()
  local Compile = compiler()
  -- Bits 0, 15, and 99 set across the 16-byte block.
  local block = { 0x01, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x08, 0, 0, 0 }
  local chars = {}
  for _, byte in ipairs(block) do
    chars[#chars + 1] = string.char(byte)
  end
  local record = assert(Compile.decodePersonal(buildPersonal({ tmhm = table.concat(chars) }), context()))
  Assert.deepEqual(record.tmhm, { 0, 15, 99 })
end

function T.rejects_members_with_an_unexpected_size()
  local Compile = compiler()
  local record, err = Compile.decodePersonal(string.rep("\0", 0x2B), context())
  Assert.isNil(record)
  Assert.isTrue(Errors.is(err), "size failure must be structured")
  Assert.equal(assert(err).code, "MON_PERSONAL_BAD_SIZE")
  Assert.equal(assert(err).context.archive, "personal")
  Assert.equal(assert(err).context.memberId, 152)
end

function T.rejects_unknown_enumerated_source_ids()
  local Compile = compiler()
  local record, err = Compile.decodePersonal(buildPersonal({ growthCurve = 255 }), context())
  Assert.isNil(record)
  Assert.isTrue(Errors.is(err), "unknown growth id must fail structurally")
  Assert.equal(assert(err).code, "MON_PERSONAL_BAD_VALUE")
  local typed, typeErr = Compile.decodePersonal(buildPersonal({ type1 = 255 }), context())
  Assert.isNil(typed)
  Assert.isTrue(Errors.is(typeErr), "unknown type id must fail structurally")
end

return { tests = T }
