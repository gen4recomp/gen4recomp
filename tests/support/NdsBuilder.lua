-- Test helper: assemble a minimal but valid NDS ROM image in memory.
-- Layout after the 0x200 header: arm9, arm7, arm9 overlay table, arm7 overlay
-- table, FNT, FAT, then file payloads in fileId order. Overlay and unmapped
-- files take the lowest FAT ids; named NitroFS files follow.
--
-- spec = {
--   gameCode=, title=, makerCode=, unitCode=, romVersion=,
--   overlays9 = { "content", ... },   -- arm9 overlays, fileIds 0..
--     entries may also be tables: { content=, ramAddress=, ramSize=,
--     bssSize=, staticInitStart=, staticInitEnd=, flags= }
--   unmapped  = { "content", ... },   -- unreferenced FAT entries, next ids
--   tree = { files = { {name=, content=} }, dirs = { ... } },  -- named files
--   corrupt = { fatNotDiv8=, sectionOutOfRange= },
-- }
-- Returns (dataString, meta) where meta = { fileCount=, gameCode=, romSize= }.

local FntWriter = require("tests.support.FntWriter")

local NdsBuilder = {}

local u32 = FntWriter.u32
local HEADER_SIZE = 0x200

local function collectContents(node, prefix, out)
  for _, f in ipairs(node.files or {}) do
    out[prefix .. f.name] = f.content
  end
  for _, d in ipairs(node.dirs or {}) do
    collectContents(d, prefix .. d.name .. "/", out)
  end
end

local function overlayContent(entry)
  return type(entry) == "table" and entry.content or entry
end

local function overlayEntry(overlayId, fileId, entry)
  local meta = type(entry) == "table" and entry or {}
  return u32(overlayId)
    .. u32(meta.ramAddress or 0)
    .. u32(meta.ramSize or 0)
    .. u32(meta.bssSize or 0)
    .. u32(meta.staticInitStart or 0)
    .. u32(meta.staticInitEnd or 0)
    .. u32(fileId)
    .. u32(meta.flags or 0)
end

function NdsBuilder.build(spec)
  spec = spec or {}
  local overlays9 = spec.overlays9 or {}
  local unmapped = spec.unmapped or {}
  local tree = spec.tree or { files = {}, dirs = {} }
  local corrupt = spec.corrupt or {}

  local reserved = #overlays9 + #unmapped
  local fntBytes, byFileId = FntWriter.encode(tree, reserved)

  -- Payloads keyed by zero-based fileId.
  local pathContent = {}
  collectContents(tree, "", pathContent)
  local payloads = {}
  for i = 1, #overlays9 do
    payloads[i - 1] = overlayContent(overlays9[i])
  end
  for i = 1, #unmapped do
    payloads[#overlays9 + i - 1] = unmapped[i]
  end
  local namedCount = 0
  for id, path in pairs(byFileId) do
    assert(pathContent[path], "no content for named file " .. path)
    payloads[id] = pathContent[path]
    namedCount = namedCount + 1
  end
  local total = reserved + namedCount

  -- Overlay tables.
  local ov9Parts = {}
  for i = 1, #overlays9 do
    ov9Parts[i] = overlayEntry(i - 1, i - 1, overlays9[i])
  end
  local ov9Bytes = table.concat(ov9Parts)
  local ov7Bytes = ""

  local arm9 = spec.arm9 or "ARM9STUB"
  local arm7 = spec.arm7 or "ARM7STUB"

  -- Section offsets.
  local cursor = HEADER_SIZE
  local arm9Off = cursor
  cursor = cursor + #arm9
  local arm7Off = cursor
  cursor = cursor + #arm7
  local ov9Off = cursor
  cursor = cursor + #ov9Bytes
  local ov7Off = cursor
  cursor = cursor + #ov7Bytes
  local fntOff = cursor
  cursor = cursor + #fntBytes
  local fatOff = cursor
  local fatSize = 8 * total
  cursor = cursor + fatSize

  -- Payload offsets and FAT bytes.
  local starts = {}
  for id = 0, total - 1 do
    starts[id] = cursor
    cursor = cursor + #payloads[id]
  end
  local romSize = cursor
  local fatParts = {}
  for id = 0, total - 1 do
    fatParts[id + 1] = u32(starts[id]) .. u32(starts[id] + #payloads[id])
  end
  local fatBytes = table.concat(fatParts)

  -- Header.
  local h = {}
  for i = 1, HEADER_SIZE do
    h[i] = "\0"
  end
  local function put(off, s)
    for i = 1, #s do
      h[off + i] = s:sub(i, i)
    end
  end
  put(0x00, spec.title or "TESTROM")
  put(0x0C, spec.gameCode or "IPKE")
  put(0x10, spec.makerCode or "01")
  put(0x12, string.char(spec.unitCode or 0))
  put(0x1E, string.char(spec.romVersion or 0))
  put(0x20, u32(arm9Off) .. u32(spec.arm9Entry or 0) .. u32(spec.arm9Ram or 0) .. u32(#arm9))
  put(0x30, u32(arm7Off) .. u32(0) .. u32(0) .. u32(#arm7))
  put(0x40, u32(fntOff) .. u32(#fntBytes))
  put(0x48, u32(fatOff) .. u32(fatSize))
  put(0x50, u32(ov9Off) .. u32(#ov9Bytes))
  put(0x58, u32(ov7Off) .. u32(#ov7Bytes))
  put(0x68, u32(0))
  put(0x80, u32(romSize))
  put(0x84, u32(0x4000))

  if corrupt.fatNotDiv8 then
    put(0x4C, u32(fatSize + 4))
  end
  if corrupt.sectionOutOfRange then
    put(0x44, u32(romSize + 0x1000))
  end

  local payloadParts = {}
  for id = 0, total - 1 do
    payloadParts[id + 1] = payloads[id]
  end

  local data = table.concat(h)
    .. arm9
    .. arm7
    .. ov9Bytes
    .. ov7Bytes
    .. fntBytes
    .. fatBytes
    .. table.concat(payloadParts)

  return data, { fileCount = total, gameCode = spec.gameCode or "IPKE", romSize = romSize }
end

return NdsBuilder
