-- Strict decoder for the Nitro G2D container formats used by HGSS UI
-- resources: the "RGCN/RCSN/RECN/RNAN" containers (and their uncompressed
-- RLCN-wrapped siblings) plus the RAHC (char tiles), TTLP/PLTT (palette),
-- NRCS (screen), KBEC (cell) and KNBA (animation) chunks. Container magics
-- and chunk IDs are stored byte-swapped (e.g. "RGCN" for NCGR, "RAHC" for
-- CHAR) as documented by GBATEK's "Nitro Character Tiles / BG Maps Screens /
-- OBJ Animations / OBJ Metatile Cells" pages. The runtime never consumes
-- these structures; the FieldUiCompiler turns them into generated assets.
-- Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local Rgb555 = require("libs.codec.src.Rgb555")
local FieldFontDecoder = require("romdump.src.digest.ui.FieldFontDecoder")

local G2dDecoder = {}

-- Named ownership of the protocol error codes; tests assert the constants,
-- never the raw strings.
G2dDecoder.ERROR = {
  TRUNCATED = "G2D_TRUNCATED",
  MAGIC_INVALID = "G2D_MAGIC_INVALID",
  BYTE_ORDER_INVALID = "G2D_BYTE_ORDER_INVALID",
  BLOCK_INVALID = "G2D_BLOCK_INVALID",
  CHUNK_DUPLICATE = "G2D_CHUNK_DUPLICATE",
  CHUNK_MISSING = "G2D_CHUNK_MISSING",
  CHUNK_INVALID = "G2D_CHUNK_INVALID",
}

local function toScale(raw)
  -- Fixed-point s32 20.12 -> float scale factor. Normalize exactly once.
  if raw >= 2147483648 then
    raw = raw - 4294967296
  end
  return raw / 4096
end

-- The container/chunk IDs are stored byte-swapped; the swap yields the
-- canonical name.
local function swapped(reader, offset)
  return string.reverse(reader:ascii(offset, 4))
end

local function _blocks(reader, opts)
  if reader:length() < 4 then
    Errors.raise(G2dDecoder.ERROR.TRUNCATED, "G2D resource is shorter than its magic", { size = reader:length() })
  end
  local magic = swapped(reader, 0)
  if not opts.magics[magic] then
    Errors.raise(G2dDecoder.ERROR.MAGIC_INVALID, "unknown G2D container magic", { magic = magic })
  end
  if reader:length() < 0x10 then
    Errors.raise(
      G2dDecoder.ERROR.TRUNCATED,
      "G2D resource is shorter than its 16-byte header",
      { size = reader:length() }
    )
  end
  local byteOrder = reader:u16le(4)
  if byteOrder ~= 0xFEFF then
    Errors.raise(G2dDecoder.ERROR.BYTE_ORDER_INVALID, "G2D byte order is not 0xFEFF", { byteOrder = byteOrder })
  end
  local declaredSize = reader:u32le(8)
  if declaredSize > reader:length() then
    Errors.raise(
      G2dDecoder.ERROR.TRUNCATED,
      "G2D resource declares " .. declaredSize .. " bytes but has " .. reader:length(),
      {
        declared = declaredSize,
        size = reader:length(),
      }
    )
  end
  local headerSize = reader:u16le(12)
  local blockCount = reader:u16le(14)
  if headerSize < 0x10 or headerSize + 8 * blockCount > declaredSize then
    Errors.raise(G2dDecoder.ERROR.BLOCK_INVALID, "G2D header claims an invalid block table", {
      headerSize = headerSize,
      blockCount = blockCount,
    })
  end
  local blocks = {}
  local offset = headerSize
  for _ = 1, blockCount do
    if offset + 8 > declaredSize then
      Errors.raise(
        G2dDecoder.ERROR.BLOCK_INVALID,
        "G2D block header extends past the declared size",
        { offset = offset }
      )
    end
    local name = swapped(reader, offset)
    local size = reader:u32le(offset + 4)
    if size < 8 or offset + size > declaredSize then
      Errors.raise(G2dDecoder.ERROR.BLOCK_INVALID, "G2D block " .. name .. " extends past the declared size", {
        name = name,
        size = size,
        offset = offset,
      })
    end
    if blocks[name] ~= nil then
      Errors.raise(
        G2dDecoder.ERROR.CHUNK_DUPLICATE,
        "G2D resource carries duplicate " .. name .. " chunks",
        { chunk = name, offset = offset }
      )
    end
    blocks[name] = { payload = offset + 8, size = size - 8 }
    offset = offset + size
  end
  return magic, blocks
