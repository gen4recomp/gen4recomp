-- Repairs terrain boundary T-junctions over compiler-owned geometry slices.

local bit = require("bit")
local ffi = require("ffi")
local Errors = require("libs.errors.src.Errors")

local TerrainBoundaryConformer = {}

ffi.cdef([[
  typedef union {
    double number;
    uint64_t bits;
    struct { uint32_t lo, hi; } words;
  } G4TerrainDoubleBits;

  typedef struct {
    uint64_t xBits, yBits, zBits;
    uint32_t idPlusOne;
    uint32_t representative;
  } G4PositionSlot;

  typedef struct {
    uint32_t a, b;
    uint32_t count;
    uint32_t firstTriangle;
    uint32_t ia, ib;
    uint32_t used;
    uint32_t pad;
  } G4EdgeSlot;

  typedef struct {
    uint32_t a, b, c;
    uint32_t used;
  } G4TriangleSlot;

  typedef struct {
    uint32_t batchIndex;
    uint32_t candidateBatch;
    uint32_t ia, ib;
    uint32_t pointVertex;
    uint32_t pad;
    double t;
  } G4SplitEvent;
]])

assert(ffi.sizeof("G4PositionSlot") == 32, "G4PositionSlot must remain 32 bytes")
assert(ffi.sizeof("G4EdgeSlot") == 32, "G4EdgeSlot must remain 32 bytes")
assert(ffi.sizeof("G4TriangleSlot") == 16, "G4TriangleSlot must remain 16 bytes")
assert(ffi.sizeof("G4SplitEvent") == 32, "G4SplitEvent must remain 32 bytes")

---@class TerrainDoubleBits
---@field number number
---@field bits integer
---@field words { lo: integer, hi: integer }

---@class TerrainHashScratch
---@field doubleBits TerrainDoubleBits
---@field positionCapacity integer
---@field positionHashCapacity integer
---@field positionSlots ffi.cdata*
---@field positionX ffi.cdata*
---@field positionY ffi.cdata*
---@field positionZ ffi.cdata*
---@field positionCount integer
---@field edgeHashCapacity integer
---@field triangleHashCapacity integer
---@field edgeSlots ffi.cdata*
---@field triangleSlots ffi.cdata*

---@class G4EdgeSlot
---@field a integer
---@field b integer
---@field count integer
---@field firstTriangle integer
---@field ia integer
---@field ib integer
---@field used integer
---@field pad integer

---@class G4TriangleSlot
---@field a integer
---@field b integer
---@field c integer
---@field used integer

---@class TerrainGeometryArena
---@field indices ffi.cdata*
---@field numeric ffi.cdata*
---@field attrib ffi.cdata*

---@class TerrainGeometrySlice
---@field arena TerrainGeometryArena
---@field vertexOffset integer
---@field vertexCount integer
---@field indexOffset integer
---@field indexCount integer

local TOLERANCE = 1e-9
local UINT32_MAX = 0xFFFFFFFF
local TRIANGLE_SLOT_SIZE = assert(ffi.sizeof("G4TriangleSlot"))

