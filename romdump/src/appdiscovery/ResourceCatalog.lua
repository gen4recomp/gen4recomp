-- Exhaustive ROM resource evidence: every named NitroFS file and every
-- member of every valid NARC, independently classified/decoded through the
-- existing Nitro format decoders, plus ROM-derived numeric NARC-ID
-- pointer-run candidates recovered from the normalized main ARM9 image and
-- the NARC path strings it contains. No resource composition is guessed;
-- each member is evidence about itself only.

local Narc = require("libs.nds.src.nitro.Narc")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local Hashing = require("romdump.src.digest.Hashing")
local ResourcePreview = require("romdump.src.appdiscovery.ResourcePreview")

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
---@field decodedSize integer|nil
---@field decodedSha1 string|nil
---@field kind string
---@field status "decoded"|"unknown"|"decode-failed"|"compression-unsupported"
---@field summary table<string, unknown>|nil
---@field previewKey string|nil

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

---@class ResourceCatalog.Preview
---@field key string
---@field fileId integer
---@field memberId integer
---@field kind string
---@field width integer
---@field height integer
---@field png string

---@class ResourceCatalog.Coverage
---@field complete boolean
---@field namedFileCount integer
---@field scannedFileCount integer
---@field narcCount integer
---@field narcMemberCount integer
---@field decodedMemberCount integer
---@field unknownMemberCount integer
---@field failedMemberCount integer

---@class ResourceCatalog.Evidence
---@field schema "g4-resource-evidence-1"
---@field files ResourceCatalog.FileRecord[]
---@field narcs ResourceCatalog.NarcRecord[]
---@field narcIdCandidates ResourceCatalog.Candidate[]
---@field previews ResourceCatalog.Preview[]
---@field gaps table<string, unknown>[]
---@field coverage ResourceCatalog.Coverage

local ResourceCatalog = {}

local PRIMARY_CANDIDATE_MIN_ENTRIES = 16
local CANDIDATE_RUN_MIN_ENTRIES = 4

--------------------------------------------------------------------------
-- Compact, closed-allowlist summaries. Only scalar/list source facts are
-- copied out of decoder results; no raw display-list/texel/palette buffer,
-- decoded geometry, or opaque decoder state is retained.
--------------------------------------------------------------------------

local function summarizeNcgr(decoded)
  local tileBytes = decoded.depth == 3 and 32 or 64
  return {
    depth = decoded.depth,
    tileByteCount = #decoded.tiles,
    tileCount = #decoded.tiles / tileBytes,
  }
end

-- G2dDecoder/FieldFontDecoder both hand back colors already expanded to
-- 8-bit sRGB (the shared Rgb555 helper they reuse for direct rendering).
-- The resource evidence summary/preview contract works in the raw
-- RGB555 0..31 channel domain instead, so narrow the decoder's 8-bit
-- output back to its exact source 5-bit value (an exact inverse of the
-- shared expand5 rounding) before it reaches either consumer.
local function narrowTo5Bit(v)
  return math.floor(v * 31 / 255 + 0.5)
end

local function toRaw555Palette(decoded)
  local colors = {}
  for i, c in ipairs(decoded.colors) do
    colors[i] = { r = narrowTo5Bit(c.r), g = narrowTo5Bit(c.g), b = narrowTo5Bit(c.b) }
  end
  return { colors = colors }
end

