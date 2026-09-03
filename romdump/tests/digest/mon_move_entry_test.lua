-- Move-entry decoding contract for the mon catalog compiler.
-- Fixture widths mirror pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- include/move.h `MoveTbl`: one 16-byte entry per move, with a u16 range, a
-- signed priority byte, and neutral trailing bytes. The producer verifies
-- every offset against the pinned decomp; the ROM suite anchors real move
-- values.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function compiler()
  return require("romdump.src.digest.MonCatalogCompiler")
end

local function u16le(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function i8(value)
  return string.char(value < 0 and (256 + value) or value)
end

-- Builds a synthetic 16-byte move entry from named fields.
local function buildMove(fields)
  local bytes = {
    u16le(fields.effect or 0),
    string.char(fields.category or 0),
    string.char(fields.power or 0),
    string.char(fields.moveType or 0),
    string.char(fields.accuracy or 0),
    string.char(fields.basePp or 0),
    string.char(fields.effectChance or 0),
    u16le(fields.range or 0),
    i8(fields.priority or 0),
    string.char(fields.flags or 0),
    string.char(fields.unknownC or 0),
    string.char(fields.contestType or 0),
    string.char(0),
    string.char(0),
  }
  local member = table.concat(bytes)
  assert(#member == 16, "move entry must be 16 bytes")
  return member
end

local function context()
  return { archive = "moves", memberId = 33 }
end

function T.normalizes_every_move_table_field_with_boundary_values()
  local Compile = compiler()
  local record = assert(Compile.decodeMove(
    buildMove({
      effect = 0,
      category = 1,
      power = 120,
      moveType = 12,
      accuracy = 100,
      basePp = 15,
      effectChance = 30,
      range = 1,
      priority = 0,
      flags = 0,
      unknownC = 2,
      contestType = 3,
    }),
    context()
  ))
  Assert.equal(record.power, 120)
  Assert.equal(record.accuracy, 100)
  Assert.equal(record.basePp, 15)
  Assert.equal(record.effectChance, 30)
  Assert.equal(record.priority, 0)
  Assert.notNil(record.effect, "effect identifier must survive")
  Assert.notNil(record.category, "damage category must survive")
  Assert.notNil(record.moveType, "type must survive")
  Assert.notNil(record.range, "range must survive")
end

function T.preserves_negative_priority_as_signed()
  local Compile = compiler()
  local record = assert(Compile.decodeMove(buildMove({ priority = -6 }), context()))
  Assert.equal(record.priority, -6)
  local fast = assert(Compile.decodeMove(buildMove({ priority = 5 }), context()))
  Assert.equal(fast.priority, 5)
end

function T.rejects_wrong_size_and_unresolvable_references()
  local Compile = compiler()
  local record, err = Compile.decodeMove(string.rep("\0", 15), context())
  Assert.isNil(record)
  Assert.isTrue(Errors.is(err), "size failure must be structured")
  Assert.equal(assert(err).code, "MON_MOVE_BAD_SIZE")
  local typed, typeErr = Compile.decodeMove(buildMove({ moveType = 255 }), context())
  Assert.isNil(typed)
  Assert.isTrue(Errors.is(typeErr), "unknown type id must fail structurally")
  Assert.equal(assert(typeErr).code, "MON_MOVE_BAD_VALUE")
end

return { tests = T }
