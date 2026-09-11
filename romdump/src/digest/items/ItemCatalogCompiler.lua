-- Source decode and semantic normalization of item data. item_data
-- members follow struct ItemData in include/item.h
-- (pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981): a u16
-- price, the hold-effect byte, and the packed bitfield u16 at offset 8
-- (naturalGiftType:5, prevent_toss:1, selectable:1, fieldPocket:4,
-- battlePocket:5 from the least-significant bit). Member selection follows
-- the ITEMNARC_PARAM column of src/item.c sItemNarcIds. Display text comes
-- through the existing message decoder at the src/message_format.c and
-- src/item.c banks (descriptions 221, names 222, indefinite names 223,
-- plural names 224, pocket names 226, berry names 251). TM/HM mapping
-- follows src/item.c TMHMGetMove over sTMHMMoves. No LOVE objects or
-- filesystem writes; callers publish through ItemCacheWriter.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local ItemSources = require("romdump.src.config.ItemSources")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ItemCache = require("libs.assets.src.ItemCache")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.reference.hgss.charmap")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local ItemPresentationCompiler = require("romdump.src.digest.items.ItemPresentationCompiler")

---@class ItemCatalogCompiler
local ItemCatalogCompiler = {}

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

local function contextLabel(context)
  return (context and context.archive or "?") .. " member " .. tostring(context and context.memberId)
end

local function checkSize(member, expected, code, context)
  if #member ~= expected then
    return nil,
      Errors.new(code, contextLabel(context) .. " is " .. #member .. " bytes, expected " .. expected, {
        archive = context.archive,
        memberId = context.memberId,
        size = #member,
        expected = expected,
      })
  end
  return true
end

---@param archive Narc
---@param memberId integer
---@param alias string
---@return string|nil, Errors.Error|nil
local function readMember(archive, memberId, alias)
  local member, err = archive:readMember(memberId)
  if not member then
    if Errors.is(err) then
      local failure = err --[[@as Errors.Error]]
      return nil, failure
    end
    return nil,
      Errors.new(
        "ITEM_MEMBER_MISSING",
        alias .. " member " .. memberId .. " is absent",
        { alias = alias, memberId = memberId }
      )
  end
  return member
end

-- Decode one 34-byte item_data member into the catalog-consumed facts: the
-- hold-effect byte driving friendship behavior, the toss/selectability
-- flags, and the field pocket. Price, use behavior, and party parameters
-- stay producer-side with the rest of ItemData.
---@param member string
---@param context Errors.Context|nil
---@return table<string, unknown>|nil, Errors.Error|nil
function ItemCatalogCompiler.decodeItemData(member, context)
  context = context or {}
  local ok, sizeErr = checkSize(member, ItemSources.ITEM_DATA_SIZE, "ITEM_DATA_BAD_SIZE", context)
  if not ok then
    return nil, sizeErr
  end
  local reader = BinaryReader.new(member, contextLabel(context))
  local word = reader:u16le(ItemSources.ITEM_DATA_BITFIELD_OFFSET)
  local tossBit = 2 ^ ItemSources.ITEM_DATA_PREVENT_TOSS_BIT
  local selectBit = 2 ^ ItemSources.ITEM_DATA_SELECTABLE_BIT
  local pocketShift = 2 ^ ItemSources.ITEM_DATA_FIELD_POCKET_SHIFT
  return {
    holdEffect = string.byte(member, ItemSources.ITEM_DATA_HOLD_EFFECT_OFFSET + 1),
    preventToss = math.floor(word / tossBit) % 2 == 1,
    selectable = math.floor(word / selectBit) % 2 == 1,
    fieldPocket = math.floor(word / pocketShift) % (ItemSources.ITEM_DATA_FIELD_POCKET_MASK + 1),
  }
end

---@param romFs RomFs
---@param alias string
---@return Narc|nil, Errors.Error|nil
local function openArchive(romFs, alias)
  local archive, err = romFs:openNarc(alias)
  if not archive then
    if Errors.is(err) then
      local failure = err --[[@as Errors.Error]]
      return nil, failure
    end
    return nil, Errors.new("ITEM_ARCHIVE_UNAVAILABLE", "item archive " .. alias .. " is unavailable", { alias = alias })
  end
  return archive
end

