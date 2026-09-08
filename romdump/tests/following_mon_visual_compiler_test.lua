-- Follower visual capability gate: the follower producer only publishes
-- field-actor visuals that can face the four cardinal directions and animate
-- walking. Structurally valid generic output is not enough: a static model
-- has no locomotion frames, a missing walk clip falls back to standing, and
-- an atlas that aliases every pose to one frame cannot show movement. These
-- tests drive the real producer entry point with schema-shaped synthetic
-- visuals through a stubbed sprite pipeline, so no user-owned dump is needed.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local FollowingMonVisualCompiler = require("romdump.src.digest.actor.FollowingMonVisualCompiler")

local T = {}

local CARDINAL_DIRECTIONS = { "north", "south", "west", "east" }

local function validPolygon()
  return {
    cullMode = "back",
    polygonMode = "modulation",
    polygonId = 1,
    polygonAlpha = 31,
    lightMask = 0,
    translucentDepthWrite = false,
    depthEqual = false,
    fogEnabled = false,
  }
end

local function validVertices()
  return {
    { x = -1, y = 0, z = 0, u = 0, v = 0, nx = 0, ny = 1, nz = 0, r = 255, g = 0, b = 0, a = 255, colorSource = 0 },
    { x = 1, y = 0, z = 0, u = 1, v = 0, nx = 0, ny = 1, nz = 0, r = 0, g = 255, b = 0, colorSource = 1 },
    { x = 1, y = 2, z = 0, u = 1, v = 1, nx = 0, ny = 1, nz = 0, r = 0, g = 0, b = 255, colorSource = 2 },
    { x = -1, y = 2, z = 0, u = 0, v = 1, nx = 0, ny = 1, nz = 0, r = 255, g = 255, b = 255, a = 128, colorSource = 0 },
  }
end

local function validAtlasGeometry()
  return {
    vertices = validVertices(),
    indices = { 0, 1, 2, 0, 2, 3 },
    anchorTiles = { x = 0, y = 0, z = 0 },
    bounds = { width = 2, height = 2, depth = 0 },
    baseTransform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
  }
end

local function atlasRender(spriteId, frameCount)
  return {
    kind = "atlas",
    image = FieldActorCache.atlasPath(spriteId),
    frameWidth = 32,
    frameHeight = 32,
    frameCount = frameCount,
    alphaClass = "opaque",
    polygon = validPolygon(),
    geometry = validAtlasGeometry(),
  }
end

local function idlePose(frameIndex, ticks)
  return {
    frames = { { frameIndex = frameIndex, ticks = ticks, displayOffsetY = 0 } },
    loop = true,
    durationTicks = ticks,
  }
end

local function walkPose(firstFrame, secondFrame)
  return {
    frames = { { frameIndex = firstFrame, ticks = 5 }, { frameIndex = secondFrame, ticks = 5 } },
    loop = true,
    durationTicks = 10,
  }
end

-- A capable atlas: every cardinal direction carries its own idle frame and a
-- two-frame walk clip, all resident in an 8-frame strip.
local function capableDirections()
  return {
    north = { idle = idlePose(1, 5), walk = walkPose(1, 2) },
    south = { idle = idlePose(3, 5), walk = walkPose(3, 4) },
    west = { idle = idlePose(5, 5), walk = walkPose(5, 6) },
    east = { idle = idlePose(7, 5), walk = walkPose(7, 8) },
  }
end

local function capableAtlasVisual(spriteId)
  return {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = atlasRender(spriteId, 8),
    idlePresentation = { mode = "static", cadence = 0 },
    directions = capableDirections(),
    gestures = {},
  }
end

local function staticModelVisual(spriteId)
  local pose = {
    frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } },
    loop = true,
    durationTicks = 1,
  }
  local directions = {}
  for _, direction in ipairs(CARDINAL_DIRECTIONS) do
    directions[direction] = { idle = pose, walk = pose }
  end
  return {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = {
      kind = "staticModel",
      image = FieldActorCache.atlasPath(spriteId),
      frameWidth = 64,
      frameHeight = 64,
      frameCount = 1,
      parts = {
        {
          textured = true,
          alphaClass = "opaque",
          polygon = validPolygon(),
          geometry = {
            vertices = validVertices(),
            indices = { 0, 1, 2, 0, 2, 3 },
            anchorTiles = { x = 0, y = 0, z = 0 },
            bounds = { width = 2, height = 2, depth = 0 },
            center = { 0, 1, 0 },
          },
        },
      },
    },
    idlePresentation = { mode = "static", cadence = 0 },
    directions = directions,
    gestures = {},
  }
end

local function walklessAtlasVisual(spriteId)
  local directions = {}
  local idleFrames = { north = 1, south = 3, west = 5, east = 7 }
  for _, direction in ipairs(CARDINAL_DIRECTIONS) do
    directions[direction] = { idle = idlePose(idleFrames[direction], 5) }
  end
  return {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = atlasRender(spriteId, 8),
    idlePresentation = { mode = "static", cadence = 0 },
    directions = directions,
    gestures = {},
  }
