-- ROM-conformance test: Professor Elm's Lab 1F (map 61) against a real HGSS dump.
-- Each function receives the open RomFs. This module is NOT in the public
-- ordinary unit suite; it runs only in the ROM-gated layer where a dump exists,
-- and asserts the externally observable resolution and container conditions.

local Assert = require("tests.support.Assert")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local AreaData = require("romdump.src.digest.map.AreaData")
local LandData = require("romdump.src.digest.map.LandData")
local HgssPermissionGrid = require("romdump.src.digest.field.HgssPermissionGrid")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")
local MapAssetInspector = require("romdump.src.digest.map.MapAssetInspector")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local InventoryAssert = require("tests.support.InventoryAssert")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local CompiledAsset = require("tests.rom.support.CompiledAsset")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {}

local function resolve(romFs)
  return assert(MapResolver.resolve(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"))
end

local function isFinite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Every texture must decode to a supported, finitely-dimensioned record with a
-- byte range inside the pack -- the observable texture inventory.
local function assertTextureInventory(label, pack, packSize)
  Assert.isTrue(#pack.textures > 0, label .. ": pack has textures")
  for _, t in ipairs(pack.textures) do
    Assert.isTrue(
      TextureDecoder.SUPPORTED[t.formatRaw],
      label .. ": unsupported format " .. tostring(t.formatRaw) .. " for " .. t.name
    )
    Assert.isTrue(t.width >= 8 and t.height >= 8, label .. ": finite dimensions for " .. t.name)
    Assert.isTrue(type(t.color0Transparent) == "boolean", label .. ": color0 flag for " .. t.name)
    Assert.isTrue(
      type(t.repeatX) == "boolean" and type(t.flipX) == "boolean",
      label .. ": wrap/flip flags for " .. t.name
    )
    Assert.isTrue(t.dataAbsolute + t.dataSize <= packSize, label .. ": texel byte range in bounds for " .. t.name)
  end
end

-- Semantic resolution through the catalog, matrix, and model grid.
function T.semantic_resolution(romFs)
  local r = resolve(romFs)
  Assert.equal(r.map.id, 61)
  Assert.equal(r.matrixMemberId, 100)
  Assert.equal(r.matrix.width, 1)
  Assert.equal(r.matrix.height, 1)
  Assert.equal(r.matrix.name, "m_labo01_")
  Assert.equal(r.matrixX, 0)
  Assert.equal(r.matrixZ, 0)
  Assert.equal(r.landDataMemberId, 244)
  Assert.equal(r.worldOriginX, 0)
  Assert.equal(r.worldOriginZ, 0)
end

-- Area-data member is exactly 8 bytes and decodes to the indoor pack.
function T.area_data(romFs)
  local r = resolve(romFs)
  local narc = assert(romFs:openNarc("area_data"))
  local area = assert(AreaData.decode(assert(narc:readMember(r.areaDataMemberId))))
  Assert.equal(area.buildingTexturePackId, 1)
  Assert.equal(area.mapTexturePackId, 25)
  Assert.equal(area.dynamicTextureType, 0xFFFF)
  Assert.equal(area.areaType, "indoor")
  Assert.equal(area.lightTypeRaw, 0)
end

-- Land-data container boundaries, BGS, collision, buildings, model, BDHC.
function T.land_containers(romFs)
  local r = resolve(romFs)
  local narc = assert(romFs:openNarc("land_data"))
  local bytes = assert(narc:readMember(r.landDataMemberId))
  local land = assert(LandData.decode(bytes, { mapId = r.map.id, alias = "land_data", memberId = r.landDataMemberId }))
  Assert.equal(land.bgs.signature, 0x1234)
  Assert.equal(land.sizes.permissions, 0x800)
  Assert.equal(land.sizes.buildings % 0x30, 0)
  Assert.equal(land.mapModelBytes:sub(1, 4), "BMD0")
  Assert.notNil(land.bdhcBytes, "BDHC slice must be available as opaque bytes")
  Assert.notNil(land.collision.cells[1])
  Assert.equal(#land.collision.cells, 1024)
  -- Indoor chunk carries no BGS/soundplate payload, so permissions sit at 0x14.
  Assert.equal(#land.bgs.payload, 0)
  -- Observed raw permission bytes: only 0x80 hard-blocks; 0 and 6 are
  -- passable surface responses, not obstacles. The raw byte distribution is a
  -- romdump diagnostic, so it is read through HgssPermissionGrid.
  local rawSlice = bytes:sub(land.offsets.permissions + 1, land.offsets.permissions + land.sizes.permissions)
  local permissionGrid = assert(HgssPermissionGrid.decode(rawSlice, { mapId = r.map.id }))
  Assert.deepEqual(permissionGrid.usedPermissionValues, { 0, 6, 128 })
end

-- The map and building texture packs inventory cleanly, and every
-- material name the map model references resolves to a real texture.
function T.texture_inventory(romFs)
  local r = resolve(romFs)
  local area = assert(AreaData.decode(assert(romFs:openNarc("area_data")):readMember(r.areaDataMemberId)))

  local mapTexBytes = assert(romFs:openNarc("map_textures")):readMember(area.mapTexturePackId)
  local mapPack = assert(Nsbtx.decode(mapTexBytes))
  assertTextureInventory("elms_lab/map", mapPack, #mapTexBytes)

  local bldTexBytes = assert(romFs:openNarc("building_textures")):readMember(area.buildingTexturePackId)
  local bldPack = assert(Nsbtx.decode(bldTexBytes))
  assertTextureInventory("elms_lab/building", bldPack, #bldTexBytes)

  -- Every texture the map model binds must exist in the map texture pack.
  local land =
    assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId), { mapId = r.map.id }))
  local model = assert(Nsbmd.decode(land.mapModelBytes)).models[1]
  for _, assoc in ipairs(model.textureAssociations) do
    Assert.notNil(mapPack.textureByName[assoc.name], "map material texture missing from pack: " .. assoc.name)
  end
end

-- The map model inventories fully -- counts, SBC/GX opcode coverage,
-- material associations, and finite bounds for every shape batch -- with no
-- unsupported command in the Elm target set.
function T.geometry_inventory(romFs)
  local r = resolve(romFs)
  local land =
    assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId), { mapId = r.map.id }))
  local nsbmd = assert(Nsbmd.decode(land.mapModelBytes))
  Assert.equal(#nsbmd.models, 1)
  local model = nsbmd.models[1]
  Assert.equal(model.info.numNode, 1)
  Assert.equal(model.info.numMat, 10)
  Assert.equal(model.info.numShp, 10)
  Assert.equal(#model.shapes, 10)

  -- SBC pairs each shape with a material; RET terminates the stream.
  Assert.equal(#model.sbc.draws, 10)
  Assert.equal(model.sbc.opcodeCounts[0x05], 10) -- SHP
  Assert.equal(model.sbc.opcodeCounts[0x04], 10) -- MAT
  Assert.equal(model.sbc.opcodeCounts[0x01], 1) -- RET

  -- Finite bounds for every compiled mesh batch.
  for _, shp in ipairs(model.shapes) do
    Assert.notNil(shp.bounds, "shape " .. shp.name .. " produced no geometry bounds")
    for k = 1, 3 do
      Assert.isTrue(
        isFinite(shp.bounds.min[k]) and isFinite(shp.bounds.max[k]),
        "non-finite bound in shape " .. shp.name
      )
    end
    Assert.isTrue(shp.triangleCount > 0, "shape " .. shp.name .. " has no triangles")
  end

  -- 9 of 10 materials are textured (lambert1 is untextured); each textured
  -- material carries both a texture and a palette association.
  local textured = 0
  for _, mat in ipairs(model.materials) do
    if mat.textureName then
      textured = textured + 1
      Assert.notNil(mat.paletteName, "textured material lacks palette: " .. mat.name)
    end
  end
  Assert.equal(textured, 9)

  -- The inspector assembles the whole report with no warnings.
  local report = assert(MapAssetInspector.inspect(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"))
  Assert.equal(#report.warnings, 0)
  Assert.equal(report.buildings.archiveAlias, "interior_build_models")
  -- The material/polygon-state inventory is finite and fully supported.
  InventoryAssert.assertSupported(report.featureInventory, "elms_lab")

  -- Elm's indoor area selects field-light profile 1 (area01light.txt); the
  -- profile parses and its records cover the day.
  Assert.equal(report.lighting.lightTypeRaw, 0)
  Assert.equal(report.lighting.profileId, 1)
  Assert.equal(report.lighting.sourcePath, "data/area01light.txt")
  Assert.isTrue(report.lighting.recordCount > 0, "elm profile has records")
  for _, s in ipairs(report.buildings.modelSummaries) do
    Assert.notNil(s.bounds, "building model " .. s.memberId .. " produced no bounds")
  end
end

-- Every parsed material record is structurally valid and
-- every compiled vertex carries a resolved color source.
function T.material_and_vertex_validity(romFs)
  local r = resolve(romFs)
  local land =
    assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId), { mapId = r.map.id }))
  local nsbmd = assert(Nsbmd.decode(land.mapModelBytes))
  local model = nsbmd.models[1]

  for _, mat in ipairs(model.materials) do
    Assert.isTrue(mat.size >= 0x2C, "material size >= 0x2C: " .. mat.name)
    Assert.equal(mat.itemTag, 0, "standard material item tag: " .. mat.name)
    Assert.isTrue(
      mat.polyAttrMask == 0xFFFFFFFF or mat.polyAttrMask == 0x3F1FF8FF,
      "polyAttrMask covers meaningful bits: " .. mat.name
    )
    Assert.equal(mat.texImageParamMask, 0xFFFFFFFF, "texImageParamMask is full: " .. mat.name)
  end

  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"))
  for sha, batch in pairs(bundle.meshes) do
    for _, v in ipairs(CompiledAsset.mesh(batch).vertices) do
      Assert.notNil(v[13], "vertex has resolved color source in " .. sha)
      Assert.isTrue(v[13] >= 0 and v[13] <= 2, "colorSource is valid in " .. sha)
    end
  end
end

-- The spawn and the exit warp are passable tiles on the real
-- collision grid: spawn (4,13), one step south onto the warp tile (4,14).
-- Only the hard-blocked cells block; the 32x32 cell is a hard boundary.
function T.traversal(romFs)
  local r = resolve(romFs)
  local land =
    assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId), { mapId = r.map.id }))
  local collision = CollisionGrid.new(land.collision, {
    worldOriginX = r.worldOriginX,
    worldOriginZ = r.worldOriginZ,
  })

  -- The exit warp (4,14) is passable and one step south of the spawn.
  Assert.isFalse(collision:isBlockedLocal(4, 14))
  Assert.isTrue(collision:containsLocal(4, 14))

  -- Only hard-blocked cells block: the perimeter wall hard-blocks, interior
  -- floor (behavior 0 / response 6) does not.
  Assert.isTrue(collision:isBlockedLocal(0, 0))
  Assert.isFalse(collision:isBlockedLocal(4, 13))

  -- Movement respects a wall: the (12,13) wall tile is hard-blocked.
  Assert.isTrue(collision:isBlockedLocal(12, 13))

  -- The 32x32 cell is a hard boundary: a step off the grid is refused.
  Assert.isFalse(collision:containsLocal(-1, 16))
  Assert.isFalse(collision:containsLocal(16, -1))
end

-- Professor Elm is source object event 0, not an optional/hidden scenery
-- piece: HGSS's own zone-event record places him at (6,5) with the lab
-- sprite, behind the lab's hide flag. Object id 0 must decode and compile
-- exactly like any other object id, and his sprite must be a real compiled
-- actor visual the runtime can acquire -- never a map-specific placeholder.
function T.elm_is_a_real_generated_object_zero_with_a_compiled_sprite(romFs)
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 61))
  local elm
  for _, event in ipairs(bundle.field.events.objects) do
    if event.objectEventId == 0 then
      elm = event
    end
  end
  Assert.notNil(elm, "map 61 must declare object event 0")
  Assert.equal(elm.x, 6)
  Assert.equal(elm.z, 5)
  Assert.equal(elm.spriteId, 99)
  Assert.equal(elm.eventFlag, FieldScriptSymbols.flagsByName.FLAG_HIDE_ELMS_LAB_ELM)

  local actors = assert(FieldActorCompiler.compile(romFs))
  Assert.notNil(actors.visuals[elm.spriteId], "Elm's sprite must be a compiled actor visual")
  local known = false
  for _, spriteId in ipairs(actors.index.spriteIds) do
    if spriteId == elm.spriteId then
      known = true
    end
  end
  Assert.isTrue(known, "Elm's sprite must be present in the compiled actor index")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