-- Decode one display-text bank into its message texts indexed by native id.
-- Banks are selected by ItemSources.messageBanks; every message must
-- tokenize.
---@param messagesNarc Narc
---@param bankId integer
---@param expectedCount integer
---@param label string
---@return table<integer, string>|nil, Errors.Error|nil
local function decodeTextBank(messagesNarc, bankId, expectedCount, label)
  local member, memberErr = messagesNarc:readMember(bankId)
  if not member then
    return nil, memberErr
  end
  local bank, bankErr = FieldMessageBank.decode(member, { label = label })
  if not bank then
    return nil, bankErr
  end
  if #bank.messages ~= expectedCount then
    return nil,
      Errors.new(
        "ITEM_TEXT_COUNT_MISMATCH",
        label .. " carries " .. #bank.messages .. " messages, expected " .. expectedCount,
        {
          bankId = bankId,
          count = #bank.messages,
          expected = expectedCount,
        }
      )
  end
  local texts = {}
  for index, message in ipairs(bank.messages) do
    local tokens, tokenErr = FieldMessageTokenizer.tokenize(message.raw, charmap, {})
    if not tokens then
      local failure = assert(tokenErr) --[[@as Errors.Error]]
      failure.context = failure.context or {}
      failure.context.bankId = bankId
      failure.context.messageId = index - 1
      return nil, failure
    end
    texts[index - 1] = FieldMessageText.tokensToText(tokens)
  end
  return texts
end

---@param texts table<integer, string>
---@param id integer
---@param what string
---@param context Errors.Context
---@return string|nil, Errors.Error|nil
local function requireText(texts, id, what, context)
  local text = texts[id]
  if type(text) ~= "string" or text == "" then
    return nil,
      Errors.new("ITEM_TEXT_MISSING", contextLabel(context) .. " has no " .. what .. " text for id " .. id, {
        archive = context.archive,
        memberId = context.memberId,
        id = id,
      })
  end
  return text
end

