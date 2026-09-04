-- Source decode and semantic normalization of non-image mon data.
-- Personal members follow include/pokemon_types_def.h BASE_STATS widths
-- (pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981):
-- six base stats, two types, catch rate, base experience, packed EV yields,
-- two held items, gender/egg-cycle/friendship/growth fields, two egg groups,
-- two u8 abilities, the Great Marsh rate, packed color/flip metadata, and
-- four TM/HM compatibility words. Level-up learnsets follow
-- src/pokemon.c InitBoxMonMoveset/LoadLevelUpLearnset_HandleAlternateForm
-- packing (move id in the low 9 bits, level in the high 7, 0xFFFF
-- terminator). Move entries follow include/move.h MoveTbl widths with the
-- src/move.c MoveAttr field names. Evolutions follow the struct Evolution
-- slot layout with src/pokemon.c evolution-check parameter semantics.
-- Personal/learnset member selection follows ResolveMonForm; evolution
-- members resolve by plain species id (LoadMonEvolutionTable). Display text
-- comes through the existing message decoder at the src/message_format.c
-- banks (species 237, move names 750, move descriptions 749, ability names
-- 720, ability descriptions 722). No LOVE objects or filesystem writes;
-- callers publish through MonCacheWriter.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local MonSources = require("romdump.src.config.MonSources")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.reference.hgss.charmap")
local Hashing = require("romdump.src.digest.Hashing")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("libs.assets.src.PngWriter")
local MonPresentationCompiler = require("romdump.src.digest.MonPresentationCompiler")

---@class MonCatalogCompiler
local MonCatalogCompiler = {}

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

---@param keys table<integer|string, string>
---@param id integer
---@param what string
---@param code string
---@param context Errors.Context
---@return string|nil, Errors.Error|nil
local function lookupKey(keys, id, what, code, context)
  local key = keys[id]
  if key == nil then
    return nil,
      Errors.new(code, contextLabel(context) .. " references unknown " .. what .. " id " .. id, {
        archive = context.archive,
        memberId = context.memberId,
        id = id,
      })
  end
  return key
end

