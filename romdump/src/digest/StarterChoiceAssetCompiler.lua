-- Compiles the retail choose-starter application resources into the
-- source-independent starter-choice cache family. The two chooser archives
-- carry four 3D resource groups (tabletop, turntable, ball, ball effect),
-- three joint clips plus one material clip, the species-display sprite
-- groups, and the chooser message bank supplies the normalized prompts. All
-- Nitro/text decoding reuses the existing digest helpers; this module owns
-- only source selection, semantic role assignment, unit normalization, and
-- the dependency record. Source basis: pret/pokeheartgold
-- src/choose_starter_app.c and src/choose_starter.c.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
local charmap = require("romdump.src.reference.hgss.charmap")

local StarterChoiceAssetCompiler = {}

StarterChoiceAssetCompiler.ERROR = { SOURCE_INVALID = "STARTER_CHOICE_SOURCE_INVALID" }

-- Producer-only source selection. The main archive holds the four 3D models
-- (members 0-3) and their four animation resources (members 4-7); the sub
-- archive holds the background groups followed by the three species-display
-- sprite groups, each with a dedicated palette member.
local MAIN_ARCHIVE = "NARC_application_choose_starter_choose_starter_main_res"
local SUB_ARCHIVE = "NARC_application_choose_starter_choose_starter_sub_res"
local MODEL_MEMBERS = { tabletop = 0, turntable = 1, ball = 2, ballEffect = 3 }
local ANIM_MEMBERS = { effect = 4, open = 5, rock = 6, turntable = 7 }
local MESSAGE_BANK = 190
local MESSAGE_INITIAL_INDEX = 0
local MESSAGE_CONFIRM_INDEX = 7
local SPRITE_GROUPS = {
  chikorita = { char = 17, cell = 18, palette = 6 },
  cyndaquil = { char = 20, cell = 21, palette = 7 },
  totodile = { char = 23, cell = 24, palette = 8 },
}
local SPECIES_ORDER = { "chikorita", "cyndaquil", "totodile" }

-- Normalized application state constants. The camera out/inside values are
-- the pinned retail constants in decimal degrees with the retail look-at
-- targets and distances; the ball placements are the normalized lateral
-- tabletop layout for the three presentation slots.
local SCENE_CONSTANTS = {
  ballPositions = {
    { x = -16, y = 0, z = 0 },
    { x = 0, y = 0, z = 0 },
    { x = 16, y = 0, z = 0 },
  },
  camera = {
    out = { angleX = -49.57, perspective = 24.805, target = { x = 0, y = 0, z = 14 }, distance = 100 },
    inside = { angleX = -30.76, perspective = 22.7, target = { x = 0, y = 0, z = 12 }, distance = 60 },
    transitionTicks = 8,
  },
  ballYRotation = { out = 0, inside = 180 },
}

---@param message string
---@param context Errors.Context|nil
local function sourceError(message, context)
  Errors.raise(StarterChoiceAssetCompiler.ERROR.SOURCE_INVALID, message, context or {})
end

---@param archive Narc
---@param archiveName string
---@param memberId integer
---@param role string
---@param dependencies table<string, unknown>[]
---@return string
local function readMember(archive, archiveName, memberId, role, dependencies)
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    sourceError("starter-choice source member is unavailable: " .. tostring(err), {
      archive = archiveName,
      memberId = memberId,
      role = role,
    })
  end
  dependencies[#dependencies + 1] = {
    archive = archiveName,
    memberId = memberId,
    role = role,
    sha1 = Hashing.sha1hex(bytes),
  }
  return bytes
end

---@param romFs RomFs
---@param symbol string
---@return Narc|nil, Errors.Error|nil
local function openArchive(romFs, symbol)
  local archive, err = romFs:openNarc(symbol)
  if not archive then
    sourceError("starter-choice source archive is unavailable: " .. tostring(err), { archive = symbol })
  end
  return archive
end

---@param bytes string
---@param memberId integer
---@param role string
---@return table<string, unknown>
local function decodeModel(bytes, memberId, role)
  local ok, model = pcall(Nsbmd.decode, bytes, { alias = MAIN_ARCHIVE, memberId = memberId })
  if not ok then
    sourceError("starter-choice 3D resource is not a decodable model: " .. tostring(model), {
      memberId = memberId,
      role = role,
    })
  end
  ---@cast model table<string, unknown>
  if #model.models ~= 1 then
    sourceError("starter-choice 3D resource carries an unexpected model count", {
      memberId = memberId,
      role = role,
      modelCount = #model.models,
    })
  end
  return model
end

