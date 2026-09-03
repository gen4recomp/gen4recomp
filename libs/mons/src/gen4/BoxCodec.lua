-- Exact Generation-IV boxed-mon codec. Layout mirrors
-- pret/pokeheartgold include/pokemon_types_def.h (BoxPokemon with its four
-- 0x20 data blocks A-D); the PID-selected block permutation mirrors
-- GetSubstruct, the word-wise cipher mirrors MonEncryptSegment and
-- MonDecryptSegment, and the checksum mirrors CalcMonChecksum. The semantic
-- record stays authoritative: project and decode expose only the boxed
-- projection (party condition, mail, and capsule bytes do not exist in the
-- 0x88 form), and encoding malformed content fails instead of coercing it.
-- Codec cipher state is local and never consumes the gameplay generator.

local BinaryReader = require("libs.codec.src.BinaryReader")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local Errors = require("libs.errors.src.Errors")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local Personality = require("libs.mons.src.gen4.Personality")

---@class BoxCodec
local BoxCodec = {}

BoxCodec.SIZE = 136
BoxCodec.BLOCK_SIZE = 32
BoxCodec.TERMINATOR = 0xFFFF

-- Logical block order A, B, C, D placed at these stored offsets per row,
-- where the row is bits 13..17 of the personality value. Rows 24..31 alias
-- rows 0..7.
local PERMUTATION = {
  { 0x00, 0x20, 0x40, 0x60 },
  { 0x00, 0x20, 0x60, 0x40 },
  { 0x00, 0x40, 0x20, 0x60 },
  { 0x00, 0x60, 0x20, 0x40 },
  { 0x00, 0x40, 0x60, 0x20 },
  { 0x00, 0x60, 0x40, 0x20 },
  { 0x20, 0x00, 0x40, 0x60 },
  { 0x20, 0x00, 0x60, 0x40 },
  { 0x40, 0x00, 0x20, 0x60 },
  { 0x60, 0x00, 0x20, 0x40 },
  { 0x40, 0x00, 0x60, 0x20 },
  { 0x60, 0x00, 0x40, 0x20 },
  { 0x20, 0x40, 0x00, 0x60 },
  { 0x20, 0x60, 0x00, 0x40 },
  { 0x40, 0x20, 0x00, 0x60 },
  { 0x60, 0x20, 0x00, 0x40 },
  { 0x40, 0x60, 0x00, 0x20 },
  { 0x60, 0x40, 0x00, 0x20 },
  { 0x20, 0x40, 0x60, 0x00 },
  { 0x20, 0x60, 0x40, 0x00 },
  { 0x40, 0x20, 0x60, 0x00 },
  { 0x60, 0x20, 0x40, 0x00 },
  { 0x40, 0x60, 0x20, 0x00 },
  { 0x60, 0x40, 0x20, 0x00 },
  { 0x00, 0x20, 0x40, 0x60 },
  { 0x00, 0x20, 0x60, 0x40 },
  { 0x00, 0x40, 0x20, 0x60 },
  { 0x00, 0x60, 0x20, 0x40 },
  { 0x00, 0x40, 0x60, 0x20 },
  { 0x00, 0x60, 0x40, 0x20 },
  { 0x20, 0x00, 0x40, 0x60 },
  { 0x20, 0x00, 0x60, 0x40 },
}

---@param a integer
---@param b integer
---@return integer
local function xor16(a, b)
  local value = 0
  local place = 1
  for _ = 1, 16 do
    local abit = math.floor(a / place) % 2
    local bbit = math.floor(b / place) % 2
    if abit ~= bbit then
      value = value + place
    end
    place = place * 2
  end
  return value
end

---@param words integer[]
---@return integer
local function checksumWords(words)
  local total = 0
  for _, word in ipairs(words) do
    total = (total + word) % 65536
  end
  return total
end

