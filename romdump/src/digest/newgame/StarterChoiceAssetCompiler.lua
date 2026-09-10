-- Compiles the retail choose-starter application resources into the
-- source-independent starter-choice cache family. The main chooser archive
-- carries four 3D resource groups (tabletop, turntable, ball, ball effect)
-- with three joint clips plus one material clip; the chooser message bank
-- supplies the semantic message roles; the scene constants normalize the
-- source ball ring, turntable, camera, and timing facts into the shared
-- runtime model unit; the visible info-surface artwork compiles from the
-- retail sub BG1/BG2 tile resources; and the machine surface carries the
-- retail 3D rear-plane clear color plus source window/portrait geometry. The
-- chooser window text palette compiles to source-independent text colors. The
-- host keeps one generated decorative backdrop. Candidate pictures are never
-- compiled here: the mon presentation pipeline owns portrait identity. All
-- Nitro/text decoding reuses the existing digest helpers; this module owns
-- only source selection, semantic role assignment, unit normalization, and
-- the dependency record. Source basis: pret/pokeheartgold
-- src/choose_starter_app.c and src/choose_starter.c.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local PngWriter = require("libs.assets.src.PngWriter")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
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
-- and confirm bottom prompts. Producer-only indices; runtime sees prepared
-- glyph lines.
local MESSAGE_TOP_INITIAL = 0
local MESSAGE_CONFIRM = { 1, 2, 3 }
local MESSAGE_INSPECT = { 4, 5, 6 }
local MESSAGE_BOTTOM_NORMAL = 7
local MESSAGE_BOTTOM_CONFIRM = 8

