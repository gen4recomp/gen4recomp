-- Starter-ball derived-cache graphics proof: the production Elm's Lab scene's
-- runtime-prop draws contribute visible pixels from a fixed machine-area view.
-- The camera target is a constant source-derived machine-area position, never
-- read from the generated draw centers, so a world-placement error moves the
-- props out of view instead of being followed.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local RomImporter = require("romdump.src.source.RomImporter")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local T = {}

-- Fixed Elm machine-area target in field tiles, derived from the retail
-- starter base translations (source/16: x in [8.1875, 8.8125], z in
-- [4.0625, 4.5]), not from any generated draw.
local MACHINE_TARGET = { x = 8.5, y = 0, z = 4.2 }

local function visiblePixels(image, width, height)
  local found = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local red, green, blue, alpha = image:getPixel(x, y)
      if alpha > 0.5 and math.max(red, green, blue) > 0.05 then
        found = found + 1
      end
    end
  end
  return found
end

function T.starter_balls_are_visible_from_the_fixed_machine_area(scope)
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      local scene = assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua"))
      local runtime = MapSceneLoader.load(cache, scene)
      scope:own({
        release = function()
          runtime:release()
        end,
      })

      local group = assert(scene.runtimeProps and scene.runtimeProps.starter_balls)
      runtime:replaceRuntimeStaticProps("starter_balls", group.placements)
      Assert.equal(#runtime.runtimePropDraws, 3, "the real scene owns one draw set for three starter placements")

      local profiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
      local profile = assert(profiles.profiles[scene.cameraType or 0])
      local camera = FieldCamera.new(profile, {
        canonicalAspect = 4 / 3,
        initialTarget = { x = MACHINE_TARGET.x, y = MACHINE_TARGET.y, z = MACHINE_TARGET.z },
      })
      local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
      camera:setProjectionAspect(viewport:worldAspect())
      local renderer = scope:own(FieldRenderer.new())

      local canvas = scope:own(love.graphics.newCanvas(1280, 720))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 1)
      renderer:draw({
        lighting = runtime.lighting,
        edgeColors = runtime.edgeColors,
        fog = runtime.fog,
      }, camera, { runtime.runtimePropDraws }, nil, viewport, 0)
      love.graphics.setCanvas()
      local image = scope:own(canvas:newImageData())
      Assert.isTrue(visiblePixels(image, 1280, 720) > 20, "the fixed machine-area view shows starter-ball pixels")
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
