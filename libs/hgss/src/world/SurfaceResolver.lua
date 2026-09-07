-- Selects a reachable BDHC surface at a destination point. Compatibility
-- policy for overlaps is continuity first, then unique nearest height; exact
-- ties raise instead of silently choosing highest/lowest. A crossing onto a
-- new surface is allowed when the destination surface's height at the shared
-- edge stays within the step-height limit of the current surface's height
-- there. The limit is the pinned movement collision's (asm/unk_02054648.s
-- `sub_02054954`: 5 << 14 in 16.16 tile units, i.e. 1.25 tiles): only steps
-- changing height by 1.25 tiles or more are rejected. No plane-join epsilon
-- is applied -- real ROM floors (e.g. MAP_NEW_BARK_PLAYER_HOUSE_1F) have
-- quantized-height seams between adjacent plates. Pure domain module.
--
-- TERRAIN_SURFACE_DISCONNECTED raises carry a `kind` discriminator:
-- "step-beyond" is an ordinary step-height rejection (a legal move the world
-- refuses), while "current-inconsistent" means the current surface disagrees
-- with the player's own position or the crossing edge -- corrupted terrain
-- that callers must propagate rather than treat as a blocked step.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class SurfaceResolver
---@field terrain TerrainSurface
---@field stepHeightLimit number
local SurfaceResolver = {}
SurfaceResolver.__index = SurfaceResolver

-- Maximum step-up height in world units (1 unit == 1 tile). Mirrors the
-- original movement collision's step check (asm/unk_02054648.s
-- `sub_02054954`), which rejects a destination surface whose height differs
-- from the current height by 5 << 14 in 16.16 fixed-point tile units.
local STEP_HEIGHT_LIMIT = 5 * 2 ^ 14 / 2 ^ 16
local HEIGHT_TIE_EPSILON = 1e-9

-- True when the error is an ordinary step rejection (the destination surface
-- is beyond the reachable step height) rather than corrupted or ambiguous
-- terrain. The movement and interaction whitelists accept exactly this
-- TERRAIN_SURFACE_DISCONNECTED variant as a normal rejection.
---@param err unknown
---@return boolean
function SurfaceResolver.isStepRejection(err)
  return Errors.is(err) and err.code == FieldErrors.TERRAIN_SURFACE_DISCONNECTED and err.context.kind == "step-beyond"
end

function SurfaceResolver.new(terrain, opts)
  assert(terrain and terrain.candidatesAt and terrain.sampleHeight, "SurfaceResolver.new requires a TerrainSurface")
  opts = opts or {}
  return setmetatable(
    { terrain = terrain, stepHeightLimit = opts.stepHeightLimit or STEP_HEIGHT_LIMIT },
    SurfaceResolver
  )
end

local function raise(code, message, opts, extra)
  extra = extra or {}
  extra.localX = opts.localX
  extra.localZ = opts.localZ
  extra.currentSurfaceId = opts.currentSurfaceId
  Errors.raise(code, message, extra)
end

local function closestUnique(terrain, candidates, localX, localZ, currentY, opts)
  if #candidates == 1 then
    return candidates[1]
  end
  if currentY == nil then
    raise(
      FieldErrors.TERRAIN_SURFACE_AMBIGUOUS,
      "multiple terrain surfaces cover the coordinate",
      opts,
      { candidateCount = #candidates }
    )
  end
  local best, bestDelta, tied
  for _, plate in ipairs(candidates) do
    local delta = math.abs(terrain:sampleHeight(plate.id, localX, localZ) - currentY)
    if not bestDelta or delta < bestDelta - HEIGHT_TIE_EPSILON then
      best, bestDelta, tied = plate, delta, false
    elseif math.abs(delta - bestDelta) <= HEIGHT_TIE_EPSILON then
      tied = true
    end
  end
  if tied then
    raise(
      FieldErrors.TERRAIN_SURFACE_AMBIGUOUS,
      "equally near terrain surfaces cover the coordinate",
      opts,
      { candidateCount = #candidates, heightDelta = bestDelta }
    )
  end
  return best
end

function SurfaceResolver:resolve(opts)
  assert(type(opts) == "table", "SurfaceResolver.resolve requires options")
  assert(type(opts.localX) == "number" and type(opts.localZ) == "number", "destination coordinates must be numbers")
  local candidates = self.terrain:candidatesAt(opts.localX, opts.localZ)
  if #candidates == 0 then
    raise(FieldErrors.TERRAIN_SURFACE_NOT_FOUND, "no terrain surface covers the coordinate", opts)
  end

  local current = opts.currentSurfaceId ~= nil and self.terrain:plate(opts.currentSurfaceId) or nil
  if opts.currentSurfaceId ~= nil and not current then
    raise(FieldErrors.TERRAIN_SURFACE_NOT_FOUND, "current terrain surface does not exist", opts)
  end

  if current and opts.crossing then
    local crossing = opts.crossing
    assert(
      type(crossing.fromX) == "number"
        and type(crossing.fromZ) == "number"
        and type(crossing.toX) == "number"
        and type(crossing.toZ) == "number",
      "crossing requires numeric endpoints"
    )
    if not self.terrain:contains(current.id, crossing.fromX, crossing.fromZ) then
      raise(
        FieldErrors.TERRAIN_SURFACE_DISCONNECTED,
        "current surface does not cover the crossing source",
        opts,
        { kind = "current-inconsistent", fromX = crossing.fromX, fromZ = crossing.fromZ }
      )
    end
  end

  if current and self.terrain:contains(current.id, opts.localX, opts.localZ) then
    return self.terrain:sample(current.id, opts.localX, opts.localZ)
  end

  local eligible = candidates
  if current and opts.crossing then
    local crossing = opts.crossing
    local edgeX = (crossing.fromX + crossing.toX) / 2
    local edgeZ = (crossing.fromZ + crossing.toZ) / 2
    if not self.terrain:contains(current.id, edgeX, edgeZ) then
      raise(
        FieldErrors.TERRAIN_SURFACE_DISCONNECTED,
        "current surface does not reach the shared edge",
        opts,
        { kind = "current-inconsistent", edgeX = edgeX, edgeZ = edgeZ }
      )
    end
    local sourceY = self.terrain:sampleHeight(current.id, edgeX, edgeZ)
    eligible = {}
    for _, plate in ipairs(candidates) do
      if self.terrain:contains(plate.id, edgeX, edgeZ) then
        local destinationY = self.terrain:sampleHeight(plate.id, edgeX, edgeZ)
        if math.abs(sourceY - destinationY) < self.stepHeightLimit then
          eligible[#eligible + 1] = plate
        end
      end
    end
    if #eligible == 0 then
      raise(
        FieldErrors.TERRAIN_SURFACE_DISCONNECTED,
        "destination surfaces are a step beyond the current surface",
        opts,
        { kind = "step-beyond", edgeX = edgeX, edgeZ = edgeZ, stepHeightLimit = self.stepHeightLimit }
      )
    end
  end

  local selected = closestUnique(self.terrain, eligible, opts.localX, opts.localZ, opts.currentY, opts)
  return self.terrain:sample(selected.id, opts.localX, opts.localZ)
end

return SurfaceResolver