---@param bytes string
---@param memberId integer
---@param role string
---@param clipId string
---@return table<string, unknown>
local function compileClip(bytes, memberId, role, clipId)
  local decoded, err = NitroAnimation.decode(bytes, { alias = MAIN_ARCHIVE, memberId = memberId })
  if not decoded then
    sourceError("starter-choice animation resource is not decodable: " .. tostring(err), {
      memberId = memberId,
      role = role,
    })
  end
  ---@cast decoded { animations: table[] }
  if #decoded.animations ~= 1 then
    sourceError("starter-choice animation resource carries an unexpected animation count", {
      memberId = memberId,
      role = role,
      animationCount = #decoded.animations,
    })
  end
  local ok, clip = pcall(MapPropAnimCompiler.compileDecoded, decoded, {
    name = decoded.animations[1].name,
    id = clipId,
    source = { type = "nitro", format = decoded.format },
  })
  if not ok then
    if Errors.is(clip) then
      ---@cast clip Errors.Error
      sourceError("starter-choice animation resource failed to compile: " .. clip.message, {
        memberId = memberId,
        role = role,
        cause = clip.code,
      })
    end
    error(clip, 0)
  end
  return clip
end

---@param bytes string
---@param kind string
---@param role string
---@param memberId integer
---@return table<string, unknown>
local function decodeG2d(kind, bytes, role, memberId)
  local value, err = G2dDecoder[kind](bytes, { label = role })
  if not value then
    assert(err)
    sourceError("starter-choice sprite resource failed " .. kind .. ": " .. err.message, {
      memberId = memberId,
      role = role,
      cause = err.code,
    })
  end
  return value
end