-- Decode one 0x2C personal member into normalized source values. Enum
-- identities stay numeric here; the catalog assembly maps them to semantic
-- keys so one failed lookup names the offending member.
---@param member string
---@param context Errors.Context|nil
---@return table<string, unknown>|nil, Errors.Error|nil
function MonCatalogCompiler.decodePersonal(member, context)
  context = context or {}
  local ok, sizeErr = checkSize(member, MonSources.PERSONAL_SIZE, "MON_PERSONAL_BAD_SIZE", context)
  if not ok then
    return nil, sizeErr
  end
  local reader = BinaryReader.new(member, contextLabel(context))
  local stats = {
    hp = reader:u8(0),
    attack = reader:u8(1),
    defense = reader:u8(2),
    speed = reader:u8(3),
    specialAttack = reader:u8(4),
    specialDefense = reader:u8(5),
  }
  local type1, type2 = reader:u8(6), reader:u8(7)
  if MonSources.typeKeys[type1] == nil or MonSources.typeKeys[type2] == nil then
    return nil,
      Errors.new("MON_PERSONAL_BAD_VALUE", contextLabel(context) .. " has an unknown type", {
        archive = context.archive,
        memberId = context.memberId,
        type1 = type1,
        type2 = type2,
      })
  end
  local evWord = reader:u16le(10)
  if evWord >= 4096 then
    return nil,
      Errors.new("MON_PERSONAL_BAD_VALUE", contextLabel(context) .. " has reserved EV bits set", {
        archive = context.archive,
        memberId = context.memberId,
        evWord = evWord,
      })
  end
  local growthCurve = reader:u8(19)
  if MonSources.growthKeys[growthCurve] == nil then
    return nil,
      Errors.new("MON_PERSONAL_BAD_VALUE", contextLabel(context) .. " has an unknown growth curve", {
        archive = context.archive,
        memberId = context.memberId,
        growthCurve = growthCurve,
      })
  end
  local eggGroup1, eggGroup2 = reader:u8(20), reader:u8(21)
  if MonSources.eggGroupKeys[eggGroup1] == nil or MonSources.eggGroupKeys[eggGroup2] == nil then
    return nil,
      Errors.new("MON_PERSONAL_BAD_VALUE", contextLabel(context) .. " has an unknown egg group", {
        archive = context.archive,
        memberId = context.memberId,
        eggGroup1 = eggGroup1,
        eggGroup2 = eggGroup2,
      })
  end
  local ability1, ability2 = reader:u8(22), reader:u8(23)
  if ability1 > MonSources.NUM_ABILITIES or ability2 > MonSources.NUM_ABILITIES then
    return nil,
      Errors.new("MON_PERSONAL_BAD_VALUE", contextLabel(context) .. " has an unknown ability", {
        archive = context.archive,
        memberId = context.memberId,
        ability1 = ability1,
        ability2 = ability2,
      })
  end
  local colorFlip = reader:u8(25)
  local pad = reader:u16le(26)
  if pad ~= 0 then
    return nil,
      Errors.new("MON_PERSONAL_BAD_VALUE", contextLabel(context) .. " has nonzero reserved bytes", {
        archive = context.archive,
        memberId = context.memberId,
        pad = pad,
      })
  end
  local tmhm = {}
  for word = 0, 3 do
    local bits = reader:u32le(28 + word * 4)
    for bit = 0, 31 do
      local machine = word * 32 + bit
      if machine > 99 then
        if bits % 2 == 1 then
          return nil,
            Errors.new("MON_PERSONAL_BAD_VALUE", contextLabel(context) .. " has reserved tmhm bits set", {
              archive = context.archive,
              memberId = context.memberId,
              machine = machine,
            })
        end
      elseif bits % 2 == 1 then
        tmhm[#tmhm + 1] = machine
      end
      bits = math.floor(bits / 2)
    end
  end
  return {
    baseStats = stats,
    types = { type1, type2 },
    catchRate = reader:u8(8),
    baseExpYield = reader:u8(9),
    evYield = {
      hp = evWord % 4,
      attack = math.floor(evWord / 4) % 4,
      defense = math.floor(evWord / 16) % 4,
      speed = math.floor(evWord / 64) % 4,
      specialAttack = math.floor(evWord / 256) % 4,
      specialDefense = math.floor(evWord / 1024) % 4,
    },
    heldItems = { reader:u16le(12), reader:u16le(14) },
    genderRatio = reader:u8(16),
    eggCycles = reader:u8(17),
    baseFriendship = reader:u8(18),
    growthCurve = growthCurve,
    eggGroups = { eggGroup1, eggGroup2 },
    abilities = { ability1, ability2 },
    marshRate = reader:u8(24),
    color = colorFlip % 128,
    flip = colorFlip >= 128,
    tmhm = tmhm,
  }
end

-- Decode one level-up learnset member into ordered { level, move } records.
-- Source order (including repeated levels) is semantic: initial-moveset
-- selection consumes entries positionally, so entries are never re-sorted.
---@param member string
---@param context Errors.Context|nil
---@return table<integer, table<string, unknown>>|nil, Errors.Error|nil
function MonCatalogCompiler.decodeLearnset(member, context)
  context = context or {}
  if #member == 0 or #member % 2 ~= 0 then
    return nil,
      Errors.new("MON_LEARNSET_BAD_SIZE", contextLabel(context) .. " has a truncated learnset entry", {
        archive = context.archive,
        memberId = context.memberId,
        size = #member,
      })
  end
  local reader = BinaryReader.new(member, contextLabel(context))
  local moves = {}
  local count = #member / 2
  local terminated = false
  for index = 0, count - 1 do
    local packed = reader:u16le(index * 2)
    if packed == MonSources.LEARNSET_TERMINATOR then
      terminated = true
      break
    end
    local move = packed % (MonSources.LEARNSET_MOVE_MASK + 1)
    local level = math.floor(packed / (2 ^ MonSources.LEARNSET_LEVEL_SHIFT))
    if move < 1 or move > MonSources.NUM_MOVES then
      return nil,
        Errors.new("MON_LEARNSET_BAD_VALUE", contextLabel(context) .. " references unknown move " .. move, {
          archive = context.archive,
          memberId = context.memberId,
          move = move,
        })
    end
    moves[#moves + 1] = { level = level, move = move }
  end
  if not terminated then
    return nil,
      Errors.new("MON_LEARNSET_NO_TERMINATOR", contextLabel(context) .. " has no 0xFFFF terminator", {
        archive = context.archive,
        memberId = context.memberId,
      })
  end
  return moves
end

-- Decode one 16-byte MoveTbl entry. Field names follow the src/move.c
-- MoveAttr vocabulary; the trailing word is verified zero padding on
-- supported dumps.
---@param entry string
---@param context Errors.Context|nil
---@return table<string, unknown>|nil, Errors.Error|nil
function MonCatalogCompiler.decodeMove(entry, context)
  context = context or {}
  local ok, sizeErr = checkSize(entry, MonSources.MOVE_ENTRY_SIZE, "MON_MOVE_BAD_SIZE", context)
  if not ok then
    return nil, sizeErr
  end
  local reader = BinaryReader.new(entry, contextLabel(context))
  local moveType = reader:u8(4)
  if MonSources.typeKeys[moveType] == nil then
    return nil,
      Errors.new("MON_MOVE_BAD_VALUE", contextLabel(context) .. " has an unknown type", {
        archive = context.archive,
        memberId = context.memberId,
        moveType = moveType,
      })
  end
  local category = reader:u8(2)
  if MonSources.damageCategories[category] == nil then
    return nil,
      Errors.new("MON_MOVE_BAD_VALUE", contextLabel(context) .. " has an unknown category", {
        archive = context.archive,
        memberId = context.memberId,
        category = category,
      })
  end
  local priority = reader:u8(10)
  if priority >= 128 then
    priority = priority - 256
  end
  local reserved = reader:u16le(14)
  if reserved ~= 0 then
    return nil,
      Errors.new("MON_MOVE_BAD_VALUE", contextLabel(context) .. " has nonzero reserved bytes", {
        archive = context.archive,
        memberId = context.memberId,
        reserved = reserved,
      })
  end
  return {
    effect = reader:u16le(0),
    category = category,
    power = reader:u8(3),
    moveType = moveType,
    accuracy = reader:u8(5),
    basePp = reader:u8(6),
    effectChance = reader:u8(7),
    range = reader:u16le(8),
    priority = priority,
    flags = reader:u8(11),
    unknownC = reader:u8(12),
    contestType = reader:u8(13),
  }
end

-- Decode one 44-byte evolution member into raw slots. Zero-method slots
-- are omitted; every other slot must name a known method and target.
---@param member string
---@param context Errors.Context|nil
---@return table<integer, table<string, unknown>>|nil, Errors.Error|nil
function MonCatalogCompiler.decodeEvolution(member, context)
  context = context or {}
  local ok, sizeErr = checkSize(member, MonSources.EVO_MEMBER_SIZE, "MON_EVO_BAD_SIZE", context)
  if not ok then
    return nil, sizeErr
  end
  local reader = BinaryReader.new(member, contextLabel(context))
  local slots = {}
  for slot = 0, MonSources.EVO_SLOTS - 1 do
    local method = reader:u16le(slot * 6)
    local param = reader:u16le(slot * 6 + 2)
    local target = reader:u16le(slot * 6 + 4)
    if method ~= 0 then
      if MonSources.evolutionMethods[method] == nil then
        return nil,
          Errors.new("MON_EVO_BAD_VALUE", contextLabel(context) .. " names unknown evolution method " .. method, {
            archive = context.archive,
            memberId = context.memberId,
            method = method,
          })
      end
      slots[#slots + 1] = { method = method, param = param, target = target }
    end
  end
  local pad = reader:u16le(MonSources.EVO_SLOTS * 6)
  if pad ~= 0 then
    return nil,
      Errors.new("MON_EVO_BAD_VALUE", contextLabel(context) .. " has nonzero reserved bytes", {
        archive = context.archive,
        memberId = context.memberId,
        pad = pad,
      })
  end
  return slots
end

-- Decode one growth-table member (101 u32 cumulative experience values for
-- levels 0..100) into the 100 level values runtime creation consumes.
---@param member string
---@param context Errors.Context|nil
---@return table<integer, integer>|nil, Errors.Error|nil
function MonCatalogCompiler.decodeGrowth(member, context)
  context = context or {}
  local expected = MonSources.GROWTH_ENTRY_COUNT * 4
  if #member ~= expected then
    return nil,
      Errors.new("MON_GROWTH_BAD_SIZE", contextLabel(context) .. " is " .. #member .. " bytes, expected " .. expected, {
        archive = context.archive,
        memberId = context.memberId,
        size = #member,
        expected = expected,
      })
  end
  local reader = BinaryReader.new(member, contextLabel(context))
  local curve = {}
  for level = 1, 100 do
    curve[level] = reader:u32le(level * 4)
  end
  return curve
end

-- Decode one display-text bank into its message texts indexed by native id.
-- Banks are selected by MonSources.messageBanks (src/message_format.c call
-- sites, content-verified for descriptions); every message must tokenize.
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
        "MON_TEXT_COUNT_MISMATCH",
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
      Errors.new("MON_TEXT_MISSING", contextLabel(context) .. " has no " .. what .. " text for id " .. id, {
        archive = context.archive,
        memberId = context.memberId,
        id = id,
      })
  end
  return text
end

-- Normalize one raw evolution slot into its semantic record. Level-like
-- parameters stay integers; item/move/species parameters become semantic
-- keys; fixed-threshold and trigger methods carry no parameter. Parameter
-- semantics follow the src/pokemon.c evolution checks.
local function normalizeEvolution(slot, context)
  local methodKey = must(MonSources.evolutionMethods[slot.method])
  local targetKey, targetErr = lookupKey(MonSources.speciesKeys, slot.target, "species", "MON_EVO_BAD_VALUE", context)
  if not targetKey then
    return nil, targetErr
  end
  if slot.target < 1 or slot.target > MonSources.MAX_SPECIES then
    return nil,
      Errors.new("MON_EVO_BAD_VALUE", contextLabel(context) .. " evolves into reserved species " .. slot.target, {
        archive = context.archive,
        memberId = context.memberId,
        target = slot.target,
      })
  end
  local entry = { method = methodKey, target = targetKey, form = 0 }
  local param = slot.param
  if
    methodKey == "level"
    or methodKey == "level_atk_gt_def"
    or methodKey == "level_atk_eq_def"
    or methodKey == "level_atk_lt_def"
    or methodKey == "level_pid_lo"
    or methodKey == "level_pid_hi"
    or methodKey == "level_ninjask"
    or methodKey == "level_shedinja"
    or methodKey == "level_male"
    or methodKey == "level_female"
  then
    if param < 1 or param > 100 then
      return nil,
        Errors.new("MON_EVO_BAD_VALUE", contextLabel(context) .. " carries an out-of-range evolution level", {
          archive = context.archive,
          memberId = context.memberId,
          method = methodKey,
          param = param,
        })
    end
    entry.level = param
  elseif
    methodKey == "trade_item"
    or methodKey == "stone"
    or methodKey == "stone_male"
    or methodKey == "stone_female"
    or methodKey == "item_day"
    or methodKey == "item_night"
  then
    local itemKey, itemErr = lookupKey(MonSources.itemKeys, param, "item", "MON_EVO_BAD_VALUE", context)
    if not itemKey then
      return nil, itemErr
    end
    entry.item = itemKey
  elseif methodKey == "beauty" then
    entry.threshold = param
  elseif methodKey == "has_move" then
    local moveKey, moveErr = lookupKey(MonSources.moveKeys, param, "move", "MON_EVO_BAD_VALUE", context)
    if not moveKey then
      return nil, moveErr
    end
    entry.move = moveKey
  elseif methodKey == "other_party_mon" then
    local speciesKey, speciesErr = lookupKey(MonSources.speciesKeys, param, "species", "MON_EVO_BAD_VALUE", context)
    if not speciesKey then
      return nil, speciesErr
    end
    entry.species = speciesKey
  end
  return entry
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
    return nil, Errors.new("MON_ARCHIVE_UNAVAILABLE", "mon archive " .. alias .. " is unavailable", { alias = alias })
  end
  return archive
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
        "MON_MEMBER_MISSING",
        alias .. " member " .. memberId .. " is absent",
        { alias = alias, memberId = memberId }
      )
  end
  return member
end

-- Decode one 34-byte item_data member into its held-item facts. Only the
-- hold-effect byte survives: price, pockets, and use behavior stay
-- producer-side with the rest of ItemData (include/item.h).
---@param member string
---@param context Errors.Context|nil
---@return table<string, unknown>|nil, Errors.Error|nil
function MonCatalogCompiler.decodeItemData(member, context)
  context = context or {}
  local ok, sizeErr = checkSize(member, MonSources.ITEM_DATA_SIZE, "MON_ITEM_DATA_BAD_SIZE", context)
  if not ok then
    return nil, sizeErr
  end
  return { holdEffect = string.byte(member, MonSources.ITEM_DATA_HOLD_EFFECT_OFFSET + 1) }
end

-- Assemble the generated item collection: one record per source native
-- identity 0..536, keyed by the producer semantic key. Ball membership comes
-- from the pinned source ball subset; the friendship fact comes from the
-- decoded hold-effect byte, never from a runtime table.
---@param romFs RomFs
---@return table<string, unknown>|nil, Errors.Error|nil
function MonCatalogCompiler.compileItems(romFs)
  local archive, err = openArchive(romFs, "item_data")
  if not archive then
    return nil, err
  end
  local items = {}
  for nativeId = 0, 536 do
    local key = MonSources.itemKeys[nativeId]
    if key == nil then
      return nil,
        Errors.new("MON_ITEM_UNKNOWN_IDENTITY", "source item identity " .. nativeId .. " has no semantic key", {
          nativeId = nativeId,
        })
    end
    if items[key] ~= nil then
      return nil, Errors.new("MON_ITEM_DUPLICATE_KEY", "source item key " .. key .. " is defined twice", { key = key })
    end
    local memberId = MonSources.itemDataMember(nativeId)
    local member, memberErr = readMember(archive, memberId, "item_data")
    if not member then
      return nil, memberErr
    end
    local decoded, decodeErr = MonCatalogCompiler.decodeItemData(member, { archive = "item_data", memberId = memberId })
    if not decoded then
      return nil, decodeErr
    end
    items[key] = {
      nativeId = nativeId,
      isBall = MonSources.ballItemIds[nativeId] == true,
      friendshipBoost = decoded.holdEffect == MonSources.HOLD_EFFECT_FRIENDSHIP_UP,
    }
  end
  return items
end

-- Follower parameters for one tp_param member: the height-restriction size
-- byte and the exact map-object parameter the source installs
-- (FollowMon_SetObjectForm). The remaining two bytes are never read by the
-- source and stay producer-side.
local function followerParams(tpMember, context)
  if #tpMember ~= 4 then
    return nil,
      Errors.new("MON_FOLLOWER_BAD_SIZE", contextLabel(context) .. " is " .. #tpMember .. " bytes, expected 4", {
        archive = context.archive,
        memberId = context.memberId,
        size = #tpMember,
      })
  end
  local size = string.byte(tpMember, 2)
  local objectParam = string.byte(tpMember, 2) * 256 + string.byte(tpMember, 3)
  return { size = size, objectParam = objectParam }
