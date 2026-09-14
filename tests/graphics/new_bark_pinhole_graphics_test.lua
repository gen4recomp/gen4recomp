-- Graphics regression for outdoor raster pinholes over the real New Bark
-- Town central scene through the production presentation path.
--
-- The compiled central-cell scene loads through MapSceneLoader, renders its
-- terrain draws through FieldRenderer's world MRT under the outdoor camera
-- profile across a subpixel camera walk, and the renderState target is
-- scanned for isolated enclosed rear-plane pixels: a rear-plane sample whose
-- eight neighbors all drew terrain. Separately rendered terrain batches that
-- segment a shared boundary span differently can leave such a sample owned
-- by neither batch; after producer boundary repair the sweep must find zero.
-- The assertion is a semantic zero count, never a golden screenshot.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local RomImporter = require("romdump.src.source.RomImporter")

local NEW_BARK_MAP_ID = 60
local INSET_PX = 24

local function isRear(r)
  return r >= 0.99
end

local function countEnclosedRear(stateImg, w, h)
  local count = 0
  for x = INSET_PX, w - 1 - INSET_PX do
    for y = INSET_PX, h - 1 - INSET_PX do
      local r = stateImg:getPixel(x, y)
      if isRear(r) then
        local enclosed = true
        for ox = -1, 1 do
          for oy = -1, 1 do
            if (ox ~= 0 or oy ~= 0) and isRear(stateImg:getPixel(x + ox, y + oy)) then
              enclosed = false
              break
            end
          end
          if not enclosed then
            break
          end
        end
        if enclosed then
          count = count + 1
        end
      end
    end
  end
  return count
end

local function sceneCenter(draws)
  local cx, cy, cz, n = 0, 0, 0, 0
  for _, draw in ipairs(draws) do
    local center = assert(draw.center, "terrain draw carries a sort center")
    cx, cy, cz = cx + center[1], cy + center[2], cz + center[3]
    n = n + 1
  end
  Assert.isTrue(n > 0, "the scene draws terrain")
  return { x = cx / n, y = cy / n, z = cz / n }
end

local function runVersion(scope, versionId)
  local cache = CacheFs.forVersion(versionId)
  local scene = assert(cache:loadLua(MapAssetCache.mapDir(NEW_BARK_MAP_ID) .. "/scene.lua"))
  local runtime = MapSceneLoader.load(cache, scene)
  scope:own({
    release = function()
      runtime:release()
    end,
  })
  local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local profile =
    assert(cameraProfiles.profiles[scene.cameraType or 0], "a camera profile exists for the scene camera type")

  local center = sceneCenter(runtime.mapDraws)
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  local fieldRenderer = FieldRenderer.new({
    clearColor = { 0.08, 0.09, 0.12, 1 },
    worldRasterScale = 3,
  })
  scope:own({
    release = function()
      fieldRenderer:release()
    end,
  })
  local sceneRuntime = {
    lighting = runtime.lighting,
    edgeColors = runtime.edgeColors,
    fog = runtime.fog,
  }

  local total = 0
  local worst = 0
  for i = 0, 23 do
    local camera = FieldCamera.new(profile, {
      canonicalAspect = 4 / 3,
      initialTarget = {
        x = center.x + i * 0.2 + (i % 2) * 0.013,
        y = center.y,
        z = center.z + i * 0.13 + (i % 3) * 0.007,
      },
    })
    camera:setProjectionAspect(viewport:worldAspect())
    fieldRenderer:draw(sceneRuntime, camera, { runtime.mapDraws }, nil, viewport, 0, 3)
    local stateImg = fieldRenderer.renderState:newImageData()
    local holes = countEnclosedRear(stateImg, fieldRenderer.gxRenderer.stateW, fieldRenderer.gxRenderer.stateH)
    total = total + holes
    worst = math.max(worst, holes)
    stateImg:release()
  end
  Assert.isTrue(
    total == 0,
    "no isolated enclosed rear-plane pixel across the New Bark walk: " .. total .. " total, worst frame " .. worst
  )
end

local suite = GraphicsSmoke.suite({
  ["new_bark_walk_leaves_no_isolated_rear_plane_samples"] = function(scope)
    local versions = 0
    for _, versionId in ipairs(GameVersion.ORDER) do
      if RomImporter.isReady(versionId) then
        versions = versions + 1
        runVersion(scope, versionId)
      end
    end
    Assert.isTrue(versions > 0, "a ready imported game version is required")
  end,
})
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
