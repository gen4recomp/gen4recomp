-- Normalizes main ARM9 and ARM9/ARM7 overlay bytes read directly from an
-- NdsRom into immutable RAM-addressed executable images. Backwards-LZ
-- normalization of the main ARM9 image is a bounded heuristic: the decoded
-- candidate is accepted only when decoding succeeds and strictly grows the
-- byte length, since the NDS header carries no compression flag for it.

local Errors = require("libs.errors.src.Errors")
local OverlayCompression = require("libs.nds.src.rom.OverlayCompression")
local Hashing = require("romdump.src.digest.Hashing")

---@class RomImage.Record
---@field kind "arm9-main"|"arm9-overlay"|"arm7-overlay"
---@field id string
---@field ramAddress integer
---@field bytes string
---@field rawSize integer
---@field decodedSize integer
---@field normalization "raw"|"backwards-lz"
---@field rawSha1 string
---@field decodedSha1 string
---@field source { offset: integer, entryAddress: integer }|{ fileId: integer, ramAddress: integer, ramSize: integer, bssSize: integer, isCompressed: boolean }

---@class RomImage.Source
---@field header fun(self: RomImage.Source): { arm9: { offset: integer, size: integer, ramAddress: integer, entryAddress: integer } }
---@field read fun(self: RomImage.Source, offset: integer, size: integer): string
---@field arm9Overlays fun(self: RomImage.Source): table[]
---@field readOverlay fun(self: RomImage.Source, cpu: string, overlayId: integer): string?, ({ fileId: integer, ramAddress: integer, isCompressed: boolean }|Errors.Error)?
---@field readFatFile fun(self: RomImage.Source, fileId: integer): string

---@class RomImage
---@field private _rom RomImage.Source
---@field private _images table<string, RomImage.Record>
local RomImage = {}
RomImage.__index = RomImage

local MAX_ADDRESS = 2 ^ 32

local function validateRange(ramAddress, size, id)
  if
    type(ramAddress) ~= "number"
    or type(size) ~= "number"
    or size <= 0
    or ramAddress < 0
    or ramAddress + size > MAX_ADDRESS
  then
    Errors.raise(
      "APPDISCOVERY_IMAGE_RANGE_INVALID",
      "invalid image address range for " .. tostring(id),
      { id = id, ramAddress = ramAddress, size = size }
    )
  end
end

---@param rom RomImage.Source
---@return RomImage
function RomImage.new(rom)
  assert(rom, "RomImage.new requires an NdsRom")
  return setmetatable({ _rom = rom, _images = {} }, RomImage)
end

---@return RomImage.Record
function RomImage:mainArm9()
  local existing = self._images["arm9-main"]
  if existing then
    return existing
  end

  local header = self._rom:header()
  local arm9 = header.arm9
  local raw = self._rom:read(arm9.offset, arm9.size)

  local bytes, normalization = raw, "raw"
  local decoded = OverlayCompression.decode(raw)
  if decoded and #decoded > #raw then
    bytes = decoded
    normalization = "backwards-lz"
  end

  validateRange(arm9.ramAddress, #bytes, "arm9-main")

  local record = {
    kind = "arm9-main",
    id = "arm9-main",
    ramAddress = arm9.ramAddress,
    bytes = bytes,
    rawSize = #raw,
    decodedSize = #bytes,
    normalization = normalization,
    rawSha1 = Hashing.sha1hex(raw),
    decodedSha1 = Hashing.sha1hex(bytes),
    source = { offset = arm9.offset, entryAddress = arm9.entryAddress },
  }
  self._images["arm9-main"] = record
  return record
end

---@param cpu "arm9"|"arm7"
---@param overlayId integer
---@return RomImage.Record
function RomImage:overlay(cpu, overlayId)
  local id = cpu .. "-overlay:" .. tostring(overlayId)
  local existing = self._images[id]
  if existing then
    return existing
  end

  local decodedBytes, info = self._rom:readOverlay(cpu, overlayId)
  if not decodedBytes then
    error(info)
  end
  ---@cast info { fileId: integer, ramAddress: integer, isCompressed: boolean }
  local rawBytes = self._rom:readFatFile(info.fileId)
  local normalization = info.isCompressed and "backwards-lz" or "raw"

  validateRange(info.ramAddress, #decodedBytes, id)

  local record = {
    kind = cpu .. "-overlay",
    id = id,
    ramAddress = info.ramAddress,
    bytes = decodedBytes,
    rawSize = #rawBytes,
    decodedSize = #decodedBytes,
    normalization = normalization,
    rawSha1 = Hashing.sha1hex(rawBytes),
    decodedSha1 = Hashing.sha1hex(decodedBytes),
    source = info,
  }
  self._images[id] = record
  return record
end

---@return RomImage.Record[]
function RomImage:arm9Overlays()
  local overlayIds = {}
  for _, overlay in ipairs(self._rom:arm9Overlays()) do
    overlayIds[#overlayIds + 1] = overlay.overlayId
  end
  table.sort(overlayIds)

  local records = {}
  for _, overlayId in ipairs(overlayIds) do
    records[#records + 1] = self:overlay("arm9", overlayId)
  end
  return records
end

return RomImage
