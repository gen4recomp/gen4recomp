-- Behavior: fractional field UI scaling produces no internal wayfinding seams.
-- The earlier tiled path drew 24 quads (192x8 strip) which can show white gaps
-- at fractional scales; the precomposed surface draws one rect per graphic.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldSignpostFixture = require("tests.support.FieldSignpostFixture")
local FieldSignpostRenderer = require("libs.hgss.src.ui.FieldSignpostRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local function quantize(v)
  return math.floor(v * 255 + 0.5)
end

local function solidWayfindingBytes(width, height)
  local r, g, b = 220, 20, 60
  return PngWriter.encode(width, height, string.rep(string.char(r, g, b, 255), width * height))
end

local function cacheWithSolidWayfinding()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:write(FieldUiFixture.WAYFINDING_PATH, solidWayfindingBytes(48, 128))
  return cache
end

local function manifestWithBaselineWayfinding()
  return FieldUiFixture.manifest()
end

local function renderAndCheckSeam(scope, viewportW, viewportH, zoom)
  local cache = cacheWithSolidWayfinding()
  local manifest = manifestWithBaselineWayfinding()
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cache }))
  local renderer = scope:own(FieldSignpostRenderer.new({
    cacheFs = cache,
    manifest = manifest,
    text = text,
    windowStyles = FieldSignpostFixture.styles(),
  }))
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0, map = 0, offset = 0 })
  local viewport = FieldViewport.new(viewportW, viewportH, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(zoom)

  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(viewportW, viewportH))
  lg.setCanvas(canvas)
  lg.clear(1, 1, 1, 1)
  renderer:draw(controller, viewport, 1, fieldScale)
  lg.setCanvas()
  local data = scope:own(canvas:newImageData())

  local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
  local layout = FieldDialogueTheme.layout(viewport.referenceFrame, fieldScale)
  local graphicRegion = { x = 16, y = 152, width = 56, height = 32 }
  local hostX0 = layout.origin.x + graphicRegion.x * layout.scale
  local hostY0 = layout.origin.y + graphicRegion.y * layout.scale
  local hostW = 48 * layout.scale
  local hostH = 32 * layout.scale

  local boundaries = {}
  for i = 1, 3 do
    boundaries[i] = hostY0 + (i * 8) * layout.scale
  end

  local insetLogical = 4
  local insetHost = insetLogical * layout.scale
  local sampleX0 = math.floor(hostX0 + insetHost + 0.5)
  local sampleX1 = math.floor(hostX0 + hostW - insetHost + 0.5) - 1
  if sampleX1 < sampleX0 then
    sampleX1 = sampleX0
  end

  local hasSeam = false
  local seamInfo = nil
  for _, by in ipairs(boundaries) do
    local yCandidates = { math.floor(by) - 1, math.floor(by), math.ceil(by), math.ceil(by) + 1 }
    for _, y in ipairs(yCandidates) do
      local x = math.floor((sampleX0 + sampleX1) / 2)
      if x >= 0 and x < viewportW and y >= 0 and y < viewportH then
        local r, g, b = data:getPixel(x, y)
        local qr, qg, qb = quantize(r), quantize(g), quantize(b)
        local isWhite = qr > 250 and qg > 250 and qb > 250
        if isWhite then
          hasSeam = true
          seamInfo = string.format(
            "white seam at logical boundary host y=%.2f sampled y=%d x=%d (%d,%d,%d)",
            by,
            y,
            x,
            qr,
            qg,
            qb
          )
          break
        end
      end
    end
    if hasSeam then
      break
    end
    local yInt = math.floor(by)
    for scanY = yInt - 1, yInt + 1 do
      if scanY >= 0 and scanY < viewportH then
        local whiteRun = 0
        for x = sampleX0, sampleX1 do
          local r, g, b = data:getPixel(x, scanY)
          local qr, qg, qb = quantize(r), quantize(g), quantize(b)
          if qr > 250 and qg > 250 and qb > 250 then
            whiteRun = whiteRun + 1
          end
        end
        if whiteRun > (sampleX1 - sampleX0 + 1) * 0.5 then
          hasSeam = true
          seamInfo = string.format("white run %d at boundary y=%.2f scanY=%d", whiteRun, by, scanY)
          break
        end
      end
    end
    if hasSeam then
      break
    end
  end

  return hasSeam,
    seamInfo,
    {
      hostX0 = hostX0,
      hostY0 = hostY0,
      hostW = hostW,
      hostH = hostH,
      fieldScale = fieldScale,
      layout = layout,
    }
end

function T.fractional_scale_has_no_internal_horizontal_seam(scope)
  -- Fractional candidate: 768x500 zoom 1 gives fieldScale = 500/192 ≈ 2.604 (8*scale non-integer).
  -- Also satisfies viewport 512x500-style fractional intent (expanded height 500 with non-integer scale).
  -- Single-draw (48x32) has no internal seams by construction, so this asserts absence of white gaps.
  local viewportW, viewportH, zoom = 768, 500, 1
  local hasSeam, seamInfo, dbg = renderAndCheckSeam(scope, viewportW, viewportH, zoom)
  Assert.isFalse(
    hasSeam,
    seamInfo
      or string.format(
        "unexpected white seam at fractional scale %.4f host %dx%d zoom %.2f",
        dbg.fieldScale,
        viewportW,
        viewportH,
        zoom
      )
  )
end

return GraphicsSmoke.suite(T)
