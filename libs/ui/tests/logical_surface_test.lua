-- Unit contract for the stateless shared logical drawing boundary: one root
-- transform per placement, the visible clip intersected rather than replaced,
-- borrowed graphics state restored on success and on callback failure, and
-- the original callback error propagated unwrapped. The fake graphics
-- namespace stands in for the injected LOVE-like collaborator; pixel-exact
-- magnification across densities lives in the graphics suite.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")

local T = {}

local function logicalSurfaceFor(behavior)
  local ok, moduleOrError = pcall(require, "libs.ui.src.LogicalSurface")
  Assert.isTrue(ok, behavior .. " is missing: the shared logical drawing scope is unavailable")
  Assert.isTrue(type(moduleOrError) == "table", behavior .. " is missing: the scope has no public table")
  local Surface = moduleOrError
  Assert.isTrue(type(Surface.draw) == "function", behavior .. " is missing: the root placement scope is unavailable")
  Assert.isTrue(type(Surface.clip) == "function", behavior .. " is missing: the nested logical clip is unavailable")
  return Surface
end

-- The locked cropped placement shape the pixel policy resolves: the complete
-- transformed surface plus its independent visible clip. Fixture data only;
-- the policy suite owns how these numbers are selected.
local function croppedPlacement()
  return {
    frame = { x = -9, y = -8, width = 768, height = 576 },
    origin = { x = -9, y = -8 },
    scale = 3,
    logicalWidth = 256,
    logicalHeight = 192,
    clipRect = { x = 0, y = 1, width = 750, height = 558 },
    pixelScale = 3,
    pixelRatio = 1,
    visibleLogicalRect = { x = 3, y = 3, width = 250, height = 186 },
    crop = { left = 3, right = 3, top = 3, bottom = 3 },
  }
end

