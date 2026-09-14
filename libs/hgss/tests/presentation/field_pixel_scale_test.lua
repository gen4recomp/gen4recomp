-- Field pixel scale contracts for the production presentation policy.

local Assert = require("tests.support.Assert")

local T = {}

local function controller()
  local ok, result = pcall(require, "libs.hgss.src.presentation.FieldPixelScale")
  Assert.isTrue(ok, "the field must expose an integer pixel-scale controller")
  return result.new({
    baseCameraZoom = 1,
    minCameraZoom = 0.5,
    maxCameraZoom = 1.5,
    referenceHeight = 600,
    resizeCompensation = 0.7,
  })
end

function T.default_resize_curve_resolves_locked_integer_levels()
  local scale = controller()
  local cases = {
    { height = 480, expected = 3 },
    { height = 600, expected = 3 },
    { height = 720, expected = 3 },
    { height = 1080, expected = 4 },
    { height = 1440, expected = 4 },
    { height = 2160, expected = 6 },
  }
  for _, case in ipairs(cases) do
    scale:resize(case.height)
    local resolved = scale:resolvedScale()
    Assert.equal(resolved, case.expected, "automatic field scale at height " .. case.height)
    Assert.equal(resolved % 1, 0, "field scale must be an integer at height " .. case.height)
  end
end

function T.omitted_configuration_uses_the_locked_defaults()
  local FieldPixelScale = require("libs.hgss.src.presentation.FieldPixelScale")
  local scale = FieldPixelScale.new()
  scale:resize(2160)
  Assert.equal(scale:resolvedScale(), 6)
end

function T.manual_scale_levels_preserve_offset_across_resize_and_bounds()
  local scale = controller()
  scale:resize(720)
  Assert.equal(scale:resolvedScale(), 3)

  scale:zoomIn()
  Assert.equal(scale:resolvedScale(), 4, "zoom in must advance one integer level")

  scale:resize(1080)
  Assert.equal(scale:resolvedScale(), 5, "resize must preserve the one-level manual offset")

  scale:reset()
  Assert.equal(scale:resolvedScale(), 4, "reset must restore the automatic baseline")

  scale:resize(480)
  Assert.equal(scale:resolvedScale(), 3)
  scale:zoomIn()
  scale:zoomIn()
  Assert.equal(scale:resolvedScale(), 3, "repeated zoom in at the bound must saturate")
  scale:resize(720)
  Assert.equal(scale:resolvedScale(), 3, "bound saturation must not accumulate a hidden offset")

  scale:resize(1080)
  scale:zoomOut()
  Assert.equal(scale:resolvedScale(), 3, "zoom out must advance one integer level")
  scale:reset()
  Assert.equal(scale:resolvedScale(), 4, "reset must clear the manual level offset")
end

function T.invalid_configuration_and_resize_values_are_rejected()
  Assert.throws(function()
    local FieldPixelScale = require("libs.hgss.src.presentation.FieldPixelScale")
    local invalidConfiguration = 1
    ---@diagnostic disable-next-line: param-type-mismatch
    FieldPixelScale.new(invalidConfiguration)
  end)

  local invalidConfigurations = {
    false,
    { baseCameraZoom = 0 },
    { baseCameraZoom = false },
    { baseCameraZoom = "1" },
    { baseCameraZoom = math.huge },
    { baseCameraZoom = 0 / 0 },
    { minCameraZoom = 0 },
    { minCameraZoom = false },
    { minCameraZoom = -math.huge },
    { minCameraZoom = 0 / 0 },
    { minCameraZoom = "0.5" },
    { maxCameraZoom = 0 },
    { maxCameraZoom = false },
    { maxCameraZoom = math.huge },
    { maxCameraZoom = 0 / 0 },
    { maxCameraZoom = "1.5" },
    { minCameraZoom = 2, maxCameraZoom = 1 },
    { referenceHeight = 0 },
    { referenceHeight = false },
    { referenceHeight = -math.huge },
    { referenceHeight = 0 / 0 },
    { referenceHeight = "600" },
    { resizeCompensation = -0.1 },
    { resizeCompensation = 1.1 },
    { resizeCompensation = math.huge },
    { resizeCompensation = 0 / 0 },
    { resizeCompensation = "0.7" },
  }
  for _, config in ipairs(invalidConfigurations) do
    Assert.throws(function()
      local FieldPixelScale = require("libs.hgss.src.presentation.FieldPixelScale")
      ---@diagnostic disable-next-line: param-type-mismatch
      FieldPixelScale.new(config)
    end)
  end

  local scale = controller()
  for _, height in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0, "720" }) do
    Assert.throws(function()
      scale:resize(height)
    end)
  end
end

function T.integer_bounds_include_exact_endpoints_and_fallback_at_tiny_sizes()
  local FieldPixelScale = require("libs.hgss.src.presentation.FieldPixelScale")
  local endpoint = FieldPixelScale.new({
    baseCameraZoom = 1,
    minCameraZoom = 1.5,
    maxCameraZoom = 2.5,
    referenceHeight = 192,
    resizeCompensation = 0,
  })
  endpoint:resize(192)
  Assert.equal(endpoint:resolvedScale(), 2, "the exact integer interval endpoint remains legal")
  Assert.near(endpoint:cameraZoom(), 2, 1e-12)

  local tiny = FieldPixelScale.new({
    baseCameraZoom = 1,
    minCameraZoom = 0.5,
    maxCameraZoom = 1.5,
    referenceHeight = 1,
    resizeCompensation = 0,
  })
  Assert.equal(tiny:resolvedScale(), 1, "a tiny host falls back to one pixel")
  Assert.near(tiny:cameraZoom(), 192, 1e-12)
end

function T.automatic_scale_uses_half_up_quantization_at_thresholds()
  local FieldPixelScale = require("libs.hgss.src.presentation.FieldPixelScale")
  local scale = FieldPixelScale.new({
    baseCameraZoom = 1,
    minCameraZoom = 0.1,
    maxCameraZoom = 10,
    referenceHeight = 192,
    resizeCompensation = 0,
  })
  scale:resize(192 * 2.499)
  Assert.equal(scale:resolvedScale(), 2, "values immediately below the half threshold round down")
  scale:resize(192 * 2.501)
  Assert.equal(scale:resolvedScale(), 3, "values immediately above the half threshold round up")
end

return { tests = T }
