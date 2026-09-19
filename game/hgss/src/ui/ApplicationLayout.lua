-- Pure product layout defaults over actual display measurements. Classification
-- is one shared tolerant contract (near-4:3 stays fullscreen inside a
-- 12-logical-pixel entry band with 14-pixel retain hysteresis; anything else
-- is wide or tall; a genuine world/auxiliary role pair is dual), and the
-- single/dual/window helpers fit native panes with the shared logical-surface policy.
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
local PAIR_GAP = 8

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
---@field windowPosition { x: number, y: number } copied normalized wide/tall position
---@field nativeLikeInterface fun(context: ApplicationLayout.Context, view: table<string, unknown>): table<string, unknown>

---@class ApplicationLayout.Geometry
---@field placements table<string, LayoutGeometry.Placement> complete placements by native pane id
---@field coverage LayoutGeometry.Rect[] host regions the interface owns opaquely
---@field window ApplicationLayout.WindowGeometry?

---@class ApplicationLayout.WindowGeometry
---@field outer LayoutGeometry.Placement complete outer frame placement
---@field body LayoutGeometry.Placement complete content placement derived at (1,13,W,H)
---@field grabRect LayoutGeometry.Rect host-space title-strip rectangle derived from source (1,1,W,12)

---@param bounds LayoutGeometry.Rect
---@return LayoutGeometry.Rect
local function copyRect(bounds)
  return { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height }
end

---@return ApplicationLayout.Geometry empty geometry for temporarily unavailable space, never nil
local function emptyGeometry()
  return { placements = {}, coverage = {} }
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
-- a genuine pair, the selected single surface otherwise. Coverage is the
-- usable region itself, matte included. Unavailable space yields an empty
-- geometry record the leaf turns into an inactive plan.
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
    coverage = { copyRect(bounds) },
  }
end

---@param placement LayoutGeometry.Placement
---@return boolean true when the fit holds an integer scale at or above 1x
local function fitsInteger(placement)
  return placement.pixelScale ~= nil and placement.pixelScale >= 1
end

---@param value number
---@param ratio number
---@return number snapped host coordinate
local function snapPhysical(value, ratio)
  return math.floor(value * ratio) / ratio
end

-- A draggable window inside the existing drawable: content W x H with a
-- 1-logical-pixel border and a 12-pixel title/grab strip, so the outer
-- frame is (W+2) x (H+14) fitted with zero crop. The preferred initial size
-- is the largest integer scale inside a centred 80% rectangle; when even
-- that misses 1x the whole available bounds are used. The remembered
-- normalized position places the frame (default centres); the whole outer
-- frame stays clamped to the usable bounds with its origin on the physical
-- grid. Cropping is disabled in windows. Returns nil only when the outer
-- frame cannot fit 1x and the leaf must fall back to its nativeLike case.
---@param context ApplicationLayout.Context
---@param native ApplicationLayout.Native
---@param options ApplicationLayout.FixedFitOptions?
---@return ApplicationLayout.Geometry?
function ApplicationLayout.windowed(context, native, options)
  assertNative(native, "windowed")
  local ratio = contextRatio(context)
  local primary = assert(context.primary, "windowed requires its primary surface")
  local usable = primary.usableBounds
  if usable == nil then
    return emptyGeometry()
  end
  local outerWidth = native.width + 2
  local outerHeight = native.height + 14
  local preferredScale, _, _ = fitOptions(options)
  local fitBounds = { x = usable.x, y = usable.y, width = usable.width, height = usable.height }
  if preferredScale == nil then
    local eightyWidth = usable.width * 0.8
    local eightyHeight = usable.height * 0.8
    local eightyScale = math.min(math.floor(eightyWidth / outerWidth), math.floor(eightyHeight / outerHeight))
    if eightyScale >= 1 then
      preferredScale = eightyScale
      fitBounds = {
        x = usable.x + (usable.width - eightyWidth) / 2,
        y = usable.y + (usable.height - eightyHeight) / 2,
        width = eightyWidth,
        height = eightyHeight,
      }
    end
  end
  local placement = PixelScale.placeFixed(fitBounds, outerWidth, outerHeight, {
    pixelRatio = ratio,
    preferredScale = preferredScale,
    maxOverdraw = { left = 0, right = 0, top = 0, bottom = 0 },
  })
  if placement == nil or not fitsInteger(placement) then
    return nil
  end
  local frame = placement.frame
  local position = context.windowPosition or { x = 0.5, y = 0.5 }
  assert(
    type(position.x) == "number" and type(position.y) == "number",
    "the windowed context needs its normalized position"
  )
  local travelX = usable.width - frame.width
  local travelY = usable.height - frame.height
  local x = usable.x + (travelX > 0 and position.x * travelX or travelX / 2)
  local y = usable.y + (travelY > 0 and position.y * travelY or travelY / 2)
  x = math.max(usable.x, math.min(x, usable.x + usable.width - frame.width))
  y = math.max(usable.y, math.min(y, usable.y + usable.height - frame.height))
  local origin = { x = snapPhysical(x, ratio), y = snapPhysical(y, ratio) }
  local outer = {
    frame = { x = origin.x, y = origin.y, width = frame.width, height = frame.height },
    origin = { x = origin.x, y = origin.y },
    scale = placement.scale,
    logicalWidth = placement.logicalWidth,
    logicalHeight = placement.logicalHeight,
    clipRect = { x = origin.x, y = origin.y, width = frame.width, height = frame.height },
    pixelScale = placement.pixelScale,
    pixelRatio = placement.pixelRatio,
  }
  local body = assert(
    LayoutGeometry.subPlacement(outer, { x = 1, y = 13, width = native.width, height = native.height }),
    "the window body must fit its outer frame"
  )
  local grabRect = LayoutGeometry.logicalRectToHost(outer, { x = 1, y = 1, width = native.width, height = 12 })
  return {
    placements = { [native.id] = body },
    coverage = {},
    window = { outer = outer, body = body, grabRect = grabRect },
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
    coverage = { copyRect(worldBounds), copyRect(auxBounds) },
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
      x = upperNative.width + PAIR_GAP,
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
    y = upperNative.height + PAIR_GAP,
    width = lowerNative.width,
    height = lowerNative.height,
  }
  return upper, lower
end

-- One-display pair composition: a single integer fit of the combined
-- logical envelope (upper left/lower right, or upper above/lower below)
-- with zero crop and the 8-logical-pixel gap, then subPlacement for each
-- pane. The panes never fit independently and never stretch unequally.
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
    envelopeWidth = upperNative.width + PAIR_GAP + lowerNative.width
    envelopeHeight = math.max(upperNative.height, lowerNative.height)
  else
    envelopeWidth = math.max(upperNative.width, lowerNative.width)
    envelopeHeight = upperNative.height + PAIR_GAP + lowerNative.height
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
    coverage = { copyRect(usable) },
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