local function isFinite(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end

local function nextPowerOfTwo(value)
  local capacity = 1
  while capacity < value do
    capacity = capacity * 2
  end
  return capacity
end

local function validateSlice(batch)
  assert(
    type(batch) == "table"
      and type(batch.arena) == "table"
      and type(batch.vertexOffset) == "number"
      and type(batch.vertexCount) == "number"
      and type(batch.indexOffset) == "number"
      and type(batch.indexCount) == "number",
    "conformance requires compiled geometry slices"
  )
  assert(batch.vertexCount >= 0 and batch.indexCount >= 0, "geometry slice counts must be non-negative")
  assert(batch.indexCount % 3 == 0, "geometry slice index count must be a multiple of three")
end

---@param batch TerrainGeometrySlice
---@param offset integer
---@return integer
local function indexAt(batch, offset)
  local value = tonumber(batch.arena.indices[batch.indexOffset + offset])
  assert(value >= 0 and value < batch.vertexCount, "batch index references missing vertex")
  ---@cast value integer
  return value
end

local function vertexScalars(batch, localIndex)
  assert(localIndex >= 0 and localIndex < batch.vertexCount, "batch vertex index is out of range")
  local offset = batch.vertexOffset + localIndex
  local numeric = batch.arena.numeric[offset]
  local attrib = batch.arena.attrib[offset]
  assert(
    isFinite(numeric.x)
      and isFinite(numeric.y)
      and isFinite(numeric.z)
      and isFinite(numeric.u)
      and isFinite(numeric.v)
      and isFinite(numeric.nx)
      and isFinite(numeric.ny)
      and isFinite(numeric.nz),
    "terrain geometry values must be finite"
  )
  return numeric, attrib
end

---@param doubleBits TerrainDoubleBits
---@param value number
---@return integer, integer
local function bitWords(doubleBits, value)
  if value == 0 then
    value = 0
  end
  doubleBits.number = value
  local lo = assert(tonumber(doubleBits.words.lo))
  local hi = assert(tonumber(doubleBits.words.hi))
  ---@cast lo integer
  ---@cast hi integer
  return bit.tobit(lo), bit.tobit(hi)
end

---@param hash integer
---@param word integer
---@return integer
local function mix(hash, word)
  return bit.tobit(bit.bxor(hash, word) * 16777619)
end

---@param a integer
---@param b integer
---@param c integer
---@param d integer
---@param e integer
---@param f integer
---@return integer
local function hashWords(a, b, c, d, e, f)
  local hash = -2128831035
  hash = mix(hash, a)
  hash = mix(hash, b)
  hash = mix(hash, c)
  hash = mix(hash, d)
  hash = mix(hash, e)
  return mix(hash, f)
end

local function zeroArray(array, count, elementSize)
  ffi.fill(array, count * elementSize, 0)
end

local function copyEdgeSlot(destination, source)
  destination.a, destination.b = source.a, source.b
  destination.count, destination.firstTriangle = source.count, source.firstTriangle
  destination.ia, destination.ib = source.ia, source.ib
  destination.used, destination.pad = source.used, source.pad
end

local function copyEvent(destination, source)
  destination.batchIndex, destination.candidateBatch = source.batchIndex, source.candidateBatch
  destination.ia, destination.ib = source.ia, source.ib
  destination.pointVertex, destination.pad, destination.t = source.pointVertex, source.pad, source.t
end

local function ensureArray(owner, field, capacityField, ctype, required)
  local current = owner[capacityField] or 0
  if current >= required then
    return
  end
  local capacity = nextPowerOfTwo(math.max(1, required))
  local old = owner[field]
  local array = ffi.new(ctype .. "[?]", capacity)
  if old ~= nil then
    ffi.copy(array, old, current * ffi.sizeof(ctype))
  end
  owner[field], owner[capacityField] = array, capacity
end

local function newScratch()
  return {
    doubleBits = ffi.new("G4TerrainDoubleBits"),
    positionCount = 0,
    eventCount = 0,
  }
end

local function scratchFor(context)
  if context == nil then
    return newScratch()
  end
  if context.terrainScratch == nil then
    context.terrainScratch = newScratch()
  end
  return context.terrainScratch
end

local function ensurePositionCapacity(scratch, required)
  local old = scratch.positionCapacity or 0
  if old >= required then
    return
  end
  local capacity = nextPowerOfTwo(math.max(1, required))
  local oldSlots, oldX, oldY, oldZ = scratch.positionSlots, scratch.positionX, scratch.positionY, scratch.positionZ
  scratch.positionSlots = ffi.new("G4PositionSlot[?]", capacity)
  scratch.positionX, scratch.positionY, scratch.positionZ =
    ffi.new("double[?]", capacity), ffi.new("double[?]", capacity), ffi.new("double[?]", capacity)
  if oldSlots ~= nil then
    ffi.copy(scratch.positionSlots, oldSlots, old * ffi.sizeof("G4PositionSlot"))
    ffi.copy(scratch.positionX, oldX, old * ffi.sizeof("double"))
    ffi.copy(scratch.positionY, oldY, old * ffi.sizeof("double"))
    ffi.copy(scratch.positionZ, oldZ, old * ffi.sizeof("double"))
  end
  scratch.positionCapacity = capacity
end

local function positionCoordinates(scratch, positionId)
  local index = positionId - 1
  return scratch.positionX[index], scratch.positionY[index], scratch.positionZ[index]
end

local function positionHashIndex(scratch, xLo, xHi, yLo, yHi, zLo, zHi)
  return bit.band(hashWords(xLo, xHi, yLo, yHi, zLo, zHi), scratch.positionHashCapacity - 1)
end

---@param scratch TerrainHashScratch
---@param x number
---@param y number
---@param z number
---@param representative integer
---@return integer
local function positionId(scratch, x, y, z, representative)
  assert(isFinite(x) and isFinite(y) and isFinite(z), "terrain position identity requires finite coordinates")
  local doubleBits = scratch.doubleBits --[[@as TerrainDoubleBits]]
  local xLo, xHi = bitWords(doubleBits, x)
  local yLo, yHi = bitWords(doubleBits, y)
  local zLo, zHi = bitWords(doubleBits, z)
  local slotIndex = positionHashIndex(scratch, xLo, xHi, yLo, yHi, zLo, zHi)
  while true do
    local slot = scratch.positionSlots[slotIndex]
    if slot.idPlusOne == 0 then
      local id = scratch.positionCount + 1
      assert(id <= UINT32_MAX, "terrain position identity exceeds uint32_t capacity")
      doubleBits.number = x
      slot.xBits = doubleBits.bits
      doubleBits.number = y
      slot.yBits = doubleBits.bits
      doubleBits.number = z
      slot.zBits = doubleBits.bits
      slot.idPlusOne, slot.representative = id, representative
      scratch.positionX[id - 1], scratch.positionY[id - 1], scratch.positionZ[id - 1] = x, y, z
      scratch.positionCount = id
      ---@cast id integer
      return id
    end
    doubleBits.number = x
    local matches = slot.xBits == doubleBits.bits
    doubleBits.number = y
    matches = matches and slot.yBits == doubleBits.bits
    doubleBits.number = z
    matches = matches and slot.zBits == doubleBits.bits
    if matches then
      local id = assert(tonumber(slot.idPlusOne))
      ---@cast id integer
      return id
    end
    slotIndex = (slotIndex + 1) % scratch.positionHashCapacity
  end
end

---@param scratch TerrainHashScratch
---@param a integer
---@param b integer
---@return integer
local function edgeHashIndex(scratch, a, b)
  return bit.band(hashWords(a, b, 0, 0, 0, 0), scratch.edgeHashCapacity - 1)
end

---@param scratch TerrainHashScratch
---@param a integer
---@param b integer
---@param c integer
---@return integer
local function triangleHashIndex(scratch, a, b, c)
  return bit.band(hashWords(a, b, c, 0, 0, 0), scratch.triangleHashCapacity - 1)
end

---@param a integer
---@param b integer
---@param c integer
---@return integer, integer, integer
local function canonical3(a, b, c)
  if a > b then
    a, b = b, a
  end
  if b > c then
    b, c = c, b
  end
  if a > b then
    a, b = b, a
  end
  return a, b, c
end

---@param scratch TerrainHashScratch
---@param a integer
---@param b integer
---@param c integer
---@return G4TriangleSlot|nil
local function findTriangle(scratch, a, b, c)
  local index = triangleHashIndex(scratch, a, b, c)
  while true do
    local slot = scratch.triangleSlots[index]
    ---@cast slot G4TriangleSlot
    if slot.used == 0 then
      return slot
    end
    if slot.a == a and slot.b == b and slot.c == c then
      return nil
    end
    index = (index + 1) % scratch.triangleHashCapacity
  end
end

---@param scratch TerrainHashScratch
---@param a integer
---@param b integer
---@return G4EdgeSlot
local function findEdge(scratch, a, b)
  if a > b then
    a, b = b, a
  end
  local index = edgeHashIndex(scratch, a, b)
  while true do
    local slot = scratch.edgeSlots[index]
    ---@cast slot G4EdgeSlot
    if slot.used == 0 then
      slot.a, slot.b, slot.count, slot.used = a, b, 0, 1
      return slot
    end
    if slot.a == a and slot.b == b then
      return slot
    end
    index = (index + 1) % scratch.edgeHashCapacity
  end
end

---@param scratch TerrainHashScratch
---@param a integer
---@param b integer
---@param triangle integer
---@param ia integer
---@param ib integer
local function countEdge(scratch, a, b, triangle, ia, ib)
  local edge = findEdge(scratch, a, b)
  edge.count = edge.count + 1
  if edge.count == 1 then
    edge.firstTriangle, edge.ia, edge.ib = triangle, ia, ib
  end
end

local function sortEdges(edges, count, scratch)
  ensureArray(scratch, "edgeSort", "edgeSortCapacity", "G4EdgeSlot", count)
  local source, target = edges, scratch.edgeSort
  local width = 1
  while width < count do
    local start = 0
    while start < count do
      local middle, finish = math.min(start + width, count), math.min(start + width * 2, count)
      local left, right, output = start, middle, start
      while output < finish do
        if
          right >= finish
          or (
            left < middle
            and (
              source[left].a < source[right].a
              or (source[left].a == source[right].a and source[left].b <= source[right].b)
            )
          )
        then
          copyEdgeSlot(target[output], source[left])
          left = left + 1
        else
          copyEdgeSlot(target[output], source[right])
          right = right + 1
        end
        output = output + 1
      end
      start = finish
    end
    source, target, width = target, source, width * 2
  end
  if source ~= edges then
    ffi.copy(edges, source, count * ffi.sizeof("G4EdgeSlot"))
  end
end

local function sortUint32(values, count, scratch)
  ensureArray(scratch, "uintSort", "uintSortCapacity", "uint32_t", count)
  local source, target = values, scratch.uintSort
  local width = 1
  while width < count do
    local start = 0
    while start < count do
      local middle, finish = math.min(start + width, count), math.min(start + width * 2, count)
      local left, right, output = start, middle, start
      while output < finish do
        if right >= finish or (left < middle and source[left] <= source[right]) then
          target[output] = source[left]
          left = left + 1
        else
          target[output] = source[right]
          right = right + 1
        end
        output = output + 1
      end
      start = finish
    end
    source, target, width = target, source, width * 2
  end
  if source ~= values then
    ffi.copy(values, source, count * ffi.sizeof("uint32_t"))
  end
end

local function assignPositions(batches, scratch)
  local totalVertices = 0
  for _, batch in ipairs(batches) do
    validateSlice(batch)
    totalVertices = totalVertices + batch.vertexCount
  end
  ensurePositionCapacity(scratch, totalVertices * 2)
  scratch.positionHashCapacity = scratch.positionCapacity
  zeroArray(scratch.positionSlots, scratch.positionHashCapacity, ffi.sizeof("G4PositionSlot"))
  scratch.positionCount = 0
  local analyses = {}
  for batchIndex, batch in ipairs(batches) do
    local analysis = { batch = batch }
    local field, capacityField = "positionIds" .. batchIndex, "positionIdCapacity" .. batchIndex
    ensureArray(scratch, field, capacityField, "uint32_t", batch.vertexCount)
    analysis.positionIds = scratch[field]
    for localIndex = 0, batch.vertexCount - 1 do
      local numeric = vertexScalars(batch, localIndex)
      analysis.positionIds[localIndex] = positionId(scratch, numeric.x, numeric.y, numeric.z, localIndex)
    end
    analyses[batchIndex] = analysis
  end
  return analyses, scratch.positionCount
end

local function analyzeBatch(analysis, scratch)
  local batch, triangleCount = analysis.batch, analysis.batch.indexCount / 3
  local edgeCapacity, triangleCapacity =
    nextPowerOfTwo(math.max(2, triangleCount * 6)), nextPowerOfTwo(math.max(2, triangleCount * 2))
  ensureArray(scratch, "edgeSlots", "edgeHashCapacity", "G4EdgeSlot", edgeCapacity)
  ensureArray(scratch, "triangleSlots", "triangleHashCapacity", "G4TriangleSlot", triangleCapacity)
  scratch.edgeHashCapacity, scratch.triangleHashCapacity = edgeCapacity, triangleCapacity
  zeroArray(scratch.edgeSlots, edgeCapacity, ffi.sizeof("G4EdgeSlot"))
  zeroArray(scratch.triangleSlots, triangleCapacity, ffi.sizeof("G4TriangleSlot"))
  for triangle = 0, triangleCount - 1 do
    local i0, i1, i2 = indexAt(batch, triangle * 3), indexAt(batch, triangle * 3 + 1), indexAt(batch, triangle * 3 + 2)
    local p0, p1, p2 =
      tonumber(analysis.positionIds[i0]), tonumber(analysis.positionIds[i1]), tonumber(analysis.positionIds[i2])
    if p0 ~= p1 and p1 ~= p2 and p2 ~= p0 then
      ---@cast p0 integer
      ---@cast p1 integer
      ---@cast p2 integer
      local a, b, c = canonical3(p0, p1, p2)
      local triangleSlot = findTriangle(scratch, a, b, c)
      if triangleSlot ~= nil then
        triangleSlot.a, triangleSlot.b, triangleSlot.c, triangleSlot.used = a, b, c, 1
        countEdge(scratch, p0, p1, triangle, i0, i1)
        countEdge(scratch, p1, p2, triangle, i1, i2)
        countEdge(scratch, p2, p0, triangle, i2, i0)
      end
    end
  end
  local edgeCount = 0
  for index = 0, edgeCapacity - 1 do
    local edge = scratch.edgeSlots[index]
    if edge.used ~= 0 and edge.count == 1 then
      edgeCount = edgeCount + 1
    end
  end
  ensureArray(analysis, "edges", "edgeCapacity", "G4EdgeSlot", edgeCount)
  local output = 0
  for index = 0, edgeCapacity - 1 do
    local edge = scratch.edgeSlots[index]
    if edge.used ~= 0 and edge.count == 1 then
      copyEdgeSlot(analysis.edges[output], edge)
      output = output + 1
    end
  end
  sortEdges(analysis.edges, edgeCount, scratch)
  analysis.edgeCount = edgeCount
  ensureArray(analysis, "pointIds", "pointCapacity", "uint32_t", math.max(1, edgeCount * 2))
  for edgeIndex = 0, edgeCount - 1 do
    analysis.pointIds[edgeIndex * 2], analysis.pointIds[edgeIndex * 2 + 1] =
      analysis.edges[edgeIndex].a, analysis.edges[edgeIndex].b
  end
  local pointCount = edgeCount * 2
  sortUint32(analysis.pointIds, pointCount, scratch)
  local unique = 0
  for index = 0, pointCount - 1 do
    local point = analysis.pointIds[index]
    if unique == 0 or point ~= analysis.pointIds[unique - 1] then
      analysis.pointIds[unique], unique = point, unique + 1
    end
  end
  analysis.pointCount = unique
end

local function splitParam(scratch, aId, bId, pointId)
  if pointId == aId or pointId == bId then
    return nil
  end
  local ax, ay, az = positionCoordinates(scratch, aId)
  local bx, by, bz = positionCoordinates(scratch, bId)
  local px, py, pz = positionCoordinates(scratch, pointId)
  local abx, aby, abz, apx, apy, apz = bx - ax, by - ay, bz - az, px - ax, py - ay, pz - az
  local length2 = abx * abx + aby * aby + abz * abz
  if length2 == 0 then
    return nil
  end
  local t = (apx * abx + apy * aby + apz * abz) / length2
  if t <= 0 or t >= 1 then
    return nil
  end
  local cx, cy, cz = apy * abz - apz * aby, apz * abx - apx * abz, apx * aby - apy * abx
  if (cx * cx + cy * cy + cz * cz) / length2 > TOLERANCE * TOLERANCE then
    return nil
  end
  if apx * apx + apy * apy + apz * apz <= TOLERANCE * TOLERANCE then
    return nil
  end
  local bpx, bpy, bpz = px - bx, py - by, pz - bz
  if bpx * bpx + bpy * bpy + bpz * bpz <= TOLERANCE * TOLERANCE then
    return nil
  end
  return t
end

local function eventEdgeIds(event, analyses)
  local ids = analyses[event.batchIndex + 1].positionIds
  local a, b = tonumber(ids[event.ia]), tonumber(ids[event.ib])
  if a > b then
    a, b = b, a
  end
  return a, b
end

local function eventLess(a, b, analyses)
  if a.batchIndex ~= b.batchIndex then
    return a.batchIndex < b.batchIndex
  end
  local aa, ab, ba, bb = eventEdgeIds(a, analyses)
  ba, bb = eventEdgeIds(b, analyses)
  if aa ~= ba then
    return aa < ba
  end
  if ab ~= bb then
    return ab < bb
  end
  if a.candidateBatch ~= b.candidateBatch then
    return a.candidateBatch < b.candidateBatch
  end
  if a.t ~= b.t then
    return a.t < b.t
  end
  return a.pointVertex < b.pointVertex
end

local function sortEvents(scratch, count, analyses)
  ensureArray(scratch, "eventSort", "eventSortCapacity", "G4SplitEvent", count)
  local source, target, width = scratch.events, scratch.eventSort, 1
  while width < count do
    local start = 0
    while start < count do
      local middle, finish = math.min(start + width, count), math.min(start + width * 2, count)
      local left, right, output = start, middle, start
      while output < finish do
        if right >= finish or (left < middle and eventLess(source[left], source[right], analyses)) then
          copyEvent(target[output], source[left])
          left = left + 1
        else
          copyEvent(target[output], source[right])
          right = right + 1
        end
        output = output + 1
      end
      start = finish
    end
    source, target, width = target, source, width * 2
  end
  if source ~= scratch.events then
    ffi.copy(scratch.events, source, count * ffi.sizeof("G4SplitEvent"))
  end
end

local function collectEvents(analyses, scratch)
  scratch.eventCount = 0
  for batchIndex, analysis in ipairs(analyses) do
    for edgeIndex = 0, analysis.edgeCount - 1 do
      local edge = analysis.edges[edgeIndex]
      for candidateBatch, candidate in ipairs(analyses) do
        for pointIndex = 0, candidate.pointCount - 1 do
          local pointId = tonumber(candidate.pointIds[pointIndex])
          local t = splitParam(scratch, edge.a, edge.b, pointId)
          if t ~= nil then
            local index = scratch.eventCount
            ensureArray(scratch, "events", "eventCapacity", "G4SplitEvent", index + 1)
            local event = scratch.events[index]
            event.batchIndex, event.candidateBatch, event.ia, event.ib, event.pointVertex, event.t =
              batchIndex - 1, candidateBatch - 1, edge.ia, edge.ib, pointId, t
            event.pad = 0
            scratch.eventCount = index + 1
          end
        end
      end
    end
  end
  sortEvents(scratch, scratch.eventCount, analyses)
  return scratch.eventCount
end

local function eventSameEdge(a, b, analyses)
  if a.batchIndex ~= b.batchIndex then
    return false
  end
  local aa, ab = eventEdgeIds(a, analyses)
  local ba, bb = eventEdgeIds(b, analyses)
  return aa == ba and ab == bb
end

local function collectBreaks(scratch, start, finish)
  ensureArray(scratch, "breaks", "breakCapacity", "G4SplitEvent", math.max(1, finish - start))
  local count = 0
  for index = start, finish - 1 do
    local event = scratch.events[index]
    local duplicate = false
    for existing = 0, count - 1 do
      if scratch.breaks[existing].pointVertex == event.pointVertex then
        duplicate = true
        break
      end
    end
    if not duplicate then
      copyEvent(scratch.breaks[count], event)
      count = count + 1
    end
  end
  for index = 1, count - 1 do
    local value = scratch.breaks[index]
    local cursor = index - 1
    while
      cursor >= 0
      and (
        scratch.breaks[cursor].t > value.t
        or (scratch.breaks[cursor].t == value.t and scratch.breaks[cursor].pointVertex > value.pointVertex)
      )
    do
      copyEvent(scratch.breaks[cursor + 1], scratch.breaks[cursor])
      cursor = cursor - 1
    end
    copyEvent(scratch.breaks[cursor + 1], value)
  end
  return count
end

local function conformErrorContext(context, batchIndex, batch, a, b)
  local out = { batchIndex = batchIndex }
  if type(context) == "table" then
    for _, key in ipairs({ "mapId", "mapSymbol", "role", "modelArchive", "modelMemberId", "modelName" }) do
      if context[key] ~= nil then
        out[key] = context[key]
      end
    end
  end
  out.materialIndex = batch.materialIndex
  local va, vb = vertexScalars(batch, a), vertexScalars(batch, b)
  out.edgeStart, out.edgeEnd = { x = va.x, y = va.y, z = va.z }, { x = vb.x, y = vb.y, z = vb.z }
  out.colorSourceA, out.colorSourceB =
    batch.arena.attrib[batch.vertexOffset + a].colorSource, batch.arena.attrib[batch.vertexOffset + b].colorSource
  return out
end

local function validateEventGroups(batches, analyses, scratch, eventCount, context)
  local total, index = 0, 0
  ensureArray(scratch, "plannedCounts", "plannedCountCapacity", "uint32_t", #analyses)
  ffi.fill(scratch.plannedCounts, #analyses * ffi.sizeof("uint32_t"), 0)
  while index < eventCount do
    local first, finish = scratch.events[index], index + 1
    while finish < eventCount and eventSameEdge(first, scratch.events[finish], analyses) do
      finish = finish + 1
    end
    local count = collectBreaks(scratch, index, finish)
    local batchIndex, batch = first.batchIndex + 1, batches[first.batchIndex + 1]
    local attribA, attribB =
      batch.arena.attrib[batch.vertexOffset + first.ia], batch.arena.attrib[batch.vertexOffset + first.ib]
    if attribA.colorSource ~= attribB.colorSource then
      Errors.raise(
        "MAP_COMPILE_TERRAIN_BOUNDARY_COLOR_SOURCE_CONFLICT",
        "terrain boundary edge endpoints disagree on colorSource ("
          .. tostring(attribA.colorSource)
          .. " ~= "
          .. tostring(attribB.colorSource)
          .. "); cannot interpolate the inserted vertex",
        conformErrorContext(context, batchIndex, batch, first.ia, first.ib)
      )
    end
    total = total + count
    scratch.plannedCounts[batchIndex - 1] = scratch.plannedCounts[batchIndex - 1] + count
    index = finish
  end
  return total, scratch.plannedCounts
end

local function lerpByte(a, b, t)
  return math.max(0, math.min(255, math.floor(a + (b - a) * t + 0.5)))
end

local function appendInterpolatedVertex(batch, scratch, localIndex, event, pointId, t)
  local numericA, attribA = vertexScalars(batch, event.ia)
  local numericB, attribB = vertexScalars(batch, event.ib)
  local x, y, z = positionCoordinates(scratch, pointId)
  local destination = batch.arena.numeric[batch.vertexOffset + localIndex]
  destination.x, destination.y, destination.z = x, y, z
  destination.u, destination.v = numericA.u + (numericB.u - numericA.u) * t, numericA.v + (numericB.v - numericA.v) * t
  destination.nx, destination.ny, destination.nz =
    numericA.nx + (numericB.nx - numericA.nx) * t,
    numericA.ny + (numericB.ny - numericA.ny) * t,
    numericA.nz + (numericB.nz - numericA.nz) * t
  local attrib = batch.arena.attrib[batch.vertexOffset + localIndex]
  attrib.r, attrib.g, attrib.b, attrib.a =
    lerpByte(attribA.r, attribB.r, t),
    lerpByte(attribA.g, attribB.g, t),
    lerpByte(attribA.b, attribB.b, t),
    lerpByte(attribA.a, attribB.a, t)
  attrib.colorSource = attribA.colorSource
end

local function splitTriangle(triangles, triangleCount, owner, start, finish, point)
  for index = triangleCount, owner + 1, -1 do
    ffi.copy(triangles[index], triangles[index - 1], TRIANGLE_SLOT_SIZE)
  end
  local tri = triangles[owner]
  local firstA, firstB, firstC, secondA, secondB, secondC
  if (tri.a == start or tri.a == finish) and (tri.b == start or tri.b == finish) then
    firstA, firstB, firstC, secondA, secondB, secondC = tri.a, point, tri.c, point, tri.b, tri.c
  elseif (tri.b == start or tri.b == finish) and (tri.c == start or tri.c == finish) then
    firstA, firstB, firstC, secondA, secondB, secondC = tri.b, point, tri.a, point, tri.c, tri.a
  else
    firstA, firstB, firstC, secondA, secondB, secondC = tri.c, point, tri.b, point, tri.a, tri.b
  end
  tri.a, tri.b, tri.c = firstA, firstB, firstC
  triangles[owner + 1].a, triangles[owner + 1].b, triangles[owner + 1].c = secondA, secondB, secondC
  return triangleCount + 1
end

local function applyBatch(batch, analyses, scratch, eventStart, eventFinish, plannedCount)
  local oldOffset, oldCount, triangleCount = batch.vertexOffset, batch.vertexCount, batch.indexCount / 3
  ensureArray(scratch, "triangles", "triangleCapacity", "G4TriangleSlot", triangleCount + plannedCount)
  for triangle = 0, triangleCount - 1 do
    local tri = scratch.triangles[triangle]
    tri.a, tri.b, tri.c, tri.used =
      indexAt(batch, triangle * 3), indexAt(batch, triangle * 3 + 1), indexAt(batch, triangle * 3 + 2), 1
  end
  local arena, destinationOffset = batch.arena, batch.arena.vertexCount
  arena:reserve(oldCount + plannedCount, triangleCount * 3 + plannedCount * 3)
  ffi.copy(arena.numeric[destinationOffset], arena.numeric[oldOffset], oldCount * ffi.sizeof("G4GxVertexNumeric"))
  ffi.copy(arena.attrib[destinationOffset], arena.attrib[oldOffset], oldCount * ffi.sizeof("G4GxVertexAttrib"))
  arena.vertexCount, batch.vertexOffset = destinationOffset + oldCount, destinationOffset
  local localVertexCount, index = oldCount, eventStart
  while index < eventFinish do
    local first, finish = scratch.events[index], index + 1
    while finish < eventFinish and eventSameEdge(first, scratch.events[finish], analyses) do
      finish = finish + 1
    end
    local breakCount = collectBreaks(scratch, index, finish)
    local start, edgeFinish = first.ia, first.ib
    for breakIndex = 0, breakCount - 1 do
      local br = scratch.breaks[breakIndex]
      appendInterpolatedVertex(batch, scratch, localVertexCount, first, br.pointVertex, br.t)
      local owner
      for triangle = 0, triangleCount - 1 do
        local tri = scratch.triangles[triangle]
        if
          (tri.a == start or tri.b == start or tri.c == start)
          and (tri.a == edgeFinish or tri.b == edgeFinish or tri.c == edgeFinish)
        then
          owner = triangle
          break
        end
      end
      assert(owner ~= nil, "terrain boundary repair found no owning triangle for a planned split")
      triangleCount = splitTriangle(scratch.triangles, triangleCount, owner, start, edgeFinish, localVertexCount)
      start, localVertexCount, arena.vertexCount =
        localVertexCount, localVertexCount + 1, batch.vertexOffset + localVertexCount + 1
    end
    index = finish
  end
  local indexOffset = arena.indexCount
  arena:reserve(0, triangleCount * 3)
  for triangle = 0, triangleCount - 1 do
    local tri = scratch.triangles[triangle]
    arena.indices[indexOffset + triangle * 3], arena.indices[indexOffset + triangle * 3 + 1], arena.indices[indexOffset + triangle * 3 + 2] =
      tri.a, tri.b, tri.c
  end
  arena.indexCount, batch.vertexCount = indexOffset + triangleCount * 3, localVertexCount
  batch.indexOffset, batch.indexCount = indexOffset, triangleCount * 3
end

local function errorContext(context, info)
  local out = {}
  if type(context) == "table" then
    for _, key in ipairs({ "mapId", "mapSymbol", "role", "modelArchive", "modelMemberId", "modelName" }) do
      if context[key] ~= nil then
        out[key] = context[key]
      end
    end
  end
  for key, value in pairs(info) do
    out[key] = value
  end
  return out
end

local function conformPasses(batches, context, scratch)
  local initialTris, refinements, pass = nil, 0, 0
  while true do
    local analyses, distinctPositions = assignPositions(batches, scratch)
    local triCount = 0
    for _, batch in ipairs(batches) do
      triCount = triCount + batch.indexCount / 3
    end
    initialTris = initialTris or triCount
    for _, analysis in ipairs(analyses) do
      analyzeBatch(analysis, scratch)
    end
    local eventCount = collectEvents(analyses, scratch)
    if eventCount == 0 then
      return batches
    end
    pass = pass + 1
    local planned, plannedCounts = validateEventGroups(batches, analyses, scratch, eventCount, context)
    local maxRefinements = initialTris * distinctPositions
    if planned == 0 or refinements + planned > maxRefinements then
      Errors.raise(
        "MAP_COMPILE_TERRAIN_BOUNDARY_DID_NOT_CONVERGE",
        "terrain boundary repair exceeded its physical refinement budget",
        errorContext(context, {
          batchCount = #batches,
          passes = pass,
          refinements = refinements,
          maxRefinements = maxRefinements,
          remainingEvents = eventCount,
        })
      )
    end
    local eventStart = 0
    for batchIndex, batch in ipairs(batches) do
      local batchStart = eventStart
      while eventStart < eventCount and scratch.events[eventStart].batchIndex == batchIndex - 1 do
        eventStart = eventStart + 1
      end
      if eventStart > batchStart then
        applyBatch(batch, analyses, scratch, batchStart, eventStart, plannedCounts[batchIndex - 1])
      end
    end
    refinements = refinements + planned
  end
end

function TerrainBoundaryConformer.findTJunctions(batches)
  assert(type(batches) == "table" and #batches > 0, "findTJunctions requires compiled geometry slices")
  for _, batch in ipairs(batches) do
    validateSlice(batch)
  end
  local scratch = scratchFor()
  local analyses = assignPositions(batches, scratch)
  for _, analysis in ipairs(analyses) do
    analyzeBatch(analysis, scratch)
  end
  local eventCount = collectEvents(analyses, scratch)
  local diagnostics = {}
  for index = 0, eventCount - 1 do
    local event = scratch.events[index]
    local batchIndex, candidateBatch = event.batchIndex + 1, event.candidateBatch + 1
    local batch, other = batches[batchIndex], batches[candidateBatch]
    local va, vb = vertexScalars(batch, event.ia), vertexScalars(batch, event.ib)
    local x, y, z = positionCoordinates(scratch, event.pointVertex)
    diagnostics[#diagnostics + 1] = {
      batchIndex = batchIndex,
      materialIndex = batch.materialIndex,
      edgeStart = { x = va.x, y = va.y, z = va.z },
      edgeEnd = { x = vb.x, y = vb.y, z = vb.z },
      candidateBatch = candidateBatch,
      candidateMaterial = other.materialIndex,
      position = { x = x, y = y, z = z },
    }
  end
  return diagnostics
end

function TerrainBoundaryConformer.conform(batches, context)
  assert(type(batches) == "table" and #batches > 0, "conform requires compiled geometry slices")
  for _, batch in ipairs(batches) do
    validateSlice(batch)
  end
  local arena = batches[1].arena
  for _, batch in ipairs(batches) do
    assert(batch.arena == arena, "conformance batches must share one geometry arena")
  end
  local saved = {}
  for index, batch in ipairs(batches) do
    saved[index] = {
      vertexOffset = batch.vertexOffset,
      vertexCount = batch.vertexCount,
      indexOffset = batch.indexOffset,
      indexCount = batch.indexCount,
    }
  end
  local oldVertexCount, oldIndexCount = arena.vertexCount, arena.indexCount
  local ok, result = pcall(conformPasses, batches, context, scratchFor(context))
  if not ok then
    arena.vertexCount, arena.indexCount = oldVertexCount, oldIndexCount
    for index, batch in ipairs(batches) do
      local state = saved[index]
      batch.vertexOffset, batch.vertexCount, batch.indexOffset, batch.indexCount =
        state.vertexOffset, state.vertexCount, state.indexOffset, state.indexCount
    end
    error(result, 0)
  end
  return result
end

return TerrainBoundaryConformer
