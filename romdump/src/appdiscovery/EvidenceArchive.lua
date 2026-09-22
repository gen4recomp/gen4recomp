-- Deterministic standard ZIP32/store encoder for evidence bundles: sorted
-- paths, no compression, no Zip64, fixed DOS 1980-01-01 00:00:00 timestamps,
-- and one local-file-header/central-directory/EOCD record set per member.
-- Knows nothing about ROM/evidence semantics; it only turns a path->bytes
-- map into standard-readable ZIP bytes.

local bit = require("bit")
local Errors = require("libs.errors.src.Errors")

local EvidenceArchive = {}

local MAX_ENTRIES = 65535
local MAX_U32 = 0xFFFFFFFF
local DOS_TIME = 0x0000
local DOS_DATE = 0x0021 -- 1980-01-01
local VERSION = 20
local LOCAL_FILE_HEADER_SIG = 0x04034b50
local CENTRAL_DIR_SIG = 0x02014b50
local EOCD_SIG = 0x06054b50

-- LÖVE's PhysFS ZIP archiver looks for a Zip64 end-of-central-directory
-- locator 20 bytes before the EOCD record before falling back to the
-- standard EOCD; when the EOCD sits at a file offset below 20 (only
-- possible with zero members, since any real entry's local header alone is
-- at least 31 bytes) that lookup seeks to a negative offset and the mount
-- fails outright instead of falling back. A ZIP archive may carry
-- arbitrary prepended data before its real content (as self-extracting
-- archives do); padding with zero bytes keeps the archive standard-valid
-- while satisfying that minimum offset.
local MIN_EOCD_OFFSET = 20

local CRC_TABLE = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
    else
      c = bit.rshift(c, 1)
    end
  end
  CRC_TABLE[n] = c
end

local function crc32(data)
  local crc = bit.bnot(0)
  for i = 1, #data do
    local index = bit.band(bit.bxor(crc, string.byte(data, i)), 0xFF)
    crc = bit.bxor(bit.rshift(crc, 8), CRC_TABLE[index])
  end
  return bit.bnot(crc)
end

local function u16le(value)
  return string.char(bit.band(value, 0xFF), bit.band(bit.rshift(value, 8), 0xFF))
end

local function u32le(value)
  return string.char(
    bit.band(value, 0xFF),
    bit.band(bit.rshift(value, 8), 0xFF),
    bit.band(bit.rshift(value, 16), 0xFF),
    bit.band(bit.rshift(value, 24), 0xFF)
  )
end

local function isAsciiPrintable(path)
  for i = 1, #path do
    local b = string.byte(path, i)
    if b < 0x20 or b > 0x7E then
      return false
    end
  end
  return true
end

local function invalidPath(path)
  Errors.raise("APPDISCOVERY_ARCHIVE_PATH_INVALID", "unsafe archive member path: " .. tostring(path), { path = path })
end

local function validatePath(path)
  if type(path) ~= "string" or path == "" then
    invalidPath(path)
  end
  if path:sub(1, 1) == "/" then
    invalidPath(path)
  end
  if path:find("\\", 1, true) then
    invalidPath(path)
  end
  if not isAsciiPrintable(path) then
    invalidPath(path)
  end
  for component in (path .. "/"):gmatch("([^/]*)/") do
    if component == "" or component == "." or component == ".." then
      invalidPath(path)
    end
  end
end

local function checkU32Limit(value, path)
  if value > MAX_U32 then
    Errors.raise(
      "APPDISCOVERY_ARCHIVE_LIMIT_EXCEEDED",
      "archive field exceeds the ZIP32 32-bit limit for " .. tostring(path),
      { path = path, value = value }
    )
  end
end

---@param files table<string, string>
---@return string?, Errors.Error?
function EvidenceArchive.encode(files)
  assert(type(files) == "table", "EvidenceArchive.encode requires a path->bytes table")

  local entries = {}
  for path, content in pairs(files) do
    validatePath(path)
    if type(content) ~= "string" then
      Errors.raise(
        "APPDISCOVERY_ARCHIVE_CONTENT_INVALID",
        "archive member content must be a string: " .. tostring(path),
        { path = path }
      )
    end
    entries[#entries + 1] = { path = path, content = content }
  end

  if #entries > MAX_ENTRIES then
    Errors.raise(
      "APPDISCOVERY_ARCHIVE_LIMIT_EXCEEDED",
      "archive has " .. #entries .. " entries, exceeding the ZIP32 limit of " .. MAX_ENTRIES,
      { entryCount = #entries }
    )
  end

  table.sort(entries, function(a, b)
    return a.path < b.path
  end)

  local localParts = {}
  local centralParts = {}
  local offset = 0

  for _, entry in ipairs(entries) do
    local content, path = entry.content, entry.path
    local size = #content
    checkU32Limit(size, path)
    checkU32Limit(offset, path)
    local crc = crc32(content)
    local nameLength = #path

    local localHeader = table.concat({
      u32le(LOCAL_FILE_HEADER_SIG),
      u16le(VERSION),
      u16le(0),
      u16le(0),
      u16le(DOS_TIME),
      u16le(DOS_DATE),
      u32le(crc),
      u32le(size),
      u32le(size),
      u16le(nameLength),
      u16le(0),
      path,
    })
    localParts[#localParts + 1] = localHeader
    localParts[#localParts + 1] = content

    centralParts[#centralParts + 1] = table.concat({
      u32le(CENTRAL_DIR_SIG),
      u16le(VERSION),
      u16le(VERSION),
      u16le(0),
      u16le(0),
      u16le(DOS_TIME),
      u16le(DOS_DATE),
      u32le(crc),
      u32le(size),
      u32le(size),
      u16le(nameLength),
      u16le(0),
      u16le(0),
      u16le(0),
      u16le(0),
      u32le(0),
      u32le(offset),
      path,
    })

    offset = offset + #localHeader + size
  end

  local centralDirectory = table.concat(centralParts)
  checkU32Limit(#centralDirectory, "<central directory>")
  checkU32Limit(offset, "<central directory offset>")

  local eocd = table.concat({
    u32le(EOCD_SIG),
    u16le(0),
    u16le(0),
    u16le(#entries),
    u16le(#entries),
    u32le(#centralDirectory),
    u32le(offset),
    u16le(0),
  })

  local prefixPadding = ""
  local eocdFileOffset = offset + #centralDirectory
  if eocdFileOffset < MIN_EOCD_OFFSET then
    prefixPadding = string.rep("\0", MIN_EOCD_OFFSET - eocdFileOffset)
  end

  return prefixPadding .. table.concat(localParts) .. centralDirectory .. eocd
end

return EvidenceArchive