-- Compile the complete semantic catalog from a supported dump. Every source
-- item identity 0..536 becomes one source-independent definition; pocket,
-- TM/HM, mail, and berry cross-checks fail the build instead of emitting
-- inconsistent data.
---@param romFs RomFs
---@param opts table<string, unknown>|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function ItemCatalogCompiler.compileCatalog(romFs, opts)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  local language = ItemSources.versionLanguages[versionId]
  if language == nil then
    return nil,
      Errors.new("ITEM_VERSION_UNSUPPORTED", "item catalog has no language for version " .. tostring(versionId), {
        versionId = versionId,
      })
  end
  local itemData, err = openArchive(romFs, "item_data")
  if not itemData then
    return nil, err
  end
  local messages
  messages, err = openArchive(romFs, "messages")
  if not messages then
    return nil, err
  end
  local ok, result = pcall(function()
    local banks = ItemSources.messageBanks
    local counts = ItemSources.messageCounts
    local descriptions = must(decodeTextBank(messages, banks.description, counts.description, "item descriptions"))
    local names = must(decodeTextBank(messages, banks.name, counts.name, "item names"))
    local indefinites =
      must(decodeTextBank(messages, banks.nameIndefinite, counts.nameIndefinite, "item indefinite names"))
    local plurals = must(decodeTextBank(messages, banks.namePlural, counts.namePlural, "item plural names"))
    local pocketTexts = must(decodeTextBank(messages, banks.pocket, counts.pocket, "pocket names"))
    local berryTexts = must(decodeTextBank(messages, banks.berry, counts.berry, "berry names"))
    local pocketNames = {}
    for pocketId = 0, 7 do
      local pocketKey = must(ItemSources.pocketKeys[pocketId])
      pocketNames[pocketKey] =
        must(requireText(pocketTexts, pocketId, "pocket name", { archive = "messages", memberId = banks.pocket }))
    end
    local items = {}
    for nativeId = 0, 536 do
      local key = ItemSources.itemKeys[nativeId]
      if key == nil then
        error(
          Errors.new("ITEM_UNKNOWN_IDENTITY", "source item identity " .. nativeId .. " has no semantic key", {
            nativeId = nativeId,
          }),
          0
        )
      end
      if items[key] ~= nil then
        error(Errors.new("ITEM_DUPLICATE_KEY", "source item key " .. key .. " is defined twice", { key = key }), 0)
      end
      local memberId = ItemSources.itemDataMember(nativeId)
      local member = must(readMember(itemData, memberId, "item_data"))
      local decoded = must(ItemCatalogCompiler.decodeItemData(member, { archive = "item_data", memberId = memberId }))
      local pocketKey = ItemSources.pocketKeys[decoded.fieldPocket]
      if pocketKey == nil then
        error(
          Errors.new(
            "ITEM_UNKNOWN_POCKET",
            "source item identity " .. nativeId .. " selects unknown pocket " .. decoded.fieldPocket,
            {
              nativeId = nativeId,
              pocket = decoded.fieldPocket,
            }
          ),
          0
        )
      end
      local isMachine = nativeId >= ItemSources.FIRST_TM and nativeId <= ItemSources.LAST_HM
      if (pocketKey == "tmhm") ~= isMachine then
        error(
          Errors.new(
            "ITEM_POCKET_MISMATCH",
            "source item identity " .. nativeId .. " disagrees on TM/HM pocket membership",
            {
              nativeId = nativeId,
              pocket = pocketKey,
            }
          ),
          0
        )
      end
      local isBerry = nativeId >= ItemSources.FIRST_BERRY and nativeId <= ItemSources.LAST_BERRY
      if (pocketKey == "berries") ~= isBerry then
        error(
          Errors.new(
            "ITEM_POCKET_MISMATCH",
            "source item identity " .. nativeId .. " disagrees on berry pocket membership",
            {
              nativeId = nativeId,
              pocket = pocketKey,
            }
          ),
          0
        )
      end
      local isMail = nativeId >= ItemSources.FIRST_MAIL and nativeId <= ItemSources.LAST_MAIL
      if (pocketKey == "mail") ~= isMail then
        error(
          Errors.new(
            "ITEM_POCKET_MISMATCH",
            "source item identity " .. nativeId .. " disagrees on mail pocket membership",
            {
              nativeId = nativeId,
              pocket = pocketKey,
            }
          ),
          0
        )
      end
      local context = { archive = "item_data", memberId = memberId }
      local record = {
        nativeId = nativeId,
        name = must(requireText(names, nativeId, "item name", context)),
        nameIndefinite = must(requireText(indefinites, nativeId, "item indefinite name", context)),
        namePlural = must(requireText(plurals, nativeId, "item plural name", context)),
        description = descriptions[nativeId],
        pocket = pocketKey,
        preventToss = decoded.preventToss,
        selectable = decoded.selectable,
        isBall = ItemSources.ballItemIds[nativeId] == true,
        friendshipBoost = decoded.holdEffect == ItemSources.HOLD_EFFECT_FRIENDSHIP_UP,
        icon = key,
      }
      if type(record.description) ~= "string" then
        error(Errors.new("ITEM_TEXT_MISSING", "item " .. nativeId .. " has no description", { nativeId = nativeId }), 0)
      end
      if isMachine then
        local machine = must(ItemSources.machineMoves[nativeId - ItemSources.FIRST_TM])
        record.tmhmMoveNativeId = machine.nativeId
      end
      if isBerry then
        local berryName = must(requireText(berryTexts, nativeId - ItemSources.FIRST_BERRY, "berry name", context))
        record.berryNameSingular = berryName
        record.berryNamePlural = berryName
      end
      items[key] = record
    end
    local catalog = {
      schema = ItemCache.CATALOG_SCHEMA,
      version = { id = versionId, language = language },
      items = items,
      pockets = ItemCache.POCKETS,
      pocketNames = pocketNames,
    }
    must(ItemAssetSchema.assertCatalog(catalog))
    return catalog
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

-- Compile the complete publishable class: catalog plus the icon atlas
-- inputs, manifest, content hashes, and the completion marker. Every catalog
-- icon selector must resolve to a manifest entry before the bundle leaves
-- this function.
---@param romFs RomFs
---@param opts table<string, unknown>|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function ItemCatalogCompiler.compileAll(romFs, opts)
  opts = opts or {}
  local catalog, err = ItemCatalogCompiler.compileCatalog(romFs, opts)
  if not catalog then
    return nil, err
  end
  local icons, iconsErr = ItemPresentationCompiler.compileIcons(romFs)
  if not icons then
    return nil, iconsErr
  end
  local ok, result = pcall(function()
    must(ItemAssetSchema.assertIconManifest(icons.manifest))
    must(ItemAssetSchema.assertCatalogIcons(catalog, icons.manifest))
    local catalogHash = Hashing.hashLua(catalog)
    local iconPng = PngWriter.encode(icons.image.width, icons.image.height, icons.image.pixels)
    local iconHash = Hashing.sha1hex(iconPng)
    local index = {
      schema = ItemCache.INDEX_SCHEMA,
      version = catalog.version,
      catalogHash = catalogHash,
      iconHash = iconHash,
      catalog = ItemCache.catalogPath(),
      icons = ItemCache.iconImagePath(),
      iconManifest = ItemCache.iconManifestPath(),
    }
    must(ItemAssetSchema.assertIndex(index))
    local romSha1 = romFs:metadata().sha1
    local marker = ItemCache.marker(
      romSha1,
      Hashing.hashLua({
        catalog = catalogHash,
        icons = iconHash,
        iconManifest = Hashing.hashLua(icons.manifest),
      })
    )
    return {
      marker = marker,
      index = index,
      catalog = catalog,
      icons = icons.image,
      iconManifest = icons.manifest,
      iconPng = iconPng,
      provenance = {
        schema = "g4-item-provenance-v1",
        source = ItemSources.provenance,
        rom = { version = catalog.version.id, sha1 = romSha1 },
      },
    }
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

return ItemCatalogCompiler
