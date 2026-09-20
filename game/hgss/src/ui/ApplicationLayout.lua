-- Pure product layout defaults over actual display measurements. Classification
-- is one shared tolerant contract (near-4:3 stays fullscreen inside a
-- 12-logical-pixel entry band with 14-pixel retain hysteresis; anything else
-- is wide or tall; a genuine world/auxiliary role pair is dual), and the
-- single/dual/static-frame helpers fit native panes with the shared logical-surface policy.
-- No gameplay, no resources, no application state: every helper takes plain
-- records and returns fresh geometry records only.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PixelScale = require("libs.ui.src.PixelScale")

---@class ApplicationLayout
local ApplicationLayout = {}

local NATIVE_WIDTH = 256
local NATIVE_HEIGHT = 192
local ENTER_TOLERANCE = 12
local RETAIN_TOLERANCE = 14

---@param value unknown
---@param name string
local function assertSurfaceRecord(value, name)
  assert(type(value) == "table", name .. " must be a surface record")
  assert(type(value.id) == "string" and value.id ~= "", name .. " needs a surface id")
end

---@param measurement table<string, unknown>
---@return ScreenTopology.Surface[]
local function measurementSurfaces(measurement)
  assert(type(measurement) == "table", "classification requires a display measurement")
  local topology = assert(measurement.topology, "the measurement must carry its topology")
  assert(
    type(topology) == "table" and type(topology.surfaces) == "table",
    "the measurement topology must carry surfaces"
  )
  assert(#topology.surfaces > 0, "classification requires at least one surface")
  return topology.surfaces
end

-- The tolerant configuration: a genuine world/auxiliary role pair is dual
-- before any aspect heuristic; otherwise the chosen world safe rectangle
-- (or first surface) is measured against the 4:3 native frame with a
-- relative logical aspect error per edge. Fresh entry needs the 12px band;
-- a retained native surface holds through 14px. Outside the band, wide is
-- wider than 4:3 and everything else is tall. Portrait reservations never
-- change classification, only the fitting region.
---@param measurement DisplayMeasurement
---@param previousConfiguration string?
---@return string configuration one of dualDisplay, nativeLike, wide, tall
function ApplicationLayout.classify(measurement, previousConfiguration)
  local surfaces = measurementSurfaces(measurement)
  local world
  local auxiliary
  for _, surface in ipairs(surfaces) do
    if world == nil and surface.role == "world" then
      world = surface
    end
    if auxiliary == nil and surface.role == "auxiliary" then
      auxiliary = surface
    end
  end
  if world ~= nil and auxiliary ~= nil then
    return "dualDisplay"
  end
  local chosen = world or surfaces[1]
  local safe = chosen.safeRect or chosen.rect
  assert(
    type(safe) == "table" and type(safe.width) == "number" and type(safe.height) == "number",
    "the classified surface needs its safe rectangle"
  )
  assert(safe.width > 0 and safe.height > 0, "the classified surface needs positive dimensions")
  local ratio = safe.width / safe.height
  local threshold = 4 / 3
  local error
  if ratio >= threshold then
    error = (NATIVE_HEIGHT * ratio - NATIVE_WIDTH) / 2
  else
    error = (NATIVE_WIDTH / ratio - NATIVE_HEIGHT) / 2
  end
  local native
  if previousConfiguration == "nativeLike" then
    native = error <= RETAIN_TOLERANCE
  else
    native = error <= ENTER_TOLERANCE
  end
  if native then
    return "nativeLike"
  end
  if ratio > threshold then
    return "wide"
  end
  return "tall"
end

---@param a number
---@param b number
---@param c number
---@param d number
---@return boolean
local function overlaps(a, b, c, d)
  return a < d and c < b
end

-- The usable fitting region: the largest axis-aligned rectangle inside the
-- safe area that overlaps no reservation. Candidates enumerate from safe
-- and reservation x/y edges; the winner is maximum area, then closest
-- centre to the safe centre, then lower x, then lower y. A fully occupied
-- surface is temporarily not presentable and yields nil without failing:
-- semantic state is retained and the leaf publishes an inactive plan.
---@param surface ScreenTopology.Surface
---@return LayoutGeometry.Rect?
function ApplicationLayout.usableBounds(surface)
  assertSurfaceRecord(surface, "usable bounds")
  local safe = LayoutGeometry.rect(surface.safeRect or surface.rect, "safeRect")
  local occupied = surface.occupiedRegions or {}
  local xEdges = { safe.x }
  local xEnds = { safe.x + safe.width }
  local yEdges = { safe.y }
  local yEnds = { safe.y + safe.height }
  for _, region in ipairs(occupied) do
    local rect = LayoutGeometry.rect(region, "occupiedRegions")
    xEdges[#xEdges + 1] = rect.x + rect.width
    xEnds[#xEnds + 1] = rect.x
    yEdges[#yEdges + 1] = rect.y + rect.height
    yEnds[#yEnds + 1] = rect.y
  end
  local safeCenterX = safe.x + safe.width / 2
  local safeCenterY = safe.y + safe.height / 2
  local best
  local bestArea = 0
  local bestDistance = math.huge
  for _, x1 in ipairs(xEdges) do
    for _, x2 in ipairs(xEnds) do
      if x1 < x2 and x1 >= safe.x and x2 <= safe.x + safe.width then
        for _, y1 in ipairs(yEdges) do
          for _, y2 in ipairs(yEnds) do
            if y1 < y2 and y1 >= safe.y and y2 <= safe.y + safe.height then
              local blocked = false
              for _, region in ipairs(occupied) do
                local rect = region --[[@as LayoutGeometry.Rect]]
                if overlaps(x1, x2, rect.x, rect.x + rect.width) and overlaps(y1, y2, rect.y, rect.y + rect.height) then
                  blocked = true
                  break
                end
              end
              if not blocked then
                local area = (x2 - x1) * (y2 - y1)
                local centerDistance = math.abs((x1 + x2) / 2 - safeCenterX) + math.abs((y1 + y2) / 2 - safeCenterY)
                if
                  area > bestArea
                  or (area == bestArea and centerDistance < bestDistance)
                  or (
                    area == bestArea
                    and centerDistance == bestDistance
                    and (best == nil or x1 < best.x or (x1 == best.x and y1 < best.y))
                  )
                then
                  best = { x = x1, y = y1, width = x2 - x1, height = y2 - y1 }
                  bestArea = area
                  bestDistance = centerDistance
                end
              end
            end
          end
        end
      end
    end
  end
  return best
end

---@class ApplicationLayout.SurfaceSelection
---@field surface ScreenTopology.Surface
---@field usableBounds LayoutGeometry.Rect?

---@class ApplicationLayout.Selection
---@field primary ApplicationLayout.SurfaceSelection the selected world surface, or the first surface
---@field secondary ApplicationLayout.SurfaceSelection? the selected auxiliary record, set only for a genuine pair

-- The selected surfaces behind one measurement: the first world surface in
-- stable topology order (or the first surface) is primary; the first
-- auxiliary surface joins it only when a genuine world/auxiliary pair is
-- present. Each record carries its usable fitting region, nil only when
-- reservations leave no drawable rectangle.
---@param measurement DisplayMeasurement
---@return ApplicationLayout.Selection
function ApplicationLayout.selectSurfaces(measurement)
  local surfaces = measurementSurfaces(measurement)
  local world
  local auxiliary
  for _, surface in ipairs(surfaces) do
    if world == nil and surface.role == "world" then
      world = surface
    end
    if auxiliary == nil and surface.role == "auxiliary" then
      auxiliary = surface
    end
  end
  local primarySurface = world or surfaces[1]
  local selection = {
    primary = {
      surface = primarySurface,
      usableBounds = ApplicationLayout.usableBounds(primarySurface),
    },
  }
  if world ~= nil and auxiliary ~= nil then
    selection.secondary = {
      surface = auxiliary,
      usableBounds = ApplicationLayout.usableBounds(auxiliary),
    }
  end
  return selection
end

---@class ApplicationLayout.Native
---@field id string application-local native pane identity
---@field width integer native logical width
---@field height integer native logical height

---@class ApplicationLayout.FixedFitOptions
---@field preferredScale integer?
---@field maxOverdraw { left: integer, right: integer, top: integer, bottom: integer }?
---@field protectedRect LayoutGeometry.Rect?

---@param native ApplicationLayout.Native
---@param what string
local function assertNative(native, what)
  assert(type(native) == "table" and type(native.id) == "string" and native.id ~= "", what .. " needs a pane id")
  assert(
    type(native.width) == "number" and native.width > 0 and native.width == math.floor(native.width),
    what .. " needs a positive integral width"
  )
  assert(
    type(native.height) == "number" and native.height > 0 and native.height == math.floor(native.height),
    what .. " needs a positive integral height"
  )
end

---@param context ApplicationLayout.Context
---@return number pixelRatio
local function contextRatio(context)
  assert(type(context) == "table" and type(context.measurement) == "table", "layout helpers require a context")
  local ratio = context.measurement.pixelRatio
  assert(type(ratio) == "number" and ratio == ratio and ratio > 0, "the context measurement needs its pixel ratio")
  return ratio
end

---@class ApplicationLayout.Context
---@field measurement DisplayMeasurement
---@field configuration string
---@field primary ApplicationLayout.SurfaceSelection
---@field secondary ApplicationLayout.SurfaceSelection?
---@field nativeLikeInterface fun(context: ApplicationLayout.Context, view: table<string, unknown>): table<string, unknown>

---@class ApplicationLayout.FrameGeometry
---@field placement LayoutGeometry.Placement complete outer frame placement
---@field contentBox LayoutGeometry.Rect logical content box inside the frame

---@class ApplicationLayout.Geometry
---@field placements table<string, LayoutGeometry.Placement> complete placements by native pane id
---@field fadeCoverage LayoutGeometry.Rect[] transition-only host regions, never settled paint
---@field frames ApplicationLayout.FrameGeometry[]? pure outer-frame geometry, empty when unframed
---@field envelope LayoutGeometry.Placement? common pair-envelope placement for one-display pairs

---@param bounds LayoutGeometry.Rect
---@return LayoutGeometry.Rect
local function copyRect(bounds)
  return { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height }
end

---@return ApplicationLayout.Geometry empty geometry for temporarily unavailable space, never nil
local function emptyGeometry()
  return { placements = {}, fadeCoverage = {}, frames = {} }
end

---@param options ApplicationLayout.FixedFitOptions?
---@return integer? preferredScale
---@return { left: integer, right: integer, top: integer, bottom: integer }? maxOverdraw
---@return LayoutGeometry.Rect? protectedRect
local function fitOptions(options)
  if options == nil then
    return nil, nil, nil
  end
  assert(type(options) == "table", "fit options must be a record")
  return options.preferredScale, options.maxOverdraw, options.protectedRect
end

-- Fullscreen ownership of one target region: the auxiliary usable region on
-- a genuine pair, the selected single surface otherwise. Fade coverage names
-- the usable region for transition overlays only. Unavailable space yields an
-- empty geometry record the leaf turns into an inactive plan.
---@param context ApplicationLayout.Context
---@param native ApplicationLayout.Native
---@param options ApplicationLayout.FixedFitOptions?
---@return ApplicationLayout.Geometry
function ApplicationLayout.fullscreen(context, native, options)
  assertNative(native, "fullscreen")
  local ratio = contextRatio(context)
  local target = context.secondary or context.primary
  assert(target ~= nil, "fullscreen requires its target surface")
  if target.usableBounds == nil then
    return emptyGeometry()
  end
  local bounds = assert(target.usableBounds, "fullscreen requires drawable space")
  local preferredScale, maxOverdraw, protectedRect = fitOptions(options)
  local placement = PixelScale.placeFixed(bounds, native.width, native.height, {
    pixelRatio = ratio,
    preferredScale = preferredScale,
    maxOverdraw = maxOverdraw,
    protectedRect = protectedRect,
  })
  if placement == nil then
    return emptyGeometry()
  end
  return {
    placements = { [native.id] = placement },
    fadeCoverage = { copyRect(bounds) },
    frames = {},
  }
end

---@param placement LayoutGeometry.Placement
---@return boolean true when the fit holds an integer scale at or above 1x
local function fitsInteger(placement)
  return placement.pixelScale ~= nil and placement.pixelScale >= 1
end

-- Static framed box inside the primary drawable: the complete rotated outer
-- frame (content plus 8/24/8/16) fits with zero crop at the largest allowed
-- physical integer scale, centered. The body derives from the outer frame
-- at the rotated content origin. Returns nil when no complete 1x frame
-- fits and the leaf must fall back to its effective nativeLike case.
---@param context ApplicationLayout.Context
---@param native ApplicationLayout.Native
---@param options ApplicationLayout.FixedFitOptions?
---@return ApplicationLayout.Geometry?
function ApplicationLayout.framed(context, native, options)
  assertNative(native, "framed")
  local ratio = contextRatio(context)
  local primary = assert(context.primary, "framed requires its primary surface")
  local usable = primary.usableBounds
  if usable == nil then
    return emptyGeometry()
  end
  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local insets = FieldDialogueTheme.applicationFrameInsets()
  local outerWidth = native.width + insets.left + insets.right
  local outerHeight = native.height + insets.top + insets.bottom
  local preferredScale, _, _ = fitOptions(options)
  local outer = PixelScale.placeFixed(usable, outerWidth, outerHeight, {
    pixelRatio = ratio,
    preferredScale = preferredScale,
    maxOverdraw = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  if outer == nil or not fitsInteger(outer) then
    return nil
  end
  local body = assert(
    LayoutGeometry.subPlacement(
      outer,
      { x = insets.left, y = insets.top, width = native.width, height = native.height }
    ),
    "the framed body must fit its outer frame"
  )
  local frame = {
    placement = outer,
    contentBox = { x = insets.left, y = insets.top, width = native.width, height = native.height },
  }
  return {
    placements = { [native.id] = body },
    fadeCoverage = {},
    frames = { frame },
  }
end

-- Undecorated centered pane at integer scale with zero crop. Naming uses
-- this helper for wide/tall only. Returns nil below 1x.
---@param context ApplicationLayout.Context
---@param native ApplicationLayout.Native
---@param options ApplicationLayout.FixedFitOptions?
---@return ApplicationLayout.Geometry?
function ApplicationLayout.centered(context, native, options)
  assertNative(native, "centered")
  local ratio = contextRatio(context)
  local primary = assert(context.primary, "centered requires its primary surface")
  local usable = primary.usableBounds
  if usable == nil then
    return emptyGeometry()
  end
  local preferredScale, _, _ = fitOptions(options)
  local placement = PixelScale.placeFixed(usable, native.width, native.height, {
    pixelRatio = ratio,
    preferredScale = preferredScale,
    maxOverdraw = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  if placement == nil or not fitsInteger(placement) then
    return nil
  end
  return {
    placements = { [native.id] = placement },
    fadeCoverage = {},
    frames = {},
  }
end

---@param a LayoutGeometry.Rect
---@param b LayoutGeometry.Rect
---@return LayoutGeometry.Rect? the intersection; nil when the rectangles do not overlap
local function intersectHost(a, b)
  local x = math.max(a.x, b.x)
  local y = math.max(a.y, b.y)
  local farX = math.min(a.x + a.width, b.x + b.width)
  local farY = math.min(a.y + a.height, b.y + b.height)
  if farX <= x or farY <= y then
    return nil
  end
  return { x = x, y = y, width = farX - x, height = farY - y }
end

-- Outer frame around an already-resolved content placement at the same
-- scale: nil when the placement's visible clip already equals the target
-- bounds, otherwise the outer frame clipped to the target. Never moves or
-- resizes resolved content; frame clipping may remove decoration only.
---@param bounds LayoutGeometry.Rect target usable bounds
---@param placement LayoutGeometry.Placement already-resolved content placement
---@return ApplicationLayout.FrameGeometry?
function ApplicationLayout.frameAround(bounds, placement)
  local target = LayoutGeometry.rect(bounds, "bounds")
  LayoutGeometry.validatePlacement(placement, "placement")
  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local insets = FieldDialogueTheme.applicationFrameInsets()
  local clip = placement.clipRect or placement.frame
  if clip.x == target.x and clip.y == target.y and clip.width == target.width and clip.height == target.height then
    return nil
  end
  local scale = assert(placement.scale, "frameAround requires the content scale")
  local logicalWidth = assert(placement.logicalWidth, "frameAround requires content logical dimensions")
  local logicalHeight = assert(placement.logicalHeight, "frameAround requires content logical dimensions")
  local frame = placement.frame
  local outerFrame = {
    x = frame.x - insets.left * scale,
    y = frame.y - insets.top * scale,
    width = (logicalWidth + insets.left + insets.right) * scale,
    height = (logicalHeight + insets.top + insets.bottom) * scale,
  }
  local outerOrigin = { x = outerFrame.x, y = outerFrame.y }
  local outerClip = intersectHost(target, outerFrame)
  if outerClip == nil then
    return nil
  end
  local outer = {
    frame = outerFrame,
    origin = outerOrigin,
    scale = scale,
    logicalWidth = logicalWidth + insets.left + insets.right,
    logicalHeight = logicalHeight + insets.top + insets.bottom,
    clipRect = outerClip,
  }
  if placement.pixelScale ~= nil then
    outer.pixelScale = placement.pixelScale
  end
  if placement.pixelRatio ~= nil then
    outer.pixelRatio = placement.pixelRatio
  end
  return {
    placement = outer,
    contentBox = { x = insets.left, y = insets.top, width = logicalWidth, height = logicalHeight },
  }
end

-- Physical dual mapping: the upper native pane fits the world usable
-- region and the lower fits the auxiliary region, each with its own
-- integer fit. The two mappings never collapse to one pane merely because
-- their scales differ.
---@param context ApplicationLayout.Context
---@param upperNative ApplicationLayout.Native
---@param lowerNative ApplicationLayout.Native
---@param options { upper: ApplicationLayout.FixedFitOptions?, lower: ApplicationLayout.FixedFitOptions? }?
---@return ApplicationLayout.Geometry
function ApplicationLayout.nativeDual(context, upperNative, lowerNative, options)
  assertNative(upperNative, "nativeDual upper")
  assertNative(lowerNative, "nativeDual lower")
  assert(upperNative.id ~= lowerNative.id, "a pair needs distinct pane ids")
  local ratio = contextRatio(context)
  local primary = assert(context.primary, "nativeDual requires its world surface")
  local secondary = assert(context.secondary, "nativeDual requires its auxiliary surface")
  local worldBounds = primary.usableBounds
  local auxBounds = secondary.usableBounds
  if worldBounds == nil or auxBounds == nil then
    return emptyGeometry()
  end
  options = options or {}
  assert(type(options) == "table", "nativeDual options must be a record")
  local upperFit = options.upper or {}
  local lowerFit = options.lower or {}
  local upper = PixelScale.placeFixed(worldBounds, upperNative.width, upperNative.height, {
    pixelRatio = ratio,
    preferredScale = upperFit.preferredScale,
    maxOverdraw = upperFit.maxOverdraw,
    protectedRect = upperFit.protectedRect,
  })
  local lower = PixelScale.placeFixed(auxBounds, lowerNative.width, lowerNative.height, {
    pixelRatio = ratio,
    preferredScale = lowerFit.preferredScale,
    maxOverdraw = lowerFit.maxOverdraw,
    protectedRect = lowerFit.protectedRect,
  })
  if upper == nil or lower == nil then
    return emptyGeometry()
  end
  return {
    placements = { [upperNative.id] = upper, [lowerNative.id] = lower },
    fadeCoverage = { copyRect(worldBounds), copyRect(auxBounds) },
    frames = {},
  }
end

---@param envelopeWidth number
---@param envelopeHeight number
---@param upperNative ApplicationLayout.Native
---@param lowerNative ApplicationLayout.Native
---@param horizontal boolean
---@return LayoutGeometry.Rect upperRect
---@return LayoutGeometry.Rect lowerRect
local function pairRects(envelopeWidth, envelopeHeight, upperNative, lowerNative, horizontal)
  if horizontal then
    local upper =
      { x = 0, y = (envelopeHeight - upperNative.height) / 2, width = upperNative.width, height = upperNative.height }
    local lower = {
      x = upperNative.width,
      y = (envelopeHeight - lowerNative.height) / 2,
      width = lowerNative.width,
      height = lowerNative.height,
    }
    return upper, lower
  end
  local upper =
    { x = (envelopeWidth - upperNative.width) / 2, y = 0, width = upperNative.width, height = upperNative.height }
  local lower = {
    x = (envelopeWidth - lowerNative.width) / 2,
    y = upperNative.height,
    width = lowerNative.width,
    height = lowerNative.height,
  }
  return upper, lower
end

-- One-display pair composition: a single integer fit of the combined
-- logical envelope (upper left/lower right, or upper above/lower below)
-- with zero crop and no synthetic gap, then subPlacement for each pane. The panes never fit independently and never stretch unequally.
-- Returns nil when the envelope cannot fit 1x and the leaf must fall back
-- to its nativeLike case.
---@param context ApplicationLayout.Context
---@param upperNative ApplicationLayout.Native
---@param lowerNative ApplicationLayout.Native
---@param options { upper: ApplicationLayout.FixedFitOptions?, lower: ApplicationLayout.FixedFitOptions? }?
---@param horizontal boolean
---@return ApplicationLayout.Geometry?
local function composedPair(context, upperNative, lowerNative, options, horizontal)
  assertNative(upperNative, "composed pair upper")
  assertNative(lowerNative, "composed pair lower")
  assert(upperNative.id ~= lowerNative.id, "a pair needs distinct pane ids")
  local ratio = contextRatio(context)
  local primary = assert(context.primary, "a composed pair requires its primary surface")
  local usable = primary.usableBounds
  if usable == nil then
    return emptyGeometry()
  end
  options = options or {}
  assert(type(options) == "table", "pair options must be a record")
  local upperFit = options.upper or {}
  local lowerFit = options.lower or {}
  local cap
  if upperFit.preferredScale ~= nil and lowerFit.preferredScale ~= nil then
    cap = math.min(upperFit.preferredScale, lowerFit.preferredScale)
  else
    cap = upperFit.preferredScale or lowerFit.preferredScale
  end
  local envelopeWidth
  local envelopeHeight
  if horizontal then
    envelopeWidth = upperNative.width + lowerNative.width
    envelopeHeight = math.max(upperNative.height, lowerNative.height)
  else
    envelopeWidth = math.max(upperNative.width, lowerNative.width)
    envelopeHeight = upperNative.height + lowerNative.height
  end
  local envelope = PixelScale.placeFixed(usable, envelopeWidth, envelopeHeight, {
    pixelRatio = ratio,
    preferredScale = cap,
    maxOverdraw = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  if envelope == nil or not fitsInteger(envelope) then
    return nil
  end
  local upperRect, lowerRect = pairRects(envelopeWidth, envelopeHeight, upperNative, lowerNative, horizontal)
  local upper = assert(LayoutGeometry.subPlacement(envelope, upperRect), "the upper pane must fit its envelope")
  local lower = assert(LayoutGeometry.subPlacement(envelope, lowerRect), "the lower pane must fit its envelope")
  return {
    placements = { [upperNative.id] = upper, [lowerNative.id] = lower },
    fadeCoverage = { copyRect(usable) },
    frames = {},
    envelope = envelope,
  }
end

-- Side-by-side panes on one display: info/upper left, machine/lower right.
---@param context ApplicationLayout.Context
---@param upperNative ApplicationLayout.Native
---@param lowerNative ApplicationLayout.Native
---@param options { upper: ApplicationLayout.FixedFitOptions?, lower: ApplicationLayout.FixedFitOptions? }?
---@return ApplicationLayout.Geometry?
function ApplicationLayout.sideBySide(context, upperNative, lowerNative, options)
  return composedPair(context, upperNative, lowerNative, options, true)
end

-- Stacked panes on one display: info/upper above, machine/lower below.
---@param context ApplicationLayout.Context
---@param upperNative ApplicationLayout.Native
---@param lowerNative ApplicationLayout.Native
---@param options { upper: ApplicationLayout.FixedFitOptions?, lower: ApplicationLayout.FixedFitOptions? }?
---@return ApplicationLayout.Geometry?
function ApplicationLayout.stacked(context, upperNative, lowerNative, options)
  return composedPair(context, upperNative, lowerNative, options, false)
end

return ApplicationLayout
