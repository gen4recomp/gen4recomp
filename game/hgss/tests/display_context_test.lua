-- DisplayContext ownership: one host measurement adapter behind
-- getDimensions/getDPIScale and an injected actual-surface provider. Every
-- measurement is a fresh caller-owned record with a stable structural
-- signature; provider records are validated and copied, never retained.

local Assert = require("tests.support.Assert")
local DisplayContext = require("game.hgss.src.ui.DisplayContext")

local T = { tests = {} }

local function graphics(width, height, ratio)
  return {
    getDimensions = function()
      return width, height
    end,
    getDPIScale = function()
      return ratio
    end,
  }
end

local function provider(topology)
  return function()
    return topology
  end
end

function T.tests.defaults_measure_the_graphics_drawable_with_a_single_world_surface()
  local context = DisplayContext.new({ graphics = graphics(640, 480, 1) })
  local measurement = context:measure()
  Assert.equal(measurement.width, 640, "the drawable width comes from graphics")
  Assert.equal(measurement.height, 480, "the drawable height comes from graphics")
  Assert.equal(measurement.pixelRatio, 1, "the ratio comes from graphics")
  Assert.equal(#measurement.topology.surfaces, 1, "the default is one actual surface")
  Assert.equal(measurement.topology.surfaces[1].role, "world", "the default surface is the world")
  Assert.equal(measurement.topology.surfaces[1].id, "main", "the default surface keeps its identity")
end

function T.tests.explicit_dimensions_override_the_graphics_drawable()
  local context = DisplayContext.new({ graphics = graphics(640, 480, 2) })
  local measurement = context:measure(320, 240)
  Assert.equal(measurement.width, 320, "explicit dimensions win over graphics")
  Assert.equal(measurement.height, 240, "explicit dimensions win over graphics")
  Assert.equal(measurement.pixelRatio, 2, "the framebuffer ratio is still reported")
end

function T.tests.provider_topology_is_validated_and_copied_never_retained()
  local inner = {
    id = "main",
    rect = { x = 0, y = 0, width = 100, height = 100 },
    safeRect = { x = 4, y = 4, width = 92, height = 92 },
    role = "world",
    touch = true,
    occupiedRegions = { { x = 4, y = 4, width = 10, height = 10 } },
  }
  local source = { surfaces = { inner } }
  local context = DisplayContext.new({ graphics = graphics(100, 100, 1), topologyProvider = provider(source) })
  local measurement = context:measure()
  Assert.equal(#measurement.topology.surfaces, 1, "the provider surface is measured")
  inner.rect.width = 10
  inner.occupiedRegions[1].width = 1
  Assert.equal(
    measurement.topology.surfaces[1].rect.width,
    100,
    "the measurement keeps a copy, not the provider record"
  )
  Assert.equal(measurement.topology.surfaces[1].occupiedRegions[1].width, 10, "reservations are copied, not retained")
end

function T.tests.signatures_are_stable_and_structural_never_timestamps()
  local context = DisplayContext.new({ graphics = graphics(640, 480, 1) })
  local first = context:measure()
  local second = context:measure()
  Assert.equal(first.signature, second.signature, "repeated measures share one signature")
  Assert.isTrue(type(first.signature) == "string" and first.signature ~= "", "the signature is a real identity")
  local resized = context:measure(800, 600)
  Assert.isTrue(resized.signature ~= first.signature, "dimensions enter the signature")
  local hidpi = DisplayContext.new({ graphics = graphics(640, 480, 2) }):measure()
  Assert.isTrue(hidpi.signature ~= first.signature, "the pixel ratio enters the signature")
end

function T.tests.safe_areas_touch_and_reservations_enter_the_signature()
  local base = {
    surfaces = {
      {
        id = "main",
        rect = { x = 0, y = 0, width = 100, height = 100 },
        role = "world",
        touch = false,
      },
    },
  }
  local plain = DisplayContext.new({ graphics = graphics(100, 100, 1), topologyProvider = provider(base) }):measure()
  local touched = {
    surfaces = {
      {
        id = "main",
        rect = { x = 0, y = 0, width = 100, height = 100 },
        role = "world",
        touch = true,
      },
    },
  }
  local withTouch = DisplayContext.new({ graphics = graphics(100, 100, 1), topologyProvider = provider(touched) })
    :measure()
  Assert.isTrue(withTouch.signature ~= plain.signature, "touch capability enters the signature")
  local reserved = {
    surfaces = {
      {
        id = "main",
        rect = { x = 0, y = 0, width = 100, height = 100 },
        safeRect = { x = 0, y = 0, width = 100, height = 80 },
        role = "world",
        touch = false,
        occupiedRegions = { { x = 0, y = 60, width = 100, height = 20 } },
      },
    },
  }
  local withReservation =
    DisplayContext.new({ graphics = graphics(100, 100, 1), topologyProvider = provider(reserved) }):measure()
  Assert.isTrue(withReservation.signature ~= plain.signature, "safe areas and reservations enter the signature")
end

function T.tests.invalid_graphics_and_dimensions_fail_at_the_boundary()
  Assert.throws(function()
    DisplayContext.new({ graphics = {} })
  end, "graphics without dimensions fail at construction")
  local context = DisplayContext.new({ graphics = graphics(100, 100, 1) })
  Assert.throws(function()
    context:measure(0, 100)
  end, "an empty drawable width is not measurable")
  Assert.throws(function()
    DisplayContext.new({
      graphics = graphics(100, 100, 1),
      topologyProvider = function()
        return { surfaces = {} }
      end,
    }):measure()
  end, "a provider without surfaces fails measurement")
end

return T