end

local function blocks(data, opts, label)
  local reader = BinaryReader.new(data, label)
  local ok, magic, blks = pcall(_blocks, reader, opts)
  if not ok then
    error(magic, 0)
  end
  return magic, blks, reader
end

local function mustBlock(blks, name)
  local blk = blks[name]
  if not blk then
    Errors.raise(G2dDecoder.ERROR.CHUNK_MISSING, "G2D resource has no " .. name .. " chunk", { chunk = name })
  end
  return blk
end

local CONTAINER_MAGICS = {
  NCGR = true,
  NSCR = true,
  NCER = true,
  NANR = true,
  NCLR = true,
  RLCN = true,
}

-- OBJ pixel dimensions per GBATEK's OAM size table, indexed by attr0 shape
-- (bits 14-15) then attr1 size (bits 14-15). Square objects are 8/16/32/64;
-- wide and tall objects cover the intermediate sizes. The decoder exposes
-- shape/size so consumers can reject geometries they do not support.
local OBJ_DIMENSIONS = {
  { { 8, 8 }, { 16, 16 }, { 32, 32 }, { 64, 64 } },
  { { 16, 8 }, { 32, 8 }, { 32, 16 }, { 64, 32 } },
  { { 8, 16 }, { 8, 32 }, { 16, 32 }, { 32, 64 } },
}

-- Nitro animation play mode (NNSG2dAnimationPlayMode) normalized to
-- source-independent playback semantics at the format boundary.
local PLAY_MODE = {
  [1] = "forward",
  [2] = "forward_loop",
  [3] = "reverse",
  [4] = "reverse_loop",
}

local function decodeCharBlock(data, opts)
  local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-char")
  local blk = mustBlock(blks, "CHAR")
  if blk.size < 0x18 then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CHAR chunk is shorter than its header", { size = blk.size })
  end
  local depth = reader:u32le(blk.payload + 4)
  if depth ~= 3 and depth ~= 4 then
    Errors.raise(
      G2dDecoder.ERROR.CHUNK_INVALID,
      "CHAR depth " .. depth .. " is not 3 (4bpp) or 4 (8bpp)",
      { depth = depth }
    )
  end
  local tileBytes = reader:u32le(blk.payload + 0x10)
  local tileOffset = reader:u32le(blk.payload + 0x14)
  local tileSize = depth == 3 and 32 or 64
  if tileBytes == 0 or tileBytes % tileSize ~= 0 then
    Errors.raise(
      G2dDecoder.ERROR.CHUNK_INVALID,
      "CHAR tile region must be an exact positive multiple of the " .. tileSize .. "-byte tile size",
      { tileBytes = tileBytes, tileSize = tileSize }
    )
  end
  if tileOffset + tileBytes > blk.size then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CHAR tile region exceeds the chunk", {
      tileBytes = tileBytes,
      tileOffset = tileOffset,
      chunkSize = blk.size,
    })
  end
  return {
    depth = depth,
    tiles = reader:bytes(blk.payload + tileOffset, tileBytes),
  }
end

