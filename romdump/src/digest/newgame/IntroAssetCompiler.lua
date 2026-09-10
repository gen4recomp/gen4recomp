-- Compiles the small HGSS 2D resource set used by the Professor Oak/profile
-- flow. Nitro container decoding stays in G2dDecoder; this module owns only
-- the source mapping, native-pixel composition, semantic manifest, and
-- producer dependency record.

local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngWriter = require("libs.assets.src.PngWriter")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local IntroAssetImage = require("romdump.src.digest.newgame.IntroAssetImage")
local IntroObjPaletteResolver = require("romdump.src.digest.newgame.IntroObjPaletteResolver")
local IntroRasterizer = require("romdump.src.digest.newgame.IntroRasterizer")
local config = require("romdump.src.config.IntroAssets")

local IntroAssetCompiler = {}

IntroAssetCompiler.ERROR = { SOURCE_INVALID = "INTRO_SOURCE_INVALID" }
-- The source shrink task spends eight calls decrementing its post-change delay,
-- so each replacement remains visible for nine source ticks.
local SHRINK_FRAME_DURATION = 9

local function sourceError(message, context)
  Errors.raise(IntroAssetCompiler.ERROR.SOURCE_INVALID, message, context or {})
end

local function decodeMember(archive, memberId, label, archiveName)
  archiveName = archiveName or config.archive
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    sourceError("source intro member " .. memberId .. " is unavailable: " .. tostring(err), {
      archive = archiveName,
      memberId = memberId,
      label = label,
      sourceOffset = 0,
    })
  end
  assert(type(bytes) == "string", "intro source member must be a byte string")
  if string.byte(bytes, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(bytes)
    if not plain then
      sourceError("source intro member " .. memberId .. " has invalid compression: " .. tostring(lzErr), {
        archive = archiveName,
        memberId = memberId,
        label = label,
        sourceOffset = 0,
      })
    end
    bytes = assert(plain)
  end
  return bytes
end

local function decode(kind, bytes, label, memberId, archiveName)
  local value, err = G2dDecoder[kind](bytes, { label = label })
  if not value then
    assert(err)
    sourceError("source intro member " .. memberId .. " failed " .. kind .. ": " .. err.message, {
      archive = archiveName or config.archive,
      memberId = memberId,
      label = label,
      sourceOffset = err.context and err.context.offset or 0,
      cause = err.code,
    })
  end
  return value
end

local function addDependency(dependencies, archiveName, memberId, bytes, role)
  assert(type(bytes) == "string", "intro dependency must be a byte string")
  dependencies[#dependencies + 1] = {
    archive = archiveName,
    memberId = memberId,
    role = role,
    sha1 = Hashing.sha1hex(bytes),
  }
end

local function u32le(bytes, offset, label)
  if offset + 4 > #bytes then
    sourceError("intro resource table is truncated", { label = label, sourceOffset = offset })
  end
  return string.byte(bytes, offset + 1)
    + string.byte(bytes, offset + 2) * 256
    + string.byte(bytes, offset + 3) * 65536
    + string.byte(bytes, offset + 4) * 16777216
end

local function readResourceTable(archive, dependencies, spec, memberId, role)
  local bytes = decodeMember(archive, memberId, role, spec.resourceResolution.archive)
  addDependency(dependencies, spec.resourceResolution.archive, memberId, bytes, role)
  local records, ordered, offset = {}, {}, 4
  while true do
    local narcId = u32le(bytes, offset, role)
    if narcId == 0xFFFFFFFE then
      return records, ordered, bytes
    end
    local fileId = u32le(bytes, offset + 4, role)
    local compressed = u32le(bytes, offset + 8, role)
    local objectId = u32le(bytes, offset + 12, role)
    local record = {
      narcId = narcId,
      fileId = fileId,
      compressed = compressed,
      objectId = objectId,
      vram = u32le(bytes, offset + 16, role),
      bankCount = u32le(bytes, offset + 20, role),
    }
    if records[objectId] then
      sourceError("intro resource table contains a duplicate resource id", { objectId = objectId, label = role })
    end
    records[objectId] = record
    ordered[#ordered + 1] = record
    offset = offset + 24
  end
end

---@param resourceDataArchive table<string, unknown>
---@param dependencies table<string, unknown>
---@param spec table<string, unknown>
---@param id string
---@param paletteRecords table<string, unknown>|nil
---@param paletteBytes string|nil
---@return table<string, unknown>
local function resolveResourceSet(resourceDataArchive, dependencies, spec, id, paletteRecords, paletteBytes)
  local resolution = assert(spec.resourceResolution)
  local headerBytes = decodeMember(resourceDataArchive, resolution.header, id .. " resource header", resolution.archive)
  addDependency(dependencies, resolution.archive, resolution.header, headerBytes, id .. ":resdat-header")
  local headerOffset = spec.resourceSet * 32
  local charId = u32le(headerBytes, headerOffset, id .. " resource header")
  local paletteId = u32le(headerBytes, headerOffset + 4, id .. " resource header")
  local cellId = u32le(headerBytes, headerOffset + 8, id .. " resource header")
  local animationId = u32le(headerBytes, headerOffset + 12, id .. " resource header")
  local tables = {
    { key = "char", memberId = resolution.charTable, objectId = charId },
    { key = "palette", memberId = resolution.paletteTable, objectId = paletteId },
    { key = "cell", memberId = resolution.cellTable, objectId = cellId },
    { key = "animation", memberId = resolution.animationTable, objectId = animationId },
  }
  local resolved = {}
  for _, tableSpec in ipairs(tables) do
    local role = id .. ":resdat-" .. tableSpec.key .. "-table"
    local records
    if tableSpec.key == "palette" and paletteRecords then
      records = paletteRecords
      addDependency(dependencies, resolution.archive, tableSpec.memberId, assert(paletteBytes), role)
    else
      records = readResourceTable(resourceDataArchive, dependencies, spec, tableSpec.memberId, role)
    end
    local record = records[tableSpec.objectId]
    if not record or record.narcId ~= resolution.sourceNarcId then
      sourceError("intro resource set references an unsupported source archive", {
        asset = id,
        resourceSet = spec.resourceSet,
        resourceId = tableSpec.objectId,
        narcId = record and record.narcId,
      })
    end
    resolved[tableSpec.key] = record.fileId
  end
  local result = {}
  for key, value in pairs(spec) do
    result[key] = value --[[@as string|integer|table]]
  end
  result.char, result.palette = resolved.char, resolved.palette
  result.cell, result.animation = resolved.cell, resolved.animation
  return result
end

local function assetPath(id)
  return IntroAssetCache.assetDir() .. "/" .. id:gsub("%.", "-") .. ".png"
end

local function addAsset(manifest, assets, id, image, frames, sourceBounds, anchor, provenance, sourceCenter, playback)
  sourceBounds = sourceBounds or { x = 0, y = 0, width = image.width, height = image.height }
  anchor = anchor or { x = image.width / 2, y = image.height }
  if
    type(anchor) ~= "table"
    or type(anchor.x) ~= "number"
    or type(anchor.y) ~= "number"
    or anchor.x ~= anchor.x
    or anchor.y ~= anchor.y
    or anchor.x < 0
    or anchor.x > image.width
    or anchor.y < 0
    or anchor.y > image.height
  then
    sourceError("intro asset anchor is outside its generated surface", { asset = id })
  end
  local paths = {}
  for index, frame in ipairs(frames) do
    paths[index] = assetPath(id .. "." .. index)
    assets[paths[index]] = PngWriter.encode(frame.width, frame.height, frame.rgba)
  end
  local widget = {
    image = paths[1],
    width = image.width,
    height = image.height,
    anchor = anchor,
    sourceBounds = sourceBounds,
    sampling = "nearest",
    provenance = provenance,
    frames = {},
  }
  if sourceCenter then
    widget.sourceCenter = sourceCenter
  end
  if playback ~= nil then
    widget.playMode = assert(playback.playMode)
    widget.loopStartFrameIdx = assert(playback.loopStartFrameIdx)
  end
  for index, frame in ipairs(frames) do
    widget.frames[index] = {
      image = paths[index],
      width = frame.width,
      height = frame.height,
      duration = frame.duration,
      anchor = anchor,
      element = frame.element or "none",
      translateX = frame.translateX or 0,
      translateY = frame.translateY or 0,
      scaleX = frame.scaleX or 1,
      scaleY = frame.scaleY or 1,
      rotation = frame.rotation or 0,
    }
  end
  manifest.widgets[id] = widget
end

local loadCharPalette

local function effectivePalette(archive, dependencies, layout, id, spec)
  local ok, ownerOrError, localBank = pcall(IntroObjPaletteResolver.owner, layout, spec.vram, spec.paletteNumber)
  if not ok then
    if Errors.is(ownerOrError) then
      ---@cast ownerOrError Errors.Error
      sourceError(ownerOrError.message, ownerOrError.context)
    end
    error(ownerOrError, 0)
  end
  ---@cast ownerOrError table<string, unknown>
  local owner = ownerOrError
  if owner.narcId ~= spec.resourceResolution.sourceNarcId then
    sourceError("intro absolute palette owner is outside the supported source archive", {
      asset = id,
      engine = spec.vram,
      paletteNumber = spec.paletteNumber,
      ownerNarcId = owner.narcId,
    })
  end
  local archiveName = spec.archive or config.archive
  local paletteBytes = decodeMember(archive, owner.fileId, id .. " effective palette", archiveName)
  addDependency(dependencies, archiveName, owner.fileId, paletteBytes, id:gsub("_", "-") .. ":palette")
  local palette = decode("decodePalette", paletteBytes, id .. " effective palette", owner.fileId, archiveName)
  local sliceOk, colorsOrError = pcall(IntroObjPaletteResolver.slice, palette.colors, 3, localBank)
  if not sliceOk then
    if Errors.is(colorsOrError) then
      ---@cast colorsOrError Errors.Error
      sourceError(colorsOrError.message, colorsOrError.context)
    end
    error(colorsOrError, 0)
  end
  ---@cast colorsOrError table[]
  return colorsOrError
end

local function buildPaletteLayout(records)
  local ok, layoutOrError = pcall(IntroObjPaletteResolver.build, records)
  if not ok then
    if Errors.is(layoutOrError) then
      ---@cast layoutOrError Errors.Error
      sourceError(layoutOrError.message, layoutOrError.context)
    end
    error(layoutOrError, 0)
  end
  ---@cast layoutOrError table<string, unknown>
  return layoutOrError
end

local function compileCellAnimation(archive, dependencies, manifest, assets, id, spec, layout)
  local dependencyRole = id:gsub("_", "-")
  local archiveName = spec.archive or config.archive
  local charBytes = decodeMember(archive, spec.char, id .. " char", archiveName)
  addDependency(dependencies, archiveName, spec.char, charBytes, dependencyRole .. ":char")
  local char = decode("decodeChar", charBytes, id .. " char", spec.char, archiveName)
  if char.depth ~= 3 then
    sourceError("configured intro cell graphics do not support 8bpp", { asset = id, depth = char.depth })
  end
  local paletteColors = effectivePalette(archive, dependencies, layout, id, spec)
  local cellBytes = decodeMember(archive, spec.cell, id .. " cell", spec.archive)
  local animationBytes = decodeMember(archive, spec.animation, id .. " animation", spec.archive)
  addDependency(dependencies, spec.archive, spec.cell, cellBytes, dependencyRole .. ":cell")
  addDependency(dependencies, spec.archive, spec.animation, animationBytes, dependencyRole .. ":animation")
  local cells = decode("decodeCell", cellBytes, id .. " cell", spec.cell, spec.archive)
  local animation = decode("decodeAnimation", animationBytes, id .. " animation", spec.animation, spec.archive)
  local image, frames, playback =
    IntroRasterizer.renderAnimations(char, paletteColors, cells, animation, spec.animationIndex)
  addAsset(manifest, assets, id, image, frames, image.sourceBounds, image.anchor, {
    resourceSet = spec.resourceSet,
    paletteNumber = spec.paletteNumber,
    rule = "stable-oam-origin",
  }, spec.sourceCenter, playback)
end

local function loadCharPaletteImpl(archive, dependencies, spec, role)
  local archiveName = spec.archive or config.archive
  local charBytes = decodeMember(archive, spec.char, role .. " char", archiveName)
  local paletteBytes = decodeMember(archive, spec.palette, role .. " palette", archiveName)
  addDependency(dependencies, archiveName, spec.char, charBytes, role .. ":char")
  addDependency(dependencies, archiveName, spec.palette, paletteBytes, role .. ":palette")
  return decode("decodeChar", charBytes, role .. " char", spec.char, archiveName),
    decode("decodePalette", paletteBytes, role .. " palette", spec.palette, archiveName)
end

loadCharPalette = loadCharPaletteImpl

local function compileSingle(archive, dependencies, manifest, assets, id, spec, dependencyRole)
  dependencyRole = dependencyRole or id
  local char, palette = loadCharPalette(archive, dependencies, spec, dependencyRole)
  local image = IntroRasterizer.renderChar(char, palette.colors)
  if spec.screen then
    local screenBytes = decodeMember(archive, spec.screen, dependencyRole .. " screen", spec.archive or config.archive)
    addDependency(dependencies, spec.archive or config.archive, spec.screen, screenBytes, dependencyRole .. ":screen")
    local screen =
      decode("decodeScreen", screenBytes, dependencyRole .. " screen", spec.screen, spec.archive or config.archive)
    image = IntroRasterizer.renderScreen(char, palette.colors, screen)
  end
  local cropped = IntroAssetImage.cropAlphaUnion({ image }, { x = image.width / 2, y = image.height })
  addAsset(
    manifest,
    assets,
    id,
    cropped,
    { { width = cropped.width, height = cropped.height, rgba = cropped.frames[1].rgba, duration = 1 } },
    cropped.sourceBounds,
    cropped.anchor,
    { rule = "alpha-crop-bottom-center" }
  )
end

local function compileShrink(archive, dependencies, manifest, assets, id, spec)
  -- Shrink frames are the portrait screen (NSCR 9) rendered with each
  -- replacement NCGR. This matches OakSpeech_DrawPicOnBgLayer which loads
  -- the portrait char then its screen map (member 9) and reuses that mapping
  -- for every shrink replacement.
  local screenMember = spec.screen or 9
  local screenBytes = decodeMember(archive, screenMember, id .. " screen", spec.archive or config.archive)
  addDependency(dependencies, spec.archive or config.archive, screenMember, screenBytes, id .. ":screen")
  local screen = decode("decodeScreen", screenBytes, id .. " screen", screenMember, spec.archive or config.archive)
  local images, width = {}, nil
  for frameIndex, charMember in ipairs(spec.chars) do
    local charBytes = decodeMember(archive, charMember, id .. " char " .. frameIndex, spec.archive or config.archive)
    local paletteBytes =
      decodeMember(archive, spec.palette, id .. " palette " .. frameIndex, spec.archive or config.archive)
    if frameIndex == 1 then
      addDependency(dependencies, spec.archive or config.archive, spec.palette, paletteBytes, id .. ":palette")
    end
    addDependency(dependencies, spec.archive or config.archive, charMember, charBytes, id .. ":char:" .. frameIndex)
    local char =
      decode("decodeChar", charBytes, id .. " char " .. frameIndex, charMember, spec.archive or config.archive)
    local palette = decode(
      "decodePalette",
      paletteBytes,
      id .. " palette " .. frameIndex,
      spec.palette,
      spec.archive or config.archive
    )
    local image = IntroRasterizer.renderScreen(char, palette.colors, screen)
    if width ~= nil and image.width ~= width then
      sourceError("intro shrink frames have inconsistent dimensions", { asset = id, memberId = charMember })
    end
    width = width or image.width
    images[#images + 1] = image
  end
  local cropped = IntroAssetImage.cropAlphaUnion(images, { x = width / 2, y = images[1].height })
  local frames = {}
  for frameIndex, image in ipairs(cropped.frames) do
    frames[frameIndex] = {
      width = cropped.width,
      height = cropped.height,
      rgba = image.rgba,
      duration = SHRINK_FRAME_DURATION,
    }
  end
  addAsset(
    manifest,
    assets,
    id,
    cropped,
    frames,
    cropped.sourceBounds,
    cropped.anchor,
    { rule = "portrait-screen-alpha-union", screenMember = screenMember, paletteMember = spec.palette }
  )
end

local function sourceArchive(romFs, archiveName)
  local archive, err = romFs:openNarc(archiveName)
  if not archive then
    sourceError("source intro archive is unavailable: " .. tostring(err), { archive = archiveName, sourceOffset = 0 })
  end
  return archive
end

---@param romFs table<string, unknown> RomFs-shaped source reader
---@return table<string, unknown> bundle
function IntroAssetCompiler.compile(romFs)
  assert(
    romFs and type(romFs.metadata) == "function" and type(romFs.openNarc) == "function",
    "intro compilation requires source metadata and archive reader"
  )
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "intro source metadata must carry sha1")
  local variant = assert(type(romFs.version) == "function" and romFs:version(), "intro source variant is required")
  local paletteMember = config.variant(variant)
  local backgroundSpec = { char = config.background.char, palette = paletteMember, screen = config.background.screen }
  local archive = sourceArchive(romFs, config.archive)
  local resourceResolution = config.ball_open.resourceResolution
  local resourceDataArchive = sourceArchive(romFs, resourceResolution.archive)
  local dependencies, assets = {}, {}
  local paletteRecords, paletteOrder, paletteBytes = readResourceTable(
    resourceDataArchive,
    dependencies,
    config.ball_open,
    resourceResolution.paletteTable,
    "intro-palette-layout"
  )
  local paletteLayout = buildPaletteLayout(paletteOrder)
  local defaultToneMember = config.genderSelector.paletteMembers[variant]
  local defaultToneBytes = decodeMember(archive, defaultToneMember, "gender selector default tone", config.archive)
  addDependency(dependencies, config.archive, defaultToneMember, defaultToneBytes, "gender-selector:default-tone")
  local defaultTonePalette =
    decode("decodePalette", defaultToneBytes, "gender selector default tone", defaultToneMember, config.archive)
  local defaultTone = defaultTonePalette.colors[config.genderSelector.defaultToneEntry + 1]
  if not defaultTone then
    sourceError("gender selector default tone palette entry is missing", {
      paletteMember = defaultToneMember,
      paletteEntry = config.genderSelector.defaultToneEntry,
    })
  end
  local manifest = {
    schemaVersion = 11,
    variant = variant,
    sourceReference = { width = 256, height = 192 },
    genderSelector = {
      defaultTone = { r = defaultTone.r, g = defaultTone.g, b = defaultTone.b },
      buttons = config.genderSelector.buttons,
    },
    widgets = {},
  }

  local backgroundChar, backgroundPalette = loadCharPalette(archive, dependencies, backgroundSpec, "background")
  local backgroundBytes = decodeMember(archive, config.background.screen, "background screen", config.archive)
  addDependency(dependencies, config.archive, config.background.screen, backgroundBytes, "background:screen")
  local backgroundScreen =
    decode("decodeScreen", backgroundBytes, "background screen", config.background.screen, config.archive)
  local renderedBackground = IntroRasterizer.renderScreen(backgroundChar, backgroundPalette.colors, backgroundScreen)
  local gradient =
    IntroAssetImage.reduceGradient(renderedBackground.width, renderedBackground.height, renderedBackground.rgba)
  local backgroundPath = IntroAssetCache.assetDir() .. "/background.png"
  assets[backgroundPath] = PngWriter.encode(gradient.width, gradient.height, gradient.rgba)
  manifest.background = {
    image = backgroundPath,
    width = 1,
    height = 192,
    sampling = "linear",
    provenance = { charMember = 0, screenMember = 3, paletteMember = paletteMember },
  }

  compileSingle(archive, dependencies, manifest, assets, "oak", config.oak)
  compileSingle(archive, dependencies, manifest, assets, "male", config.gender.male)
  compileSingle(archive, dependencies, manifest, assets, "female", config.gender.female)
  for _, id in ipairs({ "gender_male", "gender_female" }) do
    local spec = config.genderSelectors[id:gsub("gender_", "")]
    compileCellAnimation(
      archive,
      dependencies,
      manifest,
      assets,
      id,
      resolveResourceSet(resourceDataArchive, dependencies, spec, id, paletteRecords, paletteBytes),
      paletteLayout
    )
  end
  compileShrink(archive, dependencies, manifest, assets, "shrink_male", config.shrink.male)
  compileShrink(archive, dependencies, manifest, assets, "shrink_female", config.shrink.female)

  local ballArchive = sourceArchive(romFs, config.ball_open.archive)
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    local spec = assert(config[id])
    assert(type(spec) == "table")
    ---@cast spec table<string, unknown>
    local resolved = resolveResourceSet(resourceDataArchive, dependencies, spec, id, paletteRecords, paletteBytes)
    compileCellAnimation(ballArchive, dependencies, manifest, assets, id, resolved, paletteLayout)
  end

  local valid, err = IntroAssetCache.validateManifest(manifest)
  if not valid then
    assert(err)
    sourceError("compiled intro manifest is invalid: " .. err.message, { cause = err.code, sourceOffset = 0 })
  end
  return {
    marker = IntroAssetCache.marker(metadata.sha1, Hashing.hashLua(dependencies)),
    manifest = manifest,
    dependencies = {
      schema = "g4-intro-provenance-v1",
      source = config.provenance,
      dependencies = dependencies,
    },
    assets = assets,
  }
end

return IntroAssetCompiler
