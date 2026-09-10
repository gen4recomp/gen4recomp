-- ROM-conformance test: New Bark Town (map 60) against a real HGSS dump. Proves
-- the shared resolution/container pipeline handles the shared EVERYWHERE matrix
-- and an outdoor area. Runs only in the ROM-gated layer. Asserts semantic
-- resolution and field-container decoding for the outdoor target.

local Assert = require("tests.support.Assert")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local AreaData = require("romdump.src.digest.map.AreaData")
local LandData = require("romdump.src.digest.map.LandData")
local HgssPermissionGrid = require("romdump.src.digest.field.HgssPermissionGrid")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")
local MapAssetInspector = require("romdump.src.digest.map.MapAssetInspector")
local InventoryAssert = require("tests.support.InventoryAssert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local NeighborPlan = require("romdump.src.digest.map.NeighborPlan")
local NeighborChunkCompiler = require("romdump.src.digest.map.NeighborChunkCompiler")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")

local T = {}

local function resolve(romFs)
  return assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
end

local function isFinite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function assertTextureInventory(label, pack, packSize)
  Assert.isTrue(#pack.textures > 0, label .. ": pack has textures")
  for _, t in ipairs(pack.textures) do
    Assert.isTrue(
      TextureDecoder.SUPPORTED[t.formatRaw],
      label .. ": unsupported format " .. tostring(t.formatRaw) .. " for " .. t.name
    )
    Assert.isTrue(t.width >= 8 and t.height >= 8, label .. ": finite dimensions for " .. t.name)
    Assert.isTrue(t.dataAbsolute + t.dataSize <= packSize, label .. ": texel byte range in bounds for " .. t.name)
  end
end

-- Locate cell (21,12) by map-header id in the 47x17 shared matrix.
function T.semantic_resolution(romFs)
  local r = resolve(romFs)
  Assert.equal(r.map.id, 60)
  Assert.equal(r.matrixMemberId, 0)
  Assert.equal(r.matrix.width, 47)
  Assert.equal(r.matrix.height, 17)
  Assert.equal(r.matrix.name, "map")
  Assert.equal(r.matrixX, 21)
  Assert.equal(r.matrixZ, 12)
  Assert.equal(r.matrixIndex, 585)
  Assert.equal(r.landDataMemberId, 0)
  Assert.equal(r.worldOriginX, 672)
  Assert.equal(r.worldOriginZ, 384)
end

-- Outdoor area-data member.
function T.area_data(romFs)
  local r = resolve(romFs)
  local narc = assert(romFs:openNarc("area_data"))
  local area = assert(AreaData.decode(assert(narc:readMember(r.areaDataMemberId))))
  Assert.equal(area.buildingTexturePackId, 0)
  Assert.equal(area.mapTexturePackId, 2)
  Assert.equal(area.dynamicTextureType, 0)
  Assert.equal(area.areaType, "outdoor")
  Assert.equal(area.lightTypeRaw, 1)
end

-- Land-data container for the outdoor chunk.
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
  -- Outdoor chunk carries an 88-byte BGS/soundplate payload (excludes the
  -- 4-byte 0x1234+size header), pushing permissions to 0x14 + 88 = 0x6C.
  Assert.equal(#land.bgs.payload, 88)
  Assert.equal(land.offsets.permissions, 0x14 + 88)
  -- Observed raw permission bytes: only 0x80 hard-blocks; 0, 4, 6 are
  -- passable surface responses. The raw byte distribution is a romdump
  -- diagnostic read through HgssPermissionGrid.
  local rawSlice = bytes:sub(land.offsets.permissions + 1, land.offsets.permissions + land.sizes.permissions)
  local permissionGrid = assert(HgssPermissionGrid.decode(rawSlice, { mapId = r.map.id }))
  Assert.deepEqual(permissionGrid.usedPermissionValues, { 0, 4, 6, 128 })
  Assert.equal(#land.collision.cells, 1024)
end

-- The outdoor map/building texture packs inventory cleanly, including
-- the extra formats (A5I3/A3I5) not present in Elm's Lab.
function T.texture_inventory(romFs)
  local r = resolve(romFs)
  local area = assert(AreaData.decode(assert(romFs:openNarc("area_data")):readMember(r.areaDataMemberId)))

  local mapTexBytes = assert(romFs:openNarc("map_textures")):readMember(area.mapTexturePackId)
  assertTextureInventory("new_bark/map", assert(Nsbtx.decode(mapTexBytes)), #mapTexBytes)

  local bldTexBytes = assert(romFs:openNarc("building_textures")):readMember(area.buildingTexturePackId)
  assertTextureInventory("new_bark/building", assert(Nsbtx.decode(bldTexBytes)), #bldTexBytes)
end

-- The outdoor map model and exterior building models inventory with no
-- unsupported command, and the New Bark laboratory (BUILD_MODEL_WK_LABO,
-- member 21) resolves through the exterior archive.
function T.geometry_inventory(romFs)
  local r = resolve(romFs)
  local land =
    assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId), { mapId = r.map.id }))
  local model = assert(Nsbmd.decode(land.mapModelBytes)).models[1]
  Assert.equal(model.info.numShp, 18)
  Assert.equal(#model.sbc.draws, 18)
  Assert.equal(model.sbc.opcodeCounts[0x01], 1) -- RET

  for _, shp in ipairs(model.shapes) do
    Assert.notNil(shp.bounds, "shape " .. shp.name .. " produced no geometry bounds")
    for k = 1, 3 do
      Assert.isTrue(
        isFinite(shp.bounds.min[k]) and isFinite(shp.bounds.max[k]),
        "non-finite bound in shape " .. shp.name
      )
    end
  end

  local report = assert(MapAssetInspector.inspect(romFs, "MAP_NEW_BARK"))
  Assert.equal(#report.warnings, 0)
  Assert.equal(report.buildings.archiveAlias, "exterior_build_models")
  -- The material/polygon-state inventory is finite and fully supported, even
  -- with the outdoor a3i5/a5i3 textures and NORMAL-lit geometry.
  InventoryAssert.assertSupported(report.featureInventory, "new_bark")

  -- New Bark's outdoor area selects field-light profile 0 (area00light.txt).
  Assert.equal(report.lighting.lightTypeRaw, 1)
  Assert.equal(report.lighting.profileId, 0)
  Assert.equal(report.lighting.sourcePath, "data/area00light.txt")
  Assert.isTrue(report.lighting.recordCount > 0, "new bark profile has records")

  -- Model 21 is present and identified as wk_labo (the laboratory exterior).
  local labo
  for _, s in ipairs(report.buildings.modelSummaries) do
    if s.memberId == 21 then
      labo = s
    end
  end
  Assert.notNil(labo, "New Bark should place exterior building model 21")
  Assert.equal(labo.modelName, "wk_labo")
end

-- New Bark's outdoor texture pack includes A3I5/A5I3 partial-alpha textures.
-- Texture storage format alone no longer decides the alpha class:
-- `AlphaClassifier` v2 is final-alpha-aware (a DECAL material ignores texture
-- alpha entirely; a MODULATE material at polygon alpha 31 whose decoded
-- texture mixes fully opaque and partially transparent texels is `mixed`,
-- not blanket `translucent`). This locks the real corpus regression: New
-- Bark's `sea_line02` material (format 6/A5I3,
-- MODULATE, polygon alpha 31) has both fully-opaque and partial texels and
-- must classify `mixed`, so its opaque texels still contribute semantic
-- state instead of silently losing edge/depth participation the way the old
-- format-forces-translucent rule made them.
function T.mixed_alpha_materials_split_by_exact_final_alpha_not_format_alone(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local scene = bundle.scene
  Assert.equal(scene.schema, MapAssetCache.SCENE_SCHEMA)

  local VALID_CLASSES = {
    [AlphaClassifier.OPAQUE] = true,
    [AlphaClassifier.CUTOUT] = true,
    [AlphaClassifier.TRANSLUCENT] = true,
    [AlphaClassifier.WIREFRAME] = true,
    [AlphaClassifier.MIXED] = true,
  }

  local found = false
  local foundMixed = false
  local function checkBatches(materials, batches)
    local fmtById = {}
    for _, m in ipairs(materials or {}) do
      if m.textureFormat == 1 or m.textureFormat == 6 then
        fmtById[m.id] = m.textureFormat
        found = true
      end
    end
    for _, b in ipairs(batches or {}) do
      if fmtById[b.material] then
        Assert.isTrue(
          VALID_CLASSES[b.alphaClass] == true,
          "format " .. fmtById[b.material] .. " batch has a real classifier alpha class, never a defaulted value"
        )
        if b.alphaClass == AlphaClassifier.MIXED then
          foundMixed = true
        end
      end
    end
  end

  checkBatches(scene.materials, scene.mapBatches)
  for _, desc in pairs(bundle.models) do
    checkBatches(desc.materials, desc.batches)
  end
  Assert.isTrue(found, "test found A3I5/A5I3 materials")
  Assert.isTrue(
    foundMixed,
    "New Bark's real corpus must contain at least one MODULATE alpha-31 A3I5/A5I3 material with mixed "
      .. "opaque/translucent texels (sea_line02) -- the exact mechanism the mixed-alpha split fixes"
  )
end

-- Flower quads tile: their UVs run outside [0,1], so they only render if the
-- material programs repeat wrap. That wrap lives in each material's parsed
-- texImageParam (NNSG3dResMatData), not the NSBTX template (which reads clamp
-- for map textures). Guard both the parse and the compiled scene material.
function T.flowers_tile_via_material_wrap(romFs)
  local r = resolve(romFs)
  local land =
    assert(LandData.decode(assert(romFs:openNarc("land_data")):readMember(r.landDataMemberId), { mapId = r.map.id }))
  local model = assert(Nsbmd.decode(land.mapModelBytes)).models[1]
  for _, mat in ipairs(model.materials) do
    if mat.textureName and mat.textureName:find("^flower") then
      Assert.isTrue(mat.repeatX and mat.repeatY, mat.name .. " must request repeat wrap")
    end
  end

  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local flowerMat
  for _, m in ipairs(bundle.scene.materials) do
    if m.name:find("^flower") then
      flowerMat = m
    end
  end
  Assert.notNil(flowerMat, "scene carries a flower material")
  Assert.equal(flowerMat.wrap.x, "repeat")
  Assert.equal(flowerMat.wrap.y, "repeat")
end

-- Binary zero-alpha textures (e.g. fence/vegetation masks) are classified as
-- cutout, not translucent, and keep depth writes.
function T.binary_zero_alpha_is_cutout(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local scene = bundle.scene

  local function textureSha1(path)
    return path and path:match("([0-9a-f]+)%.png$")
  end

  local function assertCutout(materials, batches)
    local cutoutById = {}
    for _, m in ipairs(materials or {}) do
      local sha1 = textureSha1(m.texture)
      local tex = sha1 and bundle.textures[sha1]
      if
        m.texture
        and tex
        and tex.alphaUsage
        and tex.alphaUsage.hasZero
        and m.textureFormat ~= 1
        and m.textureFormat ~= 6
      then
        cutoutById[m.id] = true
      end
    end
    for _, b in ipairs(batches or {}) do
      if cutoutById[b.material] then
        Assert.equal(b.alphaClass, "cutout", "binary zero-alpha batch is cutout, not translucent")
        Assert.isTrue(b.polygonAlpha == 31, "cutout keeps full polygon alpha")
      end
    end
  end

  assertCutout(scene.materials, scene.mapBatches)
  for _, desc in pairs(bundle.models) do
    assertCutout(desc.materials, desc.batches)
  end
end

-- Exterior building models resolve through the outdoor archive and compile
-- through the same material/light path as the map model (same profile, no
-- target-specific branch, no embedded-texture fallback).
function T.exterior_models_share_lighting_and_material_path(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local scene = bundle.scene
  -- The scene carries the normalized light records; the source profile
  -- identity (New Bark's outdoor light type resolves to profile 0) lives in
  -- the producer dependency record.
  Assert.isTrue(#scene.lighting.records > 0, "scene carries parsed light records")
  Assert.equal(bundle.dependencies.fieldLightSourcePath, "data/area00light.txt")

  local outdoorCount = 0
  for key, desc in pairs(bundle.models) do
    if key:find("^outdoor:") then
      outdoorCount = outdoorCount + 1
      -- Each exterior model descriptor carries the same lighting profile as the
      -- map: the runtime binds one set of field-light uniforms for the scene.
      -- Animated models compile through the dynamic path (segments live in
      -- desc.dynamic and classify per frame in the material evaluator);
      -- static ones keep the baked desc.batches with their alpha class.
      local batches = desc.dynamic and desc.dynamic.batches or desc.batches
      Assert.isTrue(#batches > 0, "exterior model has batches: " .. key)
      if not desc.dynamic then
        for _, b in ipairs(batches) do
          Assert.notNil(b.alphaClass, "exterior batch has alpha class: " .. key)
          Assert.notNil(b.cullMode, "exterior batch has cull mode: " .. key)
        end
      end
    end
  end
  Assert.isTrue(outdoorCount > 0, "New Bark compiles exterior building models")

  -- Representative compiled-animation payload: every animated model
  -- descriptor the bundle emits must carry a table `compiled` payload on
  -- each clip, and the representative town bundle must reach at least one.
  local animatedDescriptors = 0
  local clipCount = 0
  for modelKey, desc in pairs(bundle.models) do
    if type(desc.animations) == "table" then
      animatedDescriptors = animatedDescriptors + 1
      for _, clip in ipairs(desc.animations) do
        Assert.equal(
          type(clip.compiled),
          "table",
          "clip " .. tostring(clip.id) .. " of " .. modelKey .. " carries a compiled payload"
        )
        clipCount = clipCount + 1
      end
    end
  end
  Assert.isTrue(animatedDescriptors > 0, "New Bark emits animated model descriptors")
  Assert.isTrue(clipCount > 0, "New Bark counted emitted clips")
end

-- New Bark's central cell compiles into a scene that carries all the
-- diagnostic display data (matrix 0 cell (21,12) index 585, land 0, area
-- 2, origin (672,384)), an outdoor map model with its map texture pack, the lab
-- exterior model 21 resolved through the outdoor archive, and a consistent lab-
-- entry anchor. The debug player spawns inside the local 32x32 cell.
function T.central_cell_scene(romFs, version)
  local c = CacheFs.forVersion(version, FakeCache.new())
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  MapCacheWriter.write(c, bundle)
  local scene = bundle.scene

  local m = scene.matrix
  Assert.equal(m.width, 47)
  Assert.equal(m.height, 17)
  Assert.equal(m.x, 21)
  Assert.equal(m.z, 12)
  Assert.equal(m.worldOriginX, 672)
  Assert.equal(m.worldOriginZ, 384)
  -- Source identity (matrix/area members, texture packs, cell index) stays
  -- producer-side; the dependency record proves which bytes were compiled.
  Assert.equal(#bundle.dependencies.landDataMemberSha1, 40)
  Assert.deepEqual(bundle.dependencies.matrix, {
    memberId = 0,
    name = "map",
    index = 585,
    altitude = 0,
  })
  Assert.deepEqual(bundle.dependencies.area, {
    memberId = 2,
    type = "outdoor",
    mapTexturePackId = 2,
    buildingTexturePackId = 0,
    dynamicTextureType = 0,
    lightType = 1,
  })

  -- Outdoor map model with its texture pack is drawn, and the laboratory
  -- exterior (wk_labo, member 21) resolves through the outdoor archive.
  Assert.isTrue(#scene.mapBatches > 0, "outdoor map model has draw batches")
  local labo = false
  for _, inst in ipairs(scene.buildingInstances) do
    if inst.modelKey:find("^outdoor:21:") then
      labo = true
    end
  end
  Assert.isTrue(labo, "lab exterior model 21 placed via the outdoor archive")
end

-- The optional neighbor ring resolves all eight of New Bark's matrix neighbors
-- (Route 27 east, Route 29 west, MAP_EVERYWHERE filler elsewhere) from the
-- decoded matrix, at exact 32-tile offsets, deduplicating the land members that
-- repeat (208 fills four cells). Each unique chunk compiles to terrain batches
-- through the shared model compiler. ROM-coupled but GPU-free (windowless).
function T.neighbor_ring_plans_and_compiles(romFs)
  local r = resolve(romFs)
  local plan = NeighborPlan.plan(r.matrix, r.matrixX, r.matrixZ, function(headerId)
    local rec = MapCatalog.areaForMapHeader(headerId)
    return rec and rec.areaDataMemberId or nil
  end)

  -- All eight neighbors have a checked-in header mapping, so none are skipped.
  Assert.equal(#plan.cells, 8)
  Assert.deepEqual(plan.uniqueLandMembers, { 3, 11, 208, 209, 210 })

  -- East cell is Route 27 (header 31, land 11, reuses area 2) at +32 tiles X.
  local east
  for _, c in ipairs(plan.cells) do
    if c.x == 22 and c.z == 12 then
      east = c
    end
  end
  Assert.notNil(east, "east neighbor present")
  Assert.equal(east.mapHeaderId, 31)
  Assert.equal(east.landDataMemberId, 11)
  Assert.equal(east.areaDataMemberId, 2)
  Assert.equal(east.offsetTilesX, 32)
  Assert.equal(east.offsetTilesZ, 0)

  -- Each unique chunk compiles to non-empty terrain batches with real geometry.
  local areaOf = {}
  for _, c in ipairs(plan.cells) do
    areaOf[c.landDataMemberId] = c.areaDataMemberId
  end
  for _, member in ipairs(plan.uniqueLandMembers) do
    local chunk = NeighborChunkCompiler.compile(romFs, member, areaOf[member])
    Assert.isTrue(#chunk.batches > 0, "neighbor land " .. member .. " has batches")
    Assert.isTrue(next(chunk.meshes) ~= nil, "neighbor land " .. member .. " has meshes")
  end
end

-- The compiled New Bark bundle carries the digested neighbour ring in
-- scene.neighbors: one descriptor per drawn cell with normalized XYZ offsets and
-- real terrain batches, whose geometry is content-addressed into the shared mesh
-- pool (so it dedups with the centre scene's assets rather than living apart).
function T.neighbors_are_digested_into_the_scene(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local resolved = resolve(romFs)
  local neighbors = bundle.scene.neighbors
  Assert.isTrue(type(neighbors) == "table" and #neighbors > 0, "scene carries neighbor descriptors")

  for _, d in ipairs(neighbors) do
    Assert.isTrue(math.floor(d.offsetTilesX) == d.offsetTilesX, "integer offsetTilesX")
    Assert.isTrue(type(d.offsetTilesY) == "number" and d.offsetTilesY == d.offsetTilesY, "finite offsetTilesY")
    local dx = d.offsetTilesX / 32
    local dz = d.offsetTilesZ / 32
    local expectedY = (
      resolved.matrix:altitudeAt(resolved.matrixX + dx, resolved.matrixZ + dz)
      - resolved.matrix:altitudeAt(resolved.matrixX, resolved.matrixZ)
    ) * 0.5
    Assert.equal(d.offsetTilesY, expectedY, "neighbor Y is center-relative")
    Assert.isTrue(math.floor(d.offsetTilesZ) == d.offsetTilesZ, "integer offsetTilesZ")
    Assert.isTrue(#d.batches > 0, "descriptor has at least one batch")
    for _, b in ipairs(d.batches) do
      local sha1 = b.geometry:match("(%x+)%.g4mesh$")
      Assert.notNil(sha1, "batch geometry is a .g4mesh path: " .. tostring(b.geometry))
      Assert.notNil(bundle.meshes[sha1], "neighbor geometry present in shared mesh pool: " .. sha1)
    end
  end
end

-- The no-save boot target (FieldState) is the player's house 2F: the map
-- must compile into the cache and offer a passable tile near the cell
-- center, so a fresh boot never lands somewhere unreachable.
function T.no_save_spawn_map_compiles_with_free_tiles(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK_PLAYER_HOUSE_2F"))
  Assert.equal(bundle.scene.mapSymbol, "MAP_NEW_BARK_PLAYER_HOUSE_2F")
  local grid = CollisionGrid.new(assert(bundle.collision), {
    worldOriginX = bundle.scene.matrix.worldOriginX,
    worldOriginZ = bundle.scene.matrix.worldOriginZ,
  })
  local free = 0
  for z = 0, 31 do
    for x = 0, 31 do
      if not grid:isBlockedLocal(x, z) then
        free = free + 1
      end
    end
  end
  Assert.isTrue(free > 0, "house 2F has passable tiles")
  Assert.isFalse(grid:isBlockedLocal(15, 15) and grid:isBlockedLocal(16, 16), "the cell center area is reachable")
end

-- New Bark's terrain texture swaps conform to the known retail schedule:
-- flower01 and flower02 each cycle the exact 0,1,0,2 / 18-tick schedule as
-- direct playback steps, and flower03 stays static because the archive has
-- no record for it. Asserted on the scene compiled from the supplied ROM.
function T.terrain_flower_swaps_conform(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local scene = bundle.scene
  local byName = {}
  for _, m in ipairs(scene.materials) do
    byName[m.name] = m
  end
  local expectedDurations = { 18, 18, 18, 18 }
  for _, name in ipairs({ "flower01", "flower02" }) do
    local material = assert(byName[name], name .. " material is in the scene")
    local swap = assert(material.textureSwap, name .. " carries a textureSwap")
    Assert.equal(swap.name, name, name .. " swap names its playback group")
    Assert.equal(#swap.steps, 4, name .. " carries the four-step 0,1,0,2 schedule")
    local durations = {}
    for _, step in ipairs(swap.steps) do
      durations[#durations + 1] = step.durationTicks
    end
    Assert.deepEqual(durations, expectedDurations, name .. " carries the exact 18-tick duration sequence")
    -- The schedule repeats source index 0, so steps 1 and 3 are the same
    -- content-addressed image.
    Assert.equal(swap.steps[1].texture, swap.steps[3].texture, name .. " repeats the step-zero image")
    for _, step in ipairs(swap.steps) do
      Assert.isTrue(
        step.texture:find("^assets/generated/maps/textures/[0-9a-f]+%.png$") ~= nil,
        name .. " alternate is a cache-relative path: " .. step.texture
      )
    end
  end
  local flower03 = assert(byName.flower03, "flower03 material is in the scene")
  Assert.isNil(flower03.textureSwap, "flower03 has no fldtanime record, so it stays static")
end

-- The area texture-coordinate animation: New Bark's dynamicTextureType
-- selects the area00_ani NSBTA, compiled into a data-only clip with 360
-- frames and the eight expected material targets. Asserted on the scene
-- compiled from the supplied ROM.
function T.terrain_area_srt_clip_conforms(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local scene = bundle.scene
  local clip = scene.terrainAnimations.textureSrt
  Assert.isTrue(type(clip) == "table", "the generated scene carries the area texture-SRT clip")
  ---@cast clip table
  Assert.equal(clip.id, "area00_ani")
  Assert.equal(clip.name, "area00_ani")
  Assert.equal(clip.kind, "texsrt")
  Assert.equal(clip.category, "material")
  Assert.equal(clip.frameCount, 360)
  local expected = { "pond_on", "swave_p", "pond_edge", "sea_line02", "sea_un", "sea_on", "river", "river_r" }
  local targets = {}
  for _, track in ipairs(clip.tracks) do
    targets[#targets + 1] = track.target
  end
  table.sort(targets)
  local sorted = {}
  for _, name in ipairs(expected) do
    sorted[#sorted + 1] = name
  end
  table.sort(sorted)
  Assert.deepEqual(targets, sorted, "the eight expected material targets")
  for i, track in ipairs(clip.tracks) do
    Assert.equal(track.targetIndex, i - 1, "track indices are zero-based and aligned")
  end
  Assert.equal(#clip.compiled.targets, 8)
end

return require("tests.rom.support.RomSuite").fromFacts(T)
