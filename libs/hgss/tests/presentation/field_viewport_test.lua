-- FieldViewport adaptive Hor+ and strict 4:3 rectangle policy.

local Assert = require("tests.support.Assert")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}
local function approx(a, b)
  return math.abs(a - b) < 1e-9
end

function T.expanded_uses_full_wide_drawable_and_centered_reference_frame()
  local viewport = FieldViewport.new(1920, 1080, { mode = "expanded" })
  Assert.deepEqual(viewport.worldViewport, { x = 0, y = 0, width = 1920, height = 1080 })
  Assert.isTrue(approx(viewport.referenceFrame.width, 1440))
  Assert.isTrue(approx(viewport.referenceFrame.x, 240))
  Assert.isTrue(approx(viewport:worldAspect(), 16 / 9))
end

function T.strict_centers_a_four_by_three_world_viewport()
  local viewport = FieldViewport.new(1920, 1080, { mode = "strict" })
  Assert.deepEqual(viewport.worldViewport, { x = 240, y = 0, width = 1440, height = 1080 })
  Assert.deepEqual(viewport.referenceFrame, viewport.worldViewport)
  Assert.isTrue(approx(viewport:worldAspect(), 4 / 3))
end

function T.expanded_and_strict_are_identical_at_four_by_three()
  local expanded = FieldViewport.new(1024, 768, { mode = "expanded" })
  local strict = FieldViewport.new(1024, 768, { mode = "strict" })
  Assert.deepEqual(expanded.worldViewport, strict.worldViewport)
  Assert.deepEqual(expanded.referenceFrame, strict.referenceFrame)
end

function T.narrow_expanded_falls_back_to_strict_fit()
  local viewport = FieldViewport.new(900, 900, { mode = "expanded" })
  Assert.deepEqual(viewport.worldViewport, { x = 0, y = 112.5, width = 900, height = 675 })
  Assert.deepEqual(viewport.referenceFrame, viewport.worldViewport)
end

function T.resize_recomputes_rectangles_without_replacing_the_object()
  local viewport = FieldViewport.new(800, 600, { mode = "expanded" })
  for _ = 1, 10 do
    viewport:resize(960, 720)
    viewport:resize(2560, 720)
  end
  viewport:resize(1600, 900)
  Assert.deepEqual(viewport.worldViewport, { x = 0, y = 0, width = 1600, height = 900 })
  Assert.equal(viewport.referenceFrame.x, 200)
end

function T.invalid_dimensions_and_modes_are_rejected()
  Assert.throws(function()
    FieldViewport.new(0, 100)
  end)
  Assert.throws(function()
    FieldViewport.new(100, 100, { mode = "crop" })
  end)
end

return { tests = T }
