-- Compiles the generated field-bag presentation class: upper-pane hero
-- backdrops and description frame, lower-pane list/action/quantity/
-- confirmation screens, semantic tab/focus/strip sprite visuals, the two
-- registration-slot markers cropped from the marker source bitmap, semantic
-- action labels and prompt templates lowered from the message banks, and
-- both gender hero
-- models with pocket-indexed animation states. Source member selection and
-- geometry live in romdump/src/config/BagSources.lua; this module owns the
-- decode, rasterization, model/animation delegation, and the normalized
-- bundle. 2D mechanics reuse G2dDecoder/G2dRasterizer/PngWriter; model
-- conversion delegates to the digest/model compilers (Nsbmd decode,
-- MapPropAnimCompiler clips, DynamicModelCompiler descriptors) rather than
-- duplicating them. Item icons resolve through the item class and are never
-- read here. The runtime consumes only the manifest and the generated
-- files, never this module. Pure module: no love dependency.
-- Source basis: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- asm/overlay_15.s.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local BagSources = require("romdump.src.config.BagSources")
local BagPresentationCompiler = require("romdump.src.digest.ui.BagPresentationCompiler")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.reference.hgss.charmap")

---@class BagAssetCompiler
local BagAssetCompiler = {}

-- Named ownership of the compiler protocol error code; tests assert the
-- constant, never the raw string.
BagAssetCompiler.ERROR = {
  SOURCE_INVALID = "BAG_SOURCE_INVALID",
}

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

local function sourceError(message, context)
  error(Errors.new(BagAssetCompiler.ERROR.SOURCE_INVALID, "bag " .. message, context or {}), 0)
end

-- The single model-space normalization boundary: a source model-unit length
-- becomes the tile-space runtime unit the compiled meshes already use.
-- Angles, perspective, rotation, scales, and light vectors never cross it.
---@param raw number
---@return number
local function modelUnits(raw)
  return raw / MapUnits.MODEL_UNITS_PER_TILE
end