-- Local cipher stream over 16-bit words, seeded by the checksum. Encryption
-- and decryption are the same pass. State lives in a throwaway generator so
-- encryption never consumes the gameplay stream.
---@param words integer[]
---@param seed integer
---@return integer[]
local function cipherWords(words, seed)
  local stream = Lcrng.new(seed)
  local out = {}
  for _, word in ipairs(words) do
    out[#out + 1] = xor16(word, stream:nextU16())
  end
  return out
end

---@param map table<string, integer>
---@return table<integer, string>
local function reverseMap(map)
  assert(type(map) == "table", "reverse mapping requires a table")
  local out = {}
  for key, id in pairs(map) do
    out[id] = key
  end
  return out
end

---@param text string
---@param charmap table<string, integer>
---@param capacity integer
---@return integer[]
local function encodeText(text, charmap, capacity)
  local units = {}
  for glyph in Utf8Glyphs.iter(text) do
    units[#units + 1] = charmap[glyph]
  end
  units[#units + 1] = BoxCodec.TERMINATOR
  assert(#units <= capacity, "text exceeds its fixed capacity")
  while #units < capacity do
    units[#units + 1] = BoxCodec.TERMINATOR
  end
  return units
end

---@param reader BinaryReader
---@param offset integer
---@param count integer
---@param reverse table<integer, string>
---@param what string
---@return string
local function decodeText(reader, offset, count, reverse, what)
  local glyphs = {}
  local terminated = false
  for index = 0, count - 1 do
    local unit = reader:u16le(offset + index * 2)
    if not terminated then
      if unit == BoxCodec.TERMINATOR then
        terminated = true
      else
        local glyph = reverse[unit]
        if glyph == nil then
          MonsErrors.raise(MonsErrors.CODEC_INVALID, what .. " carries an unknown glyph", {})
        end
        glyphs[#glyphs + 1] = glyph
      end
    elseif unit ~= BoxCodec.TERMINATOR then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, what .. " carries invalid padding", {})
    end
  end
  if not terminated then
    MonsErrors.raise(MonsErrors.CODEC_INVALID, what .. " misses its terminator", {})
  end
  return table.concat(glyphs)
end

---@param projection table
---@param context table
---@return string, string, string, string
local function serializeBlocks(projection, context)
  local writerA = BinaryWriter.new()
  writerA:u16(projection.speciesId)
  writerA:u16(projection.heldItemId)
  writerA:u32(projection.trainerId)
  writerA:u32(projection.experience)
  writerA:u8(projection.friendship)
  writerA:u8(projection.abilityId)
  writerA:u8(projection.markings)
  writerA:u8(projection.languageId)
  writerA:u8(projection.evs.hp)
  writerA:u8(projection.evs.attack)
  writerA:u8(projection.evs.defense)
  writerA:u8(projection.evs.speed)
  writerA:u8(projection.evs.specialAttack)
  writerA:u8(projection.evs.specialDefense)
  writerA:u8(projection.contest.cool)
  writerA:u8(projection.contest.beauty)
  writerA:u8(projection.contest.cute)
  writerA:u8(projection.contest.smart)
  writerA:u8(projection.contest.tough)
  writerA:u8(projection.contest.sheen)
  writerA:u32(projection.ribbonsDs1)

  local writerB = BinaryWriter.new()
  for slot = 1, 4 do
    local entry = projection.moves[slot]
    if entry ~= nil then
      writerB:u16(entry.id)
    else
      writerB:u16(0)
    end
  end
  for slot = 1, 4 do
    local entry = projection.moves[slot]
    if entry ~= nil then
      writerB:u8(entry.pp)
    else
      writerB:u8(0)
    end
  end
  for slot = 1, 4 do
    local entry = projection.moves[slot]
    if entry ~= nil then
      writerB:u8(entry.ppUps)
    else
      writerB:u8(0)
    end
  end
  local ivbits = projection.ivs.hp
    + projection.ivs.attack * 32
    + projection.ivs.defense * 1024
    + projection.ivs.speed * 32768
    + projection.ivs.specialAttack * 1048576
    + projection.ivs.specialDefense * 33554432
  if projection.isEgg then
    ivbits = ivbits + 1073741824
  end
  if projection.hasNickname then
    ivbits = ivbits + 2147483648
  end
  writerB:u32(ivbits)
  writerB:u32(projection.ribbonsGba)
  -- Stored gender codes follow the fixed-vector contract: male 1, female 2.
  local flagByte = projection.form * 8 + projection.genderCode * 2
  if projection.fateful then
    flagByte = flagByte + 1
  end
  writerB:u8(flagByte)
  writerB:u8(projection.leaves)
  writerB:u16(0) -- reserved
  -- The secondary-region location fields stay zero per the fixed vectors;
  -- the primary fields in block D carry the locations decode reads back.
  writerB:u16(0) -- egg location, secondary region
  writerB:u16(0) -- met location, secondary region

  local writerC = BinaryWriter.new()
  for _, unit in ipairs(encodeText(projection.nicknameText, context.charmap, NativeLegality.NICKNAME_CAPACITY)) do
    writerC:u16(unit)
  end
  writerC:u8(0)
  writerC:u8(projection.gameId)
  writerC:u32(projection.ribbonsDs2 % 4294967296)
  writerC:u32(math.floor(projection.ribbonsDs2 / 4294967296))

  local writerD = BinaryWriter.new()
  for _, unit in ipairs(encodeText(projection.otText, context.charmap, NativeLegality.OT_NAME_CAPACITY)) do
    writerD:u16(unit)
  end
  local eggYearByte = 0
  if projection.eggMonth ~= 0 or projection.eggDay ~= 0 then
    eggYearByte = projection.eggYear - 2000
  end
  writerD:u8(eggYearByte)
  writerD:u8(projection.eggMonth)
  writerD:u8(projection.eggDay)
  writerD:u8(projection.metYear - 2000)
  writerD:u8(projection.metMonth)
  writerD:u8(projection.metDay)
  writerD:u16(projection.eggLocation)
  writerD:u16(projection.metLocation)
  writerD:u8(projection.pokerus)
  writerD:u8(projection.ballId)
  writerD:u8(projection.metLevel + projection.trainerGender * 128)
  writerD:u8(projection.terrain)
  writerD:u8(projection.ballId)
  writerD:u8((projection.mood % 256 + 256) % 256)

  local blockA = writerA:tostring()
  local blockB = writerB:tostring()
  local blockC = writerC:tostring()
  local blockD = writerD:tostring()
  assert(
    #blockA == BoxCodec.BLOCK_SIZE
      and #blockB == BoxCodec.BLOCK_SIZE
      and #blockC == BoxCodec.BLOCK_SIZE
      and #blockD == BoxCodec.BLOCK_SIZE,
    "every boxed block must be exactly 0x20 bytes"
  )
  return blockA, blockB, blockC, blockD
end

---@param blocks string[]
---@param personality integer
---@return integer[], integer
local function placeAndChecksum(blocks, personality)
  local row = math.floor(personality / 8192) % 32
  local order = PERMUTATION[row + 1]
  local slots = {}
  for logicalIndex = 1, 4 do
    slots[order[logicalIndex] / 32 + 1] = blocks[logicalIndex]
  end
  local placed = table.concat({ slots[1], slots[2], slots[3], slots[4] })
  assert(#placed == 128, "placed boxed data must be 128 bytes")
  local reader = BinaryReader.new(placed, "boxed data")
  local words = {}
  for offset = 0, 126, 2 do
    words[#words + 1] = reader:u16le(offset)
  end
  return words, checksumWords(words)
end

---@param mon table
---@param context table
---@return string
function BoxCodec.encode(mon, context)
  assert(type(mon) == "table", "encoding requires a mon record")
  assert(type(context) == "table", "encoding requires a context")
  local canonical = Mon.validate(mon, context)
  local projection = NativeLegality.project(canonical, context)
  local blockA, blockB, blockC, blockD = serializeBlocks(projection, context)
  local words, checksum = placeAndChecksum({ blockA, blockB, blockC, blockD }, canonical.personality)
  local encrypted = cipherWords(words, checksum)
  local writer = BinaryWriter.new()
  writer:u32(canonical.personality)
  writer:u16(0)
  writer:u16(checksum)
  for _, word in ipairs(encrypted) do
    writer:u16(word)
  end
  local bytes = writer:tostring()
  assert(#bytes == BoxCodec.SIZE, "boxed record must be exactly 0x88 bytes")
  return bytes
end

---@param mon table
---@param context table
---@return table
function BoxCodec.project(mon, context)
  assert(type(mon) == "table", "projection requires a mon record")
  assert(type(context) == "table", "projection requires a context")
  local canonical = Mon.validate(mon, context)
  NativeLegality.project(canonical, context)
  local out = {
    schema = Mon.SCHEMA,
    species = canonical.species,
    form = canonical.form,
    personality = canonical.personality,
    experience = canonical.experience,
    friendship = canonical.friendship,
    ability = canonical.ability,
    heldItem = canonical.heldItem,
    markings = canonical.markings,
    evs = canonical.evs,
    contest = canonical.contest,
    moves = canonical.moves,
    ivs = canonical.ivs,
    isEgg = canonical.isEgg,
    ribbons = canonical.ribbons,
    fatefulEncounter = canonical.fatefulEncounter,
    shinyLeaves = canonical.shinyLeaves,
    egg = canonical.egg,
    met = canonical.met,
    origin = canonical.origin,
    pokerus = canonical.pokerus,
    mood = canonical.mood,
  }
  if canonical.nickname ~= nil then
    out.nickname = canonical.nickname
  end
  return out
end

-- Any structured failure below the byte boundary becomes a codec failure so
-- decoding never publishes a record the bytes cannot support.
---@param fn function
---@return any
local function tryDecode(fn)
  local ok, value = pcall(fn)
  if ok then
    return value
  end
  if Errors.is(value) then
    MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed record is malformed", { cause = value.code })
  end
  error(value, 0)
end

---@param bytes string
---@param context table
---@return table
function BoxCodec.decode(bytes, context)
  assert(type(context) == "table", "decoding requires a context")
  if type(bytes) ~= "string" or #bytes ~= BoxCodec.SIZE then
    MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed record must be exactly 0x88 bytes", {})
  end
  return tryDecode(function()
    local catalog = context.catalog
    local header = BinaryReader.new(bytes, "boxed record")
    local personality = header:u32le(0)
    if header:u16le(4) ~= 0 then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed flags must be zero in storage", {})
    end
    local checksum = header:u16le(6)

    local body = BinaryReader.new(bytes:sub(9), "boxed body")
    local encrypted = {}
    for offset = 0, 126, 2 do
      encrypted[#encrypted + 1] = body:u16le(offset)
    end
    local words = cipherWords(encrypted, checksum)
    if checksumWords(words) ~= checksum then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed checksum mismatch", {})
    end

    local row = math.floor(personality / 8192) % 32
    local order = PERMUTATION[row + 1]
    local stored = {}
    for slot = 1, 64 do
      stored[slot] = words[slot]
    end
    local logical = {}
    for logicalIndex = 1, 4 do
      local first = order[logicalIndex] / 2 + 1
      local block = {}
      for index = 0, 15 do
        block[#block + 1] = stored[first + index]
      end
      local writer = BinaryWriter.new()
      for _, word in ipairs(block) do
        writer:u16(word)
      end
      logical[logicalIndex] = BinaryReader.new(writer:tostring(), "boxed block")
    end
    local readerA, readerB, readerC, readerD = logical[1], logical[2], logical[3], logical[4]

    local items = reverseMap(context.items)
    local games = reverseMap(context.games)
    local languages = reverseMap(context.languages)
    local balls = reverseMap(context.balls)
    local glyphs = reverseMap(context.charmap)

    local speciesKey = catalog:speciesKeyByNativeId(readerA:u16le(0))
    local species = catalog:species(speciesKey)
    local heldItem = items[readerA:u16le(2)]
    if heldItem == nil then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed held item is unknown", {})
    end
    local trainerId = readerA:u32le(4)
    local experience = readerA:u32le(8)
    local friendship = readerA:u8(12)
    local abilityKey = catalog:abilityKeyByNativeId(readerA:u8(13))
    local markings = readerA:u8(14)
    local language = languages[readerA:u8(15)]
    if language == nil then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed language is unknown", {})
    end
    local evs = {
      hp = readerA:u8(16),
      attack = readerA:u8(17),
      defense = readerA:u8(18),
      speed = readerA:u8(19),
      specialAttack = readerA:u8(20),
      specialDefense = readerA:u8(21),
    }
    local contest = {
      cool = readerA:u8(22),
      beauty = readerA:u8(23),
      cute = readerA:u8(24),
      smart = readerA:u8(25),
      tough = readerA:u8(26),
      sheen = readerA:u8(27),
    }
    local ds1 = readerA:u32le(28)

    local moves = {}
    for slot = 0, 3 do
      local id = readerB:u16le(slot * 2)
      if id ~= 0 then
        moves[#moves + 1] = {
          move = catalog:moveKeyByNativeId(id),
          pp = readerB:u8(8 + slot),
          ppUps = readerB:u8(12 + slot),
        }
      end
    end
    local ivbits = readerB:u32le(16)
    local ivs = {
      hp = ivbits % 32,
      attack = math.floor(ivbits / 32) % 32,
      defense = math.floor(ivbits / 1024) % 32,
      speed = math.floor(ivbits / 32768) % 32,
      specialAttack = math.floor(ivbits / 1048576) % 32,
      specialDefense = math.floor(ivbits / 33554432) % 32,
    }
    local isEgg = math.floor(ivbits / 1073741824) % 2 == 1
    local hasNickname = math.floor(ivbits / 2147483648) == 1
    local gba = readerB:u32le(20)
    local flagByte = readerB:u8(24)
    local fateful = flagByte % 2 == 1
    local genderCode = math.floor(flagByte / 2) % 4
    local form = math.floor(flagByte / 8)
    local leaves = readerB:u8(25)
    if leaves > 63 then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed shiny leaves exceed their field", {})
    end

    local nicknameText = decodeText(readerC, 0, 11, glyphs, "nickname")
    if readerC:u8(22) ~= 0 then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed nickname spare byte must be zero", {})
    end
    local game = games[readerC:u8(23)]
    if game == nil then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed game is unknown", {})
    end
    local ds2 = readerC:u32le(24) + readerC:u32le(28) * 4294967296
    if ds2 % 1 ~= 0 or ds2 > 9007199254740991 then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed ribbons exceed exact representation", {})
    end

    local otText = decodeText(readerD, 0, 8, glyphs, "trainer name")
    local eggYear = readerD:u8(16)
    local eggMonth = readerD:u8(17)
    local eggDay = readerD:u8(18)
    local metYear = readerD:u8(19)
    local metMonth = readerD:u8(20)
    local metDay = readerD:u8(21)
    if metMonth < 1 or metMonth > 12 or metDay < 1 or metDay > 31 then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed met date is out of range", {})
    end
    local eggLocation = readerD:u16le(22)
    local metLocation = readerD:u16le(24)
    local pokerus = readerD:u8(26)
    local storedBall = readerD:u8(27)
    local levelByte = readerD:u8(28)
    local terrain = readerD:u8(29)
    if readerD:u8(30) ~= storedBall then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed ball fields disagree", {})
    end
    local ball = balls[storedBall]
    if ball == nil then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed ball is unknown", {})
    end
    local metLevel = levelByte % 128
    local trainerGender = math.floor(levelByte / 128)
    if metLevel < 1 or metLevel > 100 then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed met level is out of range", {})
    end
    local moodByte = readerD:u8(31)
    local mood = moodByte >= 128 and moodByte - 256 or moodByte

    local derivedGender = Personality.gender(species.genderRatio, personality)
    local expectedCode = 0
    if derivedGender == "male" then
      expectedCode = 1
    elseif derivedGender == "female" then
      expectedCode = 2
    end
    if genderCode ~= expectedCode then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed gender disagrees with the personality", {})
    end
    local formDefinition = species.forms[form]
    if formDefinition == nil then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed form is unknown", {})
    end
    assert(formDefinition ~= nil, "boxed form resolved above")
    local permitted = false
    for _, key in ipairs(formDefinition.abilities) do
      if key == abilityKey then
        permitted = true
      end
    end
    if not permitted then
      MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed ability is not permitted by the form", {})
    end

    local egg = { location = eggLocation }
    if eggYear ~= 0 or eggMonth ~= 0 or eggDay ~= 0 then
      if eggMonth < 1 or eggMonth > 12 or eggDay < 1 or eggDay > 31 then
        MonsErrors.raise(MonsErrors.CODEC_INVALID, "boxed egg date is out of range", {})
      end
      egg.date = { year = eggYear + 2000, month = eggMonth, day = eggDay }
    end

    local projection = {
      schema = Mon.SCHEMA,
      species = speciesKey,
      form = form,
      personality = personality,
      experience = experience,
      friendship = friendship,
      ability = abilityKey,
      heldItem = heldItem,
      markings = markings,
      evs = evs,
      contest = contest,
      moves = moves,
      ivs = ivs,
      isEgg = isEgg,
      ribbons = { ds1 = ds1, gba = gba, ds2 = ds2 },
      fatefulEncounter = fateful,
      shinyLeaves = leaves,
      egg = egg,
      met = {
        location = metLocation,
        date = { year = metYear + 2000, month = metMonth, day = metDay },
        level = metLevel,
        terrain = terrain,
      },
      origin = {
        trainerId = trainerId,
        trainerName = otText,
        trainerGender = trainerGender,
        game = game,
        ball = ball,
        language = language,
      },
      pokerus = pokerus,
      mood = mood,
    }
    if hasNickname then
      projection.nickname = nicknameText
    end
    NativeLegality.project(projection, context)
    return projection
  end)
end

return BoxCodec
