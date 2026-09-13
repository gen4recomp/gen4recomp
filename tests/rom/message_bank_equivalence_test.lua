-- Single-bank message records match the aggregate normalization exactly:
-- raw code units, tokens, text, zero-based IDs, and counts are identical for
-- the opening bank and representative control-heavy banks.

local Assert = require("tests.support.Assert")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

local T = {}

function T.single_bank_records_match_the_aggregate_normalization(romFs)
  Assert.equal(type(FieldMessageCompiler.newSession), "function", "per-bank production reuses one source session")
  local session = assert(FieldMessageCompiler.newSession(romFs))
  local whole = assert(FieldMessageCompiler.compile(romFs))
  local indexed = {}
  for _, bankId in ipairs(whole.index.bankIds) do
    indexed[bankId] = true
  end
  for _, bankId in ipairs({ 219, 445, MenuProtocol.STANDARD_MESSAGE_BANK, 542, 543 }) do
    Assert.isTrue(indexed[bankId] == true, "bank " .. bankId .. " stays selected")
    local one = assert(session:compileBank(bankId), "bank " .. bankId .. " compiles alone")
    Assert.equal(one.bankId, bankId)
    -- A one-bank result carries no corpus; read it as an open map to prove
    -- the field is absent.
    ---@type table<string, unknown>
    local oneShape = one
    Assert.isNil(oneShape.banks, "a one-bank result must not retain the whole corpus")
    local expected = assert(whole.banks[bankId], "the aggregate normalization holds bank " .. bankId)
    Assert.equal(one.bank.messageCount, expected.messageCount, "bank " .. bankId .. " keeps its count")
    Assert.equal(
      LuaWriter.encode(one.bank),
      LuaWriter.encode(expected),
      "bank " .. bankId .. " keeps raw code units, tokens, and text"
    )
    for index = 0, one.bank.messageCount - 1 do
      local message = one.bank.messages[index]
      Assert.notNil(message, "bank " .. bankId .. " message " .. index .. " exists")
      Assert.equal(message.id, index, "bank " .. bankId .. " message IDs stay zero-based")
      Assert.notNil(message.raw, "bank " .. bankId .. " message " .. index .. " keeps its raw units")
      Assert.notNil(message.tokens, "bank " .. bankId .. " message " .. index .. " keeps its tokens")
      Assert.equal(type(message.text), "string", "bank " .. bankId .. " message " .. index .. " keeps its text")
    end
  end
  session:close()
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
return suite