function T.draw_runs_the_callback_once_inside_the_visible_clip_and_restores_state()
  local Surface = logicalSurfaceFor("root logical drawing")
  local lg = FakeGraphics.new({
    color = { 0.2, 0.4, 0.6, 0.8 },
    lineWidth = 3,
    scissor = { -100, -100, 2000, 2000 },
  })
  local calls = 0
  Surface.draw(lg, croppedPlacement(), function()
    calls = calls + 1
  end)
  Assert.equal(calls, 1, "the draw callback runs exactly once")
  Assert.equal(lg:pushDepth(), 0, "the pushed scope is popped exactly once")
  local transforms = lg.transforms
  Assert.equal(transforms[#transforms - 1][1], "translate", "the root scope translates to the placement origin")
  Assert.equal(transforms[#transforms][1], "scale", "the root scope scales uniformly after translating")
  local intersections = lg.scissorIntersections
  Assert.notNil(intersections[#intersections], "the visible clip is intersected, never skipped")
  Assert.deepEqual(
    intersections[#intersections].requested,
    { 0, 1, 750, 558 },
    "the scope clips to the placement clip, not the full frame"
  )
  Assert.deepEqual(
    intersections[#intersections].effective,
    { 0, 1, 750, 558 },
    "the wide outer scissor leaves the placement clip intact"
  )
  local r, g, b, a = lg.getColor()
  Assert.deepEqual({ r, g, b, a }, { 0.2, 0.4, 0.6, 0.8 }, "borrowed color is restored")
  Assert.equal(lg.getLineWidth(), 3, "borrowed line width is restored")
  local sx, sy, sw, sh = lg.getScissor()
  Assert.deepEqual({ sx, sy, sw, sh }, { -100, -100, 2000, 2000 }, "the outer scissor is restored")
end

function T.draw_propagates_the_callback_failure_and_balances_the_scope()
  local Surface = logicalSurfaceFor("root logical drawing")
  local lg = FakeGraphics.new({
    color = { 0.2, 0.4, 0.6, 0.8 },
    scissor = { 0, 0, 800, 600 },
  })
  local marker = {}
  local ok, err = pcall(Surface.draw, lg, croppedPlacement(), function()
    error(marker, 0)
  end)
  Assert.isFalse(ok, "a callback failure fails the scope")
  Assert.isTrue(err == marker, "the original error object propagates unwrapped")
  Assert.equal(lg:pushDepth(), 0, "a failed scope still pops exactly once")
  local r, g, b, a = lg.getColor()
  Assert.deepEqual({ r, g, b, a }, { 0.2, 0.4, 0.6, 0.8 }, "borrowed color is restored after failure")
  local sx, sy, sw, sh = lg.getScissor()
  Assert.deepEqual({ sx, sy, sw, sh }, { 0, 0, 800, 600 }, "the outer scissor is restored after failure")
end

function T.nested_clip_runs_content_and_restores_the_outer_scope_on_failure()
  local Surface = logicalSurfaceFor("nested logical clipping")
  local lg = FakeGraphics.new({ scissor = { 0, 0, 800, 600 } })
  local contentCalls = 0
  Surface.draw(lg, croppedPlacement(), function()
    Surface.clip(lg, { x = 10, y = 20, width = 30, height = 40 }, function()
      contentCalls = contentCalls + 1
    end)
  end)
  Assert.equal(contentCalls, 1, "nested content runs exactly once")
  Assert.equal(lg:pushDepth(), 0, "nested scopes pop exactly once")
  local marker = {}
  local ok, err = pcall(Surface.draw, lg, croppedPlacement(), function()
    Surface.clip(lg, { x = 10, y = 20, width = 30, height = 40 }, function()
      error(marker, 0)
    end)
  end)
  Assert.isFalse(ok, "a nested failure fails the root scope")
  Assert.isTrue(err == marker, "the nested error object propagates unwrapped")
  Assert.equal(lg:pushDepth(), 0, "a failed nested scope still pops exactly once")
  local sx, sy, sw, sh = lg.getScissor()
  Assert.deepEqual({ sx, sy, sw, sh }, { 0, 0, 800, 600 }, "the outer scissor is restored after nested failure")
end

function T.invalid_scope_inputs_are_rejected()
  local Surface = logicalSurfaceFor("scope validation")
  local lg = FakeGraphics.new()
  local nothing = nil ---@type any
  Assert.throws(function()
    Surface.draw(lg, nothing, function() end)
  end, "a missing placement is a programming error")
  Assert.throws(function()
    Surface.draw(lg, croppedPlacement(), nothing)
  end, "a missing draw callback is a programming error")
  Assert.throws(function()
    Surface.clip(lg, { x = 0, y = 0, width = 0, height = 10 }, function() end)
  end, "an empty logical clip has no drawable surface")
end

function T.repeated_scopes_after_failure_draw_cleanly()
  local Surface = logicalSurfaceFor("root logical drawing")
  local lg = FakeGraphics.new({ scissor = { 0, 0, 800, 600 } })
  local marker = {}
  Assert.throws(function()
    Surface.draw(lg, croppedPlacement(), function()
      error(marker, 0)
    end)
  end, "the first scope fails")
  Assert.equal(lg:pushDepth(), 0, "the failed scope pops exactly once")
  local calls = 0
  Surface.draw(lg, croppedPlacement(), function()
    Surface.clip(lg, { x = 10, y = 20, width = 30, height = 40 }, function()
      calls = calls + 1
    end)
  end)
  Assert.equal(calls, 1, "a later scope draws cleanly after a failure")
  Assert.equal(lg:pushDepth(), 0, "nested scopes after a failure still balance")
  local sx, sy, sw, sh = lg.getScissor()
  Assert.deepEqual({ sx, sy, sw, sh }, { 0, 0, 800, 600 }, "the outer scissor survives failures")
end

function T.malformed_placements_are_rejected_before_any_push()
  local Surface = logicalSurfaceFor("scope validation")
  local lg = FakeGraphics.new()
  local placement = croppedPlacement()
  placement.scale = 0
  Assert.throws(function()
    Surface.draw(lg, placement, function() end)
  end, "a non-positive scale is a programming error")
  local clipped = croppedPlacement()
  clipped.clipRect = { x = 0, y = 0, width = -4, height = 10 }
  Assert.throws(function()
    Surface.draw(lg, clipped, function() end)
  end, "a malformed clip is a programming error")
  Assert.equal(lg:pushDepth(), 0, "rejected scopes never push")
end

return { tests = T }
