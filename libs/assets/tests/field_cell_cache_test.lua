-- Contract tests for strict physical-cell topology and runtime addressing.

local Assert = require("tests.support.Assert")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = {}

local function index()
  return {
    schema = FieldCellCache.INDEX_SCHEMA,
    matrices = {
      {
        matrixMemberId = 4,
        width = 3,
        height = 2,
        cells = {
          {
            matrixMemberId = 4,
            index = 1,
            x = 1,
            z = 0,
            mapHeaderId = 60,
            altitude = 2,
            landDataMemberId = 7,
            areaDataMemberId = 2,
            file = FieldCellCache.cellPath(4, 1),
          },
        },
      },
    },
  }
end

local function collisionBytes()
  local cells = {}
  for _ = 1, 32 * 32 do
    cells[#cells + 1] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  return CollisionGridAsset.encode({ width = 32, height = 32, cells = cells })
end

local function completeModel()
  return {
    schema = ModelAsset.SCHEMA,
    key = "outdoor:21:complete",
    kind = "static",
    batches = {},
    materials = {},
  }
end

local function dynamicModel()
  return {
    schema = ModelAsset.SCHEMA,
    key = "outdoor:22:dynamic",
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = {
      {
        id = 0,
        name = "dynamic-material",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        colors = {
          diffuse = { r = 255, g = 255, b = 255 },
          ambient = { r = 255, g = 255, b = 255 },
          specular = { r = 255, g = 255, b = 255 },
          emission = { r = 0, g = 0, b = 0 },
        },
        alphaMode = "opaque",
        polygonMode = "modulation",
        doubleSided = false,
        polygonAlpha = 31,
        texMtxMode = 0,
        texWidth = 0,
        texHeight = 0,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
    animations = {},
  }
end

local function presentationCell()
  local geometry = "assets/generated/maps/geometry/cell-mesh.g4mesh"
  local texture = "assets/generated/maps/textures/cell-texture.png"
  local modelKey = "outdoor:21:complete"
  return {
    schema = FieldCellCache.CELL_SCHEMA,
    matrixMemberId = 4,
    index = 1,
    x = 0,
    z = 0,
    mapHeaderId = 60,
    origin = { x = 0, y = 0, z = 0 },
    altitude = 0,
    landDataMemberId = 7,
    areaDataMemberId = 2,
    collision = { file = FieldCellCache.collisionPath(4, 1), width = 32, height = 32 },
    terrain = { schema = MapAssetCache.TERRAIN_SCHEMA, file = FieldCellCache.terrainPath(4, 1) },
    batches = {
      {
        geometry = geometry,
        material = 0,
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 5,
        fogEnabled = false,
      },
    },
    materials = {
      {
        id = 0,
        texture = texture,
        texWidth = 1,
        texHeight = 1,
        texMtxMode = 0,
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
    buildingInstances = {
      {
        placementIndex = 0,
        modelKey = modelKey,
        transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
      },
    },
    terrainAnimations = { textureSrt = false },
    calibration = { modelExtentTilesX = 32, modelExtentTilesZ = 32, posScale = 1 },
    dependencies = {
      marker = "marker",
      matrixMemberId = 4,
      index = 1,
      descriptor = {
        matrixMemberId = 4,
        index = 1,
        x = 0,
        z = 0,
        mapHeaderId = 60,
        altitude = 0,
        landDataMemberId = 7,
        areaDataMemberId = 2,
      },
    },
  }
end

local function presentationCache(present)
  local cell = presentationCell()
  local cellIndex = {
    schema = FieldCellCache.INDEX_SCHEMA,
    matrices = {
      {
        matrixMemberId = 4,
        width = 1,
        height = 1,
        cells = {
          {
            matrixMemberId = 4,
            index = 1,
            x = 0,
            z = 0,
            mapHeaderId = 60,
            altitude = 0,
            landDataMemberId = 7,
            areaDataMemberId = 2,
            file = cell.file or FieldCellCache.cellPath(4, 1),
          },
        },
      },
    },
  }
  cell.file = FieldCellCache.cellPath(4, 1)
  local paths = {
    geometry = cell.batches[1].geometry,
    texture = cell.materials[1].texture,
    model = MapAssetCache.modelPath(cell.buildingInstances[1].modelKey),
  }
  return {
    read = function(_, path)
      if path == FieldCellCache.markerPath() then
        return "marker"
      end
      if path == FieldCellCache.cellMarkerPath(4, 1) then
        return "marker"
      end
      if path == cell.collision.file then
        return collisionBytes()
      end
      return nil
    end,
    loadLua = function(_, path)
      if path == FieldCellCache.indexPath() then
        return cellIndex
      end
      if path == cell.file then
        return cell
      end
      if path == FieldCellCache.dependenciesPath(4, 1) then
        return cell.dependencies
      end
      if path == paths.model and present.model then
        return completeModel()
      end
      if path == cell.terrain.file then
        return { schema = MapAssetCache.TERRAIN_SCHEMA }
      end
      return nil
    end,
    exists = function(_, path)
      if path == cell.collision.file or path == cell.terrain.file then
        return true
      end
      if path == paths.geometry then
        return present.geometry
      end
      if path == paths.texture then
        return present.texture
      end
      if path == paths.model then
        return present.model
      end
      return false
    end,
  }
end

function T.resolves_physical_coordinate_without_logical_map()
  local entry = FieldCellCache.find(index(), 4, 1, 0)
  Assert.isTrue(entry ~= nil)
  entry = assert(entry)
  Assert.equal(entry.file, "data/generated/field/cells/4/1/cell.lua")
  Assert.isNil(FieldCellCache.find(index(), 4, 2, 0))
end

function T.rejects_duplicate_coordinates()
  local value = index()
  local first = value.matrices[1].cells[1]
  local duplicate = {}
  for key, item in pairs(first) do
    duplicate[key] = item
  end
  duplicate.index = 2
  value.matrices[1].cells[2] = duplicate
  local fs = {
    read = function()
      return "marker"
    end,
    loadLua = function(_, path)
      if path == FieldCellCache.indexPath() then
        return value
      end
      return nil
    end,
  }
  Assert.isFalse(FieldCellCache.isReady(fs, "marker"))
end

function T.rejects_malformed_collision_bytes_without_raising()
  local value = index()
  local cell = {
    schema = FieldCellCache.CELL_SCHEMA,
    matrixMemberId = 4,
    index = 1,
    x = 1,
    z = 0,
    mapHeaderId = 60,
    altitude = 2,
    landDataMemberId = 7,
    areaDataMemberId = 2,
    collision = { file = "collision.g4collision", width = 32, height = 32 },
    terrain = { file = "terrain.lua" },
    batches = {},
    materials = {},
    buildingInstances = {},
  }
  local fs = {
    read = function(_, path)
      if path == FieldCellCache.markerPath() then
        return "marker"
      end
      return "not-a-g4collision"
    end,
    loadLua = function(_, path)
      if path == FieldCellCache.indexPath() then
        return value
      end
      if path == value.matrices[1].cells[1].file then
        return cell
      end
      return nil
    end,
    exists = function(_, path)
      return path == cell.collision.file or path == cell.terrain.file
    end,
  }
  local ok, ready = pcall(FieldCellCache.isReady, fs, "marker")
  Assert.isTrue(ok, "malformed collision data must be an invalid cache, not an exception")
  Assert.isFalse(ready)
end

function T.rejects_missing_presentation_references()
  local cases = {
    { name = "geometry", present = { geometry = false, texture = true, model = true } },
    { name = "texture", present = { geometry = true, texture = false, model = true } },
    { name = "model", present = { geometry = true, texture = true, model = false } },
  }
  for _, case in ipairs(cases) do
    Assert.isFalse(
      FieldCellCache.isReady(presentationCache(case.present), "marker"),
      "missing " .. case.name .. " must invalidate the field-cell class"
    )
  end
end

function T.accepts_finite_half_tile_origin_and_rejects_non_finite_origin()
  local finite = presentationCache({ geometry = true, texture = true, model = true })
  local cell = assert(finite:loadLua(FieldCellCache.cellPath(4, 1)))
  cell.origin.y = 0.5
  Assert.isTrue(FieldCellCache.isReady(finite, "marker"), "half-tile origin is valid")

  for _, value in ipairs({ 0 / 0, math.huge, -math.huge }) do
    cell.origin.y = value
    Assert.isFalse(FieldCellCache.isReady(finite, "marker"), "non-finite origin is invalid")
  end
end

function T.rejects_out_of_range_cell_coordinates()
  local value = index()
  value.matrices[1].cells[1].x = value.matrices[1].width
  local fs = {
    read = function()
      return "marker"
    end,
    loadLua = function(_, path)
      if path == FieldCellCache.indexPath() then
        return value
      end
      return nil
    end,
  }
  Assert.isFalse(FieldCellCache.isReady(fs, "marker"))
end

function T.rejects_a_cell_that_does_not_match_its_index_descriptor()
  local cache = presentationCache({ geometry = true, texture = true, model = true })
  local cell = assert(cache:loadLua(FieldCellCache.cellPath(4, 1)))
  cell.mapHeaderId = 61
  Assert.isFalse(FieldCellCache.isReady(cache, "marker"))
end

function T.rejects_a_non_table_expected_descriptor()
  local cache = presentationCache({ geometry = true, texture = true, model = true })
  local cell = assert(cache:loadLua(FieldCellCache.cellPath(4, 1)))
  Assert.isFalse(FieldCellCache.validateCell(cache, cell, "marker"))
end

function T.validates_static_and_dynamic_building_references()
  local cache = presentationCache({ geometry = true, texture = true, model = true })
  local originalLoadLua = cache.loadLua
  cache.loadLua = function(self, path)
    if path == MapAssetCache.modelPath("outdoor:21:complete") then
      return completeModel()
    end
    if path == MapAssetCache.modelPath("outdoor:22:dynamic") then
      return dynamicModel()
    end
    return originalLoadLua(self, path)
  end
  local originalExists = cache.exists
  cache.exists = function(self, path, expectedType)
    if path == MapAssetCache.modelPath("outdoor:22:dynamic") then
      return expectedType == nil or expectedType == "file"
    end
    return originalExists(self, path, expectedType)
  end
  local cell = assert(cache:loadLua(FieldCellCache.cellPath(4, 1)))
  cell.buildingInstances[1].modelKey = "outdoor:22:dynamic"
  Assert.isTrue(FieldCellCache.isReady(cache, "marker"), "dynamic model reference is valid")
end

function T.exposes_independent_cell_markers_without_weakening_corpus_readiness()
  Assert.equal(
    FieldCellCache.cellMarkerPath(4, 1),
    "data/generated/field/cells/4/1/complete",
    "each cell owns its completion marker"
  )
  Assert.equal(
    FieldCellCache.dependenciesPath(4, 1),
    "data/generated/field/cells/4/1/dependencies.lua",
    "each cell owns its dependency record"
  )
  local cache = presentationCache({ geometry = true, texture = true, model = true })
  local cell = assert(cache:loadLua(FieldCellCache.cellPath(4, 1)))
  local descriptor = {
    matrixMemberId = 4,
    index = 1,
    x = 0,
    z = 0,
    mapHeaderId = 60,
    altitude = 0,
    landDataMemberId = 7,
    areaDataMemberId = 2,
    file = FieldCellCache.cellPath(4, 1),
  }
  cell.dependencies = {
    marker = "cell-marker",
    descriptor = {
      matrixMemberId = 4,
      index = 1,
      x = 0,
      z = 0,
      mapHeaderId = 60,
      altitude = 0,
      landDataMemberId = 7,
      areaDataMemberId = 2,
    },
  }
  cell.dependencies.matrixMemberId = 4
  cell.dependencies.index = 1
  cache.read = function(_, path)
    if path == FieldCellCache.markerPath() then
      return "corpus-marker"
    end
    if path == FieldCellCache.cellMarkerPath(4, 1) then
      return "cell-marker"
    end
    return collisionBytes()
  end
  cache.loadLua = function(_, path)
    if path == FieldCellCache.cellPath(4, 1) then
      return cell
    end
    if path == FieldCellCache.dependenciesPath(4, 1) then
      return cell.dependencies
    end
    if path == FieldCellCache.indexPath() then
      return index()
    end
    if path == cell.terrain.file then
      return { schema = MapAssetCache.TERRAIN_SCHEMA }
    end
    if path == MapAssetCache.modelPath("outdoor:21:complete") then
      return completeModel()
    end
    return nil
  end
  Assert.isTrue(FieldCellCache.isCellReady(cache, descriptor, "cell-marker"))
  Assert.isFalse(FieldCellCache.isReady(cache, "cell-marker"), "a cell marker cannot attest the corpus")
end

return { metadata = { capabilities = {} }, tests = T }
