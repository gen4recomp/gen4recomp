-- Validates a supported Nintendo DS ROM and exposes its project-facing map.
-- Generic cartridge parsing is owned by libs.nds; this wrapper owns supported
-- version identity, cache destinations, and RomSource lifetime.

local Errors = require("libs.errors.src.Errors")
local Cartridge = require("libs.nds.src.rom.Cartridge")
local GameVersion = require("romdump.src.source.GameVersion")
local OverlayCompression = require("libs.nds.src.rom.OverlayCompression")

local COMPRESSED_SIZE_BITS = 24

local NdsRom = {}
NdsRom.__index = NdsRom

function NdsRom._parse(source, versions)
  local header = Cartridge.readHeader(source)
  local romSize = source:size()

  -- Friendly early size check when the game code is recognized. Not a
  -- substitute for SHA-1, which is authoritative.
  local byCode = versions.forGameCode(header.gameCode)
  if byCode and byCode.expectedSize and byCode.expectedSize ~= romSize then
    Errors.raise(
      "NDS_SIZE_MISMATCH",
      "ROM size " .. romSize .. " does not match expected " .. byCode.expectedSize .. " for " .. header.gameCode,
      { size = romSize, expectedSize = byCode.expectedSize, gameCode = header.gameCode }
    )
  end

  local sha1 = source:sha1()
  local versionInfo = versions.forSha1(sha1)
  if not versionInfo then
    Errors.raise(
      "NDS_UNKNOWN_ROM",
      "no supported version matches SHA-1 " .. sha1 .. " (patched, modified, overdumped, or unsupported)",
      { sha1 = sha1, gameCode = header.gameCode }
    )
  end
  if versionInfo.gameCode ~= header.gameCode then
    Errors.raise(
      "NDS_GAME_CODE_MISMATCH",
      "header game code " .. header.gameCode .. " does not match " .. versionInfo.gameCode .. " for the matched version",
      { headerGameCode = header.gameCode, versionGameCode = versionInfo.gameCode, sha1 = sha1 }
    )
  end

  local cartridge = Cartridge.parse(source, header)
  return setmetatable({
    _source = source,
    _versionInfo = versionInfo,
    _cartridge = cartridge,
  }, NdsRom)
end

function NdsRom.open(source, versions)
  versions = versions or GameVersion
  local ok, result = pcall(NdsRom._parse, source, versions)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function NdsRom:size()
  return self._cartridge:size()
end

function NdsRom:header()
  return self._cartridge:header()
end

function NdsRom:nitroFs()
  return self._cartridge:nitroFs()
end

function NdsRom:arm9Overlays()
  return self._cartridge:arm9Overlays()
end

function NdsRom:arm7Overlays()
  return self._cartridge:arm7Overlays()
end

function NdsRom:fatCount()
  return self._cartridge:fatCount()
end

function NdsRom:versionInfo()
  return self._versionInfo
end

function NdsRom:read(offset, length)
  return self._cartridge:read(offset, length)
end

function NdsRom:readFatFile(fileId)
  return self._cartridge:readFatFile(fileId)
end

-- Assign exactly one cache destination to every FAT entry, in the priority
-- order FNT name > arm9 overlay > arm7 overlay > unmapped.
function NdsRom:fileMap()
  local overlayByFileId = {}
  for _, ov in ipairs(self:arm9Overlays()) do
    overlayByFileId[ov.fileId] = { kind = "overlay9", overlayId = ov.overlayId }
  end
  for _, ov in ipairs(self:arm7Overlays()) do
    overlayByFileId[ov.fileId] = { kind = "overlay7", overlayId = ov.overlayId }
  end

  local named = self:nitroFs().byFileId
  local map, seen = {}, {}
  for fileId = 0, self:fatCount() - 1 do
    local entry = self._cartridge:fatFileInfo(fileId)
    local dest = { fileId = fileId, offset = entry.startOffset, size = entry.size }
    local sourcePath = named[fileId]
    local overlay = overlayByFileId[fileId]
    if sourcePath then
      dest.kind = "nitrofs"
      dest.sourcePath = sourcePath
      dest.path = "romfs/" .. sourcePath
    elseif overlay then
      dest.kind = overlay.kind
      dest.overlayId = overlay.overlayId
      dest.path = "system/" .. overlay.kind .. "/overlay_" .. overlay.overlayId .. ".bin"
    else
      dest.kind = "unmapped"
      dest.path = "system/unmapped/file_" .. fileId .. ".bin"
    end
    assert(not seen[dest.path], "duplicate cache destination: " .. dest.path)
    seen[dest.path] = true
    map[fileId] = dest
  end
  return map
end

-- Direct source-facing overlay-table lookup, normalized to the same flag
-- convention as RomFs:overlayInfo, for callers that read overlays straight
-- from the cartridge rather than through the imported cache.
function NdsRom:overlayInfo(cpu, overlayId)
  local overlays
  if cpu == "arm9" then
    overlays = self:arm9Overlays()
  elseif cpu == "arm7" then
    overlays = self:arm7Overlays()
  else
    return nil,
      Errors.new(
        "NDS_OVERLAY_UNKNOWN_CPU",
        "unknown overlay CPU " .. tostring(cpu),
        { cpu = cpu, overlayId = overlayId }
      )
  end
  for _, entry in ipairs(overlays) do
    if entry.overlayId == overlayId then
      return {
        cpu = cpu,
        overlayId = entry.overlayId,
        fileId = entry.fileId,
        ramAddress = entry.ramAddress,
        ramSize = entry.ramSize,
        bssSize = entry.bssSize,
        staticInitStart = entry.staticInitStart,
        staticInitEnd = entry.staticInitEnd,
        flags = entry.flags,
        compressedSize = entry.flags % (2 ^ COMPRESSED_SIZE_BITS),
        isCompressed = math.floor(entry.flags / (2 ^ COMPRESSED_SIZE_BITS)) % 2 == 1,
      }
    end
  end
  return nil,
    Errors.new(
      "NDS_OVERLAY_UNKNOWN_ID",
      "no " .. cpu .. " overlay for overlayId " .. tostring(overlayId),
      { cpu = cpu, overlayId = overlayId }
    )
end

-- Direct source-facing overlay read: FAT bytes plus, when the overlay-table
-- flags mark it compressed, the existing backwards-LZ codec.
function NdsRom:readOverlay(cpu, overlayId)
  local info, err = self:overlayInfo(cpu, overlayId)
  if not info then
    return nil, err
  end
  local bytes = self:readFatFile(info.fileId)
  if info.isCompressed then
    local decoded, decodeErr = OverlayCompression.decode(bytes, info.ramSize)
    if not decoded then
      return nil, decodeErr
    end
    bytes = decoded
  end
  return bytes, info
end

function NdsRom:release()
  self._source:release()
end

return NdsRom
