-- Production field composition contracts for integer scale ownership.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldPresentation = require("data.manifests.field_presentation")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "presentation", "composition" },
  },
  tests = {},
}

local MAP = "MAP_BURNED_TOWER_1F"

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function resize(game, width, height)
  game.runtime:resizePresentation(width, height, topology(width, height))
end

local function withProductionRuntime(fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({
      versionId = versionId,
      map = MAP,
      save = "fresh",
      fieldOptions = { viewportWidth = 1280, viewportHeight = 720 },
    })
    local ok, err = xpcall(function()
      game:waitForFieldReady()
      fn(game)
      Assert.isNil(game.runtime.errorText, "the production field must remain healthy")
      Assert.equal(game:renderAttempts(), 0, "field scale composition must stop before GPU rendering")
    end, debug.traceback)
    local closed, closeError = pcall(function()
      game:close()
    end)
    if not closed then
      error(closeError, 0)
    end
    if not ok then
      error(err, 0)
    end
  end)
end

T.tests.production_projection_uses_the_resolved_scale_and_fitted_reference_height = function()
  withProductionRuntime(function(game)
    local runtime = game.runtime
    local scale = runtime.fieldPixelScale
    Assert.notNil(scale, "FieldRuntime must own the field pixel-scale controller")

    resize(game, 1280, 720)
    local expandedHeight = runtime.viewport.referenceFrame.height
    local expandedScale = scale:resolvedScale()
    Assert.near(
      (expandedHeight / 192) * runtime.camera.zoom,
      expandedScale,
      1e-9,
      "camera zoom must be derived from the expanded reference-frame height"
    )

    resize(game, 900, 900)
    Assert.equal(runtime.viewport.referenceFrame.height, 675, "narrow topology must use the fitted reference height")
    local narrowScale = scale:resolvedScale()
    Assert.near(
      (runtime.viewport.referenceFrame.height / 192) * runtime.camera.zoom,
      narrowScale,
      1e-9,
      "camera zoom must be derived from the fitted reference-frame height"
    )

    Assert.keySet(FieldViewport, "__index,new,resize,worldAspect", "FieldViewport must expose geometry only")
  end)
end

T.tests.field_presentation_publishes_one_scale_authority = function()
  Assert.isTrue(type(FieldPresentation.fieldScale) == "table", "field presentation must publish scale tuning")
  Assert.equal(FieldPresentation.fieldScale.baseCameraZoom, 1)
  Assert.equal(FieldPresentation.fieldScale.minCameraZoom, 0.5)
  Assert.equal(FieldPresentation.fieldScale.maxCameraZoom, 1.5)
  Assert.equal(FieldPresentation.fieldScale.referenceHeight, 600)
  Assert.equal(FieldPresentation.fieldScale.resizeCompensation, 0.7)

  withProductionRuntime(function(game)
    local runtime = game.runtime
    local scale = runtime.fieldPixelScale
    Assert.notNil(scale, "FieldRuntime must publish its scale authority")
    local before = scale:resolvedScale()
    scale:zoomIn()
    Assert.equal(scale:resolvedScale(), before + 1, "the scale control must move one integer level")
    runtime:applyFieldPixelScaleChange()
    Assert.near(
      (runtime.viewport.referenceFrame.height / 192) * runtime.camera.zoom,
      scale:resolvedScale(),
      1e-9,
      "refreshing the scale control must refresh the derived camera projection"
    )
  end)
end

return T
