-- Exhaustive ROM resource evidence: every named NitroFS file and every
-- member of every valid NARC, independently classified/decoded through the
-- existing Nitro format decoders, plus ROM-derived numeric NARC-ID
-- pointer-run candidates recovered from the normalized main ARM9 image and
-- the NARC path strings it contains. No resource composition is guessed;
-- each member is evidence about itself only.

local Narc = require("libs.nds.src.nitro.Narc")
local Lz10 = require("romdump.src.digest.Lz10")
local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local Hashing = require("romdump.src.digest.Hashing")

---@class ResourceCatalog.RomSource
---@field nitroFs fun(self: ResourceCatalog.RomSource): { byFileId: table<integer, string> }
---@field readFatFile fun(self: ResourceCatalog.RomSource, fileId: integer): string

---@class ResourceCatalog.FileRecord
---@field fileId integer
---@field path string
---@field size integer
---@field sha1 string
---@field magic string
---@field kind "narc"|"file"|"malformed-narc"

---@class ResourceCatalog.MemberRecord
---@field memberId integer
---@field rawSize integer
---@field rawSha1 string
---@field compression "none"|"lz10"|"lz11"
---@field compressionCandidate "lz10"|nil
---@field decodedSize integer|nil
---@field decodedSha1 string|nil
---@field kind string
---@field status "decoded"|"unknown"|"decode-failed"|"compression-unsupported"
---@field summary table<string, string|number>|nil

---@class ResourceCatalog.DetailSelection
---@field fileId integer
---@field memberId integer

---@class ResourceCatalog.Detail
---@field fileId integer
---@field memberId integer
---@field narcPath string
---@field kind string
---@field status string
---@field compression string
---@field compressionCandidate string|nil
---@field rawSize integer
---@field rawSha1 string
---@field decodedSize integer|nil
---@field decodedSha1 string|nil
---@field payloadBasis "raw"|"lz10-decoded"
---@field payload string
---@field payloadSize integer
---@field payloadSha1 string
---@field structure table<string, unknown>|nil

---@class ResourceCatalog.NarcRecord
---@field fileId integer
---@field path string
---@field size integer
---@field sha1 string
---@field memberCount integer
---@field members ResourceCatalog.MemberRecord[]

---@class ResourceCatalog.CandidateEntry
---@field index integer
---@field pointerAddress integer
---@field stringAddress integer
---@field path string

---@class ResourceCatalog.Candidate
---@field address integer
---@field entryCount integer
---@field primaryCandidate boolean
---@field entries ResourceCatalog.CandidateEntry[]

---@class ResourceCatalog.Coverage
---@field enumerationComplete boolean
---@field namedFileCount integer
---@field scannedFileCount integer
---@field narcCount integer
---@field narcMemberCount integer
---@field decodedMemberCount integer
---@field unknownMemberCount integer
---@field failedMemberCount integer
---@field unsupportedMemberCount integer

---@class ResourceCatalog.Evidence
---@field schema "g4-resource-evidence-1"
---@field files ResourceCatalog.FileRecord[]
---@field narcs ResourceCatalog.NarcRecord[]
---@field narcIdCandidates ResourceCatalog.Candidate[]
---@field gaps table<string, unknown>[]
---@field details ResourceCatalog.Detail[]
---@field coverage ResourceCatalog.Coverage

local ResourceCatalog = {}

local PRIMARY_CANDIDATE_MIN_ENTRIES = 16
local CANDIDATE_RUN_MIN_ENTRIES = 4

--------------------------------------------------------------------------
-- Bounded scalar summaries retain only census facts from validated resources.
--------------------------------------------------------------------------

local function summarizeNcgr(decoded)
  local tileBytes = decoded.depth == 3 and 32 or 64
  return {
    depth = decoded.depth,
    tileCount = #decoded.tiles / tileBytes,
  }
end