local function decodeScreenBlock(data, opts)
  local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-screen")
  local blk = mustBlock(blks, "SCRN")
  if blk.size < 12 then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "SCRN chunk is shorter than its header", { size = blk.size })
  end
  local width = reader:u16le(blk.payload)
  local height = reader:u16le(blk.payload + 2)
  local dataSize = reader:u32le(blk.payload + 8)
  if width == 0 or height == 0 or width % 8 ~= 0 or height % 8 ~= 0 then
    Errors.raise(
      G2dDecoder.ERROR.CHUNK_INVALID,
      "SCRN dimensions must be multiples of 8 pixels",
      { width = width, height = height }
    )
  end
  -- The entry bytes must match the tile geometry exactly: metadata describing
  -- one geometry while supplying another amount of map data is malformed.
  local expectedBytes = width / 8 * (height / 8) * 2
  if dataSize ~= expectedBytes then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "SCRN data size does not match the screen dimensions", {
      width = width,
      height = height,
      dataSize = dataSize,
      expectedBytes = expectedBytes,
    })
  end
  if 12 + dataSize > blk.size then
    Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "SCRN entry data exceeds the chunk", {
      dataSize = dataSize,
      chunkSize = blk.size,
    })
  end
  local entries = {}
  local count = math.floor(dataSize / 2)
  for i = 0, count - 1 do
    local e = reader:u16le(blk.payload + 12 + i * 2)
    entries[i + 1] = {
      tile = e % 1024,
      flipH = math.floor(e / 1024) % 2 == 1,
      flipV = math.floor(e / 2048) % 2 == 1,
      palette = math.floor(e / 4096),
    }
  end
  return { width = width, height = height, entries = entries }
end

