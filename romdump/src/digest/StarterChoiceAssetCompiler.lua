-- Compiles the retail choose-starter application resources into the
-- source-independent starter-choice cache family. The main chooser archive
-- carries four 3D resource groups (tabletop, turntable, ball, ball effect)
-- with three joint clips plus one material clip; the chooser message bank
-- supplies the semantic message roles; the scene constants normalize the
-- source ball ring, turntable, camera, and timing facts; and the chooser owns
-- one generated presentation backdrop. Candidate pictures are never compiled
-- here: the mon presentation pipeline owns portrait identity. All Nitro/text
-- decoding reuses the existing digest helpers; this module owns only source
-- selection, semantic role assignment, unit normalization, and the dependency
-- record. Source basis: pret/pokeheartgold src/choose_starter_app.c and
-- src/choose_starter.c.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
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
-- (members 0-3) and their four animation resources (members 4-7).
local MAIN_ARCHIVE = "NARC_application_choose_starter_choose_starter_main_res"
local MODEL_MEMBERS = { tabletop = 0, turntable = 1, ball = 2, ballEffect = 3 }
local ANIM_MEMBERS = { effect = 4, open = 5, rock = 6, turntable = 7 }
local MESSAGE_BANK = 190
-- Semantic message roles over bank 190: the initial top prompt, one confirm
-- description and one inspect description per candidate slot, and the normal
-- and confirm bottom prompts. Producer-only indices; runtime sees strings.
local MESSAGE_TOP_INITIAL = 0
local MESSAGE_CONFIRM = { 1, 2, 3 }
local MESSAGE_INSPECT = { 4, 5, 6 }
local MESSAGE_BOTTOM_NORMAL = 7
local MESSAGE_BOTTOM_CONFIRM = 8

-- Normalized application state constants. The camera out/inside values are
-- the pinned retail constants: decimal-degree X angles, full vertical fields
-- of view (the source perspective fields are half-angles, doubled here per
-- the repository camera-table convention), look-at targets, and distances.
-- The out pose is the resting boot pose from the source camera initializer
-- (target height 15 with the +14 Z shift); the inside pose is the source
-- zoom-in endpoint. The ball layout is the source ring model: the base
-- model position is radius 32 at model Y 14, the three slots sit 120 degrees
-- apart around Y starting from the selected ball, touch centers sit 13 above
-- the model origins, and the selected ball arcs over the source -30.76
-- degree endpoint around its touch point. The turntable advances one
-- 120-degree selection step at the source rotation rate. Timing carries only
-- source-observable boundaries: the eight-step camera path, the eight-step
-- inspect arc, the small-wobble source frame, and the two white fade
-- boundaries.
local CAMERA = {
  out = { angleX = -49.57, perspective = 49.61, target = { x = 0, y = 15, z = 14 }, distance = 100 },
  inside = { angleX = -30.76, perspective = 45.4, target = { x = 0, y = 0, z = 12 }, distance = 60 },
}
local BALL_LAYOUT = {
  radius = 32,
  modelY = 14,
  touchYOffsetY = 13,
  slotAnglesDegrees = { 0, 120, 240 },
  inspectArcDegrees = -30.76,
}
local TURNTABLE = {
  selectionStepDegrees = 120,
  rotationDegreesPerTick = 0.5,
}
local TIMING = {
  cameraTicks = 8,
  ballArcTicks = 8,
  smallWobbleFrame = 80,
  infoFadeTicks = 10,
  machineFadeTicks = 16,
}

-- Chooser-owned backdrop dimensions: one widescreen surface the host
-- composition stretches over the drawable area behind both logical surfaces.
local BACKDROP_WIDTH = 512
local BACKDROP_HEIGHT = 192

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

