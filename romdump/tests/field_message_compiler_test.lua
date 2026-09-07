-- Deterministic message-bank compilation and cache readiness/rollback using a
-- synthetic encrypted bank member.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local ScriptMembers = require("romdump.src.reference.hgss.script_members")
local FieldMessages = require("romdump.src.config.FieldMessages")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

local T = {}

local function sourceReferenceBankIds()
  local ids = {}
  for map in MapCatalog.all() do
    ids[assert(map.messageMemberId)] = true
  end
  for _, bankId in pairs(ScriptMembers.banks) do
    ids[assert(bankId)] = true
  end
  ids[MenuProtocol.STANDARD_MESSAGE_BANK] = true
  -- Oak's scripted opening introduction reads directly from this bank; see
  -- FieldMessageCompiler's OAK_INTRO_MESSAGE_BANK.
  ids[219] = true
  -- The friend-name buffer command reads the opposite protagonist's name
  -- from this bank through the player gender; see FieldMessageCompiler's
  -- opposite-protagonist name bank.
  ids[445] = true
  local out = {}
  for bankId in pairs(ids) do
    out[#out + 1] = bankId
  end
  table.sort(out)
  return out
end

local function fixture()
  local messages = {
    { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF },
    {
      0x013A,
      0x0156,
      0x0153,
      0x014A,
      0x0149,
      0x0157,
      0x0157,
      0x0153,
      0x0156,
      0x01DE,
      0xFFFE,
      0x0103,
      0x0002,
      0x0000,
      0x0000,
      0xFFFF,
    },
  }
  local members = {
    [542] = FieldMessageBank.encodeForTests(messages, 0x4F2F),
    [543] = FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0x0131, 0x0148, 0x01DE, 0xFFFF },
    }, 0xB447),
  }
  local function generatedMember(bankId)
    return FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
    }, 0x4000 + bankId)
  end
  -- Bank 191 (the standard menu-items bank) and bank 219 (Oak's opening
  -- introduction) are both required regardless of the map/script reference
  -- set; serve them the same way, one short message each with its own key.
  members[191] = FieldMessageBank.encodeForTests({
    { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
  }, 0xD191)
  members[219] = FieldMessageBank.encodeForTests({
    { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
  }, 0xD219)
  local romFs = {
    resolvedNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function(_, fileId)
      Assert.equal(fileId, 77)
      return "archive-bytes"
    end,
    openNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return {
        readMember = function(_, memberId)
          members[memberId] = members[memberId] or generatedMember(memberId)
          return members[memberId]
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  ---@cast romFs RomFs
  local function sha1(bytes)
    for bankId, memberBytes in pairs(members) do
      if bytes == memberBytes then
        return string.format("member-%d-sha", bankId)
      end
    end
    return "archive-sha"
  end
  return romFs, sha1, function()
    return "dependency-sha"
  end
end

function T.compiles_tokenized_lossless_banks()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.deepEqual(bundle.index.bankIds, sourceReferenceBankIds())
  Assert.equal(bundle.index.schema, FieldMessageCache.INDEX_SCHEMA)

  local bank = bundle.banks[542]
  Assert.equal(bank.schema, FieldMessageCache.SCHEMA)
  Assert.equal(bank.bankId, 542)
  Assert.equal(bank.messageCount, 2)
  Assert.isNil(bank.source, "bank source identity lives in the dependency record")
  Assert.deepEqual(bank.messages[0].raw, { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF })
  -- The asset carries the modder-facing display text beside the tokens.
  Assert.equal(bank.messages[0].text, "Wow, ")
  Assert.equal(bank.messages[1].text, "Professor {STRVAR_1 3, 0, 0}")
  Assert.equal(bank.messages[1].tokens[11].kind, "substitution")
  Assert.equal(bank.messages[1].tokens[11].control, 0x0103)
  Assert.deepEqual(bank.messages[1].tokens[11].args, { 0x0000, 0x0000 })
  Assert.equal(bank.messages[1].tokens[#bank.messages[1].tokens].kind, "eos")

  Assert.equal(bundle.dependencies.messageNarc.narcId, 27)
  Assert.equal(bundle.dependencies.bank542MemberSha1, "member-542-sha")
  Assert.equal(bundle.dependencies.bank543MemberSha1, "member-543-sha")
  for _, bankId in ipairs(bundle.index.bankIds) do
    Assert.equal(bundle.dependencies["bank" .. bankId .. "MemberSha1"], "member-" .. bankId .. "-sha")
  end
  Assert.equal(bundle.marker, "field-message-cache-v3:rom-sha:dependency-sha")
end

function T.source_references_form_one_sorted_bank_set()
  Assert.equal(
    type(FieldMessageCompiler.requiredBankIds),
    "function",
    "the compiler must expose source-derived bank selection"
  )
  local required = FieldMessageCompiler.requiredBankIds()
  local expected = {}
  for map in MapCatalog.all() do
    expected[assert(map.messageMemberId)] = true
  end
  for _, bankId in pairs(ScriptMembers.banks) do
    expected[assert(bankId)] = true
  end
  expected[MenuProtocol.STANDARD_MESSAGE_BANK] = true
  -- Oak's scripted opening introduction reads directly from this bank; see
  -- FieldMessageCompiler's OAK_INTRO_MESSAGE_BANK.
  expected[219] = true
  -- The friend-name buffer command reads the opposite protagonist's name
  -- from this bank through the player gender; see FieldMessageCompiler's
  -- opposite-protagonist name bank.
  expected[445] = true

  Assert.deepEqual(required, sourceReferenceBankIds())

  local seen = {}
  for index, bankId in ipairs(required) do
    Assert.equal(type(bankId), "number")
    Assert.isNil(seen[bankId], "a source bank must be emitted only once")
    if index > 1 then
      Assert.isTrue(required[index - 1] < bankId, "source bank IDs must be ascending")
    end
    seen[bankId] = true
  end
  for bankId in pairs(expected) do
    Assert.isTrue(seen[bankId], "every map/script message bank must be selected: " .. bankId)
  end
  local expectedCount = 0
  for _ in pairs(expected) do
    expectedCount = expectedCount + 1
  end
  Assert.equal(#required, expectedCount)

  local repeated = FieldMessageCompiler.requiredBankIds()
  Assert.isFalse(required == repeated, "each selection call must return a fresh array")
  Assert.deepEqual(repeated, required)
end

function T.route_29_bank_is_published_and_served_by_the_provider()
  local route29 = MapCatalog.require("MAP_ROUTE_29")
  Assert.equal(route29.messageMemberId, 373)

  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local occurrences = 0
  for _, bankId in ipairs(bundle.index.bankIds) do
    if bankId == route29.messageMemberId then
      occurrences = occurrences + 1
    end
  end
  Assert.equal(occurrences, 1, "Route 29's message bank must be indexed exactly once")

  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMessageCacheWriter.write(cache, bundle)
  local provider = assert(FieldMessageProvider.new(cache))
  local bank, err = provider:acquireBank(route29.messageMemberId)
  Assert.notNil(bank, err and err.message or "Route 29 message bank must be generated")
  Assert.equal(assert(bank).schema, FieldMessageCache.SCHEMA)
  Assert.equal(assert(bank).bankId, route29.messageMemberId)
  Assert.equal(provider:stats().loads, 1)
  provider:releaseBank(route29.messageMemberId)
end

function T.message_manifest_has_no_selected_bank_policy()
  Assert.isNil(FieldMessages.banks, "message bank selection must not live in the config manifest")
  Assert.equal(
    type(FieldMessageCompiler.requiredBankIds),
    "function",
    "message bank selection must be derived by the compiler"
  )
end

function T.compilation_is_deterministic()
  local romFs, sha1, hashLua = fixture()
  local a = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local b = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.equal(LuaWriter.encode(a.index), LuaWriter.encode(b.index))
  Assert.equal(LuaWriter.encode(a.banks[542]), LuaWriter.encode(b.banks[542]))
  Assert.equal(a.marker, b.marker)
end

function T.writer_commits_marker_last_and_reads_back()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMessageCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldMessageCache.isReady(cache, bundle.marker))
  Assert.isFalse(FieldMessageCache.isReady(cache, bundle.marker .. "-stale"))
  local loaded = assert(cache:loadLua(FieldMessageCache.bankPath(542)))
  Assert.equal(loaded.bankId, 542)
  Assert.equal(loaded.schema, FieldMessageCache.SCHEMA)
end

function T.writer_failure_invalidates_the_class()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("banks/0543.lua", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  Assert.throws(function()
    FieldMessageCacheWriter.write(cache, bundle)
  end)
  Assert.isFalse(cache:exists(FieldMessageCache.dir()))
end

function T.failed_rebuild_preserves_the_previous_messages()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldMessageCacheWriter.write(cache, first)
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("banks/0543.lua", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  second.marker = FieldMessageCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldMessageCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldMessageCache.isReady(cache, first.marker), "the previous messages remain ready")
  Assert.equal(cache:read(FieldMessageCache.markerPath()), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-messages"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldMessageCacheWriter.write(cache, second)
  Assert.isTrue(FieldMessageCache.isReady(cache, second.marker), "a retry publishes the new messages")
end

function T.unmapped_glyph_fails_compilation_with_context()
  local messages = { { 0x0001, 0xFFFF } } -- kana code outside the charmap
  local member = FieldMessageBank.encodeForTests(messages, 0x1234)
  local function validMember(bankId)
    return FieldMessageBank.encodeForTests({ { 0x012F, 0xFFFF } }, 0x5000 + bankId)
  end
  local romFs = {
    _version = "heartgold",
    _metadata = { sha1 = "rom-sha" },
    resolvedNarc = function()
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function()
      return "archive-bytes"
    end,
    openNarc = function()
      return {
        readMember = function(_, memberId)
          if memberId == 542 then
            return member
          end
          return validMember(memberId)
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  } --[[@as RomFs]]
  local bundle, err = FieldMessageCompiler.compile(romFs --[[@as RomFs]])
  Assert.isNil(bundle, "expected a failure result")
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "MESSAGE_GLYPH_UNMAPPED")
  Assert.equal(assert(err).context.bankId, 542)
  Assert.equal(assert(err).context.messageId, 0)
end

return { tests = T }