---@param data string
---@param opts? { label?: string }
---@return { depth: integer, tiles: string }?
---@return Errors.Error?
function G2dDecoder.decodeChar(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeChar requires a string")
  opts = opts or {}
  local ok, result = pcall(decodeCharBlock, data, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param data string
---@param opts? { label?: string }
---@return { width: integer, height: integer, entries: table[] }?
---@return Errors.Error?
function G2dDecoder.decodeScreen(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeScreen requires a string")
  opts = opts or {}
  local ok, result = pcall(decodeScreenBlock, data, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param data string
---@param opts? { label?: string }
---@return { colors: { r: integer, g: integer, b: integer }[] }?
---@return Errors.Error?
function G2dDecoder.decodePalette(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodePalette requires a string")
  opts = opts or {}
  if data:sub(1, 4) == "RLCN" then
    -- RLCN-wrapped TTLP palette data (NNS_G2dGetUnpackedPaletteData).
    local pal, err = FieldFontDecoder.decodePalette(data, { label = opts.label })
    if not pal then
      return nil, err
    end
    return { colors = pal.colors }
  end
  local function decodePaletteBlock()
    local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-palette")
    local blk = mustBlock(blks, "PLTT")
    if blk.size < 12 then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "PLTT chunk is shorter than its header", { size = blk.size })
    end
    local depth = string.byte(reader:bytes(blk.payload, 1))
    local colorCount = reader:u16le(blk.payload + 2)
    local dataOffset = reader:u32le(blk.payload + 8)
    if depth ~= 3 and depth ~= 4 then
      Errors.raise(
        G2dDecoder.ERROR.CHUNK_INVALID,
        "PLTT depth " .. depth .. " is not 3 (4bpp) or 4 (8bpp)",
        { depth = depth }
      )
    end
    if colorCount == 0 or dataOffset + colorCount * 2 > blk.size then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "PLTT color data exceeds the chunk", {
        colorCount = colorCount,
        dataOffset = dataOffset,
        chunkSize = blk.size,
      })
    end
    local colors = {}
    for i = 0, colorCount - 1 do
      local word = reader:u16le(blk.payload + dataOffset + i * 2)
      colors[i + 1] = Rgb555.decode(word)
    end
    return { colors = colors }
  end
  local ok, result = pcall(decodePaletteBlock)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param data string
---@param opts? { label?: string }
---@return { cells: { objs: { x: integer, y: integer, tile: integer, flipH: boolean, flipV: boolean, palette: integer, shape: integer, size: integer, width: integer, height: integer }[] }[] }?
---@return Errors.Error?
function G2dDecoder.decodeCell(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeCell requires a string")
  opts = opts or {}
  local function decodeCellBlock()
    local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-cell")
    local blk = mustBlock(blks, "CEBK")
    if blk.size < 0x20 then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CELL chunk is shorter than its header", { size = blk.size })
    end
    local cellCount = reader:u16le(blk.payload)
    local entrySize = reader:u16le(blk.payload + 2)
    local tableOffset = reader:u32le(blk.payload + 4)
    if entrySize ~= 0 and entrySize ~= 1 then
      Errors.raise(
        G2dDecoder.ERROR.CHUNK_INVALID,
        "CELL entry size " .. entrySize .. " is not 0 (8 bytes) or 1 (16 bytes)",
        { entrySize = entrySize }
      )
    end
    local stride = entrySize == 0 and 8 or 16
    if cellCount == 0 or tableOffset + cellCount * stride > blk.size then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CELL metatile table exceeds the chunk", {
        cellCount = cellCount,
        tableOffset = tableOffset,
        chunkSize = blk.size,
      })
    end
    local cells = {}
    local attrTable = blk.payload + tableOffset + cellCount * stride
    for c = 0, cellCount - 1 do
      local base = blk.payload + tableOffset + c * stride
      local numObjs = reader:u16le(base)
      local objOffset = reader:u32le(base + 4)
      if attrTable - blk.payload + objOffset + numObjs * 6 > blk.size then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "CELL OBJ table exceeds the chunk", {
          numObjs = numObjs,
          objOffset = objOffset,
          chunkSize = blk.size,
        })
      end
      local objs = {}
      for o = 0, numObjs - 1 do
        local obase = attrTable + objOffset + o * 6
        -- OAM-ordered attributes (GBATEK "OAM (Object Attribute Mapping)"):
        -- attr0 carries y and the shape bits (14-15), attr1 carries x, the
        -- flips (12-13) and the size bits (14-15), attr2 carries the tile
        -- index and the palette bank (12-15).
        local attr0 = reader:u16le(obase)
        local attr1 = reader:u16le(obase + 2)
        local attr2 = reader:u16le(obase + 4)
        local x = attr1 % 512
        if x >= 256 then
          x = x - 512
        end
        local y = attr0 % 256
        if y >= 128 then
          y = y - 256
        end
        local shape = math.floor(attr0 / 16384)
        if shape == 3 then
          Errors.raise(
            G2dDecoder.ERROR.CHUNK_INVALID,
            "CELL OBJ carries the reserved OAM shape bits",
            { attr0 = attr0 }
          )
        end
        local size = math.floor(attr1 / 16384)
        local dims = OBJ_DIMENSIONS[shape + 1][size + 1]
        objs[o + 1] = {
          x = x,
          y = y,
          tile = attr2 % 1024,
          flipH = math.floor(attr1 / 4096) % 2 == 1,
          flipV = math.floor(attr1 / 8192) % 2 == 1,
          palette = math.floor(attr2 / 4096),
          shape = shape,
          size = size,
          width = dims[1],
          height = dims[2],
        }
      end
      cells[c + 1] = { objs = objs }
    end
    return { cells = cells }
  end
  local ok, result = pcall(decodeCellBlock)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param data string
---@param opts? { label?: string }
---@return { anims: { frames: { cell: integer, duration: integer, element: string, translateX: integer, translateY: integer, scaleX: number, scaleY: number, rotation: number }[], playMode: string, loopStartFrameIdx: integer }[] }?
---@return Errors.Error?
function G2dDecoder.decodeAnimation(data, opts)
  assert(type(data) == "string", "G2dDecoder.decodeAnimation requires a string")
  opts = opts or {}
  local function decodeAnimationBlock()
    local _, blks, reader = blocks(data, { magics = CONTAINER_MAGICS }, opts.label or "g2d-animation")
    local blk = mustBlock(blks, "ABNK")
    if blk.size < 0x18 then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM chunk is shorter than its header", { size = blk.size })
    end
    local animCount = reader:u16le(blk.payload)
    local frameCount = reader:u16le(blk.payload + 2)
    local animsOffset = reader:u32le(blk.payload + 4)
    local framesOffset = reader:u32le(blk.payload + 8)
    local dataOffset = reader:u32le(blk.payload + 12)
    if animCount == 0 or animsOffset + animCount * 16 > blk.size then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM animation table exceeds the chunk", {
        animCount = animCount,
        animsOffset = animsOffset,
        chunkSize = blk.size,
      })
    end
    if framesOffset + frameCount * 8 > blk.size then
      Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame table exceeds the chunk", {
        frameCount = frameCount,
        framesOffset = framesOffset,
        chunkSize = blk.size,
      })
    end
    local anims = {}
    for a = 0, animCount - 1 do
      local abase = blk.payload + animsOffset + a * 16
      -- NNSG2dAnimSequenceData layout (g2d_Anim_data.h): u16 numFrames,
      -- u16 loopStartFrameIdx, u32 animType, u32 playMode, then the
      -- first-frame pointer.
      local numFrames = reader:u16le(abase)
      local loopStartFrameIdx = reader:u16le(abase + 2)
      local animType = reader:u32le(abase + 4)
      local animationType = animType % 65536
      local cellType = math.floor(animType / 65536) % 65536
      local playModeRaw = reader:u32le(abase + 8)
      local firstFrame = reader:u32le(abase + 12)
      local playMode = PLAY_MODE[playModeRaw]
      if playMode == nil then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM playMode is unsupported", {
          playMode = playModeRaw,
          animation = a,
        })
      end
      if loopStartFrameIdx >= numFrames then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM loop start is outside the animation", {
          loopStartFrameIdx = loopStartFrameIdx,
          numFrames = numFrames,
          animation = a,
        })
      end
      -- Animation element type is authoritative NANR metadata. The decoder must
      -- not infer transform size from frame-data length; it must use this type
      -- to decide how many bytes to read for each frame property.
      if animationType ~= 0 and animationType ~= 1 and animationType ~= 2 then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM animationType is unsupported", {
          animationType = animationType,
          animation = a,
        })
      end
      if cellType ~= 1 and cellType ~= 2 then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM cellType is unsupported", {
          cellType = cellType,
          animation = a,
        })
      end
      -- The HGSS exporter stores this field as a byte offset into the frame
      -- table. Normalize it once at the source-format boundary; treating the
      -- same value as either bytes or an index would make valid resources
      -- decode differently based on the total frame count.
      if firstFrame % 8 ~= 0 then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM first frame offset is not frame-aligned", {
          firstFrame = firstFrame,
          frameCount = frameCount,
        })
      end
      local firstFrameIndex = firstFrame / 8
      -- firstFrame is now a frame index and numFrames a frame count: the
      -- range must fit the frame table total, then its actual byte span must
      -- fit the chunk. Never mix frame indexes with chunk-byte sizes.
      if firstFrameIndex + numFrames > frameCount then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM animation frame range exceeds the frame table", {
          numFrames = numFrames,
          firstFrame = firstFrameIndex,
          frameCount = frameCount,
        })
      end
      if framesOffset + (firstFrameIndex + numFrames) * 8 > blk.size then
        Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM animation frame range exceeds the chunk", {
          numFrames = numFrames,
          firstFrame = firstFrameIndex,
          chunkSize = blk.size,
        })
      end
      local frames = {}
      for f = 0, numFrames - 1 do
        local fbase = blk.payload + framesOffset + (firstFrameIndex + f) * 8
        local frameData = reader:u32le(fbase)
        local duration = reader:u16le(fbase + 4)
        if duration <= 0 then
          Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame duration must be positive", {
            duration = duration,
            animation = a,
            frame = f,
          })
        end
        local propBase = blk.payload + dataOffset + frameData
        -- Validate property bounds according to the animation's element type.
        -- The property size is fixed per type: 2 for type 0 (plus dword padding),
        -- 8 for type 2 (translate), 16 for type 1 (SRT). The check must be
        -- type-aware rather than inferring from remaining bytes.
        local element, translateX, translateY, scaleX, scaleY, rotation
        if animationType == 0 then
          if dataOffset + frameData + 2 > blk.size then
            Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame data exceeds the chunk", {
              frameData = frameData,
              dataOffset = dataOffset,
              chunkSize = blk.size,
            })
          end
          local cell = reader:u16le(propBase)
          element = "none"
          translateX, translateY = 0, 0
          scaleX, scaleY = 1, 1
          rotation = 0
          frames[f + 1] = {
            cell = cell,
            duration = duration,
            element = element,
            translateX = translateX,
            translateY = translateY,
            scaleX = scaleX,
            scaleY = scaleY,
            rotation = rotation,
          }
        elseif animationType == 2 then
          if dataOffset + frameData + 8 > blk.size then
            Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame data exceeds the chunk", {
              frameData = frameData,
              dataOffset = dataOffset,
              chunkSize = blk.size,
            })
          end
          local cell = reader:u16le(propBase)
          local tx = reader:u16le(propBase + 4)
          local ty = reader:u16le(propBase + 6)
          if tx >= 32768 then
            tx = tx - 65536
          end
          if ty >= 32768 then
            ty = ty - 65536
          end
          element = "translate"
          translateX, translateY = tx, ty
          scaleX, scaleY = 1, 1
          rotation = 0
          frames[f + 1] = {
            cell = cell,
            duration = duration,
            element = element,
            translateX = translateX,
            translateY = translateY,
            scaleX = scaleX,
            scaleY = scaleY,
            rotation = rotation,
          }
        else -- animationType == 1 : SRT (scale, rotate, translate)
          if dataOffset + frameData + 16 > blk.size then
            Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM frame data exceeds the chunk", {
              frameData = frameData,
              dataOffset = dataOffset,
              chunkSize = blk.size,
            })
          end
          local cell = reader:u16le(propBase)
          local rotRaw = reader:u16le(propBase + 2)
          local scaleWRaw = reader:u32le(propBase + 4)
          local scaleHRaw = reader:u32le(propBase + 8)
          local tx = reader:u16le(propBase + 12)
          local ty = reader:u16le(propBase + 14)
          if tx >= 32768 then
            tx = tx - 65536
          end
          if ty >= 32768 then
            ty = ty - 65536
          end
          element = "affine"
          translateX, translateY = tx, ty
          scaleX = toScale(scaleWRaw)
          scaleY = toScale(scaleHRaw)
          -- Rotation unit: degrees (0..360) derived from uint16 full turn.
          rotation = rotRaw * 360 / 65536
          if scaleX ~= scaleX or scaleY ~= scaleY or rotation ~= rotation then
            Errors.raise(G2dDecoder.ERROR.CHUNK_INVALID, "ANIM transform contains non-finite value", {
              scaleX = scaleX,
              scaleY = scaleY,
              rotation = rotation,
            })
          end
          frames[f + 1] = {
            cell = cell,
            duration = duration,
            element = element,
            translateX = translateX,
            translateY = translateY,
            scaleX = scaleX,
            scaleY = scaleY,
            rotation = rotation,
          }
        end
      end
      anims[a + 1] = {
        frames = frames,
        animationType = animationType,
        cellType = cellType,
        playMode = playMode,
        loopStartFrameIdx = loopStartFrameIdx,
      }
    end
    return { anims = anims }
  end
  local ok, result = pcall(decodeAnimationBlock)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return G2dDecoder
