-- FollowingMonTransitionRenderer tests that the transient effect draws
-- only its currently active source part at the normalized partner anchor,
-- reuses pooled immutable resources across parts, never advances lifecycle
-- state during draw, and releases its resources exactly once. The model
-- stack is stubbed the way the terrain renderer test stubs it; projection
-- stays real.

local Assert = require("tests.support.Assert")

local T = { metadata = { capabilities = {} }, tests = {} }

local MODEL = {
  materials = {
    {
      id = 0,
      name = "transition",
      texture = "transition.png",
      wrap = { x = "clamp", y = "clamp" },
    },
  },
  batches = {
    {
      geometry = "transition.mesh",
      material = 0,
      alphaClass = "cutout",
      cullMode = "back",
      polygonAlpha = 31,
      polygonMode = "modulation",
      polygonId = 0,
      translucentDepthWrite = false,
      depthEqual = false,
      lightMask = 15,
      fogEnabled = false,
    },
  },
}

local function definition()
  return {
    models = {
      {
        kind = "static",
        materials = MODEL.materials,
        batches = MODEL.batches,
      },
      {
        kind = "nitro-dynamic",
        materials = MODEL.materials,
        batches = MODEL.batches,
        animations = { { name = "transition", frameCount = 8 } },
      },
    },
    placementOffset = { x = 0, y = 6, z = 0.5 },
  }
end

local function meshlessModelInstance()
  local instance = { transform = {}, updates = 0 }
  function instance:updateFixed()
    self.updates = self.updates + 1
  end
  function instance:evaluatePose() end
  function instance:drawItems(renderMeshesById)
    assert(type(renderMeshesById) == "table", "the transition renderer must provide render meshes")
    return { { transform = self.transform } }
  end
  return instance
end

local function newRenderer(poolCalls)
  local moduleNames = {
    "libs.hgss.src.presentation.FollowingMonTransitionRenderer",
    "libs.hgss.src.presentation.ModelDefinition",
    "libs.hgss.src.presentation.ModelInstance",
    "libs.hgss.src.presentation.SceneDescriptor",
  }
  local saved = {}
  for _, name in ipairs(moduleNames) do
    saved[name] = package.loaded[name]
  end
  package.loaded["libs.hgss.src.presentation.ModelDefinition"] = {
    fromNitroDescriptor = function(_, descriptor)
      return { key = descriptor.key, meshes = { { id = "part", geometry = "transition.mesh" } } }
    end,
  }
  package.loaded["libs.hgss.src.presentation.ModelInstance"] = {
    new = function()
      return meshlessModelInstance()
    end,
  }
  package.loaded["libs.hgss.src.presentation.SceneDescriptor"] = {
    wrap = function()
      return { x = "clamp", y = "clamp" }
    end,
    wrapByMaterial = function()
      return { [0] = { x = "clamp", y = "clamp" } }
    end,
  }
  package.loaded["libs.hgss.src.presentation.FollowingMonTransitionRenderer"] = nil
  local Renderer = require("libs.hgss.src.presentation.FollowingMonTransitionRenderer")
  local pool = {
    build = function(_, fn)
      poolCalls.builds = (poolCalls.builds or 0) + 1
      return fn()
    end,
    meshFor = function()
      poolCalls.meshes = (poolCalls.meshes or 0) + 1
      return { mesh = {}, center = { 0, 0, 0 } }
    end,
    imageFor = function()
      poolCalls.images = (poolCalls.images or 0) + 1
      return {}
    end,
  }
  local renderer = Renderer.new({ transition = definition() }, pool)
  local function cleanup()
    renderer:dispose()
    for _, name in ipairs(moduleNames) do
      package.loaded[name] = saved[name]
    end
  end
  return renderer, cleanup
end

local function runtimeMap()
  return {
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function()
        return true
      end,
    },
  }
end

local function status(phase, initialInstance, animatedInstance)
  return {
    instances = {
      {
        phase = phase,
        fieldX = 2,
        fieldZ = 5,
        worldY = 3,
        initialInstance = initialInstance,
        animatedInstance = animatedInstance,
      },
    },
  }
end

T.tests["empty status draws nothing without projection"] = function()
  local poolCalls = {}
  local renderer, cleanup = newRenderer(poolCalls)
  local ok, items = pcall(function()
    return renderer:drawItems({ instances = {} }, {})
  end)
  cleanup()
  Assert.isTrue(ok, tostring(items))
  Assert.equal(#items, 0)
end

T.tests["prelude draws only the companion part at the normalized anchor"] = function()
  local poolCalls = {}
  local renderer, cleanup = newRenderer(poolCalls)
  local initial = renderer:newInstance("initial")
  local animated = renderer:newInstance("animated")
  local ok, items = pcall(function()
    return renderer:drawItems(status("prelude", initial, animated), runtimeMap())
  end)
  cleanup()
  Assert.isTrue(ok, tostring(items))
  Assert.equal(#items, 1)
  Assert.equal(items[1].transitionPart, "initial", "the prelude draws the companion part only")
  Assert.equal(items[1].transform[13], -13.5, "the anchor projects the partner tile")
  Assert.equal(items[1].transform[14], 9, "the draw adds the normalized vertical offset")
  Assert.equal(items[1].transform[15], -10.0, "the draw adds the normalized depth offset")
  Assert.equal(animated.updates, 0, "draw never advances the inactive part either")
end

T.tests["animated phase draws only the animated part at the same anchor"] = function()
  local poolCalls = {}
  local renderer, cleanup = newRenderer(poolCalls)
  local initial = renderer:newInstance("initial")
  local animated = renderer:newInstance("animated")
  local ok, items = pcall(function()
    return renderer:drawItems(status("animated", initial, animated), runtimeMap())
  end)
  cleanup()
  Assert.isTrue(ok, tostring(items))
  Assert.equal(#items, 1)
  Assert.equal(items[1].transitionPart, "animated", "the switch swaps the drawn part")
  Assert.equal(items[1].transform[13], -13.5, "the anchor still projects the partner tile")
  Assert.equal(items[1].transform[14], 9, "the normalized offset survives the phase switch")
  Assert.equal(animated.updates, 0, "draw never advances lifecycle state")
end

T.tests["unknown parts fail loudly instead of drawing a substitute"] = function()
  local poolCalls = {}
  local renderer, cleanup = newRenderer(poolCalls)
  local ok = pcall(function()
    renderer:newInstance("follower")
  end)
  cleanup()
  Assert.isFalse(ok, "an unknown part must fail rather than alias a real one")
end

T.tests["mutable instances share pooled immutable resources"] = function()
  local poolCalls = {}
  local renderer, cleanup = newRenderer(poolCalls)
  local first = renderer:newInstance("animated")
  local meshesAfterFirst = poolCalls.meshes
  local second = renderer:newInstance("animated")
  cleanup()
  Assert.isTrue(first ~= second, "mutable part instances stay independent")
  Assert.equal(poolCalls.meshes, meshesAfterFirst, "repeated instances reuse pooled meshes")
  Assert.equal(poolCalls.builds, 1, "immutable resources build once per renderer lifetime")
end

return T
