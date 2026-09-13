-- Resolves normalized field warp records into destination map coordinates and
-- terrain surfaces. Warp indexes are zero-based; event coordinates remain in
-- the authoritative global field domain. Scripted warps arrive as `direct`
-- records carrying pre-resolved global destination coordinates and resolve
-- through their own branch before any indexed-record dispatch. Warp *trigger*
-- semantics live in TransitionTrigger; this module only locates records and
-- resolves destinations.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")

local WarpSystem = {}

-- Dynamic-warp anchors: destinationWarpId 0x100 means the warp points at a
-- runtime-chosen destination (unsupported; kept as a loud rejection per the
-- field transition contract). The raw HGSS meaning is the dynamic-warp anchor;
-- real warps carry plain warp indexes, so this branch is a refusal, not a path.
WarpSystem.DYNAMIC_WARP_SENTINEL = 0x100

local WARP_Y_SCALE = 16

local function warps(runtimeMap)
  return assert(
    runtimeMap and runtimeMap.fieldData and runtimeMap.fieldData.events and runtimeMap.fieldData.events.warps,
    "runtime map warp data required"
  )
end

local function resolutionRecord(sourceMap, sourceWarp, destinationMap, destinationWarp, fieldX, fieldZ, sample)
  return {
    sourceMap = sourceMap,
    sourceWarp = sourceWarp,
    destinationMap = destinationMap,
    destinationWarp = destinationWarp,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = sample.surfaceId,
    worldY = sample.worldY,
    suppression = {
      mapId = destinationMap.mapId,
      fieldX = fieldX,
      fieldZ = fieldZ,
    },
  }
end

function WarpSystem.findAt(runtimeMap, fieldX, fieldZ)
  for _, warp in ipairs(warps(runtimeMap)) do
    if warp.x == fieldX and warp.z == fieldZ then
      return warp
    end
  end
  return nil
end

local function loadDestination(loader, sourceMap, warp)
  local ok, result = pcall(loader.load, loader, warp.destinationMapId)
  if ok then
    return result
  end
  if Errors.is(result) and result.code == FieldErrors.FIELD_MAP_UNKNOWN then
    Errors.raise(FieldErrors.FIELD_DESTINATION_MAP_UNKNOWN, "warp destination map is unavailable", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = warp.destinationMapId,
      cause = result.code,
    })
  end
  error(result)
end

-- The arrival surface of a scripted direct warp. An explicit record `y` wins
-- (the caller's intent), then the destination map's indexed warp named by the
-- record (its height is authoritative, exactly as in the indexed path), then
-- the topmost walkable terrain surface at the point. Never an unconditional
-- zero-height hint: that selects the wrong floor on vertically stacked maps.
---@param destinationMap table<string, unknown>
---@param warp table<string, unknown>
---@param localX number
---@param localZ number
---@return table<string, unknown> sample
local function directSurface(destinationMap, warp, localX, localZ)
  local x = localX + FieldCoordinates.TILE_CENTER_OFFSET
  local z = localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local hintY
  if type(warp.y) == "number" then
    hintY = warp.y
  else
    local destinationWarp = warps(destinationMap)[(warp.destinationWarpId or 0) + 1]
    if destinationWarp ~= nil and destinationWarp.index == (warp.destinationWarpId or 0) then
      hintY = destinationWarp.y / WARP_Y_SCALE
    end
  end
  if hintY ~= nil then
    return SurfaceResolver.new(destinationMap.terrain):resolve({ localX = x, localZ = z, currentY = hintY })
  end
  local best
  for _, plate in ipairs(destinationMap.terrain:candidatesAt(x, z)) do
    if plate.walkable ~= false then
      local sample = destinationMap.terrain:sample(plate.id, x, z)
      if best == nil or sample.worldY > best.worldY then
        best = sample
      end
    end
  end
  assert(best, "warp destination has no walkable terrain surface at its coordinates")
  return best
end

-- Shared destination coordinate selection for planning and resolution:
-- the global arrival coordinates and the selected destination warp record
-- for a source warp, preserving direct-before-dynamic-sentinel behavior
-- and indexed validation. Pure over already-loaded field data; height and
-- surface selection stay in resolveDestination.
---@param sourceMap table<string, unknown>
---@param warp table<string, unknown>
---@param destinationFieldData table<string, unknown>
---@return { fieldX: integer, fieldZ: integer, warp: table<string, unknown> }
function WarpSystem.destinationCoordinates(sourceMap, warp, destinationFieldData)
  assert(sourceMap and sourceMap.mapId and warp, "source map and warp required")
  assert(
    destinationFieldData and destinationFieldData.events and destinationFieldData.events.warps,
    "destination field warp data required"
  )
  -- A scripted `direct` record carries pre-resolved global coordinates and
  -- selects itself before every indexed-path dispatch, including the
  -- dynamic-warp refusal.
  if warp.direct then
    assert(type(warp.x) == "number" and type(warp.z) == "number", "direct warp carries global coordinates")
    return { fieldX = warp.x, fieldZ = warp.z, warp = warp }
  end
  if warp.destinationWarpId == WarpSystem.DYNAMIC_WARP_SENTINEL then
    Errors.raise(FieldErrors.FIELD_DYNAMIC_WARP_UNSUPPORTED, "dynamic warp anchors are not supported", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = warp.destinationMapId,
      destinationWarpId = warp.destinationWarpId,
    })
  end
  local destinationWarps = destinationFieldData.events.warps
  local destinationWarp = destinationWarps[warp.destinationWarpId + 1]
  if not destinationWarp or destinationWarp.index ~= warp.destinationWarpId then
    Errors.raise(FieldErrors.FIELD_DESTINATION_WARP_UNKNOWN, "destination warp index is unavailable", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = warp.destinationMapId,
      destinationWarpId = warp.destinationWarpId,
    })
  end
  return { fieldX = destinationWarp.x, fieldZ = destinationWarp.z, warp = destinationWarp }
