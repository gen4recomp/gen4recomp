-- Pure render-queue builder. Traverses ordered scene parts (map, building,
-- neighbour, and actor), partitions their draw items into opaque / cutout /
-- mixedOpaque / wireframe passes, and blended translucent/mixed-translucent
-- entries. Preserves source order for opaque/cutout/mixedOpaque/wireframe.
-- Sorts blended draws approximately back-to-front in camera space using the
-- item center and the view matrix. The item's traversal position across
-- ordered parts is the deterministic tie-breaker for equal-depth blended
-- draws, so the queue never invents cross-group ordering. This is an
-- explicit approximation of DS auto sorting, not a claim of exact hardware
-- ordering. Pure domain module: no love, arithmetic only.
--
-- Queue construction validates its input contract and never mutates the
-- caller's draw records: only the five known alpha classes are accepted
-- (anything else -- including a missing class -- fails loudly instead of
-- defaulting to opaque). Mixed items appear in mixedOpaque AND in blended
-- with fragmentPass="mixed"; blended contains queue-owned wrapper records
-- {item, fragmentPass} that reference the original items. Translucent
-- items appear only in blended with fragmentPass="translucent". Blended
-- depth/source-order keys live in reusable key storage owned by the scratch;
-- the visible blended array is filled with stable wrapper references after
-- sorting a reusable integer order array, so warmed builds allocate nothing.
-- The returned queue holds original items in
-- opaque/cutout/mixedOpaque/wireframe; blended holds wrapper records.

local ffi = require("ffi")

local Errors = require("libs.errors.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")

ffi.cdef([[
typedef struct {
  double viewZ;
  int32_t position;
  int32_t entryIndex;
} G4RenderSortKey;
]])

local RenderQueue = {}
local RENDER_QUEUE_UNKNOWN_ALPHA_CLASS = "RENDER_QUEUE_UNKNOWN_ALPHA_CLASS"

local INITIAL_SORT_CAPACITY = 16

local ALPHA_CLASSES = {
  [AlphaClassifier.OPAQUE] = true,
  [AlphaClassifier.CUTOUT] = true,
  [AlphaClassifier.TRANSLUCENT] = true,
  [AlphaClassifier.WIREFRAME] = true,
  [AlphaClassifier.MIXED] = true,
}

-- Validate the item's renderer-facing alpha class instead of inferring it from
-- material state. Queue classification is the authority for the pass an item
-- lands in; the renderer receives that selected class when drawing it.
---@param item table<string, unknown>
---@return string
function RenderQueue.classifyAlphaClass(item)
  local mode = item.alphaClass
  if not ALPHA_CLASSES[mode] then
    Errors.raise(
      RENDER_QUEUE_UNKNOWN_ALPHA_CLASS,
      "render item has unknown alpha class " .. tostring(mode),
      { alphaClass = mode }
    )
  end
  return mode
end

-- Transform a world-space center into view space and return its Z distance
-- from the camera. The camera looks down -Z in view space, so objects in
-- front of the camera carry negative view-space Z and a more negative value
-- means farther away; sorting ascending therefore places far objects first.
local function viewSpaceZ(viewMatrix, x, y, z)
  local _, _, viewZ = Matrix4.transformPoint(viewMatrix, x, y, z)
  return viewZ
end

-- A full billboard is identity-oriented in view space. Its model-space center
-- therefore contributes directly along the view axes after component-wise
-- scaling, without resolving a camera-facing world matrix.
local function itemViewSpaceZ(item, viewMatrix)
  if item.billboardCenter == nil then
    local wx, wy, wz = Matrix4.transformPoint(item.transform, item.center[1], item.center[2], item.center[3])
    return viewSpaceZ(viewMatrix, wx, wy, wz)
  end
  assert(item.billboardScale, "billboard item requires billboardScale")
  local _, _, viewCenterZ =
    Matrix4.transformPoint(viewMatrix, item.billboardCenter[1], item.billboardCenter[2], item.billboardCenter[3])
  return viewCenterZ + item.center[3] * item.billboardScale[3]
end

local function clear(items)
  for i = #items, 1, -1 do
    items[i] = nil
  end
end

---@class RenderQueueScratch
---@field opaque table[]
---@field cutout table[]
---@field mixedOpaque table[]
---@field wireframe table[]
---@field blended table[]
---@field _blendedEntries table[]
---@field _sortKeys ffi.cdata*
---@field _sortOrder number[]
---@field _sortCompare fun(leftIndex: number, rightIndex: number): boolean
---@field _sortCapacity number

