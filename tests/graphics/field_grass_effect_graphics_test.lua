-- Real generated grass presentation through the model, material, and GPU
-- paths. The assertions inspect stable material identity and a real draw.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController")
local FieldTerrainEffectRenderer = require("libs.hgss.src.presentation.FieldTerrainEffectRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local function updateWithOwner(controller, owner)
  local update = controller.updateFixed
  ---@cast update fun(self: table, owner: table)
  return update(controller, owner)
end

local function sceneRuntime()
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  return {
    mapDraws = {},
    buildingDraws = {},
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
end

local function runVersion(scope, versionId)
  local cache = CacheFs.forVersion(versionId)
  local index = assert(cache:loadLua(FieldEffectAssetCache.indexPath()))
  local assets = { effects = {} }
  for _, kind in ipairs({ "tall_grass", "very_tall_grass", "trainer_reveal" }) do
    assets.effects[kind] = assert(cache:loadLua(index.effects[kind].path))
  end

  Assert.equal(Contract.fieldEffects.cacheFormat, "field-effect-cache-v8")
  local pool = scope:own(GpuAssetPool.new(cache))
  local renderer = FieldTerrainEffectRenderer.new(assets, pool)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local controller = FieldTerrainEffectController.new({
    effects = assets.effects,
    modelFactory = function(kind)
      return renderer:newInstance(kind)
    end,
  })
  local runtimeMap = {
    projectPhysicalPoint = function()
      return { worldX = 0, worldY = 0, worldZ = 0 }
    end,
  }
  local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local camera = FieldCamera.new(cameraProfiles.profiles[0], { canonicalAspect = 4 / 3 })
  local fieldRenderer = FieldRenderer.new({ clearColor = { 0.1, 0.2, 0.3, 1 } })
  scope:own({
    release = function()
      fieldRenderer:release()
    end,
  })
  local viewport = FieldViewport.new(256, 192, { mode = "strict" })
  local target = scope:own(love.graphics.newCanvas(256, 192))
  local effectKind = "tall_grass"

  for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
    effectKind = kind
    controller:clear()
    controller:emit({
      kind = effectKind,
      fieldX = 0,
      fieldZ = 0,
      worldY = 0,
      cellKey = "0:0",
      sourceSurfaceId = 0,
    })
    local firstItems = renderer:drawItems(controller:status(), runtimeMap)
    Assert.isTrue(#firstItems > 0, kind .. " must produce a real draw item at frame zero")
    local firstImage = firstItems[1].material.image
    local changed = false
    local frameItems = firstItems
    for _ = 1, 12 do
      updateWithOwner(controller, { fieldX = 0, fieldZ = 0, facing = "north" })
      frameItems = renderer:drawItems(controller:status(), runtimeMap)
      Assert.isTrue(#frameItems > 0, kind .. " must remain drawable during its intro")
      if frameItems[1].material.image ~= firstImage then
        changed = true
      end
    end
    Assert.isTrue(changed, kind .. " must change its effective material during the intro")
    local heldImage = frameItems[1].material.image
    for _ = 1, 3 do
      updateWithOwner(controller, { fieldX = 0, fieldZ = 0, facing = "north" })
    end
    local heldItems = renderer:drawItems(controller:status(), runtimeMap)
    Assert.isTrue(#heldItems > 0, kind .. " must remain drawable after the intro")
    Assert.equal(heldItems[1].material.image, heldImage, kind .. " must hold its final material")

    love.graphics.setCanvas(target)
    fieldRenderer:draw(sceneRuntime(), camera, { heldItems }, nil, viewport, 0, 3)
    love.graphics.setCanvas()
    Assert.isTrue(fieldRenderer.stats.drawCalls > 0, kind .. " must reach a real graphics draw")
  end
end

local T = GraphicsSmoke.suite({
  ["generated grass changes material and remains drawable at its held frame"] = function(scope)
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
T.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
T.metadata.tags = { "field", "grass", "materials" }
return T