local function summarizeNclr(decoded)
  return { colorCount = #decoded.colors }
end

local function summarizeNscr(decoded)
  local maxTile, maxPalette, hFlipCount, vFlipCount = 0, 0, 0, 0
  for _, e in ipairs(decoded.entries) do
    if e.tile > maxTile then
      maxTile = e.tile
    end
    if e.palette > maxPalette then
      maxPalette = e.palette
    end
    if e.flipH then
      hFlipCount = hFlipCount + 1
    end
    if e.flipV then
      vFlipCount = vFlipCount + 1
    end
  end
  return {
    width = decoded.width,
    height = decoded.height,
    entryCount = #decoded.entries,
    maxReferencedTile = maxTile,
    maxReferencedPalette = maxPalette,
    hFlipCount = hFlipCount,
    vFlipCount = vFlipCount,
  }
end

local function summarizeNcer(decoded)
  local objectCount = 0
  for _, cell in ipairs(decoded.cells) do
    objectCount = objectCount + #cell.objs
  end
  return { cellCount = #decoded.cells, objectCount = objectCount }
end

local function summarizeNanr(decoded)
  local frameCount, totalDuration = 0, 0
  for _, animation in ipairs(decoded.anims) do
    frameCount = frameCount + #animation.frames
    for _, frame in ipairs(animation.frames) do
      totalDuration = totalDuration + frame.duration
    end
  end
  return { animationCount = #decoded.anims, frameCount = frameCount, totalDuration = totalDuration }
end

local function summarizeModel(decoded)
  local nodeCount, materialCount, shapeCount = 0, 0, 0
  local totalVertices, totalTriangles = 0, 0
  for _, model in ipairs(decoded.models) do
    nodeCount = nodeCount + #model.nodes
    materialCount = materialCount + #model.materials
    shapeCount = shapeCount + #model.shapes
    for _, shape in ipairs(model.shapes) do
      totalVertices = totalVertices + shape.vertexCount
      totalTriangles = totalTriangles + shape.triangleCount
    end
  end
  return {
    modelCount = #decoded.models,
    nodeCount = nodeCount,
    materialCount = materialCount,
    shapeCount = shapeCount,
    totalVertices = totalVertices,
    totalTriangles = totalTriangles,
  }
end

local function summarizeTexture(decoded)
  return { textureCount = #decoded.textures, paletteCount = #decoded.palettes }
end

local function animationTargetCount(resource)
  local targetCount = resource.numTargets or resource.numAnm
  assert(type(resource.numFrame) == "number", "animation decoder omitted numFrame")
  assert(type(targetCount) == "number", "animation decoder omitted target count")
  return targetCount
end

local function summarizeAnimation(decoded)
  local frameCount, targetCount = 0, 0
  for _, animation in ipairs(decoded.animations) do
    local resource = animation.resource
    local targetCountForAnimation = animationTargetCount(resource)
    frameCount = frameCount + resource.numFrame
    targetCount = targetCount + targetCountForAnimation
  end
  return {
    format = decoded.format,
    animationCount = #decoded.animations,
    frameCount = frameCount,
    targetCount = targetCount,
  }
end

--------------------------------------------------------------------------
-- Decoder dispatch: exactly one supported kind per exact container magic.
--------------------------------------------------------------------------

local DISPATCH = {
  RGCN = { kind = "ncgr", decode = G2dDecoder.decodeChar, summarize = summarizeNcgr },
  RCSN = { kind = "nscr", decode = G2dDecoder.decodeScreen, summarize = summarizeNscr },
  RECN = { kind = "ncer", decode = G2dDecoder.decodeCell, summarize = summarizeNcer },
  RNAN = { kind = "nanr", decode = G2dDecoder.decodeAnimation, summarize = summarizeNanr },
  RLCN = {
    kind = "nclr",
    decode = G2dDecoder.decodePalette,
    summarize = summarizeNclr,
  },
  BMD0 = { kind = "nsbmd", decode = Nsbmd.decode, summarize = summarizeModel },
  BTX0 = { kind = "nsbtx", decode = Nsbtx.decode, summarize = summarizeTexture },
  BCA0 = { kind = "nsbca", decode = NitroAnimation.decode, summarize = summarizeAnimation },
  BTA0 = { kind = "nsbta", decode = NitroAnimation.decode, summarize = summarizeAnimation },
  BTP0 = { kind = "nsbtp", decode = NitroAnimation.decode, summarize = summarizeAnimation },
  BMA0 = { kind = "nsbma", decode = NitroAnimation.decode, summarize = summarizeAnimation },
}

local function copyBounds(bounds)
  if not bounds then
    return nil
  end
  return {
    min = { bounds.min[1], bounds.min[2], bounds.min[3] },
    max = { bounds.max[1], bounds.max[2], bounds.max[3] },
  }
end

local function projectNcgr(decoded)
  local tileStride = decoded.depth == 3 and 32 or 64
  return {
    depth = decoded.depth,
    tileByteCount = #decoded.tiles,
    tileCount = #decoded.tiles / tileStride,
  }
end

local function projectNclr(decoded)
  local colors = {}
  for i, color in ipairs(decoded.colors) do
    colors[i] = {
      r = color.r,
      g = color.g,
      b = color.b,
    }
  end
  return { colorCount = #colors, colors = colors }
end

local function projectNscr(decoded)
  local entries = {}
  for i, entry in ipairs(decoded.entries) do
    entries[i] = {
      tile = entry.tile,
      palette = entry.palette,
      flipH = entry.flipH,
      flipV = entry.flipV,
    }
  end
  return { width = decoded.width, height = decoded.height, entries = entries }
end

local function projectNcer(decoded)
  local cells = {}
  for i, cell in ipairs(decoded.cells) do
    local objects = {}
    for j, object in ipairs(cell.objs) do
      objects[j] = {
        x = object.x,
        y = object.y,
        tile = object.tile,
        palette = object.palette,
        shape = object.shape,
        size = object.size,
        width = object.width,
        height = object.height,
        flipH = object.flipH,
        flipV = object.flipV,
      }
    end
    cells[i] = { objectCount = #objects, objects = objects }
  end
  return { cellCount = #cells, cells = cells }
end

local function projectNanr(decoded)
  local animations = {}
  for i, animation in ipairs(decoded.anims) do
    local frames = {}
    local totalDuration = 0
    for j, frame in ipairs(animation.frames) do
      totalDuration = totalDuration + frame.duration
      frames[j] = {
        cell = frame.cell,
        duration = frame.duration,
        element = frame.element,
        translateX = frame.translateX,
        translateY = frame.translateY,
        scaleX = frame.scaleX,
        scaleY = frame.scaleY,
        rotation = frame.rotation,
      }
    end
    animations[i] = {
      playMode = animation.playMode,
      loopStartFrameIdx = animation.loopStartFrameIdx,
      frameCount = #frames,
      totalDuration = totalDuration,
      frames = frames,
    }
  end
  return { animationCount = #animations, animations = animations }
end

local function projectNsbmd(decoded)
  local models = {}
  for i, model in ipairs(decoded.models) do
    local nodeNames = {}
    for j, node in ipairs(model.nodes) do
      nodeNames[j] = node.name
    end
    local materials = {}
    for j, material in ipairs(model.materials) do
      local projected = { name = material.name }
      if material.textureName ~= nil then
        projected.textureName = material.textureName
      end
      if material.paletteName ~= nil then
        projected.paletteName = material.paletteName
      end
      materials[j] = projected
    end
    local shapes = {}
    for j, shape in ipairs(model.shapes) do
      shapes[j] = {
        index = shape.index,
        name = shape.name,
        vertexCount = shape.vertexCount,
        triangleCount = shape.triangleCount,
        bounds = copyBounds(shape.bounds),
      }
    end
    local function projectAssociations(associations)
      local result = {}
      for j, association in ipairs(associations) do
        local materialIndices = {}
        for k, materialIndex in ipairs(association.materials) do
          materialIndices[k] = materialIndex
        end
        result[j] = { name = association.name, materials = materialIndices }
      end
      return result
    end
    models[i] = {
      index = model.index,
      name = model.name,
      bounds = copyBounds(model.bounds),
      nodeNames = nodeNames,
      materials = materials,
      shapes = shapes,
      textureAssociations = projectAssociations(model.textureAssociations),
      paletteAssociations = projectAssociations(model.paletteAssociations),
    }
  end
  return { modelCount = #models, models = models }
end

local function projectNsbtx(decoded)
  local textures = {}
  for i, texture in ipairs(decoded.textures) do
    textures[i] = {
      name = texture.name,
      format = texture.format,
      width = texture.width,
      height = texture.height,
      color0Transparent = texture.color0Transparent,
      repeatX = texture.repeatX,
      repeatY = texture.repeatY,
      flipX = texture.flipX,
      flipY = texture.flipY,
      coordinateTransformMode = texture.coordinateTransformMode,
      dataSize = texture.dataSize,
    }
  end
  local palettes = {}
  for i, palette in ipairs(decoded.palettes) do
    palettes[i] = { name = palette.name }
  end
  return {
    textureCount = #textures,
    textures = textures,
    paletteCount = #palettes,
    palettes = palettes,
  }
end

local function projectAnimation(decoded)
  local animations = {}
  for i, animation in ipairs(decoded.animations) do
    local resource = animation.resource
    animations[i] = {
      name = animation.name,
      frameCount = resource.numFrame,
      targetCount = animationTargetCount(resource),
    }
  end
  return { format = decoded.format, animationCount = #animations, animations = animations }
end

local DETAIL_PROJECTORS = {
  ncgr = projectNcgr,
  nclr = projectNclr,
  nscr = projectNscr,
  ncer = projectNcer,
  nanr = projectNanr,
  nsbmd = projectNsbmd,
  nsbtx = projectNsbtx,
  nsbca = projectAnimation,
  nsbta = projectAnimation,
  nsbtp = projectAnimation,
  nsbma = projectAnimation,
}

--------------------------------------------------------------------------
-- Member normalization/classification.
--------------------------------------------------------------------------

local function readLe24(bytes)
  return string.byte(bytes, 2) + string.byte(bytes, 3) * 256 + string.byte(bytes, 4) * 65536
end

local function readLe32(bytes, offset)
  local b1, b2, b3, b4 = string.byte(bytes, offset, offset + 3)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function hasPlausibleLz10Envelope(raw)
  return #raw >= 5 and readLe24(raw) > 0
end

local function hasPlausibleLz11Envelope(raw)
  if #raw < 4 then
    return false
  end

  local decodedSize = readLe24(raw)
  if decodedSize > 0 then
    return #raw >= 5
  end

  return #raw >= 9 and readLe32(raw, 5) > 0
end

local function classifyMember(fileId, memberId, raw, gaps)
  local rawSize, rawSha1 = #raw, Hashing.sha1hex(raw)
  local marker = Narc.detectCompression(raw)

  local member = {
    memberId = memberId,
    rawSize = rawSize,
    rawSha1 = rawSha1,
    compression = "none",
    compressionCandidate = nil,
    decodedSize = nil,
    decodedSha1 = nil,
    kind = "unknown",
    status = "unknown",
    summary = nil,
  }

  local normalized = nil
  local decodedFormat = nil
  local spec = nil
  if marker == "lz10" and hasPlausibleLz10Envelope(raw) then
    local decoded, err = Lz10.decode(raw)
    if decoded then
      member.compression = "lz10"
      normalized = decoded
      member.decodedSize = #decoded
      member.decodedSha1 = Hashing.sha1hex(decoded)
    else
      member.compressionCandidate = "lz10"
      gaps[#gaps + 1] = {
        kind = "decode_failed",
        fileId = fileId,
        memberId = memberId,
        format = "lz10",
        compressionCandidate = "lz10",
        error = err and err.message,
      }
    end
  elseif marker == "lz11" and hasPlausibleLz11Envelope(raw) then
    member.compression = "lz11"
    member.status = "compression-unsupported"
    gaps[#gaps + 1] = { kind = "unsupported_lz11", fileId = fileId, memberId = memberId }
  else
    normalized = raw
  end

  if normalized then
    spec = DISPATCH[normalized:sub(1, 4)]
    if spec then
      member.kind = spec.kind
      local decoded, err = spec.decode(normalized)
      if decoded then
        decodedFormat = decoded
        member.status = "decoded"
        member.summary = spec.summarize(decoded)
      else
        member.status = "decode-failed"
        gaps[#gaps + 1] = {
          kind = "decode_failed",
          fileId = fileId,
          memberId = memberId,
          format = spec.kind,
          error = err and err.message,
        }
      end
    end
  end

  return member, normalized, decodedFormat
end

local function selectionKey(fileId, memberId)
  return fileId .. ":" .. memberId
end

local function normalizeSelections(resourceDetails)
  assert(type(resourceDetails) == "table", "resource detail selections must be a table")
  local normalized = {}
  local seen = {}
  for _, selection in ipairs(resourceDetails) do
    assert(type(selection) == "table", "resource detail selection must be a table")
    local fileId, memberId = selection.fileId, selection.memberId
    assert(
      type(fileId) == "number"
        and fileId >= 0
        and fileId % 1 == 0
        and type(memberId) == "number"
        and memberId >= 0
        and memberId % 1 == 0,
      "resource detail selection ids must be non-negative integers"
    )
    local key = selectionKey(fileId, memberId)
    assert(not seen[key], "duplicate resource detail selection: " .. key)
    seen[key] = true
    normalized[#normalized + 1] = { fileId = fileId, memberId = memberId }
  end
  table.sort(normalized, function(a, b)
    return a.fileId < b.fileId or (a.fileId == b.fileId and a.memberId < b.memberId)
  end)
  return normalized, seen
end

local function buildDetail(fileId, memberId, narcPath, raw, member, normalized, decoded)
  local payloadBasis = "raw"
  local payload = raw
  if member.compression == "lz10" then
    assert(type(normalized) == "string", "confirmed LZ10 detail requires normalized bytes")
    payloadBasis = "lz10-decoded"
    payload = normalized
  end

  local structure
  if member.status == "decoded" then
    assert(decoded ~= nil, "decoded resource member must retain its decoder result")
    local projector = DETAIL_PROJECTORS[member.kind]
    assert(projector, "decoded resource kind has no detail projection: " .. member.kind)
    structure = projector(decoded)
  end

  return {
    fileId = fileId,
    memberId = memberId,
    narcPath = narcPath,
    kind = member.kind,
    status = member.status,
    compression = member.compression,
    compressionCandidate = member.compressionCandidate,
    rawSize = member.rawSize,
    rawSha1 = member.rawSha1,
    decodedSize = member.decodedSize,
    decodedSha1 = member.decodedSha1,
    payloadBasis = payloadBasis,
    payload = payload,
    payloadSize = #payload,
    payloadSha1 = Hashing.sha1hex(payload),
    structure = structure,
  }
end

--------------------------------------------------------------------------
-- ROM-derived numeric NARC-ID pointer-run candidate reconstruction.
--------------------------------------------------------------------------

local function u32le(bytes, offset)
  local b1, b2, b3, b4 = string.byte(bytes, offset + 1, offset + 4)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function findStringOccurrences(bytes, ramAddress, path)
  local pattern = path .. "\0"
  local occurrences = {}
  local from = 1
  while true do
    local start = string.find(bytes, pattern, from, true)
    if not start then
      break
    end
    occurrences[#occurrences + 1] = { address = ramAddress + (start - 1), path = path }
    from = start + 1
  end
  return occurrences
end

local function findNarcIdCandidates(mainImage, narcPaths)
  local bytes, ramAddress = mainImage.bytes, mainImage.ramAddress

  local targetsByAddress = {}
  for _, path in ipairs(narcPaths) do
    for _, occ in ipairs(findStringOccurrences(bytes, ramAddress, path)) do
      targetsByAddress[occ.address] = occ.path
    end
  end

  local runs = {}
  local current = {}
  local length = #bytes
  local offset = 0
  while offset + 4 <= length do
    local target = targetsByAddress[u32le(bytes, offset)]
    if target then
      current[#current + 1] = {
        index = #current,
        pointerAddress = ramAddress + offset,
        stringAddress = u32le(bytes, offset),
        path = target,
      }
    else
      if #current >= CANDIDATE_RUN_MIN_ENTRIES then
        runs[#runs + 1] = current
      end
      current = {}
    end
    offset = offset + 4
  end
  if #current >= CANDIDATE_RUN_MIN_ENTRIES then
    runs[#runs + 1] = current
  end

  local candidates = {}
  for _, entries in ipairs(runs) do
    candidates[#candidates + 1] = {
      address = entries[1].pointerAddress,
      entryCount = #entries,
      primaryCandidate = false,
      entries = entries,
    }
  end

  table.sort(candidates, function(a, b)
    if a.entryCount ~= b.entryCount then
      return a.entryCount > b.entryCount
    end
    return a.address < b.address
  end)

  if #candidates > 0 then
    local maxLength = candidates[1].entryCount
    local tieCount = 0
    for _, c in ipairs(candidates) do
      if c.entryCount == maxLength then
        tieCount = tieCount + 1
      end
    end
    if tieCount == 1 and maxLength >= PRIMARY_CANDIDATE_MIN_ENTRIES then
      candidates[1].primaryCandidate = true
    end
  end

  return candidates
end

--------------------------------------------------------------------------
-- Scan.
--------------------------------------------------------------------------

---@param rom ResourceCatalog.RomSource
---@param romImage RomImage
---@param resourceDetails ResourceCatalog.DetailSelection[]|nil
---@return ResourceCatalog.Evidence
function ResourceCatalog.scan(rom, romImage, resourceDetails)
  assert(rom, "ResourceCatalog.scan requires an NdsRom")
  assert(romImage, "ResourceCatalog.scan requires a RomImage")
  local selections, selectionSet = normalizeSelections(resourceDetails or {})
  local matchedSelections = {}

  local named = rom:nitroFs().byFileId
  local fileIds = {}
  for fileId in pairs(named) do
    fileIds[#fileIds + 1] = fileId
  end
  table.sort(fileIds)

  local files, narcs, gaps, details = {}, {}, {}, {}
  local narcPaths = {}
  local enumerationComplete = true
  local narcMemberCount, decodedMemberCount, unknownMemberCount, failedMemberCount, unsupportedMemberCount =
    0, 0, 0, 0, 0

  for _, fileId in ipairs(fileIds) do
    local path = named[fileId]
    local bytes = rom:readFatFile(fileId)
    local size, sha1 = #bytes, Hashing.sha1hex(bytes)
    local magic = bytes:sub(1, math.min(4, #bytes))

    local kind = "file"
    if bytes:sub(1, 4) == "NARC" then
      local narc = Narc.open(bytes, path)
      if narc then
        kind = "narc"
        local memberCount = narc:memberCount()
        local members = {}
        for memberId = 0, memberCount - 1 do
          local raw = assert(narc:readMember(memberId))
          local member, normalized, decoded = classifyMember(fileId, memberId, raw, gaps)
          members[memberId + 1] = member
          local key = selectionKey(fileId, memberId)
          if selectionSet[key] then
            details[#details + 1] = buildDetail(fileId, memberId, path, raw, member, normalized, decoded)
            matchedSelections[key] = true
          end
          narcMemberCount = narcMemberCount + 1
          if member.status == "decoded" then
            decodedMemberCount = decodedMemberCount + 1
          elseif member.status == "unknown" then
            unknownMemberCount = unknownMemberCount + 1
          elseif member.status == "decode-failed" then
            failedMemberCount = failedMemberCount + 1
          elseif member.status == "compression-unsupported" then
            unsupportedMemberCount = unsupportedMemberCount + 1
          else
            error("unrecognized resource member status: " .. tostring(member.status))
          end
        end
        narcs[#narcs + 1] = {
          fileId = fileId,
          path = path,
          size = size,
          sha1 = sha1,
          memberCount = memberCount,
          members = members,
        }
        narcPaths[#narcPaths + 1] = path
      else
        kind = "malformed-narc"
        enumerationComplete = false
        gaps[#gaps + 1] = { kind = "malformed_narc", fileId = fileId, path = path }
      end
    end

    files[#files + 1] = { fileId = fileId, path = path, size = size, sha1 = sha1, magic = magic, kind = kind }
  end

  for _, selection in ipairs(selections) do
    local key = selectionKey(selection.fileId, selection.memberId)
    if not matchedSelections[key] then
      Errors.raise(
        "APPDISCOVERY_RESOURCE_DETAIL_NOT_FOUND",
        "requested resource detail does not identify a valid NARC member",
        { fileId = selection.fileId, memberId = selection.memberId }
      )
    end
  end

  table.sort(details, function(a, b)
    return a.fileId < b.fileId or (a.fileId == b.fileId and a.memberId < b.memberId)
  end)

  local mainImage = romImage:mainArm9()
  local narcIdCandidates = findNarcIdCandidates(mainImage, narcPaths)

  assert(
    decodedMemberCount + unknownMemberCount + failedMemberCount + unsupportedMemberCount == narcMemberCount,
    "resource member status census must reconcile"
  )

  return {
    schema = "g4-resource-evidence-1",
    files = files,
    narcs = narcs,
    narcIdCandidates = narcIdCandidates,
    gaps = gaps,
    details = details,
    coverage = {
      enumerationComplete = enumerationComplete,
      namedFileCount = #files,
      scannedFileCount = #files,
      narcCount = #narcs,
      narcMemberCount = narcMemberCount,
      decodedMemberCount = decodedMemberCount,
      unknownMemberCount = unknownMemberCount,
      failedMemberCount = failedMemberCount,
      unsupportedMemberCount = unsupportedMemberCount,
    },
  }
end

return ResourceCatalog
