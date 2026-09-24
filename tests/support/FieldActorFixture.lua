-- Synthetic byte builders for the HGSS field-actor formats. Every byte here is
-- authored for tests: no ROM-derived table, texture, or timeline is committed.
-- The overlay builder lays the four tables out at caller-chosen runtime
-- addresses inside one padded image, so a locator manifest of the real shape can
-- be exercised without a ROM.

local FieldActorFixture = {}

---@param v number
---@return string
local function u8(v)
  return string.char(math.floor(v) % 256)
end

---@param v number
---@return string
local function u16(v)
  v = v % 65536
  return string.char(math.floor(v) % 256, math.floor(v / 256))
end

---@param v number
---@return string
local function u32(v)
  return u16(v % 65536) .. u16(math.floor(v / 65536))
end

FieldActorFixture.u8 = u8
FieldActorFixture.u16 = u16
FieldActorFixture.u32 = u32

-- records: array of { spriteId, mapModelId, packed }.
function FieldActorFixture.graphicsTable(records, opts)
  opts = opts or {}
  local out = {}
  for _, r in ipairs(records) do
    out[#out + 1] = u16(r.spriteId) .. u16(r.mapModelId) .. u16(r.packed)
  end
  if not opts.omitTerminator then
    out[#out + 1] = u16(0xFFFF) .. u16(0) .. u16(opts.terminatorPacked or 0xFC00)
  end
  return table.concat(out)
end

-- pairs: array of { key, memberId }. Terminated by key 255, as in the ROM.
function FieldActorFixture.keyTable(pairsList)
  local out = {}
  for _, p in ipairs(pairsList) do
    out[#out + 1] = u16(p.key) .. u16(p.memberId)
  end
  out[#out + 1] = u16(255) .. u16(0)
  return table.concat(out)
end

-- ranges: array of { startFrame, endFrame, endMode }. Terminated by a zero
-- start/end record, matching the original tables.
function FieldActorFixture.rangeTable(ranges)
  local out = {}
  for _, r in ipairs(ranges) do
    out[#out + 1] = u32(r.startFrame) .. u32(r.endFrame) .. u32(r.endMode or 0)
  end
  out[#out + 1] = u32(0) .. u32(0) .. u32(2)
  return table.concat(out)
end

-- descriptors: array of { modelKey, timelineKey, rangesAddress }.
function FieldActorFixture.descriptorTable(descriptors)
  local out = {}
  for _, d in ipairs(descriptors) do
    out[#out + 1] = u8(0) .. u8(0) .. u8(d.modelKey) .. u8(d.timelineKey) .. u32(d.rangesAddress)
  end
  return table.concat(out)
end

-- entries: array of { threshold, textureSlot, paletteSlot }.
function FieldActorFixture.timeline(entries, opts)
  opts = opts or {}
  local thresholds, textures, palettes = {}, {}, {}
  for _, e in ipairs(entries) do
    thresholds[#thresholds + 1] = u16(e.threshold)
    textures[#textures + 1] = u8(e.textureSlot)
    palettes[#palettes + 1] = u8(e.paletteSlot or 0)
  end
  local count = opts.declaredCount or #entries
  return u32(count)
    .. table.concat(thresholds)
    .. table.concat(textures)
    .. table.concat(palettes)
    .. (opts.trailer or "")
end

-- Place named byte blocks at explicit runtime addresses inside one overlay
-- image. blocks: array of { address, bytes }. The image ends exactly at the last
-- block, so an unterminated table runs off the end instead of walking padding.
function FieldActorFixture.overlay(ramAddress, blocks, opts)
  opts = opts or {}
  local highest = 0
  for _, b in ipairs(blocks) do
    highest = math.max(highest, b.address - ramAddress + #b.bytes)
  end
  local size = opts.size or highest
  local image = {}
  for i = 1, size do
    image[i] = "\0"
  end
  for _, b in ipairs(blocks) do
    local offset = b.address - ramAddress
    for i = 1, #b.bytes do
      image[offset + i] = b.bytes:sub(i, i)
    end
  end
  return table.concat(image)
end

-- A complete, minimal overlay carrying one humanoid-shaped descriptor plus the
-- two key tables, laid out the way the real overlay is. Callers override pieces
-- through opts to build failure cases.
function FieldActorFixture.sampleOverlay(opts)
  opts = opts or {}
  local RAM = 0x02000000
  local A = {
    ranges = 0x02000100,
    descriptors = 0x02000200,
    modelKeys = 0x02000280,
    timelineKeys = 0x020002C0,
    graphics = 0x02000300,
  }
  local records = opts.records
    or {
      { spriteId = 0, mapModelId = 69, packed = 0x0000 },
      { spriteId = 29, mapModelId = 25, packed = 0x0000 },
      { spriteId = 1032, mapModelId = 483, packed = 0x0000 },
    }
  local bytes = FieldActorFixture.overlay(RAM, {
    {
      address = A.ranges,
      bytes = FieldActorFixture.rangeTable(opts.ranges or {
        { startFrame = 0, endFrame = 15 },
        { startFrame = 16, endFrame = 31 },
        { startFrame = 32, endFrame = 47 },
        { startFrame = 48, endFrame = 63 },
      }),
    },
    { address = A.graphics, bytes = FieldActorFixture.graphicsTable(records, opts) },
    {
      address = A.descriptors,
      bytes = FieldActorFixture.descriptorTable(
        opts.descriptors or { { modelKey = 3, timelineKey = 4, rangesAddress = A.ranges } }
      ),
    },
    {
      address = A.modelKeys,
      bytes = FieldActorFixture.keyTable(opts.modelKeys or { { key = 3, memberId = 266 } }),
    },
    {
      address = A.timelineKeys,
      bytes = FieldActorFixture.keyTable(opts.timelineKeys or { { key = 4, memberId = 280 } }),
    },
  })
  local manifest = {
    tables = {
      graphics = { address = A.graphics },
      descriptors = { address = A.descriptors, count = opts.descriptorCount or 1 },
      modelKeys = { address = A.modelKeys },
      timelineKeys = { address = A.timelineKeys },
    },
  }
  if opts.expectedRecordCount then
    manifest.tables.graphics.expectedRecordCount = opts.expectedRecordCount
  end
  if opts.expectedTerminatorOffset then
    manifest.tables.graphics.expectedTerminatorOffset = opts.expectedTerminatorOffset
  end
  return bytes, { ramAddress = RAM }, manifest
end

-- A synthetic field-actor visual definition: the runtime-facing shape
-- the actor compiler emits. One atlas frame per direction plus one extra, so a
-- direction, a pose clock, and an atlas offset are all distinguishable.
-- opts.frameCount widens the strip; opts.omitWalk drops the walk clips so the
-- idle fallback is testable.
function FieldActorFixture.visual(spriteId, opts)
  opts = opts or {}
  local frameCount = opts.frameCount or 5
  local directions = {}
  for index, direction in ipairs({ "north", "south", "west", "east" }) do
    local set = {
      idle = { frames = { { frameIndex = index, ticks = 1, displayOffsetY = 0 } }, loop = true, durationTicks = 1 },
    }
    if not opts.omitWalk then
      set.walk = {
        frames = {
          { frameIndex = index, ticks = 2, displayOffsetY = 0 },
          { frameIndex = 5, ticks = 3, displayOffsetY = 0 },
        },
        loop = true,
        durationTicks = 5,
        sourceRange = { startFrame = 0, endFrame = 15, endMode = 0 },
      }
    end
    directions[direction] = set
  end

  local function vertex(x, y, u, v)
    return {
      x = x,
      y = y,
      z = 0,
      u = u,
      v = v,
      nx = 0,
      ny = 0,
      nz = 1,
      r = 0,
      g = 0,
      b = 0,
      a = 255,
      colorSource = 1,
    }
  end

  return {
    schema = "g4-field-actor-v3",
    spriteId = spriteId,
    render = {
      kind = "atlas",
      image = string.format("assets/generated/field/actors/%04d.png", spriteId),
      frameWidth = 32,
      frameHeight = 32,
      frameCount = frameCount,
      billboardMode = "cameraFacingFull",
      mirrorEastWest = false,
      textureFormat = 3,
      alphaUsage = { hasZero = true, hasPartial = false, hasOpaque = true },
      alphaClass = "cutout",
      polygon = {
        polygonAttrRaw = 0x001F8081,
        polygonAlpha = 31,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 1,
        cullMode = "back",
        translucentDepthWrite = false,
        depthEqual = false,
        farClipEnabled = false,
        oneDotEnabled = false,
        fogEnabled = true,
      },
      geometry = {
        modelName = "mmdl_m32x32",
        vertices = {
          vertex(-1, 0, 0, 1),
          vertex(1, 0, 1, 1),
          vertex(1, 2, 1, 0),
          vertex(-1, 2, 0, 0),
        },
        indices = { 0, 1, 2, 0, 2, 3 },
        baseTransform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
        anchorTiles = { x = 0, y = 6 / 16, z = 0 },
        bounds = { width = 2, height = 2, depth = 0 },
      },
    },
    anchor = { x = 0, y = 6, z = 0 },
    bounds = { width = 32, height = 32, depth = 0 },
    pivot = { x = 0.5, y = 1 },
    frames = { { textureSlot = 0, paletteSlot = 0 } },
    directions = directions,
    gestures = {},
    idlePresentation = opts.idlePresentation or {
      mode = "static",
      cadence = 0,
    },
  }
end

return FieldActorFixture