-- Normalized application state constants. The camera out/inside values are
-- the pinned retail constants: decimal-degree X angles, full vertical fields
-- of view (the source perspective fields are half-angles, doubled here per
-- the repository camera-table convention), absolute look-at targets, and
-- distances. The out pose is the resting boot pose from the source camera
-- initializer (target height 15 with the +14 Z shift); the inside pose is
-- the source zoom-in endpoint with the same fixed target height applied
-- (the source relative +12 Z shift). The ball layout is the source ring
-- model: the base model position is radius 32 at model Y 14, the three
-- slots sit 120 degrees apart around Y starting from the selected ball,
-- touch centers sit 13 above the model origins, and the selected ball arcs
-- over the source -30.76 degree endpoint around the distinct +13.453 pivot.
-- The turntable advances one 120-degree selection step at the normalized
-- source rotation rate. Timing carries only source-observable boundaries:
-- the eight-step camera path, the eight-step inspect arc, the small-wobble
-- source frame, and the two white fade boundaries.
local CAMERA = {
  out = { angleX = -49.57, perspective = 49.61, target = { x = 0, y = 15, z = 14 }, distance = 100 },
  inside = { angleX = -30.76, perspective = 45.4, target = { x = 0, y = 15, z = 12 }, distance = 60 },
}
-- Source perspective clipping planes in the same raw Nitro coordinate domain
-- as the camera distances above.
local CAMERA_CLIP = { near = 4, far = 256 }
local BALL_LAYOUT = {
  radius = 32,
  modelY = 14,
  touchYOffsetY = 13,
  inspectPivotYOffsetY = 13.453,
  slotAnglesDegrees = { 0, 120, 240 },
  inspectArcDegrees = -30.76,
}
local TURNTABLE = {
  selectionStepDegrees = 120,
  -- Retail stores the turntable speed as a Nitro binary-angle index of raw
  -- 2048 over a full turn of 65536; normalized once here to degrees per
  -- fixed update so no fixed-point unit reaches the runtime contract.
  rotationDegreesPerTick = (2048 / 65536) * 360,
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

-- Visible info-surface artwork: sub BG1 (base) and sub BG2 (overlay)
-- char/screen/palette members of the main chooser archive. The main BG2
-- members stay unpublished: the chooser leaves that Engine A plane disabled
-- and shows the 3D rear-plane clear color instead.
local INFO_BG_BASE = { char = 10, screen = 11, palette = 9 }
local INFO_BG_OVERLAY = { char = 16, screen = 17, palette = 15 }

-- Source info-layer blend: the overlay contributes 5/16 over the base, so an
-- ordinary alpha-over composition leaves 11/16 for the destination.
local INFO_BLEND = { overlayNumerator = 5, overlayDenominator = 16 }

-- Chooser-owned window text palette: the retail choose-starter application
-- loads this NCLR member for both chooser engines, and its text printer
-- addresses foreground/shadow pairs inside it per COLOR field. Source basis:
-- pret/pokeheartgold src/choose_starter_app.c (makeAndDrawWindows) and
-- src/render_text.c (COLOR control handling).
local CHOOSER_WINDOW_PALETTE_MEMBER = 8

-- Retail machine 3D rear-plane clear color channels from GX_RGB(31,31,16).
local MACHINE_CLEAR = { r = 31, g = 31, b = 16 }

-- Source window/portrait geometry in 256x192 surface pixels, never
-- model-scaled: the machine prompt is the unframed bottom window, the info
-- message is the framed bottom window, and the portrait is the 80x80 sprite
-- slot on the info surface.
local MACHINE_PROMPT = {
  box = { x = 8, y = 152, width = 232, height = 32 },
  textOrigin = { x = 8, y = 152 },
  framed = false,
}
local INFO_MESSAGE = {
  box = { x = 16, y = 152, width = 216, height = 32 },
  textOrigin = { x = 16, y = 152 },
  framed = true,
}
local INFO_PORTRAIT = { x = 88, y = 56, width = 80, height = 80 }

-- The single model-space normalization boundary: a raw Nitro source length
-- becomes the shared runtime unit the compiled meshes already use. Pixel
-- rectangles, angles, fields of view, and timings never cross it.
---@param raw number
---@return number
local function modelUnits(raw)
  return raw / MapUnits.MODEL_UNITS_PER_TILE
end

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
  assert(bytes ~= nil, "unavailable source members fail above")
  assert(bytes ~= nil, "unavailable source members fail above")
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
---@param role string
---@return string
local function maybeDecompress(bytes, role)
  if string.byte(bytes, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(bytes)
    if not plain then
      assert(lzErr)
      sourceError("starter-choice source member is not decodable: " .. lzErr.message, { role = role })
    end
    assert(plain ~= nil, "undecodable source members fail above")
    return plain
  end
  return bytes
end

-- Decode one info-surface background layer from its char/screen/palette
-- members and rasterize it through the shared decoded-G2D mechanics. The
-- source loader copies the first sixteen NCLR colors into the layer's
-- hardware palette slot and rewrites the tilemap to that slot in VRAM; the
-- producer-local record pairs those sixteen colors with bank 0 instead, so
-- no hardware slot number reaches the manifest. Index-0 pixels stay
-- transparent so the lower layer shows through where the source hardware
-- would expose its destination.
---@param archive Narc
---@param spec { char: integer, screen: integer, palette: integer }
---@param role string
---@param dependencies table<string, unknown>[]
---@return { width: integer, height: integer, rgba: string }
local function compileInfoBackground(archive, spec, role, dependencies)
  local charBytes =
    maybeDecompress(readMember(archive, MAIN_ARCHIVE, spec.char, role .. ":char", dependencies), role .. ":char")
  local screenBytes =
    maybeDecompress(readMember(archive, MAIN_ARCHIVE, spec.screen, role .. ":screen", dependencies), role .. ":screen")
  local paletteBytes = maybeDecompress(
    readMember(archive, MAIN_ARCHIVE, spec.palette, role .. ":palette", dependencies),
    role .. ":palette"
  )
  local charData, charErr = G2dDecoder.decodeChar(charBytes, { label = role .. ":char" })
  if not charData then
    assert(charErr)
    sourceError("starter-choice background member does not decode: " .. charErr.message, {
      role = role,
      cause = charErr.code,
    })
  end
  assert(charData ~= nil, "undecodable background members fail above")
  local screenData, screenErr = G2dDecoder.decodeScreen(screenBytes, { label = role .. ":screen" })
  if not screenData then
    assert(screenErr)
    sourceError("starter-choice background member does not decode: " .. screenErr.message, {
      role = role,
      cause = screenErr.code,
    })
  end
  assert(screenData ~= nil, "undecodable background members fail above")
  local paletteData, paletteErr = G2dDecoder.decodePalette(paletteBytes, { label = role .. ":palette" })
  if not paletteData then
    assert(paletteErr)
    sourceError("starter-choice background member does not decode: " .. paletteErr.message, {
      role = role,
      cause = paletteErr.code,
    })
  end
  assert(paletteData ~= nil, "undecodable background members fail above")
  if #paletteData.colors < 16 then
    sourceError("starter-choice background palette carries fewer than sixteen colors", {
      role = role,
      colors = #paletteData.colors,
    })
  end
  local localColors = {}
  for index = 1, 16 do
    localColors[index] = paletteData.colors[index]
  end
  local entries = {}
  for index, screenEntry in ipairs(screenData.entries) do
    entries[index] = { tile = screenEntry.tile, flipH = screenEntry.flipH, flipV = screenEntry.flipV, palette = 0 }
  end
  local ok, image = pcall(G2dRasterizer.renderScreen, charData, { colors = localColors }, {
    width = screenData.width,
    height = screenData.height,
    entries = entries,
  }, { role = role })
  if not ok then
    if Errors.is(image) then
      ---@cast image Errors.Error
      sourceError("starter-choice background does not rasterize: " .. image.message, {
        role = role,
        cause = image.code,
      })
    end
    error(image, 0)
  end
  ---@cast image { width: integer, height: integer, pixels: string }
  if image.width ~= 256 or image.height ~= 192 then
    sourceError("starter-choice background has unexpected dimensions", {
      role = role,
      width = image.width,
      height = image.height,
    })
  end
  return { width = image.width, height = image.height, rgba = image.pixels }
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
  ---@cast decoded { animations: table[], format: string }
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
---@return table<string, unknown>
local function preparedMessage(bank, index, role)
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
  assert(tokens, "starter-choice message entry must tokenize before normalization")
  local currentColor = 0
  local lines = { {} }
  local line = lines[1]
  for position, token in ipairs(tokens) do
    if token.kind == "glyph" then
      if type(token.code) ~= "number" then
        sourceError("starter-choice message entry carries a glyph without a code", {
          index = index,
          role = role,
          position = position,
        })
      end
      line[#line + 1] = {
        kind = "glyph",
        code = token.code,
        colorIndex = currentColor,
      }
    elseif token.kind == "line_break" then
      if #lines >= 2 then
        sourceError("starter-choice message entry carries more than two lines", {
          index = index,
          role = role,
          position = position,
        })
      end
      if #line == 0 then
        sourceError("starter-choice message entry carries an empty line", {
          index = index,
          role = role,
          position = position,
        })
      end
      line = {}
      lines[#lines + 1] = line
    elseif token.kind == "style" and token.control == FieldMessageText.COLOR then
      local args = token.args or {}
      local value = args[1]
      if
        #args ~= 1
        or type(value) ~= "number"
        or value % 1 ~= 0
        or value < 0
        or value >= FieldMessageText.COLOR_VARIANT_COUNT
      then
        sourceError("starter-choice message entry carries an unsupported color selection", {
          index = index,
          role = role,
          position = position,
          control = token.control,
          value = value,
        })
      end
      currentColor = value
    elseif token.kind == "eos" then
      break
    else
      sourceError("starter-choice message entry carries an unsupported control", {
        index = index,
        role = role,
        position = position,
        kind = token.kind,
        control = token.control,
      })
    end
  end
  if #line == 0 then
    sourceError("starter-choice message entry has no decoded text", { index = index, role = role })
  end
  return { lines = lines }
end

---@param color table<string, unknown>
---@param what string
---@return { r: integer, g: integer, b: integer }
local function copyRgb(color, what)
  if
    type(color) ~= "table"
    or type(color.r) ~= "number"
    or color.r % 1 ~= 0
    or color.r < 0
    or color.r > 255
    or type(color.g) ~= "number"
    or color.g % 1 ~= 0
    or color.g < 0
    or color.g > 255
    or type(color.b) ~= "number"
    or color.b % 1 ~= 0
    or color.b < 0
    or color.b > 255
  then
    sourceError("starter-choice chooser palette carries a non-RGB entry for " .. what, {})
  end
  ---@cast color { r: integer, g: integer, b: integer }
  return { r = color.r, g = color.g, b = color.b }
end

-- Normalizes the chooser window NCLR into source-independent text colors:
-- COLOR field n addresses the palette pair (2n+1, 2n+2), the framed info
-- background is slot 15, and the unframed machine background is slot 0.
-- Only byte RGB records reach the manifest; no source slot numbers survive.
---@param paletteBytes string
---@return { variants: { foreground: { r: integer, g: integer, b: integer }, shadow: { r: integer, g: integer, b: integer } }[], infoBackground: { r: integer, g: integer, b: integer }, machineBackground: { r: integer, g: integer, b: integer } }
local function compileChooserTextColors(paletteBytes)
  local bytes = maybeDecompress(paletteBytes, "chooser-text-palette")
  local palette, paletteErr = G2dDecoder.decodePalette(bytes, { label = "chooser-text-palette" })
  if not palette then
    assert(paletteErr)
    sourceError("starter-choice chooser palette does not decode: " .. paletteErr.message, {
      cause = paletteErr.code,
    })
  end
  assert(palette ~= nil, "undecodable chooser palette fails above")
  if #palette.colors < 16 then
    sourceError("starter-choice chooser palette carries fewer than sixteen colors", {
      colors = #palette.colors,
    })
  end
  local variants = {}
  for colorIndex = 0, FieldMessageText.COLOR_VARIANT_COUNT - 1 do
    local foreground = palette.colors[colorIndex * 2 + 2] -- source slot 2n+1, Lua index +1
    local shadow = palette.colors[colorIndex * 2 + 3] -- source slot 2n+2, Lua index +1
    variants[colorIndex + 1] = {
      foreground = copyRgb(foreground, "variant " .. colorIndex .. " foreground"),
      shadow = copyRgb(shadow, "variant " .. colorIndex .. " shadow"),
    }
  end
  return {
    variants = variants,
    infoBackground = copyRgb(palette.colors[16], "info background"),
    machineBackground = copyRgb(palette.colors[1], "machine background"),
  }
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
  local main, mainErr = openArchive(romFs, MAIN_ARCHIVE)
  if main == nil then
    error(mainErr, 0)
  end
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
  assert(messageInfo ~= nil, "unavailable message archive fails above")
  local messageArchiveBytes = romFs:read(messageInfo.fileId)
  if not messageArchiveBytes then
    sourceError("starter-choice message archive bytes are unavailable", { archive = "messages" })
  end
  assert(messageArchiveBytes ~= nil, "unavailable message bytes fail above")
  dependencies[#dependencies + 1] =
    { archive = "messages", memberId = -1, role = "message-archive", sha1 = Hashing.sha1hex(messageArchiveBytes) }
  local messageArchive, messageArchiveErr = openArchive(romFs, "messages")
  if messageArchive == nil then
    error(messageArchiveErr, 0)
  end
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
  local tabletopPack = tabletopModel.embeddedTextures
  if tabletopPack == nil then
    -- Retail binds no texture block for a model that carries none; an empty
    -- pack is that NULL bind. A model that names textures without carrying
    -- them is a broken source, not an untextured one.
    for _, material in ipairs(tabletopModel.models[1].materials) do
      if material.textureName ~= nil then
        sourceError("starter-choice tabletop names a texture but carries no embedded texture block", {
          role = "tabletop",
          material = material.name,
          texture = material.textureName,
        })
      end
    end
    tabletopPack = { textureByName = {}, paletteByName = {} }
  end
  local tabletopCompiled = ModelAssetCompiler.compileModel(tabletopModel.models[1], tabletopPack, meshes, textures, {
    role = "tabletop",
    modelArchive = MAIN_ARCHIVE,
    modelMemberId = MODEL_MEMBERS.tabletop,
    modelName = tabletopModel.models[1].name,
  })
  for _, entry in ipairs(tabletopCompiled.unresolved) do
    sourceError("starter-choice tabletop texture binding has no source texture: " .. tostring(entry.name), {
      role = "tabletop",
      material = entry.material,
      kind = entry.kind,
      name = entry.name,
    })
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
    inspect[slot] = preparedMessage(bank, MESSAGE_INSPECT[slot], "inspect:" .. slot)
    confirm[slot] = preparedMessage(bank, MESSAGE_CONFIRM[slot], "confirm:" .. slot)
  end
  local paletteBytes =
    readMember(main, MAIN_ARCHIVE, CHOOSER_WINDOW_PALETTE_MEMBER, "chooser-text-palette", dependencies)
  local textColors = compileChooserTextColors(paletteBytes)
  local backdropImage = renderBackdrop()
  local backdropPath = StarterChoiceAssetCache.assetDir() .. "/backdrop.png"
  local infoBase = compileInfoBackground(main, INFO_BG_BASE, "background:info-base", dependencies)
  local infoBasePath = StarterChoiceAssetCache.assetDir() .. "/info-base.png"
  local infoOverlay = compileInfoBackground(main, INFO_BG_OVERLAY, "background:info-overlay", dependencies)
  local infoOverlayPath = StarterChoiceAssetCache.assetDir() .. "/info-overlay.png"
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
        radius = modelUnits(BALL_LAYOUT.radius),
        modelY = modelUnits(BALL_LAYOUT.modelY),
        touchYOffsetY = modelUnits(BALL_LAYOUT.touchYOffsetY),
        inspectPivotYOffsetY = modelUnits(BALL_LAYOUT.inspectPivotYOffsetY),
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
        near = modelUnits(CAMERA_CLIP.near),
        far = modelUnits(CAMERA_CLIP.far),
        out = {
          angleX = CAMERA.out.angleX,
          perspective = CAMERA.out.perspective,
          target = {
            x = modelUnits(CAMERA.out.target.x),
            y = modelUnits(CAMERA.out.target.y),
            z = modelUnits(CAMERA.out.target.z),
          },
          distance = modelUnits(CAMERA.out.distance),
        },
        inside = {
          angleX = CAMERA.inside.angleX,
          perspective = CAMERA.inside.perspective,
          target = {
            x = modelUnits(CAMERA.inside.target.x),
            y = modelUnits(CAMERA.inside.target.y),
            z = modelUnits(CAMERA.inside.target.z),
          },
          distance = modelUnits(CAMERA.inside.distance),
        },
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
      topInitial = preparedMessage(bank, MESSAGE_TOP_INITIAL, "topInitial"),
      inspect = inspect,
      confirm = confirm,
      bottom = {
        normal = preparedMessage(bank, MESSAGE_BOTTOM_NORMAL, "bottom:normal"),
        confirm = preparedMessage(bank, MESSAGE_BOTTOM_CONFIRM, "bottom:confirm"),
      },
    },
    backgrounds = {
      host = {
        image = backdropPath,
        width = backdropImage.width,
        height = backdropImage.height,
      },
      info = {
        base = {
          image = infoBasePath,
          width = infoBase.width,
          height = infoBase.height,
        },
        overlay = {
          image = infoOverlayPath,
          width = infoOverlay.width,
          height = infoOverlay.height,
        },
        overlayAlpha = INFO_BLEND.overlayNumerator / INFO_BLEND.overlayDenominator,
      },
    },
    surfaces = {
      machine = {
        clearColor = {
          r = MACHINE_CLEAR.r / 31,
          g = MACHINE_CLEAR.g / 31,
          b = MACHINE_CLEAR.b / 31,
          a = 1,
        },
        prompt = MACHINE_PROMPT,
      },
      info = {
        message = INFO_MESSAGE,
        portrait = INFO_PORTRAIT,
      },
    },
    textColors = textColors,
  }

  local assets = {}
  for sha1, batch in pairs(meshes) do
    assets[MapAssetCache.geometryPath(sha1)] = MeshWriter.encode(batch)
  end
  for sha1, tex in pairs(textures) do
    assets[MapAssetCache.texturePath(sha1)] = assert(tex.data, "compiled texture is missing finalized PNG Data")
  end
  assets[backdropPath] = PngWriter.encode(backdropImage.width, backdropImage.height, backdropImage.rgba)
  assets[infoBasePath] = PngWriter.encode(infoBase.width, infoBase.height, infoBase.rgba)
  assets[infoOverlayPath] = PngWriter.encode(infoOverlay.width, infoOverlay.height, infoOverlay.rgba)

  local dependencyRecord = {
    cacheFormat = StarterChoiceAssetCache.FORMAT,
    schema = StarterChoiceAssetCache.SCHEMA,
    modelSchema = ModelAsset.SCHEMA,
    charmapVersion = FieldMessageCompiler.CHARMAP_VERSION,
    versionRomSha1 = metadata.sha1,
    sceneConstants = {
      camera = CAMERA,
      cameraClipping = CAMERA_CLIP,
      ballLayout = BALL_LAYOUT,
      turntable = TURNTABLE,
      timing = TIMING,
    },
    presentationConstants = {
      machineClear = MACHINE_CLEAR,
      overlayBlend = INFO_BLEND,
      machinePrompt = MACHINE_PROMPT,
      infoMessage = INFO_MESSAGE,
      infoPortrait = INFO_PORTRAIT,
      infoBackgrounds = { base = INFO_BG_BASE, overlay = INFO_BG_OVERLAY },
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
