-- Synthetic field-bag compilation and cache publication: the 2D decode
-- paths run against hand-built members, malformed source fails with the
-- attributed protocol error, and the publication matrix (missing asset,
-- invalid bundle) reuses ArtifactPublisher through a FakeCache so the
-- previous ready class stays readable. Hero 3D compilation is covered by
-- the ROM conformance suite; no commercial bytes appear here.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
local BagCacheWriter = require("romdump.src.digest.ui.BagCacheWriter")
local BagCache = require("libs.assets.src.BagCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local charmap = require("romdump.src.reference.hgss.charmap")

local T = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function swap4(magic)
  return magic:reverse()
end

local function container(magic, blocks)
  local body = {}
  local size = 0x10
  for _, blk in ipairs(blocks) do
    body[#body + 1] = blk
    size = size + #blk
  end
  return magic .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(size) .. u16(0x10) .. u16(#blocks) .. table.concat(body)
end

local function block(magic, payload)
  return swap4(magic) .. u32(8 + #payload) .. payload
end

local function charData(tiles)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(tiles * 32) .. u32(0x18)
  local body = {}
  for _ = 1, tiles do
    body[#body + 1] = string.rep(string.char(0x11), 32)
  end
  return container("RGCN", { block("CHAR", payload .. table.concat(body)) })
end

local function screenData()
  local entries = {}
  for _ = 1, 32 * 32 do
    entries[#entries + 1] = u16(0)
  end
  return container(
    "RCSN",
    { block("SCRN", u16(256) .. u16(256) .. u32(0) .. u32(32 * 32 * 2) .. table.concat(entries)) }
  )
end

local function paletteData(colors)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = u16(c)
  end
  local bodyBytes = table.concat(body)
  local ttlp = "TTLP" .. u32(24 + #bodyBytes) .. u32(3) .. u32(0) .. u32(#colors * 2) .. u32(16) .. bodyBytes
  return "RLCN" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x10 + #ttlp) .. u16(0x10) .. u16(1) .. ttlp
end

local function palette256()
  local colors = {}
  for i = 1, 256 do
    colors[i] = (i * 0x39B) % 0x8000
  end
  return paletteData(colors)
end

local function cellData(cells)
  -- Metatile entries carry cumulative attribute-table offsets; object
  -- attributes follow the table contiguously so multi-cell members decode.
  local metas, attrs = {}, {}
  local offset = 0
  for _, objs in ipairs(cells) do
    metas[#metas + 1] = u16(#objs) .. u16(0) .. u32(offset)
    for _, o in ipairs(objs) do
      attrs[#attrs + 1] = u16((o.y % 256) + (o.shape or 0) * 16384)
        .. u16((o.x % 512) + (o.size or 0) * 16384)
        .. u16(o.tile + (o.pal or 0) * 4096)
    end
    offset = offset + #objs * 6
  end
  return container("RECN", {
    block(
      "CEBK",
      u16(#cells) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. table.concat(metas) .. table.concat(attrs)
    ),
  })
end

local function animData(count)
  -- Sequences (16 bytes each), frame entries (8 bytes each), then cell
  -- properties, so every selected sequence decodes to one static frame.
  local animsOffset = 0x18
  local framesOffset = animsOffset + count * 16
  local dataOffset = framesOffset + count * 8
  local header = u16(count)
    .. u16(count)
    .. u32(animsOffset)
    .. u32(framesOffset)
    .. u32(dataOffset)
    .. string.rep("\0", 8)
  local seqs, frames, props = {}, {}, {}
  for a = 0, count - 1 do
    seqs[#seqs + 1] = u16(1) .. u16(0) .. u32(0x00010000) .. u32(1) .. u32(a * 8)
    frames[#frames + 1] = u32(a * 2) .. u16(4) .. u16(0)
    props[#props + 1] = u16(0)
  end
  return container(
    "RNAN",
    { block("ABNK", header .. table.concat(seqs) .. table.concat(frames) .. table.concat(props)) }
  )
end

-- One animation sequence with two realized frames: Bag v3 publishes static
-- realizations only, so the producer must reject the timeline instead of
-- playing or flattening it.
local function animTwoFrameSequence()
  local header = u16(1) .. u16(2) .. u32(0x18) .. u32(0x28) .. u32(0x38) .. string.rep("\0", 8)
  local sequence = u32(2) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frame = u32(0) .. u16(4) .. u16(0)
  local property = u16(0)
  return container("RNAN", { block("ABNK", header .. sequence .. frame .. frame .. property) })
end

local function narc(members)
  local btaf = u16(#members) .. u16(0)
  local running = 0
  for _, bytes in ipairs(members) do
    btaf = btaf .. u32(running) .. u32(running + #bytes)
    running = running + #bytes
  end
  local function narcBlock(magic, payload)
    return magic .. u32(8 + #payload) .. payload
  end
  local btafBlock = narcBlock("BTAF", btaf)
  local gmifBlock = narcBlock("GMIF", table.concat(members))
  return "NARC"
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(0x10 + #btafBlock + #gmifBlock)
    .. u16(0x10)
    .. u16(2)
    .. btafBlock
    .. gmifBlock
end

-- Minimal bag archive: every audited 2D member carries decodable content.
-- Hero model members stay absent; tests stop before hero decoding by
-- failing earlier (missing 2D member) or assert the hero-stage error.
-- Message banks 0 and 10 carry short synthetic labels/templates built from
-- real charmap codes, so message lowering runs before the hero stage.
local EOS_UNIT = 0xFFFF
local ITEM_SUBSTITUTION = { 0xFFFE, 0x0108, 2, 0, 0 }
local QUANTITY_SUBSTITUTION = { 0xFFFE, 0x0134, 2, 1, 0 }

local codeForGlyph = nil
local function glyphCode(text)
  if codeForGlyph == nil then
    codeForGlyph = {}
    for code, display in pairs(charmap.glyphs) do
      codeForGlyph[display] = code
    end
  end
  local code = codeForGlyph[text]
  assert(code ~= nil, "fixture glyph has no charmap code: " .. text)
  return code
end

local function messageUnits(parts)
  local units = {}
  for _, part in ipairs(parts) do
    if type(part) == "string" then
      for index = 1, #part do
        units[#units + 1] = glyphCode(part:sub(index, index))
      end
    else
      for _, unit in ipairs(part) do
        units[#units + 1] = unit
      end
    end
  end
  units[#units + 1] = EOS_UNIT
  return units
end

local function syntheticMessageBanks()
  local bank10 = {}
  for _ = 1, 56 do
    bank10[#bank10 + 1] = { EOS_UNIT }
  end
  bank10[2] = messageUnits({ "TOSS" })
  bank10[3] = messageUnits({ "REGISTER" })
  bank10[6] = messageUnits({ "YES" })
  bank10[9] = messageUnits({ "CANCEL" })
  bank10[19] = messageUnits({ "DESELECT" })
  bank10[47] = messageUnits({ "Move ", ITEM_SUBSTITUTION, "." })
  bank10[54] = messageUnits({ "Toss ", ITEM_SUBSTITUTION, "?" })
  bank10[56] = messageUnits({ "Toss ", QUANTITY_SUBSTITUTION, " ", ITEM_SUBSTITUTION, "?" })
  local bank0 = {}
  for _ = 1, 4 do
    bank0[#bank0 + 1] = { EOS_UNIT }
  end
  bank0[4] = messageUnits({ "MOVE" })
  return { [0] = bank0, [10] = bank10 }
end
local function fixture(opts)
  opts = opts or {}
  local members = {}
  for i = 1, 95 do
    members[i] = string.rep("\0", 4)
  end
  local BagSources = require("romdump.src.config.BagSources")
  members[BagSources.chars.upper + 1] = charData(64)
  members[BagSources.chars.lower + 1] = charData(256)
  members[BagSources.palettes.upper + 1] = palette256()
  members[BagSources.palettes.lower + 1] = palette256()
  for _, memberId in ipairs({
    BagSources.screens.upperBase,
    BagSources.screens.upperAlternate,
    BagSources.screens.upperBackdropMale,
    BagSources.screens.upperBackdropFemale,
    BagSources.screens.listSlots,
    BagSources.screens.listWash,
    BagSources.screens.actionSlots,
    BagSources.screens.actionWash,
    BagSources.screens.confirmation,
    BagSources.screens.quantity,
    BagSources.screens.quantityAlt,
  }) do
    members[memberId + 1] = screenData()
  end
  local tabCells = {}
  for _ = 1, 8 do
    tabCells[#tabCells + 1] = { { x = 0, y = 0, tile = 0, size = 2 } }
  end
  members[BagSources.sprites.tabs.char + 1] = charData(200)
  members[BagSources.sprites.tabs.cell + 1] = cellData(tabCells)
  members[BagSources.sprites.tabs.palette + 1] = palette256()
  members[BagSources.sprites.tabs.anim + 1] = animData(9)
  local cursorCells = {}
  for _ = 1, 4 do
    cursorCells[#cursorCells + 1] = { { x = 0, y = 0, tile = 0, size = 1 } }
  end
  members[BagSources.sprites.cursor.char + 1] = charData(16)
  members[BagSources.sprites.cursor.cell + 1] = cellData(cursorCells)
  members[BagSources.sprites.cursor.palette + 1] = palette256()
  members[BagSources.sprites.cursor.anim + 1] = animData(4)
  members[BagSources.sprites.strip.char + 1] = charData(40)
  members[BagSources.sprites.strip.cell + 1] = cellData({ { { x = 0, y = 0, tile = 0, size = 2 } } })
  members[BagSources.sprites.strip.palette + 1] = palette256()
  members[BagSources.sprites.strip.anim + 1] = animData(1)
  members[BagSources.chars.registrationMarker + 1] = charData(26)
  if opts.tamper then
    members = opts.tamper(members)
  end
  local messageBanks = syntheticMessageBanks()
  if opts.messageTamper then
    opts.messageTamper(messageBanks)
  end
  local maxBank = 10
  local orderedMembers = {}
  for bankId = 0, maxBank do
    if messageBanks[bankId] then
      orderedMembers[bankId + 1] = FieldMessageBank.encodeForTests(messageBanks[bankId], 7)
    else
      orderedMembers[bankId + 1] = FieldMessageBank.encodeForTests({ { EOS_UNIT } }, 7)
    end
  end
  local messageBytes = narc(orderedMembers)
  local bytes = narc(members)
  local info = { fileId = 15, narcId = 15, path = "a/0/1/5", symbol = "NARC_a_0_1_5", alias = "bag_ui" }
  return {
    _version = "soulsilver",
    _metadata = { sha1 = "rom-sha" },
    resolvedNarc = function(_)
      return info
    end,
    read = function(_)
      return bytes
    end,
    openNarc = function(_, alias)
      assert(alias == "bag_ui" or alias == "messages", "unexpected archive " .. tostring(alias))
      local Narc = require("libs.nds.src.nitro.Narc")
      if alias == "messages" then
        return assert(Narc.open(messageBytes, alias))
      end
      return assert(Narc.open(bytes, alias))
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "soulsilver"
    end,
  } --[[@as RomFs]]
end

function T.missing_required_member_fails_with_the_protocol_error()
  local BagSources = require("romdump.src.config.BagSources")
  local romFs = fixture({
    tamper = function(members)
      local short = {}
      for index = 1, BagSources.screens.listSlots do
        short[index] = members[index]
      end
      return short
    end,
  })
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.isNil(bundle, "a missing screen member must not compile")
  local typed = assert(err, "a missing screen member must carry an error")
  Assert.equal(typed.code, BagAssetCompiler.ERROR.SOURCE_INVALID)
end

function T.corrupt_member_fails_with_the_protocol_error()
  local BagSources = require("romdump.src.config.BagSources")
  local romFs = fixture({
    tamper = function(members)
      members[BagSources.chars.upper + 1] = "not-a-char-container"
      return members
    end,
  })
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.isNil(bundle, "a corrupt char member must not compile")
  local typed = assert(err, "a corrupt char member must carry an error")
  Assert.equal(typed.code, BagAssetCompiler.ERROR.SOURCE_INVALID)
end

function T.complete_synthetic_archive_reaches_the_hero_stage()
  local romFs = fixture()
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.isNil(bundle, "synthetic bytes cannot supply hero models")
  local typed = assert(err, "the hero stage must fail loudly on synthetic bytes")
  Assert.equal(typed.code, BagAssetCompiler.ERROR.SOURCE_INVALID)
end

function T.animated_source_sequence_is_rejected_as_a_static_only_violation()
  local BagSources = require("romdump.src.config.BagSources")
  local romFs = fixture({
    tamper = function(members)
      members[BagSources.sprites.strip.anim + 1] = animTwoFrameSequence()
      return members
    end,
  })
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.isNil(bundle, "an animated source sequence must not compile to a runtime timeline")
  local typed = assert(err, "an animated source sequence must carry an error")
  Assert.equal(typed.code, BagAssetCompiler.ERROR.SOURCE_INVALID)
  Assert.notNil(
    tostring(typed.message):find("static"),
    "the failure must name the static-only contract rather than a later stage"
  )
end

function T.unsupported_message_substitution_fails_with_the_protocol_error()
  local romFs = fixture({
    messageTamper = function(banks)
      banks[10][54] = messageUnits({ "Toss ", { 0xFFFE, 0x0103, 2, 0, 0 }, "?" })
    end,
  })
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.isNil(bundle, "an out-of-vocabulary substitution must not compile")
  local typed = assert(err, "an out-of-vocabulary substitution must carry an error")
  Assert.equal(typed.code, BagAssetCompiler.ERROR.SOURCE_INVALID)
end

function T.message_bank_control_break_fails_with_the_protocol_error()
  local romFs = fixture({
    messageTamper = function(banks)
      banks[10][2] = messageUnits({ "TR", { 0xFFFE, 0x0200, 1, 0 }, "ASH" })
    end,
  })
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.isNil(bundle, "a control break inside a label must not compile")
  local typed = assert(err, "a control break inside a label must carry an error")
  Assert.equal(typed.code, BagAssetCompiler.ERROR.SOURCE_INVALID)
end

function T.producer_declares_the_audited_message_selection()
  local BagSources = require("romdump.src.config.BagSources")
  Assert.deepEqual(BagSources.spriteStates.tabs.normal, {
    { animation = 0, palette = 0 },
    { animation = 1, palette = 1 },
    { animation = 2, palette = 2 },
    { animation = 3, palette = 3 },
    { animation = 4, palette = 4 },
    { animation = 5, palette = 5 },
    { animation = 6, palette = 6 },
    { animation = 7, palette = 7 },
  })
  Assert.deepEqual(BagSources.spriteStates.tabs.selected, { animation = 8, palette = 9 })
  Assert.deepEqual(BagSources.spriteStates.strip, { animation = 0 })
  Assert.deepEqual(BagSources.lowerLayers, {
    browse = { "listWash", "listSlots" },
    action = { "actionWash", "actionSlots" },
    quantity = { "quantity", "quantityAlt" },
    confirmation = { "confirmation" },
  })
  local messages = assert(BagSources.messages, "the producer must declare its message selection")
  Assert.deepEqual(messages.actionLabels, {
    toss = { bank = 10, index = 1 },
    move = { bank = 0, index = 3 },
    register = { bank = 10, index = 2 },
    unregister = { bank = 10, index = 18 },
    cancel = { bank = 10, index = 8 },
    confirm = { bank = 10, index = 5 },
  })
  Assert.deepEqual(messages.templates, {
    movePrompt = { bank = 10, index = 46 },
    tossQuantity = { bank = 10, index = 53 },
    tossConfirm = { bank = 10, index = 55 },
  })
end

local function constantChannel()
  return { source = "constant", value = 0 }
end

local function trsClip(id, semanticName)
  return {
    id = id,
    name = id,
    category = "joint",
    kind = "trs",
    frameCount = 4,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { semanticName },
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = { { 0, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
            rot = constantChannel(),
            scale = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
          },
        },
      },
    },
  }
end

local function dynamicMaterial()
  return {
    id = 0,
    name = "widget",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
    alphaMode = "opaque",
    polygonMode = "modulation",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local function heroDescriptor(gender)
  local clips = {}
  for _, pocket in ipairs(POCKETS) do
    clips[#clips + 1] = trsClip(gender .. ".pose." .. pocket, "pocket." .. pocket .. ".pose")
    clips[#clips + 1] = trsClip(gender .. ".pattern." .. pocket, "pocket." .. pocket .. ".pattern")
  end
  clips[#clips + 1] = trsClip(gender .. ".material", "bag.material")
  return {
    schema = ModelAsset.SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { dynamicMaterial() },
    animations = clips,
  }
end

local function syntheticBundle(marker)
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] = {
      pocket = pocket,
      pose = "pocket." .. pocket .. ".pose",
      pattern = "pocket." .. pocket .. ".pattern",
    }
  end
  local tabs = {}
  for i = 0, 7 do
    tabs[#tabs + 1] = { x = i * 32, y = 0, width = 32, height = 32 }
  end
  local manifest = {
    schema = "g4-bag-assets-v3",
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = { image = "assets/generated/bag/upper-backdrop-male.png", width = 256, height = 256 },
        female = { image = "assets/generated/bag/upper-backdrop-female.png", width = 256, height = 256 },
      },
      description = {
        frame = {
          image = "assets/generated/bag/upper-base.png",
          alternateImage = "assets/generated/bag/upper-alternate.png",
          rect = { x = 0, y = 144, width = 256, height = 48 },
        },
        textRect = { x = 20, y = 144, width = 236, height = 48 },
      },
      model = { male = heroDescriptor("male"), female = heroDescriptor("female") },
      animations = {
        states = states,
        material = { male = "male.material", female = "female.material" },
      },
      presentation = {
        camera = {
          target = { x = 0, y = 0, z = 0 },
          distance = 339.9,
          angleXDegrees = 328.4,
          angleYDegrees = 28.3,
          perspectiveType = 0,
          perspectiveAngle = 256,
          clipNear = 123.0,
          clipFar = 1700.0,
        },
        transform = {
          translation = { x = 0, y = -48, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
        lights = {
          count = 4,
          color = { r = 31, g = 31, b = 31 },
          vectors = {
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
          },
        },
      },
    },
    interactive = {
      backgrounds = {
        browse = { image = "assets/generated/bag/background-browse.png", width = 256, height = 192 },
        action = { image = "assets/generated/bag/background-action.png", width = 256, height = 192 },
        quantity = { image = "assets/generated/bag/background-quantity.png", width = 256, height = 192 },
        confirmation = { image = "assets/generated/bag/background-confirmation.png", width = 256, height = 192 },
      },
      pocketTabs = {
        rects = tabs,
        normal = {
          { image = "assets/generated/bag/tab-normal-1.png", width = 16, height = 16 },
          { image = "assets/generated/bag/tab-normal-2.png", width = 16, height = 16 },
          { image = "assets/generated/bag/tab-normal-3.png", width = 16, height = 16 },
          { image = "assets/generated/bag/tab-normal-4.png", width = 16, height = 16 },
          { image = "assets/generated/bag/tab-normal-5.png", width = 16, height = 16 },
          { image = "assets/generated/bag/tab-normal-6.png", width = 16, height = 16 },
          { image = "assets/generated/bag/tab-normal-7.png", width = 16, height = 16 },
          { image = "assets/generated/bag/tab-normal-8.png", width = 16, height = 16 },
        },
        selected = { image = "assets/generated/bag/tab-selected-frame-1.png", width = 16, height = 16 },
      },
      itemSlots = {
        slots = {
          { rect = { x = 32, y = 40, width = 88, height = 32 }, iconCenter = { x = 48, y = 56 } },
          { rect = { x = 160, y = 40, width = 88, height = 32 }, iconCenter = { x = 176, y = 56 } },
          { rect = { x = 32, y = 80, width = 88, height = 32 }, iconCenter = { x = 48, y = 96 } },
          { rect = { x = 160, y = 80, width = 88, height = 32 }, iconCenter = { x = 176, y = 96 } },
          { rect = { x = 32, y = 120, width = 88, height = 32 }, iconCenter = { x = 48, y = 136 } },
          { rect = { x = 160, y = 120, width = 88, height = 32 }, iconCenter = { x = 176, y = 136 } },
        },
        focus = { image = "assets/generated/bag/focus-frame-1.png", width = 16, height = 16 },
        registration = {
          slot1 = { image = "assets/generated/bag/registration-slot-1.png", width = 40, height = 16 },
          slot2 = { image = "assets/generated/bag/registration-slot-2.png", width = 40, height = 16 },
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = { x = 192, y = 168, width = 56, height = 16 },
      text = {
        actions = {
          toss = "TOSS",
          move = "MOVE",
          register = "REGISTER",
          unregister = "DESELECT",
          cancel = "CANCEL",
          confirm = "YES",
        },
        movePrompt = {
          segments = { { kind = "text", value = "Move " }, { kind = "item" }, { kind = "text", value = "." } },
        },
        tossQuantity = {
          segments = { { kind = "text", value = "Toss " }, { kind = "item" }, { kind = "text", value = "?" } },
        },
        tossConfirm = {
          segments = {
            { kind = "text", value = "Toss " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "?" },
          },
        },
      },
      overlays = {
        actionMenu = {
          buttons = {
            { x = 8, y = 136, width = 80, height = 16 },
            { x = 104, y = 136, width = 80, height = 16 },
            { x = 8, y = 168, width = 80, height = 16 },
            { x = 104, y = 168, width = 80, height = 16 },
          },
        },
        quantity = {
          digits = {
            { x = 128, y = 112, width = 16, height = 24 },
            { x = 160, y = 112, width = 16, height = 24 },
            { x = 192, y = 112, width = 16, height = 24 },
          },
        },
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
      },
      widgets = {
        sourceStrip = {
          image = "assets/generated/bag/source-strip-frame-1.png",
          width = 32,
          height = 16,
          placement = { x = 177, y = 14 },
          states = { browsing = false },
        },
      },
    },
  }
  local assets = {}
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    assets[path] = "payload:" .. path
  end
  return {
    marker = marker,
    manifest = manifest,
    dependencies = { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA, fixture = true },
    assets = assets,
  }
end

function T.writer_publishes_the_class_and_reports_ready()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = syntheticBundle(BagCache.marker("rom", "deps"))
  Assert.isTrue(BagCacheWriter.write(cacheFs, bundle))
  Assert.isTrue(BagCacheWriter.isReady(cacheFs, bundle.marker))
  local loaded = BagCache.loadManifest(cacheFs)
  Assert.equal(loaded.schema, "g4-bag-assets-v3")
  Assert.equal(loaded.hero.presentation.lights.count, 4)
  Assert.deepEqual(loaded.hero.presentation.lights.color, { r = 31, g = 31, b = 31 })
  Assert.equal(#loaded.hero.presentation.lights.vectors, 4)
  for _, vector in ipairs(loaded.hero.presentation.lights.vectors) do
    Assert.deepEqual(vector, { x = 1, y = 0, z = 0 }, "published light vectors must round-trip")
  end
  Assert.deepEqual(
    cacheFs:loadLua(BagCache.provenancePath()),
    bundle.dependencies,
    "published bag dependencies must read back from the provenance path"
  )
end

function T.cache_readiness_requires_published_provenance()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = syntheticBundle(BagCache.marker("rom", "deps"))
  Assert.isTrue(BagCacheWriter.write(cacheFs, bundle))
  Assert.isTrue(BagCache.isReady(cacheFs, bundle.marker), "the complete published class is ready")
  cacheFs:remove(BagCache.provenancePath())
  Assert.isFalse(BagCache.isReady(cacheFs, bundle.marker), "a class without provenance is not ready")
end

function T.writer_rejects_a_bundle_without_dependencies()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = syntheticBundle(BagCache.marker("rom", "deps"))
  bundle.dependencies = nil
  local ok, err = pcall(BagCacheWriter.write, cacheFs, bundle)
  Assert.isFalse(ok, "a bundle without dependencies must not publish")
  Assert.isTrue(Errors.is(err), "the failure must be structured")
  Assert.equal(err.code, BagCacheWriter.ERROR.BUNDLE_INVALID)
  Assert.isNil(cacheFs:read(BagCache.markerPath()), "no marker may leak from an incomplete bundle")
end

function T.writer_rejects_a_bundle_missing_a_referenced_asset()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local first = syntheticBundle(BagCache.marker("rom", "deps"))
  Assert.isTrue(BagCacheWriter.write(cacheFs, first))
  local second = syntheticBundle(BagCache.marker("rom", "deps2"))
  second.assets["assets/generated/bag/tab-normal-1.png"] = nil
  local ok, err = pcall(BagCacheWriter.write, cacheFs, second)
  Assert.isFalse(ok, "a bundle missing a referenced asset must not publish")
  Assert.isTrue(Errors.is(err), "the failure must be structured")
  Assert.equal(cacheFs:read(BagCache.markerPath()), first.marker, "the previous marker must survive")
  Assert.isTrue(BagCacheWriter.isReady(cacheFs, first.marker), "the previous class must stay readable")
end

function T.writer_rejects_an_invalid_manifest_before_staging()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = syntheticBundle(BagCache.marker("rom", "deps"))
  bundle.manifest.interactive.pocketTabs.rects[8] = nil
  local ok, err = pcall(BagCacheWriter.write, cacheFs, bundle)
  Assert.isFalse(ok, "an invalid manifest must not publish")
  Assert.isTrue(Errors.is(err), "the failure must be structured")
  Assert.isNil(cacheFs:read(BagCache.markerPath()), "no marker may leak from a rejected bundle")
end

return { tests = T }
