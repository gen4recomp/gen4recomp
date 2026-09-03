-- Level-up learnset decoding contract for the mon catalog compiler.
-- Fixture packing mirrors pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- `InitBoxMonMoveset` entry interpretation: each u16le entry carries the move id
-- in the low 9 bits and the level in the high 7 bits, terminated by 0xFFFF.
-- Same-level source order is semantic (initial-moveset selection consumes it),
-- so the compiler must preserve entry order exactly.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function compiler()
  return require("romdump.src.digest.MonCatalogCompiler")
end

local function entry(level, move)
  local packed = level * 512 + move
  return string.char(packed % 256, math.floor(packed / 256) % 256)
end

local TERMINATOR = string.char(0xFF, 0xFF)

local function context()
  return { archive = "level_up_moves", memberId = 152 }
end

function T.decodes_packed_entries_preserving_same_level_order()
  local Compile = compiler()
  local member = table.concat({
    entry(1, 33),
    entry(1, 45),
    entry(6, 213),
    entry(9, 200),
    entry(9, 201),
    TERMINATOR,
  })
  local moves = assert(Compile.decodeLearnset(member, context()))
  Assert.equal(#moves, 5)
  Assert.deepEqual(moves[1], { level = 1, move = 33 })
  Assert.deepEqual(moves[2], { level = 1, move = 45 })
  Assert.deepEqual(moves[3], { level = 6, move = 213 })
  Assert.deepEqual(moves[4], { level = 9, move = 200 })
  Assert.deepEqual(moves[5], { level = 9, move = 201 })
end

function T.stops_at_the_terminator_and_ignores_trailing_bytes()
  local Compile = compiler()
  local member = table.concat({ entry(1, 33), TERMINATOR, entry(50, 100), entry(1, 1) })
  local moves = assert(Compile.decodeLearnset(member, context()))
  Assert.equal(#moves, 1)
  Assert.deepEqual(moves[1], { level = 1, move = 33 })
end

function T.rejects_a_member_with_no_terminator()
  local Compile = compiler()
  local moves, err = Compile.decodeLearnset(table.concat({ entry(1, 33), entry(5, 45) }), context())
  Assert.isNil(moves)
  Assert.isTrue(Errors.is(err), "missing terminator must fail structurally")
  Assert.equal(assert(err).code, "MON_LEARNSET_NO_TERMINATOR")
  Assert.equal(assert(err).context.archive, "level_up_moves")
end

function T.rejects_truncated_entries_and_unknown_moves()
  local Compile = compiler()
  local truncated, truncatedErr = Compile.decodeLearnset(string.char(0x01), context())
  Assert.isNil(truncated)
  Assert.isTrue(Errors.is(truncatedErr), "odd-length member must fail structurally")
  Assert.equal(assert(truncatedErr).code, "MON_LEARNSET_BAD_SIZE")
  local unknown, unknownErr = Compile.decodeLearnset(table.concat({ entry(1, 511), TERMINATOR }), context())
  Assert.isNil(unknown)
  Assert.isTrue(Errors.is(unknownErr), "unknown move id must fail structurally")
  Assert.equal(assert(unknownErr).code, "MON_LEARNSET_BAD_VALUE")
end

return { tests = T }