-- Deterministic chooser-owned backdrop: a vertical gradient in muted lab
-- tones with a soft horizontal vignette, carrying no interaction state. The
-- bytes are a pure function of the fixed palette below so every build for
-- every ROM emits the identical surface.
---@return { width: integer, height: integer, rgba: string }
local function renderBackdrop()
  local top = { r = 46, g = 62, b = 96 }
  local bottom = { r = 148, g = 132, b = 102 }
  local rgba = {}
  for y = 0, BACKDROP_HEIGHT - 1 do
    local alpha = y / (BACKDROP_HEIGHT - 1)
    for x = 0, BACKDROP_WIDTH - 1 do
      local edge = math.abs(x / (BACKDROP_WIDTH - 1) - 0.5) * 2
      local shade = 1 - edge * edge * 0.18
      local r = math.floor((top.r + (bottom.r - top.r) * alpha) * shade + 0.5)
      local g = math.floor((top.g + (bottom.g - top.g) * alpha) * shade + 0.5)
      local b = math.floor((top.b + (bottom.b - top.b) * alpha) * shade + 0.5)
      rgba[#rgba + 1] = string.char(r, g, b, 255)
    end
  end
  return { width = BACKDROP_WIDTH, height = BACKDROP_HEIGHT, rgba = table.concat(rgba) }
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

  local inspect, confirm = {}, {}
  for slot = 1, 3 do
    inspect[slot] = messageText(bank, MESSAGE_INSPECT[slot], "inspect:" .. slot)
    confirm[slot] = messageText(bank, MESSAGE_CONFIRM[slot], "confirm:" .. slot)
  end
  local backdropImage = renderBackdrop()
  local backdropPath = StarterChoiceAssetCache.assetDir() .. "/backdrop.png"
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
      ballLayout = {
        radius = BALL_LAYOUT.radius,
        modelY = BALL_LAYOUT.modelY,
        touchYOffsetY = BALL_LAYOUT.touchYOffsetY,
        slotAnglesDegrees = {
          BALL_LAYOUT.slotAnglesDegrees[1],
          BALL_LAYOUT.slotAnglesDegrees[2],
          BALL_LAYOUT.slotAnglesDegrees[3],
        },
        inspectArcDegrees = BALL_LAYOUT.inspectArcDegrees,
      },
      turntable = {
        selectionStepDegrees = TURNTABLE.selectionStepDegrees,
        rotationDegreesPerTick = TURNTABLE.rotationDegreesPerTick,
      },
      camera = {
        out = CAMERA.out,
        inside = CAMERA.inside,
      },
      timing = {
        cameraTicks = TIMING.cameraTicks,
        ballArcTicks = TIMING.ballArcTicks,
        smallWobbleFrame = TIMING.smallWobbleFrame,
        infoFadeTicks = TIMING.infoFadeTicks,
        machineFadeTicks = TIMING.machineFadeTicks,
      },
    },
    messages = {
      topInitial = messageText(bank, MESSAGE_TOP_INITIAL, "topInitial"),
      inspect = inspect,
      confirm = confirm,
      bottom = {
        normal = messageText(bank, MESSAGE_BOTTOM_NORMAL, "bottom:normal"),
        confirm = messageText(bank, MESSAGE_BOTTOM_CONFIRM, "bottom:confirm"),
      },
    },
    background = {
      image = backdropPath,
      width = backdropImage.width,
      height = backdropImage.height,
    },
  }

  local assets = {}
  for sha1, batch in pairs(meshes) do
    assets[MapAssetCache.geometryPath(sha1)] = MeshWriter.encode(batch)
  end
  for sha1, tex in pairs(textures) do
    assets[MapAssetCache.texturePath(sha1)] = PngWriter.encode(tex.width, tex.height, tex.pixels)
  end
  assets[backdropPath] = PngWriter.encode(backdropImage.width, backdropImage.height, backdropImage.rgba)

  local dependencyRecord = {
    cacheFormat = StarterChoiceAssetCache.FORMAT,
    schema = StarterChoiceAssetCache.SCHEMA,
    modelSchema = ModelAsset.SCHEMA,
    charmapVersion = FieldMessageCompiler.CHARMAP_VERSION,
    versionRomSha1 = metadata.sha1,
    sceneConstants = {
      camera = CAMERA,
      ballLayout = BALL_LAYOUT,
      turntable = TURNTABLE,
      timing = TIMING,
    },
    messageSelection = {
      bank = MESSAGE_BANK,
      topInitial = MESSAGE_TOP_INITIAL,
      inspect = MESSAGE_INSPECT,
      confirm = MESSAGE_CONFIRM,
      bottomNormal = MESSAGE_BOTTOM_NORMAL,
      bottomConfirm = MESSAGE_BOTTOM_CONFIRM,
    },
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