end

-- Assemble one species/form record. Learnsets, evolutions, and follower
-- parameters resolve through the same member selection the source uses;
-- icon/portrait entries are the default-variant selectors (non-egg, male
-- where the source ships a male portrait, non-shiny) and the manifests
-- carry every reachable variant.
---@param speciesId integer
---@param form integer
---@param personal table<string, unknown>
---@param learnsets table<integer, table<integer, table<string, unknown>>>
---@param evos table<integer, table<integer, table<string, unknown>>>
---@param tpArchive Narc
---@param romFs RomFs
---@return table<string, unknown>|nil, Errors.Error|nil
local function assembleForm(speciesId, form, personal, learnsets, evos, tpArchive, romFs)
  local context = { archive = "personal", memberId = MonSources.resolvePersonalMember(speciesId, form) }
  local speciesKey = must(MonSources.speciesKeys[speciesId])
  local types = {}
  for _, typeId in ipairs(personal.types) do
    types[#types + 1] = must(MonSources.typeKeys[typeId])
  end
  local abilities = {}
  local seenAbility = {}
  for _, abilityId in ipairs(personal.abilities) do
    if abilityId ~= 0 and not seenAbility[abilityId] then
      -- Ability slot 2 of 0 means "no second ability": src/pokemon.c
      -- creation falls back to slot 1, so the catalog carries one entry.
      -- Identical pairs (both slots the same ability) likewise collapse:
      -- PID selection cannot distinguish them.
      local abilityKey, abilityErr =
        lookupKey(MonSources.abilityKeys, abilityId, "ability", "MON_PERSONAL_BAD_VALUE", context)
      if not abilityKey then
        return nil, abilityErr
      end
      seenAbility[abilityId] = true
      abilities[#abilities + 1] = abilityKey
    end
  end
  if #abilities == 0 then
    -- Reserved identities (NONE/EGG/BAD_EGG) store ability 0 in both slots:
    -- ABILITY_NONE is the honest semantic record, not an invented ability.
    abilities[1] = must(MonSources.abilityKeys[0])
  end
  local eggGroups = {}
  for _, eggGroupId in ipairs(personal.eggGroups) do
    eggGroups[#eggGroups + 1] = must(MonSources.eggGroupKeys[eggGroupId])
  end
  local function heldItem(nativeId)
    local itemKey, itemErr = lookupKey(MonSources.itemKeys, nativeId, "item", "MON_PERSONAL_BAD_VALUE", context)
    if not itemKey then
      return nil, itemErr
    end
    return { item = itemKey, nativeId = nativeId }
  end
  local common, commonErr = heldItem(personal.heldItems[1])
  if not common then
    return nil, commonErr
  end
  local rare, rareErr = heldItem(personal.heldItems[2])
  if not rare then
    return nil, rareErr
  end
  local tmhm = {}
  for _, machine in ipairs(personal.tmhm) do
    tmhm[#tmhm + 1] = must(MonSources.machineMoves[machine]).move
  end
  table.sort(tmhm)
  local learnset = must(learnsets[MonSources.resolvePersonalMember(speciesId, form)])
  local levelUpMoves = {}
  for _, entry in ipairs(learnset) do
    local moveKey, moveErr = lookupKey(MonSources.moveKeys, entry.move, "move", "MON_LEARNSET_BAD_VALUE", {
      archive = "level_up_moves",
      memberId = MonSources.resolvePersonalMember(speciesId, form),
    })
    if not moveKey then
      return nil, moveErr
    end
    levelUpMoves[#levelUpMoves + 1] = { level = entry.level, move = moveKey }
  end
  local evoSlots = must(evos[MonSources.resolvePersonalMember(speciesId, form)])
  local evolutions = {}
  for _, slot in ipairs(evoSlots) do
    local entry, evoErr =
      normalizeEvolution(slot, { archive = "evolutions", memberId = MonSources.resolvePersonalMember(speciesId, form) })
    if not entry then
      return nil, evoErr
    end
    evolutions[#evolutions + 1] = entry
  end
  local variants, variantsErr = MonPresentationCompiler.portraitVariants(romFs, speciesId, form)
  if not variants then
    return nil, variantsErr
  end
  local defaultVariant = must(variants[1])
  local formRecord = {
    baseStats = personal.baseStats,
    types = types,
    abilities = abilities,
    tmhm = tmhm,
    levelUpMoves = levelUpMoves,
    evolutions = evolutions,
    icon = MonCache.iconSelector(speciesKey, form, false),
    portrait = MonCache.portraitSelector(speciesKey, form, defaultVariant.gender, false),
    follower = nil,
  }
  if speciesId >= 1 and speciesId <= MonSources.MAX_SPECIES then
    local paramIndex = must(MonSources.followerParamIndex(speciesId, form, false))
    local tpMember, tpErr = readMember(tpArchive, paramIndex, "follower_params")
    if not tpMember then
      return nil, tpErr
    end
    local params, paramsErr = followerParams(tpMember, { archive = "follower_params", memberId = paramIndex })
    if not params then
      return nil, paramsErr
    end
    formRecord.follower = {
      visualId = MonSources.followerVisualId(paramIndex),
      size = params.size,
      objectParam = params.objectParam,
    }
    if MonSources.followerFemaleFlags[speciesId] == true then
      local femaleIndex = must(MonSources.followerParamIndex(speciesId, form, true))
      local femaleMember, femaleErr = readMember(tpArchive, femaleIndex, "follower_params")
      if not femaleMember then
        return nil, femaleErr
      end
      local femaleParams, femaleParamsErr =
        followerParams(femaleMember, { archive = "follower_params", memberId = femaleIndex })
      if not femaleParams then
        return nil, femaleParamsErr
      end
      formRecord.follower.female = {
        visualId = MonSources.followerVisualId(femaleIndex),
        size = femaleParams.size,
        objectParam = femaleParams.objectParam,
      }
    end
  end
  return formRecord
end
-- Compile the complete semantic catalog from a supported dump. Every
-- personal member must be reachable: base species and egg members become
-- species records, form pseudo-members attach to their parent species form,
-- and anything else fails the build instead of dropping silently.
---@param romFs RomFs
---@param opts table<string, unknown>|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function MonCatalogCompiler.compileCatalog(romFs, opts)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  local language = MonSources.versionLanguages[versionId]
  if language == nil then
    return nil,
      Errors.new("MON_VERSION_UNSUPPORTED", "mon catalog has no language for version " .. tostring(versionId), {
        versionId = versionId,
      })
  end
  local function fail(err)
    return nil, err
  end
  local personal, err = openArchive(romFs, "personal")
  if not personal then
    return fail(err)
  end
  local growthTables
  growthTables, err = openArchive(romFs, "growth_tables")
  if not growthTables then
    return fail(err)
  end
  local learnsets
  learnsets, err = openArchive(romFs, "level_up_moves")
  if not learnsets then
    return fail(err)
  end
  local evoTables
  evoTables, err = openArchive(romFs, "evolutions")
  if not evoTables then
    return fail(err)
  end
  local moveData
  moveData, err = openArchive(romFs, "moves")
  if not moveData then
    return fail(err)
  end
  local messages
  messages, err = openArchive(romFs, "messages")
  if not messages then
    return fail(err)
  end
  local followerParamsArchive
  followerParamsArchive, err = openArchive(romFs, "follower_params")
  if not followerParamsArchive then
    return fail(err)
  end
  local ok, result = pcall(function()
    local banks = MonSources.messageBanks
    local counts = MonSources.messageCounts
    local speciesNames = must(decodeTextBank(messages, banks.species, counts.species, "species names"))
    local moveNames = must(decodeTextBank(messages, banks.moveName, counts.moves, "move names"))
    local moveDescriptions = must(decodeTextBank(messages, banks.moveDescription, counts.moves, "move descriptions"))
    local abilityNames = must(decodeTextBank(messages, banks.abilityName, counts.abilities, "ability names"))
    local abilityDescriptions =
      must(decodeTextBank(messages, banks.abilityDescription, counts.abilities, "ability descriptions"))
    local personalCount = personal:memberCount()
    if personalCount ~= 508 then
      error(
        Errors.new(
          "MON_CATALOG_MEMBER_COUNT",
          "personal archive carries " .. personalCount .. " members, expected 508",
          {
            memberCount = personalCount,
          }
        ),
        0
      )
    end
    -- Decode every personal member once; assembly attaches pseudo-members
    -- to their parent species form below.
    local decoded = {}
    for memberId = 0, personalCount - 1 do
      local member = must(readMember(personal, memberId, "personal"))
      decoded[memberId] = must(MonCatalogCompiler.decodePersonal(member, { archive = "personal", memberId = memberId }))
    end
    local growthCurves = {}
    for curveId = 0, 7 do
      local member = must(readMember(growthTables, curveId, "growth_tables"))
      local curve = must(MonCatalogCompiler.decodeGrowth(member, { archive = "growth_tables", memberId = curveId }))
      growthCurves[must(MonSources.growthKeys[curveId])] = curve
    end
    local learnsetCount = learnsets:memberCount()
    local learnsetTable = {}
    for memberId = 0, learnsetCount - 1 do
      local member = must(readMember(learnsets, memberId, "level_up_moves"))
      learnsetTable[memberId] =
        must(MonCatalogCompiler.decodeLearnset(member, { archive = "level_up_moves", memberId = memberId }))
    end
    local evoCount = evoTables:memberCount()
    local evoTable = {}
    for memberId = 0, evoCount - 1 do
      local member = must(readMember(evoTables, memberId, "evolutions"))
      evoTable[memberId] =
        must(MonCatalogCompiler.decodeEvolution(member, { archive = "evolutions", memberId = memberId }))
    end
    local moves = {}
    for moveId = 0, MonSources.NUM_MOVES do
      local entry = must(readMember(moveData, moveId, "moves"))
      local record = must(MonCatalogCompiler.decodeMove(entry, { archive = "moves", memberId = moveId }))
      local key = must(MonSources.moveKeys[moveId])
      local name = must(requireText(moveNames, moveId, "move name", { archive = "moves", memberId = moveId }))
      local description = moveDescriptions[moveId]
      if type(description) ~= "string" then
        error(Errors.new("MON_TEXT_MISSING", "move " .. moveId .. " has no description", { moveId = moveId }), 0)
      end
      moves[key] = {
        nativeId = moveId,
        name = name,
        description = description,
        effect = record.effect,
        category = must(MonSources.damageCategories[record.category]),
        power = record.power,
        moveType = must(MonSources.typeKeys[record.moveType]),
        accuracy = record.accuracy,
        basePp = record.basePp,
        effectChance = record.effectChance,
        range = record.range,
        priority = record.priority,
        flags = record.flags,
        unknownC = record.unknownC,
        contestType = record.contestType,
      }
    end
    local abilities = {}
    for abilityId = 0, MonSources.NUM_ABILITIES do
      local key = must(MonSources.abilityKeys[abilityId])
      local name =
        must(requireText(abilityNames, abilityId, "ability name", { archive = "abilities", memberId = abilityId }))
      local description = abilityDescriptions[abilityId]
      if type(description) ~= "string" then
        error(
          Errors.new("MON_TEXT_MISSING", "ability " .. abilityId .. " has no description", { abilityId = abilityId }),
          0
        )
      end
      abilities[key] = { nativeId = abilityId, name = name, description = description }
    end
    local species = {}
    local covered = {}
    local function attachForm(speciesId, form, memberId)
      local record = must(
        assembleForm(speciesId, form, must(decoded[memberId]), learnsetTable, evoTable, followerParamsArchive, romFs)
      )
      local key = must(MonSources.speciesKeys[speciesId])
      local entry = species[key]
      if entry == nil then
        local name =
          must(requireText(speciesNames, speciesId, "species name", { archive = "personal", memberId = memberId }))
        local personalRecord = must(decoded[memberId])
        local eggGroups = {}
        for _, eggGroupId in ipairs(personalRecord.eggGroups) do
          eggGroups[#eggGroups + 1] = must(MonSources.eggGroupKeys[eggGroupId])
        end
        local function heldItem(nativeId)
          return { item = must(MonSources.itemKeys[nativeId]), nativeId = nativeId }
        end
        entry = {
          nativeId = speciesId,
          name = name,
          growthCurve = must(MonSources.growthKeys[personalRecord.growthCurve]),
          baseFriendship = personalRecord.baseFriendship,
          genderRatio = personalRecord.genderRatio,
          eggCycles = personalRecord.eggCycles,
          eggGroups = eggGroups,
          catchRate = personalRecord.catchRate,
          baseExpYield = personalRecord.baseExpYield,
          evYield = personalRecord.evYield,
          heldItems = {
            common = heldItem(personalRecord.heldItems[1]),
            rare = heldItem(personalRecord.heldItems[2]),
          },
          color = personalRecord.color,
          flip = personalRecord.flip,
          forms = {},
        }
        species[key] = entry
      end
      if entry.forms[form] ~= nil then
        error(
          Errors.new("MON_CATALOG_DUPLICATE_FORM", "species " .. key .. " form " .. form .. " is defined twice", {
            species = key,
            form = form,
          }),
          0
        )
      end
      entry.forms[form] = record
      covered[memberId] = true
    end
    for speciesId = 0, MonSources.BAD_EGG_SPECIES do
      for _, form in ipairs(MonSources.runtimeForms(speciesId)) do
        attachForm(speciesId, form, MonSources.resolvePersonalMember(speciesId, form))
      end
    end
    for memberId = 0, personalCount - 1 do
      if covered[memberId] == nil then
        error(
          Errors.new("MON_CATALOG_UNREACHABLE_MEMBER", "personal member " .. memberId .. " is not reachable", {
            memberId = memberId,
          }),
          0
        )
      end
    end
    local catalog = {
      schema = MonCache.CATALOG_SCHEMA,
      version = { id = versionId, language = language },
      species = species,
      moves = moves,
      abilities = abilities,
      growthCurves = growthCurves,
      items = must(MonCatalogCompiler.compileItems(romFs)),
    }
    must(MonAssetSchema.assertCatalog(catalog))
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

-- Compile the complete publishable class: catalog plus icon/portrait atlas
-- inputs, manifests, content hashes, and the completion marker. Every
-- catalog selector must resolve to a manifest entry before the bundle
-- leaves this function.
---@param romFs RomFs
---@param opts table<string, unknown>|nil
---@return table<string, unknown>|nil, Errors.Error|string|nil
function MonCatalogCompiler.compileAll(romFs, opts)
  opts = opts or {}
  local catalog, err = MonCatalogCompiler.compileCatalog(romFs, opts)
  if not catalog then
    return nil, err
  end
  local ok, result = pcall(function()
    local icons = must(MonPresentationCompiler.compileIcons(romFs, catalog))
    local portraits = must(MonPresentationCompiler.compilePortraits(romFs, catalog))
    must(MonAssetSchema.assertIconManifest(icons.manifest))
    must(MonAssetSchema.assertPortraitManifest(portraits.manifest))
    for speciesKey, species in pairs(catalog.species) do
      for formId, form in pairs(species.forms) do
        if icons.manifest.entries[form.icon] == nil then
          error(
            Errors.new("MON_MANIFEST_UNRESOLVED_SELECTOR", "icon selector has no manifest entry: " .. form.icon, {
              species = speciesKey,
              form = formId,
              selector = form.icon,
            }),
            0
          )
        end
        if portraits.manifest.entries[form.portrait] == nil then
          error(
            Errors.new("MON_MANIFEST_UNRESOLVED_SELECTOR", "portrait selector has no entry: " .. form.portrait, {
              species = speciesKey,
              form = formId,
              selector = form.portrait,
            }),
            0
          )
        end
      end
    end
    local catalogHash = Hashing.hashLua(catalog)
    local iconPng = PngWriter.encode(icons.image.width, icons.image.height, icons.image.pixels)
    local portraitPng = PngWriter.encode(portraits.image.width, portraits.image.height, portraits.image.pixels)
    local iconHash = Hashing.sha1hex(iconPng)
    local portraitHash = Hashing.sha1hex(portraitPng)
    local index = {
      schema = MonCache.INDEX_SCHEMA,
      version = catalog.version,
      catalogHash = catalogHash,
      iconHash = iconHash,
      portraitHash = portraitHash,
      catalog = MonCache.catalogPath(),
      icons = MonCache.iconImagePath(),
      iconManifest = MonCache.iconManifestPath(),
      portraits = MonCache.portraitImagePath(),
      portraitManifest = MonCache.portraitManifestPath(),
    }
    must(MonAssetSchema.assertIndex(index))
    local romSha1 = romFs:metadata().sha1
    local marker = MonCache.marker(
      romSha1,
      Hashing.hashLua({
        catalog = catalogHash,
        icons = iconHash,
        portraits = portraitHash,
        iconManifest = Hashing.hashLua(icons.manifest),
        portraitManifest = Hashing.hashLua(portraits.manifest),
      })
    )
    return {
      marker = marker,
      index = index,
      catalog = catalog,
      icons = icons.image,
      iconManifest = icons.manifest,
      portraits = portraits.image,
      portraitManifest = portraits.manifest,
      iconPng = iconPng,
      portraitPng = portraitPng,
      provenance = {
        schema = "g4-mon-provenance-v1",
        source = MonSources.provenance,
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

return MonCatalogCompiler
