-- Bag hero camera, light, viewport, and definition-key contracts: the hero
-- renderer builds its immutable view/projection from the generated camera
-- facts (both angles participate, only perspective type 0 is supported),
-- derives its lit scene record from the generated light vectors and color
-- through the shared field-lighting record shape, draws strictly inside the
-- hero placement through the shared renderer stack, and keys model
-- definitions per gender. Narrow recording doubles stand in for the
-- GPU-backed model stack; camera math runs through the real shared matrix
-- helpers.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics").new

local HERO_MODULE = "libs.hgss.src.presentation.BagHeroRenderer"
local POOL_MODULE = "libs.hgss.src.presentation.GpuAssetPool"
local DEFINITION_MODULE = "libs.hgss.src.presentation.ModelDefinition"
local INSTANCE_MODULE = "libs.hgss.src.presentation.ModelInstance"
local RENDERER_MODULE = "libs.hgss.src.presentation.FieldRenderer"
local SCENE_MODULE = "libs.hgss.src.presentation.SceneDescriptor"

local T = {}

local function clip(id, names)
  return { id = id, name = id, semanticNames = names }
end

local function descriptor(gender)
  return {
    schema = "g4-model-v5",
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = {
      {
        id = 0,
        name = "widget",
        wrap = { x = "clamp", y = "clamp" },
      },
    },
    animations = {
      clip(gender .. ".pose.items", { "pocket.items.pose" }),
      clip(gender .. ".pattern.items", { "pocket.items.pattern" }),
      clip(gender .. ".material", {}),
    },
  }
end

local function manifest(overrides)
  local record = {
    schema = "g4-bag-assets-v3",
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = { image = "bag/hero-male.png", width = 256, height = 192 },
        female = { image = "bag/hero-female.png", width = 256, height = 192 },
      },
      description = {
        frame = {
          image = "bag/description.png",
          alternateImage = "bag/description-alt.png",
          rect = { x = 0, y = 144, width = 256, height = 48 },
        },
        textRect = { x = 20, y = 144, width = 228, height = 40 },
      },
      model = { male = descriptor("male"), female = descriptor("female") },
      animations = {
        states = {
          { pocket = "items", pose = "pocket.items.pose", pattern = "pocket.items.pattern" },
        },
        material = { male = "male.material", female = "female.material" },
      },
      presentation = {
        camera = {
          target = { x = 0, y = 0, z = 0 },
          distance = 21.24375,
          angleXDegrees = 328.4,
          angleYDegrees = 28.3,
          perspectiveType = 0,
          perspectiveAngle = 256,
          clipNear = 7.6875,
          clipFar = 106.25,
        },
        transform = {
          translation = { x = 0, y = -45, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
        lights = {
          count = 4,
          color = { r = 31, g = 31, b = 31 },
          vectors = {
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
          },
        },
        materials = {
          diffuse = { r = 15, g = 15, b = 15 },
          ambient = { r = 10, g = 10, b = 10 },
          specular = { r = 15, g = 15, b = 15 },
          emission = { r = 15, g = 15, b = 15 },
        },
      },
    },
  }
  for key, value in pairs(overrides or {}) do
    record.hero.presentation.camera[key] = value
  end
  return record
end

local function status()
  return { pocket = "items", pose = "pocket.items.pose", pattern = "pocket.items.pattern", frame = 0 }
end

