-- Elm starter-ball machine composite: the real lab scene (ordinary map and
-- building geometry, including the machine) renders together with the runtime
-- starter-ball props through the production scene loader and field renderer.
-- The camera target is the translation of the building instance the
-- independently derived ball positions register to -- real machine geometry,
-- never a ball transform -- so a world-placement error moves the balls out of
-- the machine view instead of being followed. A balls-off control proves the
-- machine oracle is independent, and the old omitted-origin placement is shown
-- to contribute nothing at the machine.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local RomFs = require("romdump.src.source.RomFs")
local StarterLab = require("romdump.src.reference.hgss.starter_lab")
local Matrix4 = require("libs.math.src.Matrix4")
local RomImporter = require("romdump.src.source.RomImporter")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}

local MAP_ID = 61
local MAP_SYMBOL = "MAP_NEW_BARK_ELMS_LAB_1F"
local WIDTH, HEIGHT = 1280, 720
local STEP = 4

-- A ball counts as registered when its scene-space centre sits inside the
-- machine footprint it belongs to (about one tile across).
local REGISTRATION_TILES = 1.5

-- Independently derived final-scene ball centres: retail base translations
-- normalized once, composed with the lab cell origin from generic map
-- primitives. Never the starter production transform.
local function expectedBallCentres(versionId)
  local romFs = assert(RomFs.open(versionId), "the lab scene origin resolves from a ready dump")
  local resolved, resolveErr = MapResolver.resolve(romFs, MAP_SYMBOL)
  romFs:close()
  assert(resolved, resolveErr and resolveErr.message or "Elm's Lab resolves to a matrix cell")
  local halfCell = FieldGrid.CELL_TILES / 2
  local originX, originZ = resolved.worldOriginX - halfCell, resolved.worldOriginZ - halfCell
  local out = {}
  for _, position in ipairs(StarterLab.positions) do
    local x, y, z = MapUnits.toTiles(position.x, position.y, position.z)
    out[#out + 1] = { x = originX + x, y = y, z = originZ + z }
  end
  return out
end

-- The old omitted-origin placement, built in-test from the same source facts:
-- the fault injection the composite oracle must reject.
local function omittedOriginPlacements()
  local out = {}
  for _, position in ipairs(StarterLab.positions) do
    local x, y, z = MapUnits.toTiles(position.x, position.y, position.z)
    out[#out + 1] = { transform = Matrix4.toArray(Matrix4.translate(x, y, z)) }
  end
  return out
end

local function distance2D(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

local function channelDistance(image, x, y, other, ox, oy)
  local r1, g1, b1 = image:getPixel(x, y)
  local r2, g2, b2 = other:getPixel(ox, oy)
  return math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2)
end

local function isCentre(x, y)
  return x >= WIDTH * 0.25 and x < WIDTH * 0.75 and y >= HEIGHT * 0.25 and y < HEIGHT * 0.75
end

local function countDiff(image, other)
  local total, centre = 0, 0
  for y = 0, HEIGHT - 1, STEP do
    for x = 0, WIDTH - 1, STEP do
      if channelDistance(image, x, y, other, x, y) > 0.03 then
        total = total + 1
        if isCentre(x, y) then
          centre = centre + 1
        end
      end
    end
  end
  return total, centre
end

local function countBright(image)
  local total, centre = 0, 0
  for y = 0, HEIGHT - 1, STEP do
    for x = 0, WIDTH - 1, STEP do
      local red, green, blue, alpha = image:getPixel(x, y)
      if alpha > 0.5 and math.max(red, green, blue) > 0.05 then
        total = total + 1
        if isCentre(x, y) then
          centre = centre + 1
        end
      end
    end
  end
  return total, centre
end

function T.starter_balls_render_on_the_machine_in_the_real_lab_frame(scope)
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local expected = expectedBallCentres(versionId)
      local cache = CacheFs.forVersion(versionId)
      local scene = assert(cache:loadLua(MapAssetCache.mapDir(MAP_ID) .. "/scene.lua"))
      local group = assert(scene.runtimeProps and scene.runtimeProps.starter_balls)

      -- The machine is the ordinary building instance the independent ball
      -- positions register to -- the nearest scene placement, found through
      -- generic scene data rather than any ball-derived shortcut.
      local machine, best = nil, math.huge
      for _, inst in ipairs(scene.buildingInstances) do
        local here = { x = inst.transform[13], z = inst.transform[15] }
        local far = 0
        for _, centre in ipairs(expected) do
          far = math.max(far, distance2D(here, centre))
        end
        if far < best then
          best, machine = far, inst
        end
      end
      Assert.isTrue(best < REGISTRATION_TILES, "the expected balls sit on a real machine placement")
      machine = assert(machine, "a lab machine placement registers the expected balls")
      local anchor = { x = machine.transform[13], y = machine.transform[14], z = machine.transform[15] }

      local runtime = MapSceneLoader.load(cache, scene)
      scope:own({
        release = function()
          runtime:release()
        end,
      })

      local profiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
      local profile = assert(profiles.profiles[scene.cameraType or 0])
      local camera = FieldCamera.new(profile, {
        canonicalAspect = 4 / 3,
        initialTarget = { x = anchor.x, y = anchor.y, z = anchor.z },
      })
      local viewport = FieldViewport.new(WIDTH, HEIGHT, { mode = "expanded" })
      camera:setProjectionAspect(viewport:worldAspect())
      local renderer = scope:own(FieldRenderer.new())

      local function renderFrame(propPlacements)
        if propPlacements ~= nil then
          runtime:replaceRuntimeStaticProps("starter_balls", propPlacements)
        end
        local worldParts = {
          runtime.mapDraws,
          runtime.staticBuildingDraws,
          runtime.animatedBuildingDraws,
          runtime.runtimePropDraws,
        }
        local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 1)
        renderer:draw({
          lighting = runtime.lighting,
          edgeColors = runtime.edgeColors,
          fog = runtime.fog,
        }, camera, worldParts, nil, viewport, 0)
        love.graphics.setCanvas()
        return scope:own(canvas:newImageData())
      end

      -- The balls-off frame leaves the runtime prop lane empty, so only
      -- ordinary lab geometry contributes.
      local withoutBalls = renderFrame(nil)
      local withoutTotal, withoutCentre = countBright(withoutBalls)
      Assert.isTrue(withoutTotal > 20, "the machine-anchored view shows lab geometry without balls")
      Assert.isTrue(withoutCentre > 20, "the machine itself is visible without balls")

      local withBalls = renderFrame(group.placements)
      local totalDiff, centreDiff = countDiff(withBalls, withoutBalls)
      Assert.isTrue(totalDiff > 20, "the production ball placements contribute visible pixels to the lab frame")
      Assert.isTrue(centreDiff > 10, "the production ball pixels land on the machine at the frame centre")

      local withWrong = renderFrame(omittedOriginPlacements())
      local _, wrongCentre = countDiff(withWrong, withoutBalls)
      Assert.equal(wrongCentre, 0, "the omitted-origin placement contributes no pixels at the machine")
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