local function summarizeNclr(decoded)
  local colors = {}
  for i, c in ipairs(decoded.colors) do
    colors[i] = { r = c.r, g = c.g, b = c.b }
  end
  return { colorCount = #decoded.colors, colors = colors }
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
  local cells = {}
  for ci, cell in ipairs(decoded.cells) do
    local objs = {}
    local minX, minY, maxX, maxY
    for oi, o in ipairs(cell.objs) do
      objs[oi] = {
        x = o.x,
        y = o.y,
        tile = o.tile,
        palette = o.palette,
        shape = o.shape,
        size = o.size,
        width = o.width,
        height = o.height,
        flipH = o.flipH,
        flipV = o.flipV,
      }
      local x0, y0, x1, y1 = o.x, o.y, o.x + o.width, o.y + o.height
      if minX == nil then
        minX, minY, maxX, maxY = x0, y0, x1, y1
      else
        minX, minY = math.min(minX, x0), math.min(minY, y0)
        maxX, maxY = math.max(maxX, x1), math.max(maxY, y1)
      end
    end
    cells[ci] = {
      objectCount = #cell.objs,
      bounds = { minX = minX, minY = minY, maxX = maxX, maxY = maxY },
      objects = objs,
    }
  end
  return { cellCount = #decoded.cells, cells = cells }
end

local function summarizeNanr(decoded)
  local anims = {}
  for ai, a in ipairs(decoded.anims) do
    local frames, totalDuration = {}, 0
    for fi, f in ipairs(a.frames) do
      frames[fi] = {
        cell = f.cell,
        duration = f.duration,
        element = f.element,
        translateX = f.translateX,
        translateY = f.translateY,
        scaleX = f.scaleX,
        scaleY = f.scaleY,
        rotation = f.rotation,
      }
      totalDuration = totalDuration + f.duration
    end
    anims[ai] = {
      playMode = a.playMode,
      loopStartFrameIdx = a.loopStartFrameIdx,
      frameCount = #a.frames,
      totalDuration = totalDuration,
      frames = frames,
    }
  end
  return { animationCount = #decoded.anims, animations = anims }
end

local function summarizeModel(decoded)
  local models = {}
  for mi, model in ipairs(decoded.models) do
    local nodeNames, materialNames, shapeNames = {}, {}, {}
    for i, n in ipairs(model.nodes) do
      nodeNames[i] = n.name
    end
    for i, m in ipairs(model.materials) do
      materialNames[i] = m.name
    end
    local totalVertices, totalTriangles = 0, 0
    for i, s in ipairs(model.shapes) do
      shapeNames[i] = s.name
      totalVertices = totalVertices + s.vertexCount
      totalTriangles = totalTriangles + s.triangleCount
    end
    local textureAssociationNames = {}
    for i, a in ipairs(model.textureAssociations) do
      textureAssociationNames[i] = a.name
    end
    local paletteAssociationNames = {}
    for i, a in ipairs(model.paletteAssociations) do
      paletteAssociationNames[i] = a.name
    end
    local bounds = nil
    if model.bounds then
      bounds = {
        min = { model.bounds.min[1], model.bounds.min[2], model.bounds.min[3] },
        max = { model.bounds.max[1], model.bounds.max[2], model.bounds.max[3] },
      }
    end
    models[mi] = {
      index = model.index,
      name = model.name,
      nodeCount = #model.nodes,
      nodeNames = nodeNames,
      materialCount = #model.materials,
      materialNames = materialNames,
      shapeCount = #model.shapes,
      shapeNames = shapeNames,
      totalVertices = totalVertices,
      totalTriangles = totalTriangles,
      bounds = bounds,
      textureAssociationNames = textureAssociationNames,
      paletteAssociationNames = paletteAssociationNames,
    }
  end
  return { modelCount = #decoded.models, models = models }
end

local function summarizeTexture(decoded)
  local textures = {}
  for i, t in ipairs(decoded.textures) do
    textures[i] = { name = t.name, format = t.format, width = t.width, height = t.height }
  end
  local palettes = {}
  for i, p in ipairs(decoded.palettes) do
    palettes[i] = { name = p.name }
  end
  return { textureCount = #decoded.textures, textures = textures, paletteCount = #decoded.palettes, palettes = palettes }
end

local function summarizeAnimation(decoded)
  local names, counts = {}, {}
  for i, a in ipairs(decoded.animations) do
    names[i] = a.name
    counts[i] = {
      frameCount = a.resource.numFrame,
      targetCount = a.resource.numTargets or a.resource.numAnm,
    }
  end
  return {
    format = decoded.format,
    animationCount = #decoded.animations,
    animationNames = names,
    animationCounts = counts,
  }
end

--------------------------------------------------------------------------
-- Decoder dispatch: exactly one supported kind per exact container magic.
--------------------------------------------------------------------------

local DISPATCH = {
  RGCN = { kind = "ncgr", decode = G2dDecoder.decodeChar, summarize = summarizeNcgr, preview = ResourcePreview.ncgr },
  RCSN = { kind = "nscr", decode = G2dDecoder.decodeScreen, summarize = summarizeNscr },
  RECN = { kind = "ncer", decode = G2dDecoder.decodeCell, summarize = summarizeNcer },
  RNAN = { kind = "nanr", decode = G2dDecoder.decodeAnimation, summarize = summarizeNanr },
  RLCN = {
    kind = "nclr",
    decode = G2dDecoder.decodePalette,
    postDecode = toRaw555Palette,
    summarize = summarizeNclr,
    preview = ResourcePreview.nclr,
  },
  BMD0 = { kind = "nsbmd", decode = Nsbmd.decode, summarize = summarizeModel },
  BTX0 = { kind = "nsbtx", decode = Nsbtx.decode, summarize = summarizeTexture },
  BCA0 = { kind = "nsbca", decode = NitroAnimation.decode, summarize = summarizeAnimation },
  BTA0 = { kind = "nsbta", decode = NitroAnimation.decode, summarize = summarizeAnimation },
  BTP0 = { kind = "nsbtp", decode = NitroAnimation.decode, summarize = summarizeAnimation },
  BMA0 = { kind = "nsbma", decode = NitroAnimation.decode, summarize = summarizeAnimation },
}

--------------------------------------------------------------------------
-- Member normalization/classification.
--------------------------------------------------------------------------

local function classifyMember(fileId, memberId, raw, gaps, previews)
  local rawSize, rawSha1 = #raw, Hashing.sha1hex(raw)
  local compression = Narc.detectCompression(raw) or "none"

  local member = {
    memberId = memberId,
    rawSize = rawSize,
    rawSha1 = rawSha1,
    compression = compression,
    decodedSize = nil,
    decodedSha1 = nil,
    kind = "unknown",
    status = "unknown",
    summary = nil,
    previewKey = nil,
  }

  local normalized = nil
  if compression == "lz10" then
    local decoded, err = Lz10.decode(raw)
    if decoded then
      normalized = decoded
      member.decodedSize = #decoded
      member.decodedSha1 = Hashing.sha1hex(decoded)
    else
      member.status = "decode-failed"
      gaps[#gaps + 1] = {
        kind = "decode_failed",
        fileId = fileId,
        memberId = memberId,
        format = "lz10",
        error = err and err.message,
      }
    end
  elseif compression == "lz11" then
    member.status = "compression-unsupported"
    gaps[#gaps + 1] = { kind = "unsupported_lz11", fileId = fileId, memberId = memberId }
  else
    normalized = raw
  end

  if normalized then
    local spec = DISPATCH[normalized:sub(1, 4)]
    if spec then
      member.kind = spec.kind
      local decoded, err = spec.decode(normalized)
      if decoded and spec.postDecode then
        decoded = spec.postDecode(decoded)
      end
      if decoded then
        member.status = "decoded"
        member.summary = spec.summarize(decoded)
        if spec.preview then
          local ok, preview = pcall(spec.preview, decoded)
          if ok then
            local key = "narc-" .. fileId .. "-member-" .. memberId .. "-" .. spec.kind
            previews[#previews + 1] = {
              key = key,
              fileId = fileId,
              memberId = memberId,
              kind = spec.kind,
              width = preview.width,
              height = preview.height,
              png = preview.png,
            }
            member.previewKey = key
          else
            gaps[#gaps + 1] = {
              kind = "preview_failed",
              fileId = fileId,
              memberId = memberId,
              format = spec.kind,
              previewStatus = "failed",
              error = tostring(preview),
            }
          end
        end
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

  return member
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
---@return ResourceCatalog.Evidence
function ResourceCatalog.scan(rom, romImage)
  assert(rom, "ResourceCatalog.scan requires an NdsRom")
  assert(romImage, "ResourceCatalog.scan requires a RomImage")

  local named = rom:nitroFs().byFileId
  local fileIds = {}
  for fileId in pairs(named) do
    fileIds[#fileIds + 1] = fileId
  end
  table.sort(fileIds)

  local files, narcs, previews, gaps = {}, {}, {}, {}
  local narcPaths = {}
  local complete = true
  local narcMemberCount, decodedMemberCount, unknownMemberCount, failedMemberCount = 0, 0, 0, 0

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
          local member = classifyMember(fileId, memberId, raw, gaps, previews)
          members[memberId + 1] = member
          narcMemberCount = narcMemberCount + 1
          if member.status == "decoded" then
            decodedMemberCount = decodedMemberCount + 1
          elseif member.status == "unknown" then
            unknownMemberCount = unknownMemberCount + 1
          elseif member.status == "decode-failed" then
            failedMemberCount = failedMemberCount + 1
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
        complete = false
        gaps[#gaps + 1] = { kind = "malformed_narc", fileId = fileId, path = path }
      end
    end

    files[#files + 1] = { fileId = fileId, path = path, size = size, sha1 = sha1, magic = magic, kind = kind }
  end

  local mainImage = romImage:mainArm9()
  local narcIdCandidates = findNarcIdCandidates(mainImage, narcPaths)

  return {
    schema = "g4-resource-evidence-1",
    files = files,
    narcs = narcs,
    narcIdCandidates = narcIdCandidates,
    previews = previews,
    gaps = gaps,
    coverage = {
      complete = complete,
      namedFileCount = #files,
      scannedFileCount = #files,
      narcCount = #narcs,
      narcMemberCount = narcMemberCount,
      decodedMemberCount = decodedMemberCount,
      unknownMemberCount = unknownMemberCount,
      failedMemberCount = failedMemberCount,
    },
  }
end

return ResourceCatalog
