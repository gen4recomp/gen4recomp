-- Compiles source-referenced HGSS message banks into tokenized, lossless bank
-- artifacts. Each bank member is validated and decrypted by FieldMessageBank
-- (src/msgdata.c Decrypt1/Decrypt2) and then tokenized by
-- FieldMessageTokenizer. Bank selection comes from frozen map and script
-- references; static font configuration remains in FieldMessages.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local charmap = require("romdump.src.reference.hgss.charmap")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local ScriptMembers = require("romdump.src.reference.hgss.script_members")
local manifest = require("romdump.src.config.FieldMessages")

-- Oak's scripted opening introduction reads its dialogue directly from this
-- bank (game/hgss/src/newgame/OakIntroComposition.lua). The opening script bank is
-- not an ordinary field script bank, so it has no `sScriptBankMapping` entry
-- and no map header references it either; it must be listed explicitly.
local OAK_INTRO_MESSAGE_BANK = 219

-- The opposite protagonist's canonical name bank: the field
-- name-resolution boundary reads it through the player gender
-- (`BufferFriendsName`), so no map header or script bank entry references
-- it either; it must be listed explicitly.
local OPPOSITE_PROTAGONIST_NAME_BANK = 445

---@class FieldMessageCompiler.BankMessage
---@field id integer
---@field text string
---@field raw integer[]
---@field tokens FieldMessageText.Token[]

---@class FieldMessageCompiler.Bank
---@field schema string
---@field bankId integer
---@field messageCount integer
---@field key integer
---@field messages table<integer, FieldMessageCompiler.BankMessage>

---@class FieldMessageCompiler.Bundle
---@field marker string
---@field index FieldMessageCache.Index
---@field banks table<integer, FieldMessageCompiler.Bank>
---@field dependencies FieldMessageCompiler.Dependencies

---@class FieldMessageCompiler.BankBundle
---@field bankId integer
---@field bank FieldMessageCompiler.Bank
---@field marker string
---@field dependencies FieldMessageCompiler.Dependencies

---@class FieldMessageCompiler.Dependencies
---@field cacheFormat string
---@field charmapVersion string
---@field manifestSchema string
---@field versionRomSha1 string
---@field messageNarc FieldMessageCompiler.NarcIdentity

---@class FieldMessageCompiler.NarcIdentity
---@field symbol string
---@field alias string
---@field narcId integer
---@field fileId integer
---@field path string
---@field sha1 string

---@class FieldMessageCompiler.Session
---@field compileBank FieldMessageCompiler.CompileBank
---@field close FieldMessageCompiler.CloseSession

---@alias FieldMessageCompiler.CompileBank fun(self: FieldMessageCompiler.Session, bankId: integer): FieldMessageCompiler.BankBundle?, Errors.Error?
---@alias FieldMessageCompiler.CloseSession fun(self: FieldMessageCompiler.Session)

local FieldMessageCompiler = {}

-- The charmap catalog identity: a source-input hash (commit + input SHA-256),
-- not an implementation version. Implementation freshness belongs to the
-- producer fingerprint.
FieldMessageCompiler.CHARMAP_VERSION = "hgss-charmap-v1:"
  .. charmap.source.commit
  .. ":"
  .. charmap.source.inputs[1].sha256

local function must(value, err)
  if value == nil then
    error(err)
  end
  return value
end

local function loadSource(romFs, sha1hex)
  local archiveInfo = romFs:resolvedNarc("messages")
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", "messages NARC is unavailable", { name = "messages" })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc("messages"))
  return {
    archive = archive,
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
  }
end

local function compileBank(source, bankId, sha1hex)
  local memberBytes = must(source.archive:readMember(bankId))
  local bank = must(FieldMessageBank.decode(memberBytes, {
    label = "msgdata-member-" .. bankId,
    messageId = bankId,
  }))
  local memberSha1 = sha1hex(memberBytes)

  local messages = {}
  for index = 0, bank.messageCount - 1 do
    local message = bank.messages[index + 1]
    local tokens, tokenizeErr = FieldMessageTokenizer.tokenize(message.raw, charmap, {
      bankId = bankId,
      messageId = index,
    })
    if not tokens then
      tokenizeErr = assert(tokenizeErr)
      tokenizeErr.context = tokenizeErr.context or {}
      tokenizeErr.context.bankId = bankId
      tokenizeErr.context.messageId = index
      error(tokenizeErr)
    end
    messages[index] = {
      id = index,
      -- Modder-facing display text (GMM-style markers for controls); the
      -- token stream stays beside it as the lossless rendering source.
      text = FieldMessageText.tokensToText(tokens),
      raw = message.raw,
      tokens = tokens,
    }
  end

  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = bank.messageCount,
    key = bank.key,
    messages = messages,
  },
    memberSha1
end

---@param bankId unknown
local function checkBankId(bankId)
  assert(type(bankId) == "number" and bankId >= 0 and bankId % 1 == 0, "bankId must be a non-negative integer")
end