local function readMember(archive, memberId, role, dependencies)
  local member, err = archive:readMember(memberId)
  if not member then
    sourceError("member " .. memberId .. " is unreadable: " .. Errors.format(err), { role = role, memberId = memberId })
  end
  assert(member ~= nil, "unreadable members fail above")
  dependencies[#dependencies + 1] = { name = "bag_ui:member:" .. memberId, role = role, sha1 = Hashing.sha1hex(member) }
  if string.byte(member, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(member)
    if not plain then
      error(lzErr, 0)
    end
    member = plain
  end
  return member
end

local function decode(kind, bytes, role)
  local record, err = G2dDecoder[kind](bytes, { label = "bag:" .. role })
  if not record then
    assert(err)
    sourceError(role .. " does not decode: " .. err.message, { role = role, cause = err.code })
  end
  return record
end

local function rasterizeScreen(charData, palette, screen, role)
  local ok, image = pcall(G2dRasterizer.renderScreen, charData, { colors = palette }, screen, { role = role })
  if not ok then
    if Errors.is(image) then
      ---@cast image Errors.Error
      sourceError(role .. " does not rasterize: " .. image.message, { role = role, cause = image.code })
    end
    error(image, 0)
  end
  return image
end

-- Upper-pane screens share one char/palette pair; lower-pane screens share
-- another. Every screen renders with native entry palette indices, matching
-- the retail layer binding the audit recovered.
local SCREEN_ROLES = {
  { role = "upper-base", member = BagSources.screens.upperBase, upper = true },
  { role = "upper-alternate", member = BagSources.screens.upperAlternate, upper = true },
  { role = "upper-backdrop-male", member = BagSources.screens.upperBackdropMale, upper = true },
  { role = "upper-backdrop-female", member = BagSources.screens.upperBackdropFemale, upper = true },
  { role = "list-slots", member = BagSources.screens.listSlots, upper = false },
  { role = "list-wash", member = BagSources.screens.listWash, upper = false },
  { role = "action-slots", member = BagSources.screens.actionSlots, upper = false },
  { role = "action-wash", member = BagSources.screens.actionWash, upper = false },
  { role = "confirmation", member = BagSources.screens.confirmation, upper = false },
  { role = "quantity", member = BagSources.screens.quantity, upper = false },
  { role = "quantity-alt", member = BagSources.screens.quantityAlt, upper = false },
}

local function compileScreens(archive, dependencies, assets)
  local upperChar =
    decode("decodeChar", readMember(archive, BagSources.chars.upper, "upper-char", dependencies), "upper-char")
  local upperPalette = decode(
    "decodePalette",
    readMember(archive, BagSources.palettes.upper, "upper-palette", dependencies),
    "upper-palette"
  )
  local lowerChar =
    decode("decodeChar", readMember(archive, BagSources.chars.lower, "lower-char", dependencies), "lower-char")
  local lowerPalette = decode(
    "decodePalette",
    readMember(archive, BagSources.palettes.lower, "lower-palette", dependencies),
    "lower-palette"
  )
  local images = {}
  local references = {}
  for _, spec in ipairs(SCREEN_ROLES) do
    local screen = decode("decodeScreen", readMember(archive, spec.member, spec.role, dependencies), spec.role)
    local image = rasterizeScreen(
      spec.upper and upperChar or lowerChar,
      spec.upper and upperPalette.colors or lowerPalette.colors,
      screen,
      spec.role
    )
    image = BagPresentationCompiler.cropImage(image, 256, 192, spec.role)
    images[spec.role] = image
    if spec.upper then
      local path = BagCache.assetDir() .. "/" .. spec.role .. ".png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      references[spec.role] = { image = path, width = image.width, height = image.height }
    end
  end
  return images, references, lowerPalette.colors
end

local function compileSpriteData(archive, group, role, dependencies)
  local charData = decode("decodeChar", readMember(archive, group.char, role .. "-char", dependencies), role .. "-char")
  local paletteData =
    decode("decodePalette", readMember(archive, group.palette, role .. "-palette", dependencies), role .. "-palette")
  local cellData = decode("decodeCell", readMember(archive, group.cell, role .. "-cell", dependencies), role .. "-cell")
  local animation =
    decode("decodeAnimation", readMember(archive, group.anim, role .. "-anim", dependencies), role .. "-anim")
  return charData, paletteData, cellData, animation
end

local function writeSpriteFrame(rendered, path, assets)
  assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
  local visual = { image = path, width = rendered.width, height = rendered.height }
  if rendered.offset.x ~= 0 or rendered.offset.y ~= 0 then
    visual.offset = rendered.offset
  end
  return visual
end

local function compileVisual(spriteData, selector, role, assets)
  local charData, paletteData, cellData, animation = unpack(spriteData)
  local sequence = animation.anims[selector.animation + 1]
  if sequence == nil then
    sourceError(role .. " selects a missing animation sequence", { animation = selector.animation })
  end
  assert(sequence ~= nil, "missing animation sequences fail above")
  if #sequence.frames ~= 1 then
    sourceError(role .. " selects an animated sequence; Bag v3 publishes static realizations only", {
      animation = selector.animation,
      frames = #sequence.frames,
    })
  end
  local rendered = G2dRasterizer.renderAnimationFrame(
    charData,
    paletteData,
    cellData,
    sequence,
    1,
    { role = role, animation = selector.animation, frame = 0 },
    selector.palette
  )
  return writeSpriteFrame(rendered, BagCache.assetDir() .. "/" .. role .. "-frame-1.png", assets)
end

local function compileSprites(archive, dependencies, assets)
  local tabsData = { compileSpriteData(archive, BagSources.sprites.tabs, "tabs", dependencies) }
  local cursorData = { compileSpriteData(archive, BagSources.sprites.cursor, "focus", dependencies) }
  local stripData = { compileSpriteData(archive, BagSources.sprites.strip, "source-strip", dependencies) }
  local tabs = {}
  for index, selector in ipairs(BagSources.spriteStates.tabs.normal) do
    tabs[index] = compileVisual(tabsData, selector, "tab-normal-" .. index, assets)
  end
  return {
    tabs = tabs,
    selected = compileVisual(tabsData, BagSources.spriteStates.tabs.selected, "tab-selected", assets),
    focus = compileVisual(cursorData, { animation = BagSources.spriteStates.cursor.animations[1] }, "focus", assets),
    strip = compileVisual(stripData, { animation = BagSources.spriteStates.strip.animation }, "source-strip", assets),
  }
end

local function compileBackgrounds(screenImages, assets)
  local screenRoles = {
    listWash = "list-wash",
    listSlots = "list-slots",
    actionWash = "action-wash",
    actionSlots = "action-slots",
    quantity = "quantity",
    quantityAlt = "quantity-alt",
    confirmation = "confirmation",
  }
  local backgrounds = {}
  for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
    local layers = {}
    for _, sourceName in ipairs(BagSources.lowerLayers[state]) do
      local role = assert(screenRoles[sourceName], "audited Bag layer has no semantic role: " .. sourceName)
      layers[#layers + 1] = assert(screenImages[role], "audited Bag layer was not decoded: " .. sourceName)
    end
    local image = BagPresentationCompiler.composeImages(layers, "interactive background " .. state)
    local path = BagCache.assetDir() .. "/background-" .. state .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
    backgrounds[state] = { image = path, width = image.width, height = image.height }
  end
  return backgrounds
end

-- Semantic message lowering. The pinned Bag messages carry two STRVAR
-- placeholders: the item-name reference (STRVAR_1 field 8) and the toss
-- quantity reference (STRVAR_1 field 52). Labels accept display glyphs and
-- line breaks only; templates additionally accept those two placeholders.
-- Every other substitution or control is malformed source, never a runtime
-- marker to interpret.
local ITEM_SUBSTITUTION = FieldMessageText.STRVAR_1 + 8
local QUANTITY_SUBSTITUTION = FieldMessageText.STRVAR_1 + 52

local function readMessageBank(archive, bankId, role, dependencies)
  local bytes, err = archive:readMember(bankId)
  if not bytes then
    sourceError("message bank " .. bankId .. " is unreadable: " .. Errors.format(err), { role = role, bank = bankId })
  end
  assert(bytes ~= nil, "unreadable message banks fail above")
  dependencies[#dependencies + 1] = { name = "messages:member:" .. bankId, role = role, sha1 = Hashing.sha1hex(bytes) }
  local bank, bankErr = FieldMessageBank.decode(bytes, { label = "bag-message-bank-" .. bankId })
  if not bank then
    assert(bankErr)
    sourceError("message bank " .. bankId .. " does not decode: " .. bankErr.message, {
      role = role,
      bank = bankId,
      cause = bankErr.code,
    })
  end
  return bank
end

local function messageTokens(bank, bankId, index, role)
  local message = bank.messages[index + 1]
  if not message then
    sourceError(
      "message bank " .. bankId .. " carries no message " .. index,
      { role = role, bank = bankId, index = index }
    )
  end
  local tokens, err = FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = bankId, messageId = index })
  if not tokens then
    assert(err)
    sourceError("bag message does not tokenize: " .. err.message, { role = role, bank = bankId, index = index })
  end
  assert(tokens ~= nil, "untokenizable bag messages fail above")
  return tokens
end

local function lowerLabel(bank, bankId, index, role)
  local parts = {}
  for _, token in ipairs(messageTokens(bank, bankId, index, role)) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      parts[#parts + 1] = token.text
    elseif token.kind == "line_break" then
      parts[#parts + 1] = "\n"
    else
      sourceError("bag label carries a non-display token " .. tostring(token.kind), {
        role = role,
        bank = bankId,
        index = index,
        kind = token.kind,
        control = token.control,
      })
    end
  end
  local label = table.concat(parts)
  if label == "" then
    sourceError("bag label has no display text", { role = role, bank = bankId, index = index })
  end
  return label
end

local function lowerTemplate(bank, bankId, index, role)
  local segments = {}
  local pending = {}
  local function flush()
    if #pending > 0 then
      segments[#segments + 1] = { kind = "text", value = table.concat(pending) }
      pending = {}
    end
  end
  for _, token in ipairs(messageTokens(bank, bankId, index, role)) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      pending[#pending + 1] = token.text
    elseif token.kind == "line_break" then
      pending[#pending + 1] = "\n"
    elseif token.kind == "substitution" and token.control == ITEM_SUBSTITUTION then
      flush()
      segments[#segments + 1] = { kind = "item" }
    elseif token.kind == "substitution" and token.control == QUANTITY_SUBSTITUTION then
      flush()
      segments[#segments + 1] = { kind = "quantity" }
    else
      sourceError("bag template carries an unsupported token " .. tostring(token.kind), {
        role = role,
        bank = bankId,
        index = index,
        kind = token.kind,
        control = token.control,
      })
    end
  end
  flush()
  if #segments == 0 then
    sourceError("bag template has no segments", { role = role, bank = bankId, index = index })
  end
  return { segments = segments }
end

local function compileText(messageArchive, dependencies)
  local banks = {}
  local function bankOf(bankId)
    if banks[bankId] == nil then
      banks[bankId] = readMessageBank(messageArchive, bankId, "message-bank-" .. bankId, dependencies)
    end
    return banks[bankId]
  end
  local labels = {}
  for _, action in ipairs({ "toss", "move", "register", "unregister", "cancel", "confirm" }) do
    local selector = BagSources.messages.actionLabels[action]
    labels[action] = lowerLabel(bankOf(selector.bank), selector.bank, selector.index, "label:" .. action)
  end
  local templates = {}
  for _, name in ipairs({ "movePrompt", "tossQuantity", "tossConfirm" }) do
    local selector = BagSources.messages.templates[name]
    templates[name] = lowerTemplate(bankOf(selector.bank), selector.bank, selector.index, "template:" .. name)
  end
  return {
    actions = labels,
    movePrompt = templates.movePrompt,
    tossQuantity = templates.tossQuantity,
    tossConfirm = templates.tossConfirm,
  }
end

-- Registration marker rasterization: decode the audited source bitmap once,
-- render it through the shared lower-Bag palette path, and crop the two
-- audited slot regions. The tile count must match the audited bitmap exactly;
-- no generic blitter is reconstructed here.
local function compileRegistrationMarkers(archive, lowerColors, dependencies, assets)
  local registration = BagSources.registration
  assert(
    registration.bitmapWidth % 8 == 0 and registration.bitmapHeight % 8 == 0,
    "audited marker bitmap is tile-aligned"
  )
  assert(
    registration.slot1X + registration.markerWidth <= registration.bitmapWidth
      and registration.slot2X + registration.markerWidth <= registration.bitmapWidth,
    "audited marker crops fit the source bitmap"
  )
  local charData = decode(
    "decodeChar",
    readMember(archive, BagSources.chars.registrationMarker, "registration-marker-char", dependencies),
    "registration-marker-char"
  )
  if charData.depth ~= 3 then
    sourceError("registration marker source is not 4bpp character data", { depth = charData.depth })
  end
  local tilesWide = registration.bitmapWidth / 8
  local tilesHigh = registration.bitmapHeight / 8
  if #charData.tiles / 32 ~= tilesWide * tilesHigh then
    sourceError("registration marker source carries an unexpected tile count", {
      tiles = #charData.tiles / 32,
      required = tilesWide * tilesHigh,
    })
  end
  local entries = {}
  for tile = 0, tilesWide * tilesHigh - 1 do
    entries[tile + 1] = { tile = tile, flipH = false, flipV = false, palette = 0 }
  end
  local bitmap = rasterizeScreen(charData, lowerColors, {
    width = registration.bitmapWidth,
    height = registration.bitmapHeight,
    entries = entries,
  }, "registration-marker-bitmap")
  local function crop(sourceX, role)
    local rows = {}
    for y = 0, registration.markerHeight - 1 do
      local rowBase = (registration.sourceY + y) * registration.bitmapWidth * 4
      rows[#rows + 1] = bitmap.pixels:sub(rowBase + sourceX * 4 + 1, rowBase + (sourceX + registration.markerWidth) * 4)
    end
    local path = BagCache.assetDir() .. "/" .. role .. ".png"
    assets[path] = PngWriter.encode(registration.markerWidth, registration.markerHeight, table.concat(rows))
    return { image = path, width = registration.markerWidth, height = registration.markerHeight }
  end
  return {
    slot1 = crop(registration.slot1X, "registration-slot-1"),
    slot2 = crop(registration.slot2X, "registration-slot-2"),
  }
end

local function decodeModel(bytes, memberId, role)
  local ok, model = pcall(Nsbmd.decode, bytes, { alias = BagSources.archive.symbol, memberId = memberId })
  if not ok then
    sourceError(role .. " is not a decodable model: " .. tostring(model), { memberId = memberId, role = role })
  end
  if type(model) ~= "table" then
    sourceError(role .. " is not a decodable model", { memberId = memberId, role = role })
  end
  assert(type(model) == "table", "undecodable models fail above")
  if type(model.models) ~= "table" then
    sourceError(role .. " is not a decodable model", { memberId = memberId, role = role })
  end
  assert(type(model.models) == "table", "undecodable models fail above")
  if #model.models ~= 1 then
    sourceError(role .. " carries an unexpected model count", {
      memberId = memberId,
      role = role,
      modelCount = #model.models,
    })
  end
  return model
end

local function compileClip(bytes, memberId, role, clipId, semanticName)
  local decoded, err = NitroAnimation.decode(bytes, { alias = BagSources.archive.symbol, memberId = memberId })
  if not decoded then
    sourceError(role .. " is not decodable: " .. tostring(err), { memberId = memberId, role = role })
  end
  assert(type(decoded) == "table", "undecodable animations fail above")
  assert(type(decoded.animations) == "table", "undecodable animations fail above")
  assert(decoded.animations[1] ~= nil, "undecodable animations fail above")
  if #decoded.animations ~= 1 then
    sourceError(role .. " carries an unexpected animation count", {
      memberId = memberId,
      role = role,
      animationCount = #decoded.animations,
    })
  end
  -- The addressable clip name is the semantic clip id, not the embedded
  -- Nitro dictionary name: the pattern and joint members of one pocket
  -- share one embedded animation name, so the source name cannot
  -- distinguish the two clips of a pocket pair. The pocket role stays on
  -- semanticNames; id and name carry the same semantic clip id.
  local ok, clip = pcall(MapPropAnimCompiler.compileDecoded, decoded, {
    name = clipId,
    id = clipId,
    source = { type = "nitro", format = decoded.format },
  })
  if not ok then
    if Errors.is(clip) then
      ---@cast clip Errors.Error
      sourceError(role .. " failed to compile: " .. clip.message, {
        memberId = memberId,
        role = role,
        cause = clip.code,
      })
    end
    error(clip, 0)
  end
  assert(type(clip) == "table", "uncompilable clips fail above")
  clip.semanticNames = { semanticName }
  return clip
end

-- Compile one gender hero: the model plus eight pocket pattern/joint pairs
-- and the shared material clip, all through the existing model compilers.
-- Clip ids are semantic; opaque member identities never leave this module.
local function compileHero(archive, gender, dependencies, textures, meshes)
  local selection = BagSources.hero[gender]
  local modelBytes = readMember(archive, selection.model, "hero-" .. gender .. "-model", dependencies)
  local decoded = decodeModel(modelBytes, selection.model, "hero-" .. gender .. "-model")
  local clips = {}
  for _, state in ipairs(BagSources.hero.states) do
    local patternMember = selection.patternBase + state.slot
    local jointMember = selection.jointBase + state.slot
    clips[#clips + 1] = compileClip(
      readMember(archive, patternMember, "hero-" .. gender .. "-pattern-" .. state.pocket, dependencies),
      patternMember,
      "hero-" .. gender .. "-pattern-" .. state.pocket,
      "bag." .. gender .. ".pattern." .. state.pocket,
      "pocket." .. state.pocket .. ".pattern"
    )
    clips[#clips + 1] = compileClip(
      readMember(archive, jointMember, "hero-" .. gender .. "-joint-" .. state.pocket, dependencies),
      jointMember,
      "hero-" .. gender .. "-joint-" .. state.pocket,
      "bag." .. gender .. ".pose." .. state.pocket,
      "pocket." .. state.pocket .. ".pose"
    )
  end
  clips[#clips + 1] = compileClip(
    readMember(archive, selection.material, "hero-" .. gender .. "-material", dependencies),
    selection.material,
    "hero-" .. gender .. "-material",
    "bag." .. gender .. ".material",
    "bag.material"
  )
  local model = decoded.models[1]
  assert(type(model) == "table", "single-model heroes fail above")
  local pack = decoded.embeddedTextures
  if pack == nil then
    pack = { textureByName = {}, paletteByName = {} }
  end
  local descriptor, unresolved = DynamicModelCompiler.compile(model, decoded, pack, { clips = clips }, {
    role = "bag-hero-" .. gender,
    modelArchive = BagSources.archive.alias,
    modelMemberId = selection.model,
    modelName = model.name,
  }, selection.model, textures, meshes)
  for _, entry in ipairs(unresolved) do
    sourceError("hero-" .. gender .. " texture binding has no source texture: " .. tostring(entry.name), {
      role = "bag-hero-" .. gender,
      material = entry.material,
      kind = entry.kind,
      name = entry.name,
    })
  end
  descriptor.memberId = nil
  local ok, err = pcall(ModelAsset.validate, descriptor)
  if not ok then
    if Errors.is(err) then
      sourceError("hero-" .. gender .. " descriptor is invalid: " .. err.message, { cause = err.code })
    end
    error(err, 0)
  end
  return descriptor
end

local function _compile(romFs)
  assert(
    romFs and type(romFs.metadata) == "function" and type(romFs.openNarc) == "function",
    "bag compilation requires source metadata and archive reader"
  )
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "bag source metadata must carry sha1")
  local dependencies = {
    { name = "assetContract", sha1 = BagCache.FORMAT .. ":" .. BagCache.SCHEMA .. ":" .. ModelAsset.SCHEMA },
  }
  local archive, archiveErr = romFs:openNarc(BagSources.archive.alias)
  if archive == nil then
    error(
      archiveErr
        or Errors.new(
          BagAssetCompiler.ERROR.SOURCE_INVALID,
          "bag archive is unavailable",
          { alias = BagSources.archive.alias }
        ),
      0
    )
  end
  assert(archive ~= nil, "unavailable archives fail above")
  local info = must(romFs:resolvedNarc(BagSources.archive.alias), "bag archive has no resolution")
  local archiveBytes = must(romFs:read(info.fileId), "bag archive bytes are unavailable")
  dependencies[#dependencies + 1] = { name = BagSources.archive.alias .. ":narc", sha1 = Hashing.sha1hex(archiveBytes) }

  local assets = {}
  local screenImages, screenReferences, lowerColors = compileScreens(archive, dependencies, assets)
  local messageArchive, messageArchiveErr = romFs:openNarc("messages")
  if messageArchive == nil then
    error(
      messageArchiveErr
        or Errors.new(
          BagAssetCompiler.ERROR.SOURCE_INVALID,
          "bag message archive is unavailable",
          { alias = "messages" }
        ),
      0
    )
  end
  assert(messageArchive ~= nil, "unavailable message archives fail above")
  local text = compileText(messageArchive, dependencies)
  local sprites = compileSprites(archive, dependencies, assets)
  local backgrounds = compileBackgrounds(screenImages, assets)
  local markers = compileRegistrationMarkers(archive, lowerColors, dependencies, assets)
  local textures, meshes = {}, {}
  local male = compileHero(archive, "male", dependencies, textures, meshes)
  local female = compileHero(archive, "female", dependencies, textures, meshes)
  for sha1, batch in pairs(meshes) do
    assets[MapAssetCache.geometryPath(sha1)] = MeshWriter.encode(batch)
  end
  do
    local keys = {}
    for sha1 in pairs(textures) do
      keys[#keys + 1] = sha1
    end
    table.sort(keys)
    for _, sha1 in ipairs(keys) do
      local texture = textures[sha1]
      assets[MapAssetCache.texturePath(sha1)] = PngWriter.encode(texture.width, texture.height, texture.pixels)
    end
  end

  local geometry = BagPresentationCompiler.compileGeometry(BagSources)
  local states = BagPresentationCompiler.compileStates(BagSources)
  local widgets = BagPresentationCompiler.compileWidgets(BagSources)
  local presentation = BagSources.presentation
  local manifest = {
    schema = BagCache.SCHEMA,
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = screenReferences["upper-backdrop-male"],
        female = screenReferences["upper-backdrop-female"],
      },
      description = {
        frame = {
          image = screenReferences["upper-base"].image,
          alternateImage = screenReferences["upper-alternate"].image,
          rect = geometry.descriptionFrame,
        },
        textRect = geometry.descriptionText,
      },
      model = { male = male, female = female },
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
      presentation = {
        camera = {
          target = {
            x = modelUnits(presentation.camera.target.x),
            y = modelUnits(presentation.camera.target.y),
            z = modelUnits(presentation.camera.target.z),
          },
          distance = modelUnits(presentation.camera.distance),
          angleXDegrees = presentation.camera.angleXDegrees,
          angleYDegrees = presentation.camera.angleYDegrees,
          perspectiveType = presentation.camera.perspectiveType,
          perspectiveAngle = presentation.camera.perspectiveAngle,
          clipNear = modelUnits(presentation.camera.clipNear),
          clipFar = modelUnits(presentation.camera.clipFar),
        },
        transform = {
          translation = {
            x = modelUnits(presentation.transform.translation.x),
            y = modelUnits(presentation.transform.translation.y),
            z = modelUnits(presentation.transform.translation.z),
          },
          rotation = {
            presentation.transform.rotation[1],
            presentation.transform.rotation[2],
            presentation.transform.rotation[3],
            presentation.transform.rotation[4],
            presentation.transform.rotation[5],
            presentation.transform.rotation[6],
            presentation.transform.rotation[7],
            presentation.transform.rotation[8],
            presentation.transform.rotation[9],
          },
          scale = {
            x = presentation.transform.scale.x,
            y = presentation.transform.scale.y,
            z = presentation.transform.scale.z,
          },
        },
        lights = {
          count = presentation.lights.count,
          color = {
            r = presentation.lights.color.r,
            g = presentation.lights.color.g,
            b = presentation.lights.color.b,
          },
          vectors = {
            {
              x = presentation.lights.vectors[1].x,
              y = presentation.lights.vectors[1].y,
              z = presentation.lights.vectors[1].z,
            },
            {
              x = presentation.lights.vectors[2].x,
              y = presentation.lights.vectors[2].y,
              z = presentation.lights.vectors[2].z,
            },
            {
              x = presentation.lights.vectors[3].x,
              y = presentation.lights.vectors[3].y,
              z = presentation.lights.vectors[3].z,
            },
            {
              x = presentation.lights.vectors[4].x,
              y = presentation.lights.vectors[4].y,
              z = presentation.lights.vectors[4].z,
            },
          },
        },
      },
    },
    interactive = {
      backgrounds = backgrounds,
      pocketTabs = {
        rects = geometry.tabs,
        normal = sprites.tabs,
        selected = sprites.selected,
      },
      itemSlots = {
        slots = geometry.slots,
        focus = sprites.focus,
        registration = {
          slot1 = markers.slot1,
          slot2 = markers.slot2,
          offset = { x = BagSources.registration.offset.x, y = BagSources.registration.offset.y },
        },
      },
      pageIndicator = geometry.pageIndicator,
      cancel = geometry.cancel,
      text = text,
      overlays = {
        actionMenu = { buttons = geometry.actionButtons },
        quantity = {
          digits = geometry.quantityDigits,
        },
        descriptionFallback = { frame = geometry.descriptionFrame, textRect = geometry.descriptionText },
      },
      widgets = {
        sourceStrip = {
          image = sprites.strip.image,
          width = sprites.strip.width,
          height = sprites.strip.height,
          offset = sprites.strip.offset,
          placement = widgets.sourceStrip.placement,
          states = widgets.sourceStrip.states,
        },
      },
    },
  }
  local ok, err = pcall(BagAssetSchema.assertManifest, manifest)
  if not ok then
    sourceError("compiled bag manifest is invalid: " .. Errors.format(err), {})
  end

  local dependencyRecord = {
    cacheFormat = BagCache.FORMAT,
    schema = BagCache.SCHEMA,
    modelSchema = ModelAsset.SCHEMA,
    versionRomSha1 = metadata.sha1,
    source = BagSources.provenance,
    selection = {
      archive = BagSources.archive,
      screens = BagSources.screens,
      chars = BagSources.chars,
      palettes = BagSources.palettes,
      sprites = BagSources.sprites,
      spriteStates = BagSources.spriteStates,
      lowerLayers = BagSources.lowerLayers,
      hero = BagSources.hero,
      messages = BagSources.messages,
      registration = BagSources.registration,
      widgets = BagSources.widgets,
    },
    presentation = BagSources.presentation,
    geometry = BagSources.geometry,
    dependencies = dependencies,
  }
  return {
    marker = BagCache.marker(metadata.sha1, Hashing.hashLua(dependencyRecord)),
    manifest = manifest,
    dependencies = dependencyRecord,
    assets = assets,
  }
end

---@param romFs RomFs
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function BagAssetCompiler.compile(romFs)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  local ok, result = xpcall(_compile, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return BagAssetCompiler
