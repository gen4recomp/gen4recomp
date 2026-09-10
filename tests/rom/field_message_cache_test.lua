-- ROM-conformance checks for message/font facts that consume the prepared
-- generated cache. Structural facts only; no retail message text is asserted.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldFontCompiler = require("romdump.src.digest.ui.FieldFontCompiler")
local charmap = require("romdump.src.reference.hgss.charmap")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

local T = {}

function T.known_target_messages_format_with_prepared_tokens(_, version)
  -- The known target messages must pass through the actual provider
  -- formatting path (compiled bank cache -> template -> substitution
  -- resolution -> prepared tokens) without an unsupported-control fault:
  -- glyphs carry their effective colorIndex, and the indicator survives with
  -- field 0. A layout/controller-only test cannot prove this: the provider is
  -- the playback boundary that validates and prepares printer controls.
  local cache = CacheFs.forVersion(version)
  local def = assert(cache:loadLua("data/generated/field/font/font-0.lua"))
  local provider = assert(FieldMessageProvider.new(cache))
  provider:acquireBank(543)
  local resolvers = {
    [0x0100] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
    [0x0101] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
    [0x0103] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
  }
  for _, messageId in ipairs({ 8, 9, 27, 92 }) do
    local template = assert(provider:get(543, messageId))
    local formatted = assert(provider:format(template, { playerName = "GOLD" }, resolvers))
    Assert.isFalse(formatted.hadUnresolvedSubstitutions)
    local indicator
    for _, token in ipairs(formatted.tokens) do
      if token.kind == "glyph" then
        Assert.equal(token.colorIndex, 0, "bank 543 message " .. messageId .. " glyph stays default color")
      elseif token.control == FieldMessageText.YESNO then
        indicator = token
      end
    end
    Assert.notNil(indicator, "message " .. messageId .. " keeps its indicator token")
    Assert.equal(indicator.kind, "focus_indicator")
    Assert.equal(indicator.control, FieldMessageText.YESNO)
    Assert.deepEqual(indicator.args, { 0 })
  end
  for _, messageId in ipairs({ 79, 80 }) do
    local template = assert(provider:get(543, messageId))
    local formatted = assert(provider:format(template, { playerName = "GOLD" }, resolvers))
    Assert.isFalse(formatted.hadUnresolvedSubstitutions)
    local current = 0
    local highlighted = 0
    local afterSpan = 0
    for _, token in ipairs(formatted.tokens) do
      if token.kind == "style" and token.control == FieldMessageText.COLOR then
        current = token.args[1]
      elseif token.kind == "glyph" then
        Assert.equal(token.colorIndex, current, "message " .. messageId .. " glyph carries the active color")
        if current == 1 then
          highlighted = highlighted + 1
        elseif highlighted > 0 then
          afterSpan = afterSpan + 1
        end
      end
    end
    Assert.isTrue(highlighted > 0, "message " .. messageId .. " highlights its color span")
    Assert.isTrue(afterSpan > 0, "message " .. messageId .. " returns to default color after the span")
  end
  provider:releaseBank(543)
end

function T.artifact_text_round_trips_through_marker_parse(romFs, version)
  -- The published text form is canonical: parsing a bank message's text with
  -- the compiled font charmap and rendering it back yields the same string.
  local messages = assert(romFs:openNarc("messages"))
  local fontDef = {
    charmap = assert(CacheFs.forVersion(version):loadLua("data/generated/field/font/font-0.lua")).charmap,
  }
  local samples = { [542] = { 0, 1, 4, 5 }, [543] = { 0, 5, 14, 18, 93, 97 } }
  for bankId, messageIds in pairs(samples) do
    local bank = assert(FieldMessageBank.decode(messages:readMember(bankId), {}))
    for _, messageId in ipairs(messageIds) do
      local tokens = assert(FieldMessageTokenizer.tokenize(bank.messages[messageId + 1].raw, charmap, {}))
      local text = FieldMessageText.tokensToText(tokens)
      local reparsed = assert(FieldMessageText.parse(text, fontDef))
      Assert.equal(
        FieldMessageText.tokensToText(reparsed),
        text,
        string.format("bank %d message %d round trip", bankId, messageId)
      )
    end
  end
end

function T.compiled_cache_artifacts_are_ready_and_stable(romFs, version)
  local cache = CacheFs.forVersion(version)
  local function archiveSha(alias)
    local info = assert(romFs:resolvedNarc(alias))
    return require("romdump.src.digest.Hashing").sha1hex(assert(romFs:read(info.fileId)))
  end
  local function memberSha(alias, memberId)
    return require("romdump.src.digest.Hashing").sha1hex(assert(assert(romFs:openNarc(alias)):readMember(memberId)))
  end
  -- Deterministic markers: compilers run with real hashes, so the marker
  -- depends only on ROM contents and the checked-in compiler versions.
  local messageBundle = assert(FieldMessageCompiler.compile(romFs))
  local menuBankSelected = false
  for _, bankId in ipairs(messageBundle.index.bankIds) do
    if bankId == MenuProtocol.STANDARD_MESSAGE_BANK then
      menuBankSelected = true
    end
  end
  Assert.isTrue(menuBankSelected, "the standard menu bank must be selected for the derived cache")
  Assert.isTrue(FieldMessageCache.isReady(cache, messageBundle.marker))
  Assert.equal(FieldMessageCache.bankPath(542), "data/generated/field/messages/banks/0542.lua")
  local fontBundle = assert(FieldFontCompiler.compile(romFs))
  Assert.isTrue(require("romdump.src.digest.ui.FieldFontCacheWriter").isReady(cache, fontBundle.marker))
  Assert.isNil(fontBundle.fonts[0].font.source)
  Assert.equal(fontBundle.dependencies.glyphMembers[1].sha1, memberSha("font", 0))
  Assert.equal(fontBundle.dependencies.paletteMemberSha1, memberSha("font", 7))
  Assert.equal(messageBundle.dependencies.messageNarc.sha1, archiveSha("messages"))
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