local function placement()
  return {
    frame = { x = 0, y = 0, width = 256, height = 192 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
  }
end

local function stubCache()
  return {
    read = function(_)
      return nil
    end,
  }
end

local function newHero(Hero, value)
  return Hero.new({ cacheFs = stubCache(), manifest = value, graphics = FakeGraphics({}) })
end

local function makeDoubles()
  local rec = { keys = {}, draws = {} }
  local poolModule = {}
  function poolModule.new()
    local pool = {}
    function pool:meshFor(_)
      return { mesh = {}, center = { 0, 0, 0 } }
    end
    function pool:imageFor(_)
      return {}
    end
    function pool:build(fn)
      return fn()
    end
    function pool:release() end
    return pool
  end
  local definitionModule = {}
  function definitionModule.fromNitroDescriptor(desc, opts)
    rec.keys[#rec.keys + 1] = opts and opts.key or nil
    local definition = { animations = desc.animations }
    function definition:animation(nameOrSemantic)
      for _, entry in ipairs(self.animations) do
        if entry.name == nameOrSemantic or entry.id == nameOrSemantic then
          return entry
        end
        for _, semantic in ipairs(entry.semanticNames) do
          if semantic == nameOrSemantic then
            return entry
          end
        end
      end
      return nil
    end
    function definition:binding()
      return {}
    end
    return definition
  end
  local instanceModule = {}
  function instanceModule.new(definition)
    local instance = { definition = definition, attachments = {} }
    function instance:play(nameOrSemantic, playOpts)
      local found = definition:animation(nameOrSemantic)
      assert(found ~= nil, "unknown clip " .. tostring(nameOrSemantic))
      local player = { count = 0 }
      function player:updateFixed()
        self.count = self.count + 1
      end
      local attachment = { clip = found, player = player, loopMode = playOpts and playOpts.loopMode or nil }
      self.attachments[#self.attachments + 1] = attachment
      return attachment
    end
    function instance:stop(handle)
      for index, attachment in ipairs(self.attachments) do
        if attachment == handle then
          table.remove(self.attachments, index)
          return 1
        end
      end
      return 0
    end
    function instance:evaluatePose() end
    function instance:drawItems()
      return {}
    end
    return instance
  end
  local rendererModule = {}
  function rendererModule.new()
    local renderer = {}
    function renderer:draw(...)
      rec.draws[#rec.draws + 1] = { ... }
    end
    function renderer:release() end
    return renderer
  end
  local sceneModule = { MIRRORED_REPEAT = "mirror" }
  function sceneModule.wrap()
    return { x = "clamp", y = "clamp" }
  end
  return rec,
    {
      [POOL_MODULE] = poolModule,
      [DEFINITION_MODULE] = definitionModule,
      [INSTANCE_MODULE] = instanceModule,
      [RENDERER_MODULE] = rendererModule,
      [SCENE_MODULE] = sceneModule,
    }
end

local DOUBLE_NAMES = { POOL_MODULE, DEFINITION_MODULE, INSTANCE_MODULE, RENDERER_MODULE, SCENE_MODULE }

local function installDoubles(doubles)
  local saved = {}
  for _, name in ipairs(DOUBLE_NAMES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = doubles[name]
  end
  package.loaded[HERO_MODULE] = nil
  return saved
end

local function restoreDoubles(saved)
  for _, name in ipairs(DOUBLE_NAMES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[HERO_MODULE] = nil
end

local function withDoubles(fn)
  local rec, doubles = makeDoubles()
  local saved = installDoubles(doubles)
  local ok, err = pcall(fn, rec)
  restoreDoubles(saved)
  if not ok then
    error(err, 0)
  end
end

local function requireHero()
  local ok, mod = pcall(require, HERO_MODULE)
  Assert.isTrue(ok, "the bag hero pane owns its model realization collaborator")
  return assert(mod)
end

function T.definitions_carry_the_gender_model_key()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = newHero(Hero, manifest())
    renderer:draw("male", status(), placement())
    renderer:draw("female", status(), placement())
    Assert.deepEqual(rec.keys, { "bag-hero:male", "bag-hero:female" }, "model definitions key by gender")
    renderer:release()
  end)
end

function T.unsupported_projection_types_fail_closed()
  withDoubles(function()
    local Hero = requireHero()
    Assert.throws(function()
      newHero(Hero, manifest({ perspectiveType = 1 }))
    end, "an orthographic hero camera has no supported mapping")
  end)
end

function T.camera_matches_the_generated_clip_planes_and_honors_both_angles()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = newHero(Hero, manifest())
    renderer:draw("male", status(), placement())
    Assert.equal(#rec.draws, 1, "one hero draw reaches the shared renderer")
    local sceneRuntime, camera = rec.draws[1][1], rec.draws[1][2]
    Assert.equal(camera.far, 106.25, "the camera carries the generated far plane")
    Assert.equal(#camera:projection(), 16, "the camera carries a projection matrix")
    Assert.equal(#camera:view(1), 16, "the camera carries a view matrix")
    local firstView = camera:view(1)
    renderer:release()

    local tilted = manifest({ angleYDegrees = 48.3 })
    local second = newHero(Hero, tilted)
    second:draw("male", status(), placement())
    Assert.equal(#rec.draws, 2, "the tilted draw reaches the shared renderer")
    local secondView = rec.draws[2][2]:view(1)
    local moved = false
    for index = 1, 16 do
      if math.abs(firstView[index] - secondView[index]) > 1e-9 then
        moved = true
      end
    end
    Assert.isTrue(moved, "the yaw angle participates in the view")
    second:release()

    local pitched = manifest({ angleXDegrees = 318.4 })
    local third = newHero(Hero, pitched)
    third:draw("male", status(), placement())
    local thirdView = rec.draws[3][2]:view(1)
    moved = false
    for index = 1, 16 do
      if math.abs(firstView[index] - thirdView[index]) > 1e-9 then
        moved = true
      end
    end
    Assert.isTrue(moved, "the pitch angle participates in the view")
    third:release()
    Assert.isTrue(sceneRuntime.lighting ~= nil, "the draw carries a lighting record")
  end)
end

function T.lighting_selects_a_lit_field_record_from_the_generated_vectors()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = newHero(Hero, manifest())
    renderer:draw("male", status(), placement())
    local lighting = rec.draws[1][1].lighting
    Assert.notNil(lighting, "the hero scene carries its lighting profile")
    Assert.equal(#lighting.records, 1, "the static hero scene carries one light record")
    local record = lighting.records[1]
    Assert.equal(#record.lights, 4, "all four generated lights reach the record")
    for index, light in ipairs(record.lights) do
      Assert.isTrue(light.enabled, "generated light " .. index .. " is enabled")
      Assert.deepEqual(light.vectorFx12, { 4096, 0, 0 }, "generated light " .. index .. " keeps its manifest direction")
      Assert.equal(light.colorRgb555, 31 + 32 * 31 + 1024 * 31, "generated light " .. index .. " keeps its white color")
    end
    Assert.equal(record.diffuseRgb555, 15 + 32 * 15 + 1024 * 15, "the diffuse register carries the generated gray")
    Assert.equal(record.ambientRgb555, 10 + 32 * 10 + 1024 * 10, "the ambient register carries the generated gray")
    Assert.equal(record.specularRgb555, 15 + 32 * 15 + 1024 * 15, "the specular register carries the generated gray")
    Assert.equal(record.emissionRgb555, 15 + 32 * 15 + 1024 * 15, "the emission register carries the generated gray")
    renderer:release()
  end)
end

function T.lighting_follows_manifest_vectors_instead_of_a_fixed_shape()
  withDoubles(function(rec)
    local Hero = requireHero()
    local tilted = manifest()
    tilted.hero.presentation.lights.vectors[1] = { x = 0, y = 1, z = 0 }
    tilted.hero.presentation.lights.color = { r = 20, g = 20, b = 20 }
    local renderer = newHero(Hero, tilted)
    renderer:draw("male", status(), placement())
    local record = rec.draws[1][1].lighting.records[1]
    Assert.deepEqual(record.lights[1].vectorFx12, { 0, 4096, 0 }, "the first light follows its manifest vector")
    Assert.deepEqual(record.lights[2].vectorFx12, { 4096, 0, 0 }, "the remaining lights keep theirs")
    Assert.equal(record.lights[1].colorRgb555, 20 + 32 * 20 + 1024 * 20, "light colors follow the manifest color")
    renderer:release()
  end)
end

function T.draw_stays_inside_the_hero_placement()
  withDoubles(function(rec)
    local Hero = requireHero()
    local renderer = newHero(Hero, manifest())
    local resolved = placement()
    resolved.frame = { x = 0, y = 0, width = 512, height = 384 }
    renderer:draw("female", status(), resolved)
    local viewport = rec.draws[1][5]
    Assert.notNil(viewport, "the draw carries its viewport")
    Assert.equal(viewport.worldViewport.width, 256, "the viewport stays at canonical width")
    Assert.equal(viewport.worldViewport.height, 192, "the viewport stays at canonical height")
    Assert.equal(viewport.worldViewport.x, 0, "the viewport matches the hero placement origin")
    renderer:release()
  end)
end

return { tests = T }