end

function WarpSystem.resolveDestination(loader, sourceMap, warp)
  assert(loader and loader.load, "warp destination loader required")
  assert(sourceMap and sourceMap.mapId and warp, "source map and warp required")

  -- A scripted `direct` record carries pre-resolved global coordinates and
  -- resolves its own warp instead of an indexed destination record. It
  -- loads through the same unknown-destination-map wrap as the indexed path
  -- (one standardized code) and must precede every indexed-path dispatch,
  -- including the dynamic-warp refusal.
  if warp.direct then
    local destinationMap = loadDestination(loader, sourceMap, warp)
    local coordinates = WarpSystem.destinationCoordinates(sourceMap, warp, assert(destinationMap.fieldData))
    local localX, localZ = FieldCoordinates.fieldToLocal(destinationMap, coordinates.fieldX, coordinates.fieldZ)
    local sample = directSurface(destinationMap, warp, localX, localZ)
    -- The direct record is the source trigger and the destination record in
    -- one table: it carries the pre-resolved destination coordinates.
    local destinationRecord = coordinates.warp
    return resolutionRecord(
      sourceMap,
      warp,
      destinationMap,
      destinationRecord,
      coordinates.fieldX,
      coordinates.fieldZ,
      sample
    )
  end
  if warp.destinationWarpId == WarpSystem.DYNAMIC_WARP_SENTINEL then
    Errors.raise(FieldErrors.FIELD_DYNAMIC_WARP_UNSUPPORTED, "dynamic warp anchors are not supported", {
      sourceMapId = sourceMap.mapId,
      sourceWarpId = warp.index,
      destinationMapId = warp.destinationMapId,
      destinationWarpId = warp.destinationWarpId,
    })
  end

  local destinationMap = loadDestination(loader, sourceMap, warp)
  local coordinates = WarpSystem.destinationCoordinates(sourceMap, warp, assert(destinationMap.fieldData))
  local destinationWarp = coordinates.warp

  local localX, localZ = FieldCoordinates.fieldToLocal(destinationMap, coordinates.fieldX, coordinates.fieldZ)
  local hintY = destinationWarp.y / WARP_Y_SCALE
  local sample = SurfaceResolver.new(destinationMap.terrain):resolve({
    localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    currentY = hintY,
  })
  return resolutionRecord(
    sourceMap,
    warp,
    destinationMap,
    destinationWarp,
    coordinates.fieldX,
    coordinates.fieldZ,
    sample
  )
end

function WarpSystem.isSuppressed(token, mapId, fieldX, fieldZ)
  return token ~= nil and token.mapId == mapId and token.fieldX == fieldX and token.fieldZ == fieldZ
end

function WarpSystem.updateSuppression(token, mapId, fieldX, fieldZ)
  if WarpSystem.isSuppressed(token, mapId, fieldX, fieldZ) then
    return token
  end
  return nil
end

return WarpSystem