local function bankDependencies(source, romFs, bankId, memberSha1)
  return {
    cacheFormat = FieldMessageCache.FORMAT,
    charmapVersion = FieldMessageCompiler.CHARMAP_VERSION,
    manifestSchema = manifest.schema,
    versionRomSha1 = romFs:metadata().sha1,
    messageNarc = {
      symbol = source.archiveInfo.symbol,
      alias = source.archiveInfo.alias,
      narcId = source.archiveInfo.narcId,
      fileId = source.archiveInfo.fileId,
      path = source.archiveInfo.path,
      sha1 = source.archiveSha1,
    },
    ["bank" .. bankId .. "MemberSha1"] = memberSha1,
  }
end

-- Returns every source-referenced message bank in stable order. Map headers and
-- script members can both reference the same bank, so the set is deduplicated
-- before it is converted to the public array.
---@return integer[]
function FieldMessageCompiler.requiredBankIds()
  local set = {}
  for map in MapCatalog.all() do
    local bankId = assert(map.messageMemberId)
    assert(type(bankId) == "number" and bankId >= 0 and bankId % 1 == 0)
    set[bankId] = true
  end
  for _, bankId in pairs(ScriptMembers.banks) do
    assert(type(bankId) == "number" and bankId >= 0 and bankId % 1 == 0)
    set[bankId] = true
  end
  -- The source script corpus addresses this global list-menu bank through a
  -- runtime protocol constant rather than a map-header association.
  set[MenuProtocol.STANDARD_MESSAGE_BANK] = true
  set[MenuProtocol.START_MENU_MESSAGE_BANK] = true
  set[OAK_INTRO_MESSAGE_BANK] = true
  set[OPPOSITE_PROTAGONIST_NAME_BANK] = true
  local out = {}
  for bankId in pairs(set) do
    out[#out + 1] = bankId
  end
  table.sort(out)
  return out
end

local function _compile(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local source = loadSource(romFs, sha1hex)
  local bankIds = FieldMessageCompiler.requiredBankIds()

  local banks = {}
  local bankSha1s = {}
  for _, bankId in ipairs(bankIds) do
    banks[bankId], bankSha1s[bankId] = compileBank(source, bankId, sha1hex)
  end

  local index = {
    schema = FieldMessageCache.INDEX_SCHEMA,
    version = romFs:version(),
    bankIds = bankIds,
  }

  local dependencies = {
    cacheFormat = FieldMessageCache.FORMAT,
    charmapVersion = FieldMessageCompiler.CHARMAP_VERSION,
    manifestSchema = manifest.schema,
    versionRomSha1 = romFs:metadata().sha1,
    messageNarc = {
      symbol = source.archiveInfo.symbol,
      alias = source.archiveInfo.alias,
      narcId = source.archiveInfo.narcId,
      fileId = source.archiveInfo.fileId,
      path = source.archiveInfo.path,
      sha1 = source.archiveSha1,
    },
  }
  for _, bankId in ipairs(bankIds) do
    dependencies["bank" .. bankId .. "MemberSha1"] = bankSha1s[bankId]
  end

  local marker = FieldMessageCache.marker(romFs:metadata().sha1, hashLua(dependencies))
  return {
    marker = marker,
    index = index,
    banks = banks,
    dependencies = dependencies,
  }
end

---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string|nil
---@param hashLua? fun(value: unknown): string|nil
---@return FieldMessageCompiler.Bundle?
---@return Errors.Error?
function FieldMessageCompiler.compile(romFs, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, sha1hex, hashLua)
  if ok then
    return result, nil
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- A worker-private source session: the message archive and its immutable
-- identity are opened once, then each selected bank compiles through the
-- same one-bank normalization. The session retains no decoded or tokenized
-- bank: each returned bundle belongs to its caller and must be staged or
-- dropped before the next bank starts. Close is idempotent; a closed
-- session compiles nothing. The session never stages or publishes.
---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string|nil
---@param hashLua? fun(value: unknown): string|nil
---@return FieldMessageCompiler.Session
function FieldMessageCompiler.newSession(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "session requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local source = loadSource(romFs, sha1hex)
  local closed = false
  local session = {}
  ---@param bankId integer
  ---@return FieldMessageCompiler.BankBundle?
  ---@return Errors.Error?
  function session:compileBank(bankId)
    if closed then
      return nil
    end
    checkBankId(bankId)
    local ok, bank, memberSha1 = pcall(compileBank, source, bankId, sha1hex)
    if not ok then
      if Errors.is(bank) then
        return nil, bank --[[@as Errors.Error]]
      end
      error(bank, 0)
    end
    assert(bank ~= nil and memberSha1 ~= nil, "one-bank normalization must return its bank")
    local dependencies = bankDependencies(source, romFs, bankId, memberSha1)
    local marker = FieldMessageCache.marker(romFs:metadata().sha1, hashLua(dependencies))
    return {
      bankId = bankId,
      bank = bank,
      marker = marker,
      dependencies = dependencies,
    }
  end
  function session:close()
    closed = true
  end
  return session --[[@as FieldMessageCompiler.Session]]
end

return FieldMessageCompiler