-- Render one object cell of 4bpp tiles into an RGBA surface using the first
-- palette bank. Pixel value 0 is transparent, matching the intro sprite
-- composition.
---@param char table<string, unknown>
---@param palette table<string, unknown>
---@param cell table<string, unknown>
---@param role string
---@return { width: integer, height: integer, rgba: string }
local function renderCell(char, palette, cell, role)
  if char.depth ~= 3 then
    sourceError("starter-choice sprites are 4bpp", { role = role, depth = char.depth })
  end
  local tileCount = #char.tiles / 32
  local colors = palette.colors
  if type(colors) ~= "table" then
    sourceError("starter-choice palette carries no colors", { role = role })
  end
  local minX, minY, maxX, maxY
  for _, object in ipairs(cell.objs) do
    minX = minX == nil and object.x or math.min(minX, object.x)
    minY = minY == nil and object.y or math.min(minY, object.y)
    maxX = maxX == nil and object.x + object.width or math.max(maxX, object.x + object.width)
    maxY = maxY == nil and object.y + object.height or math.max(maxY, object.y + object.height)
  end
  if minX == nil then
    sourceError("starter-choice sprite cell has no objects", { role = role })
  end
  local width, height = maxX - minX, maxY - minY
  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  for _, object in ipairs(cell.objs) do
    local columns, rows = object.width / 8, object.height / 8
    for row = 0, rows - 1 do
      for column = 0, columns - 1 do
        local tileColumn = object.flipH and columns - 1 - column or column
        local tileRow = object.flipV and rows - 1 - row or row
        local tile = object.tile + tileRow * columns + tileColumn
        if tile < 0 or tile >= tileCount then
          sourceError("starter-choice sprite tile reference exceeds char data", { role = role, tile = tile })
        end
        local base = tile * 32
        for py = 0, 7 do
          for px = 0, 7 do
            local byte = string.byte(char.tiles, base + py * 4 + math.floor(px / 2) + 1)
            local value = px % 2 == 0 and byte % 16 or math.floor(byte / 16)
            if value ~= 0 then
              local color = colors[value + 1]
              if not color then
                sourceError("starter-choice sprite pixel references a missing palette entry", {
                  role = role,
                  value = value,
                })
              end
              local dx = object.x - minX + column * 8 + (object.flipH and 7 - px or px)
              local dy = object.y - minY + row * 8 + (object.flipV and 7 - py or py)
              local offset = (dy * width + dx) * 4
              rgba[offset + 1], rgba[offset + 2], rgba[offset + 3], rgba[offset + 4] = color.r, color.g, color.b, 255
            end
          end
        end
      end
    end
  end
  local out = {}
  for i = 1, #rgba, 4096 do
    out[#out + 1] = string.char(unpack(rgba, i, math.min(i + 4095, #rgba)))
  end
  return { width = width, height = height, rgba = table.concat(out) }
end

---@param bank { messages: table[] }
---@param index integer
---@param role string
---@return string
local function messageText(bank, index, role)
  local message = bank.messages[index + 1]
  if not message then
    sourceError("starter-choice message bank is missing the " .. role .. " entry", { index = index })
  end
  local tokens, err = FieldMessageTokenizer.tokenize(message.raw, charmap, {
    bankId = MESSAGE_BANK,
    messageId = index,
  })
  if not tokens then
    assert(err)
    sourceError("starter-choice message entry does not tokenize: " .. err.message, { index = index, role = role })
  end
  local ok, text = pcall(FieldMessageText.tokensToText, tokens)
  if not ok or type(text) ~= "string" or text == "" then
    sourceError("starter-choice message entry has no decoded text", { index = index, role = role })
  end
  return text
end

---@param romFs RomFs
---@return table<string, unknown>
local function _compile(romFs)
  assert(
    romFs and type(romFs.metadata) == "function" and type(romFs.openNarc) == "function",
    "starter-choice compilation requires source metadata and archive reader"
  )
  local metadata = romFs:metadata()
  assert(
    type(metadata) == "table" and type(metadata.sha1) == "string",
    "starter-choice source metadata must carry sha1"
  )

  local dependencies = {}
  local main = openArchive(romFs, MAIN_ARCHIVE)
  local modelBytes = {}
  for _, role in ipairs({ "tabletop", "turntable", "ball", "ballEffect" }) do
    modelBytes[role] = readMember(main, MAIN_ARCHIVE, MODEL_MEMBERS[role], "model:" .. role, dependencies)
  end
  local animBytes = {}
  for _, role in ipairs({ "effect", "open", "rock", "turntable" }) do
    animBytes[role] = readMember(main, MAIN_ARCHIVE, ANIM_MEMBERS[role], "animation:" .. role, dependencies)
  end

  local sub = openArchive(romFs, SUB_ARCHIVE)
  local spriteBytes = {}
  for _, id in ipairs(SPECIES_ORDER) do
    local group = SPRITE_GROUPS[id]
    spriteBytes[id] = {
      char = readMember(sub, SUB_ARCHIVE, group.char, "sprite:" .. id .. ":char", dependencies),
      cell = readMember(sub, SUB_ARCHIVE, group.cell, "sprite:" .. id .. ":cell", dependencies),
      palette = readMember(sub, SUB_ARCHIVE, group.palette, "sprite:" .. id .. ":palette", dependencies),
    }
  end

  local messageInfo = romFs:resolvedNarc("messages")
  if not messageInfo then
    sourceError("starter-choice message archive is unavailable", { archive = "messages" })
  end
  local messageArchiveBytes = romFs:read(messageInfo.fileId)
  if not messageArchiveBytes then
    sourceError("starter-choice message archive bytes are unavailable", { archive = "messages" })
  end
  dependencies[#dependencies + 1] =
    { archive = "messages", memberId = -1, role = "message-archive", sha1 = Hashing.sha1hex(messageArchiveBytes) }
  local messageArchive = openArchive(romFs, "messages")
  local bankBytes = readMember(messageArchive, "messages", MESSAGE_BANK, "message-bank", dependencies)
  local bank = FieldMessageBank.decode(bankBytes, { label = "starter-choice-bank", messageId = MESSAGE_BANK })
  if not bank then
    sourceError("starter-choice message bank does not decode", { bank = MESSAGE_BANK })
  end
  ---@cast bank { messages: table[] }

  local tabletopModel = decodeModel(modelBytes.tabletop, MODEL_MEMBERS.tabletop, "tabletop")
  local turntableModel = decodeModel(modelBytes.turntable, MODEL_MEMBERS.turntable, "turntable")
  local ballModel = decodeModel(modelBytes.ball, MODEL_MEMBERS.ball, "ball")
  local effectModel = decodeModel(modelBytes.ballEffect, MODEL_MEMBERS.ballEffect, "ballEffect")

  local rockClip = compileClip(animBytes.rock, ANIM_MEMBERS.rock, "rock", "ball-rock")
  local openClip = compileClip(animBytes.open, ANIM_MEMBERS.open, "open", "ball-open")
  local effectClip = compileClip(animBytes.effect, ANIM_MEMBERS.effect, "effect", "ball-effect")
  local turntableClip = compileClip(animBytes.turntable, ANIM_MEMBERS.turntable, "turntable", "turntable")

  local meshes, textures = {}, {}
  local unresolvedMaterials = {}
  local tabletopCompiled = ModelAssetCompiler.compileModel(
    tabletopModel.models[1],
    { textureByName = {}, paletteByName = {} },
    meshes,
    textures,
    {
      role = "tabletop",
      modelArchive = MAIN_ARCHIVE,
      modelMemberId = MODEL_MEMBERS.tabletop,
      modelName = tabletopModel.models[1].name,
    }
  )
  for _, entry in ipairs(tabletopCompiled.unresolved) do
    unresolvedMaterials[#unresolvedMaterials + 1] = entry
  end

  ---@param decoded table<string, unknown>
  ---@param clips table<string, unknown>
  ---@param memberId integer
  ---@param role string
  ---@return table<string, unknown>
  local function dynamicDescriptor(decoded, clips, memberId, role)
    local model = decoded.models[1]
    local descriptor, unresolved = DynamicModelCompiler.compile(model, decoded, decoded.embeddedTextures, {
      clips = clips,
    }, {
      role = role,
      modelArchive = MAIN_ARCHIVE,
      modelMemberId = memberId,
      modelName = model.name,
    }, memberId, textures, meshes)
    for _, entry in ipairs(unresolved) do
      unresolvedMaterials[#unresolvedMaterials + 1] = entry
    end
    descriptor.memberId = nil
    return descriptor
  end

  local ballDescriptor = dynamicDescriptor(ballModel, { rockClip, openClip }, MODEL_MEMBERS.ball, "ball")
  local manifest = {
    schema = StarterChoiceAssetCache.SCHEMA,
    reference = { width = 256, height = 192 },
    models = {
      tabletop = {
        schema = ModelAsset.SCHEMA,
        kind = "static",
        batches = tabletopCompiled.batches,
        materials = tabletopCompiled.materials,
      },
      turntable = dynamicDescriptor(turntableModel, { turntableClip }, MODEL_MEMBERS.turntable, "turntable"),
      ballEffect = dynamicDescriptor(effectModel, { effectClip }, MODEL_MEMBERS.ballEffect, "ballEffect"),
      ball1 = ballDescriptor,
      ball2 = ballDescriptor,
      ball3 = ballDescriptor,
    },
    animations = {
      ballRock = { "ball-rock", "ball-rock", "ball-rock" },
      ballOpen = "ball-open",
      ballEffect = "ball-effect",
      turntable = "turntable",
    },
    scene = {
      ballPositions = SCENE_CONSTANTS.ballPositions,
      camera = SCENE_CONSTANTS.camera,
      ballYRotation = SCENE_CONSTANTS.ballYRotation,
      wobble = { frameCount = rockClip.frameCount },
    },
    messages = {
      initial = messageText(bank, MESSAGE_INITIAL_INDEX, "initial"),
      confirm = messageText(bank, MESSAGE_CONFIRM_INDEX, "confirm"),
    },
    speciesSprites = {},
  }

  local assets = {}
  for sha1, batch in pairs(meshes) do
    assets[MapAssetCache.geometryPath(sha1)] = MeshWriter.encode(batch)
  end
  for sha1, tex in pairs(textures) do
    assets[MapAssetCache.texturePath(sha1)] = PngWriter.encode(tex.width, tex.height, tex.pixels)
  end
  for _, id in ipairs(SPECIES_ORDER) do
    local group = spriteBytes[id]
    local char = decodeG2d("decodeChar", group.char, "sprite:" .. id, SPRITE_GROUPS[id].char)
    local cell = decodeG2d("decodeCell", group.cell, "sprite:" .. id, SPRITE_GROUPS[id].cell)
    local palette = decodeG2d("decodePalette", group.palette, "sprite:" .. id, SPRITE_GROUPS[id].palette)
    if #cell.cells < 1 then
      sourceError("starter-choice sprite has no display cell", { role = id })
    end
    local image = renderCell(char, palette, cell.cells[1], id)
    if image.width < 1 or image.height < 1 then
      sourceError("starter-choice sprite rendered an empty surface", { role = id })
    end
    local path = StarterChoiceAssetCache.assetDir() .. "/" .. id .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.rgba)
    manifest.speciesSprites[id] = { image = path, width = image.width, height = image.height }
  end

  local dependencyRecord = {
    cacheFormat = StarterChoiceAssetCache.FORMAT,
    schema = StarterChoiceAssetCache.SCHEMA,
    modelSchema = ModelAsset.SCHEMA,
    charmapVersion = FieldMessageCompiler.CHARMAP_VERSION,
    versionRomSha1 = metadata.sha1,
    sceneConstants = SCENE_CONSTANTS,
    messageSelection = { bank = MESSAGE_BANK, initial = MESSAGE_INITIAL_INDEX, confirm = MESSAGE_CONFIRM_INDEX },
    unresolvedMaterials = unresolvedMaterials,
    dependencies = dependencies,
  }

  local valid, err = StarterChoiceAssetCache.validateManifest(manifest)
  if not valid then
    assert(err)
    sourceError("compiled starter-choice manifest is invalid: " .. err.message, { cause = err.code })
  end

  return {
    marker = StarterChoiceAssetCache.marker(metadata.sha1, Hashing.hashLua(dependencyRecord)),
    manifest = manifest,
    dependencies = dependencyRecord,
    assets = assets,
  }
end

---@param romFs RomFs
---@return table<string, unknown>|nil bundle
---@return Errors.Error? err
function StarterChoiceAssetCompiler.compile(romFs)
  local ok, result = pcall(_compile, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result, 0)
end

return StarterChoiceAssetCompiler