end

local function singleFrameAtlasVisual(spriteId)
  local pose = {
    frames = { { frameIndex = 1, ticks = 1, displayOffsetY = 0 } },
    loop = true,
    durationTicks = 1,
  }
  local directions = {}
  for _, direction in ipairs(CARDINAL_DIRECTIONS) do
    directions[direction] = { idle = pose, walk = pose }
  end
  return {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    render = atlasRender(spriteId, 1),
    idlePresentation = { mode = "static", cadence = 0 },
    directions = directions,
    gestures = {},
  }
end

local function directionlessAtlasVisual(spriteId)
  local visual = capableAtlasVisual(spriteId)
  visual.directions = {
    north = visual.directions.north,
    south = visual.directions.south,
    west = visual.directions.west,
  }
  return visual
end

-- The sprite pipeline is the host boundary here: the test replaces the shared
-- field-sprite compilation with canned visuals and restores it afterwards so
-- no other suite observes the stub.
local function withStubbedPipeline(visualFor, fn)
  local original = FieldActorCompiler.compileSprites
  FieldActorCompiler.compileSprites = function(_, spriteIds)
    local visuals, atlases = {}, {}
    for _, spriteId in ipairs(spriteIds) do
      visuals[spriteId] = visualFor(spriteId)
      atlases[spriteId] = {}
    end
    return { visuals = visuals, atlases = atlases, dependencies = { stubbed = true } }
  end
  local ok, result = pcall(fn)
  FieldActorCompiler.compileSprites = original
  if not ok then
    error(result, 0)
  end
end

local function compileWith(visualFor)
  local result, err
  withStubbedPipeline(visualFor, function()
    result, err = FollowingMonVisualCompiler.compile({})
  end)
  return result, err
end

function T.capable_atlas_visuals_compile_into_the_follower_range()
  local compiled, err = compileWith(capableAtlasVisual)
  Assert.isTrue(err == nil, "capable atlases compile without a producer error")
  Assert.isTrue(compiled ~= nil, "capable atlases produce a follower bundle")
  assert(compiled ~= nil)
  local previous
  for _, visualId in ipairs(compiled.visualIds) do
    if previous ~= nil then
      Assert.isTrue(previous < visualId, "follower visual ids publish in sorted order")
    end
    previous = visualId
    local visual = compiled.visuals[visualId]
    Assert.isTrue(visual ~= nil, "visual id " .. visualId .. " carries a visual")
    assert(visual ~= nil)
    Assert.equal(visual.render.kind, "atlas", "visual " .. visualId .. " stays a directional atlas")
    for _, direction in ipairs(CARDINAL_DIRECTIONS) do
      Assert.isTrue(
        visual.directions[direction] ~= nil and visual.directions[direction].walk ~= nil,
        "visual " .. visualId .. " keeps a " .. direction .. " walk clip"
      )
    end
  end
end

function T.static_model_visuals_are_rejected()
  local compiled, err = compileWith(staticModelVisual)
  Assert.isTrue(compiled == nil, "static models do not publish as follower visuals")
  Assert.isTrue(Errors.is(err), "rejection carries a structured producer error")
  assert(Errors.is(err))
  Assert.equal(err.code, "MON_FOLLOWER_VISUAL_UNSUPPORTED", "rejection names the capability failure")
  Assert.isTrue(type(err.context.visualId) == "number", "rejection names the follower visual id")
  Assert.isTrue(type(err.context.spriteId) == "number", "rejection names the source sprite id")
  Assert.equal(err.context.kind, "staticModel", "rejection names the incapable render kind")
end

function T.atlas_visuals_without_walk_poses_are_rejected()
  local compiled, err = compileWith(walklessAtlasVisual)
  Assert.isTrue(compiled == nil, "walkless atlases do not publish as follower visuals")
  Assert.isTrue(Errors.is(err), "rejection carries a structured producer error")
  assert(Errors.is(err))
  Assert.equal(err.code, "MON_FOLLOWER_VISUAL_UNSUPPORTED", "rejection names the capability failure")
end

function T.single_frame_atlas_visuals_are_rejected()
  local compiled, err = compileWith(singleFrameAtlasVisual)
  Assert.isTrue(compiled == nil, "single-frame atlases do not publish as follower visuals")
  Assert.isTrue(Errors.is(err), "rejection carries a structured producer error")
  assert(Errors.is(err))
  Assert.equal(err.code, "MON_FOLLOWER_VISUAL_UNSUPPORTED", "rejection names the capability failure")
end

function T.visuals_missing_a_cardinal_direction_are_rejected()
  local compiled, err = compileWith(directionlessAtlasVisual)
  Assert.isTrue(compiled == nil, "directionless visuals do not publish as follower visuals")
  Assert.isTrue(Errors.is(err), "rejection carries a structured producer error")
end

return { tests = T }