-- The only supported scratch constructor. Allocates the five pass arrays,
-- unsorted wrapper storage, the initial key buffer, the reusable order array,
-- and one comparator that reads the scratch key buffer dynamically so later
-- capacity growth cannot leave it pointing at stale storage.
---@return RenderQueueScratch
function RenderQueue.newScratch()
  local scratch = {
    opaque = {},
    cutout = {},
    mixedOpaque = {},
    wireframe = {},
    blended = {},
    _blendedEntries = {},
    _sortKeys = ffi.new("G4RenderSortKey[?]", INITIAL_SORT_CAPACITY),
    _sortOrder = {},
    _sortCapacity = INITIAL_SORT_CAPACITY,
  }
  ---@param leftIndex number
  ---@param rightIndex number
  ---@return boolean
  local function sortCompare(leftIndex, rightIndex)
    local keys = scratch._sortKeys
    local left = keys[leftIndex - 1]
    local right = keys[rightIndex - 1]
    if left.viewZ ~= right.viewZ then
      return left.viewZ < right.viewZ
    end
    return left.position < right.position
  end
  scratch._sortCompare = sortCompare
  return scratch
end

-- Grow the key buffer geometrically when the blended count exceeds capacity.
-- Copies the keys written so far in the current build so mid-build growth
-- preserves earlier entries.
---@param scratch RenderQueueScratch
---@param needed number
local function ensureSortCapacity(scratch, needed)
  if needed <= scratch._sortCapacity then
    return
  end
  local grown = scratch._sortCapacity * 2
  if grown < needed then
    grown = needed
  end
  local replacement = ffi.new("G4RenderSortKey[?]", grown)
  local keys = scratch._sortKeys
  for index = 0, needed - 2 do
    replacement[index] = keys[index]
  end
  scratch._sortKeys = replacement
  scratch._sortCapacity = grown
end

-- Build into renderer-owned scratch storage. Parts are traversed in source
-- order and share one submission position sequence, including across part
-- boundaries. The scratch arrays retain their identities across calls.
-- Mixed items appear in both mixedOpaque and blended. Blended contains
-- queue-owned wrapper records referencing the original items.
---@param parts table[][]
---@param viewMatrix number[]
---@param scratch RenderQueueScratch
---@return RenderQueueScratch
function RenderQueue.buildInto(parts, viewMatrix, scratch)
  local opaque = scratch.opaque
  local cutout = scratch.cutout
  local mixedOpaque = scratch.mixedOpaque
  local wireframe = scratch.wireframe
  local blended = scratch.blended
  assert(opaque and cutout and mixedOpaque and wireframe and blended, "render queue scratch is incomplete")
  local unsorted = scratch._blendedEntries
  local order = scratch._sortOrder
  local compare = scratch._sortCompare
  assert(
    unsorted and scratch._sortKeys and order and compare and scratch._sortCapacity,
    "render queue scratch is incomplete"
  )

  clear(opaque)
  clear(cutout)
  clear(mixedOpaque)
  clear(wireframe)

  local position = 0
  local blendedCount = 0
  local capacity = scratch._sortCapacity
  for _, part in ipairs(parts) do
    for _, item in ipairs(part) do
      position = position + 1
      local mode = RenderQueue.classifyAlphaClass(item)

      if mode == AlphaClassifier.OPAQUE then
        opaque[#opaque + 1] = item
      elseif mode == AlphaClassifier.CUTOUT then
        cutout[#cutout + 1] = item
      elseif mode == AlphaClassifier.MIXED then
        mixedOpaque[#mixedOpaque + 1] = item

        blendedCount = blendedCount + 1
        if blendedCount > capacity then
          ensureSortCapacity(scratch, blendedCount)
          capacity = scratch._sortCapacity
        end
        local entry = unsorted[blendedCount]
        if entry == nil then
          entry = {}
          unsorted[blendedCount] = entry
        end
        entry.item = item
        entry.fragmentPass = AlphaClassifier.MIXED
        local key = scratch._sortKeys[blendedCount - 1]
        key.viewZ = itemViewSpaceZ(item, viewMatrix)
        key.position = position
        key.entryIndex = blendedCount
      elseif mode == AlphaClassifier.TRANSLUCENT then
        blendedCount = blendedCount + 1
        if blendedCount > capacity then
          ensureSortCapacity(scratch, blendedCount)
          capacity = scratch._sortCapacity
        end
        local entry = unsorted[blendedCount]
        if entry == nil then
          entry = {}
          unsorted[blendedCount] = entry
        end
        entry.item = item
        entry.fragmentPass = AlphaClassifier.TRANSLUCENT
        local key = scratch._sortKeys[blendedCount - 1]
        key.viewZ = itemViewSpaceZ(item, viewMatrix)
        key.position = position
        key.entryIndex = blendedCount
      else
        wireframe[#wireframe + 1] = item
      end
    end
  end

  for index = 1, blendedCount do
    order[index] = index
  end
  for index = #order, blendedCount + 1, -1 do
    order[index] = nil
  end

  if blendedCount > 1 then
    table.sort(order, compare)
  end

  -- Order indexes double as unsorted-entry indexes: key slot i always
  -- describes entry i, so the sorted order maps directly to wrappers.
  for rank = 1, blendedCount do
    blended[rank] = unsorted[order[rank]]
  end
  for index = #blended, blendedCount + 1, -1 do
    blended[index] = nil
  end

  return scratch
end

return RenderQueue
