-- MapAssetCompiler: constant surface, and the type-directed texture routing a
-- full compile performs. HGSS binds an ordinary placed building to the area's
-- external building texture pack (NARC 0x46) and never uploads that model's own
-- embedded TEX0; terrain binds to the area's map texture pack (NARC 0x2C). Both
-- routes are exercised with deliberately disjoint pack contents so a model bound
-- to the wrong pack cannot resolve by accident -- which shows up as a reported
-- unresolved material drawing untextured, as it would on the DS, not as a failure.
--
-- The terrain-animation wiring tests pin the producer side of the scene
-- contract: central and neighbour terrain materials carry the texture-matrix
-- fields and fldtanime-matched textureSwap records (`data/fldtanime.narc` in
-- pret/pokeheartgold), the central scene owns the one area NSBTA clip (never a
-- per-neighbour copy), placed buildings never gain a swap from a texture-name
-- coincidence, and the animation source hashes ride the dependency record into
-- the completion marker.

local Assert = require("tests.support.Assert")
local AnimationFixture = require("tests.support.AnimationFixture")
local BdhcBuilder = require("tests.support.BdhcBuilder")
local Errors = require("libs.errors.src.Errors")
local FieldTexAnimFixture = require("tests.support.FieldTextureAnimationFixture")
local FieldTextureAnimation = require("romdump.src.digest.field.FieldTextureAnimation")
local Hashing = require("romdump.src.digest.Hashing")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")
local LandDataBuilder = require("tests.support.LandDataBuilder")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapRomFixture = require("tests.support.MapRomFixture")
local NB = require("tests.support.NitroBuilder")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local TF = require("tests.support.TextureFixtures")
local Tex0Fixture = require("tests.support.Tex0Fixture")

local T = {}

local function compile(opts)
  local romFs = MapRomFixture.build(opts)
  local bundle, err = MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL)
  return bundle, err, romFs
end

local function onlyModel(bundle)
  local found
  for _, model in pairs(bundle.models) do
    if model.memberId == MapRomFixture.BUILDING_MODEL_MEMBER_ID then
      assert(not found, "expected one authored building model")
      found = model
    end
  end
  return assert(found, "expected one building model")
end

-- ---- terrain-animation fixtures ----

-- The New Bark flower01 schedule: 0 for 18 ticks, 1 for 18, 0 for 18, 2 for
-- 18, loop. Live entries only.
local FLOWER_TIMELINE = { { 0, 18 }, { 1, 18 }, { 0, 18 }, { 2, 18 } }

-- The compiled textureSwap.steps durations, in schedule order.
local FLOWER_STEP_DURATIONS = { 18, 18, 18, 18 }

-- Base map texture: 8x8 palette16 texels all index 1, so a frame's decoded
-- pixel colour identifies the palette index -- and thereby the pack -- it was
-- decoded under.
local BASE_TEXEL = string.rep(string.char(0x11), 32)

-- Palette index 2 differs per pack so a frame decoded with the wrong pack's
-- palette is visible in the pixels: green in the central pack, blue in the
-- neighbour's.
local CENTRAL_PALETTE = { TF.BLACK, TF.RED, TF.GREEN, TF.BLACK }
local NEIGHBOR_PALETTE = { TF.BLACK, TF.RED, TF.BLUE, TF.BLACK }

local function texels(pattern)
  return string.rep(string.char(pattern), 32)
end

-- A replacement BTX0 member whose dictionary textures, in order, are the swap
-- frames. The palette is deliberately the replacement's own: a compiler that
-- decoded alternates with it instead of the base material's palette would
-- produce the wrong colours.
local function replacementMember(texelList)
  local textures = {}
  for i, texel in ipairs(texelList) do
    textures[#textures + 1] = { name = "alt" .. i, texel = texel }
  end
  return Tex0Fixture.btx0({
    textures = textures,
    palettes = { { name = "alt_pal", palette = TF.palette({ TF.BLACK, TF.BLUE, TF.BLUE, TF.BLUE }) } },
  })
end

-- The map texture pack whose one texture the fldtanime table names.
local function flowerPack()
  return {
    textures = { { name = "flower01", texel = BASE_TEXEL } },
    palettes = { { name = "map_pal", palette = TF.palette(CENTRAL_PALETTE) } },
  }
end

-- The fldtanime table member naming flower01 plus its replacement member.
local function flowerAnimations()
  return {
    [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = FLOWER_TIMELINE } }),
    [1] = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) }),
  }
end

-- One decoded central terrain model whose material binds the flower01 texture.
local function terrainLandModel(opts)
  opts = opts or {}
  return NsbmdFixture.build({
    modelName = "labo01",
    textureName = "flower01",
    paletteName = "map_pal",
    origWidth = 8,
    origHeight = 8,
    triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
    materialSrt = opts.materialSrt,
  })
end

-- The compiled texture asset a scene material path refers to.
local function textureAsset(path, textures)
  for sha1, asset in pairs(textures) do
    if MapAssetCache.texturePath(sha1) == path then
      return asset
    end
  end
  error("no compiled texture for " .. path)
end

-- Pixels of an 8x8 solid-colour decoded frame (64 texels, RGBA).
local function solidPixels(r, g, b)
  return string.rep(string.char(r, g, b, 255), 64)
end

-- ---- neighbour-ring fixtures ----

-- Header 1 (MAP_NOTHING) resolves through the catalog to area member 0; the
-- fixture provides that member. Its dynamicTextureType is deliberately 0 -- a
-- non-selection sentinel for the NEIGHBOUR area, which must never compile a
-- clip: only the central area's selection does.
local NEIGHBOR_HEADER = 1
local NEIGHBOR_AREA_MEMBER = 0
local NEIGHBOR_LAND_MEMBER = 432
local NEIGHBOR_PACK_ID = 10

local function neighborAreaMember()
  return NB.u16(0) .. NB.u16(NEIGHBOR_PACK_ID) .. NB.u16(0) .. NB.u8(0) .. NB.u8(0)
end

-- One decoded neighbour land member whose model binds flower01 through the
-- cell's own map texture pack (the cell's palette names cell_pal).
local function neighborLandMember()
  return LandDataBuilder.build({
    model = NsbmdFixture.build({
      modelName = "cell0",
      textureName = "flower01",
      paletteName = "cell_pal",
      origWidth = 8,
      origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
    }),
    bdhc = BdhcBuilder.build(),
  })
end

-- The neighbour cell's own map texture pack member.
local function neighborPack()
  return Tex0Fixture.btx0({
    textures = { { name = "flower01", texel = BASE_TEXEL } },
    palettes = { { name = "cell_pal", palette = TF.palette(NEIGHBOR_PALETTE) } },
  })
end

function T.compile_requires_romfs_shaped_object()
  local err = Assert.throws(function()
    MapAssetCompiler.compile({}, "x")
  end)
  Assert.isTrue(tostring(err):find("RomFs") ~= nil, "error mentions RomFs")
end

function T.building_binds_to_the_area_building_pack_without_embedded_tex0()
  local bundle = assert(compile())
  local model = onlyModel(bundle)
  Assert.equal(model.memberId, MapRomFixture.BUILDING_MODEL_MEMBER_ID)
  Assert.notNil(model.materials[1].texture)
  Assert.equal(#bundle.scene.buildingInstances, 1)
  Assert.equal(bundle.scene.buildingInstances[1].modelKey, model.key)
end

function T.building_ignores_its_own_embedded_tex0()
  -- The embedded TEX0 is the ONLY place the requested names exist; the external
  -- building pack has different ones. HGSS would fail to resolve them too, so a
  -- compiler that silently fell back to the embedded block would pass here.
  local bundle = assert(compile({
    buildingModel = NsbmdFixture.build({
      textureName = "embedded_tex",
      paletteName = "embedded_pal",
      origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
      embeddedTex0 = Tex0Fixture.block({
        textures = { "embedded_tex" },
        palettes = { "embedded_pal" },
      }),
    }),
  }))
  Assert.isNil(onlyModel(bundle).materials[1].texture)
  Assert.equal(#bundle.unresolvedMaterials, 1)
  Assert.equal(bundle.unresolvedMaterials[1].role, "building")
  Assert.equal(bundle.unresolvedMaterials[1].name, "embedded_tex")
end

function T.building_with_no_named_bindings_compiles_as_a_no_op()
  -- Building model 38 (`leage_o03`) has no embedded TEX0 and no named material
  -- bindings; Nitro's bind loops run zero times and succeed.
  local bundle = assert(compile({
    buildingModel = NsbmdFixture.build({
      untextured = true,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
    }),
  }))
  local model = onlyModel(bundle)
  Assert.equal(#model.batches, 2)
  Assert.isNil(model.materials[1].texture)
end

function T.a_map_with_no_placed_buildings_still_compiles_starter_ball_assets()
  local bundle = assert(compile({ buildings = "" }))
  local modelCount = 0
  for _ in pairs(bundle.models) do
    modelCount = modelCount + 1
  end
  Assert.equal(modelCount, 1)
  Assert.equal(#bundle.scene.buildingInstances, 0)
  Assert.notNil(bundle.scene.runtimeProps.starterBalls)
  Assert.isNil(bundle.scene.source, "source identity lives in the dependency record")
end

function T.terrain_does_not_see_building_textures()
  local bundle = assert(compile({
    mapPack = { textures = { "unrelated" }, palettes = { "unrelated_pal" } },
  }))
  Assert.equal(#bundle.unresolvedMaterials, 1)
  local entry = bundle.unresolvedMaterials[1]
  Assert.equal(entry.role, "map")
  Assert.equal(entry.name, MapRomFixture.MAP_TEXTURE)
  Assert.equal(entry.modelArchive, "land_data")
  Assert.equal(entry.modelMemberId, MapRomFixture.LAND_DATA_MEMBER_ID)
end

function T.buildings_do_not_see_map_textures()
  local bundle = assert(compile({
    buildingPack = { textures = { "unrelated" }, palettes = { "unrelated_pal" } },
  }))
  Assert.equal(#bundle.unresolvedMaterials, 1)
  Assert.equal(bundle.unresolvedMaterials[1].role, "building")
  Assert.isNil(onlyModel(bundle).materials[1].texture)
end

function T.an_unresolved_material_names_the_source_that_was_checked()
  local bundle = assert(compile({
    buildingPack = { textures = { "unrelated" }, palettes = { "unrelated_pal" } },
  }))
  Assert.equal(
    bundle.unresolvedMaterials[1].source,
    "building_textures member " .. MapRomFixture.BUILDING_TEXTURE_PACK_ID
  )
end

-- The compiled scene must carry the real HGSS field
-- edge-color table selected by the area's raw light-pattern byte
-- (AreaData.lightTypeRaw at area-data offset 0x07), the exact byte
-- AreaDataManager_Load reads at +0x8B7 to branch between the two real overlay
-- tables ov01_02208BA0 / ov01_02208BB0 (HgssFieldEdgeColors) -- the same byte
-- HgssFieldLighting.resolve already reads to select the field-light profile.
-- FieldRenderer must stop inventing a placeholder eight-grey table.
function T.scene_edge_colors_follow_the_area_light_pattern_byte()
  local zero = assert(compile({ lightTypeRaw = 0 }))
  Assert.deepEqual(zero.scene.edgeColors, HgssFieldEdgeColors.TABLE_A)

  local nonzero = assert(compile({ lightTypeRaw = 1 }))
  Assert.deepEqual(nonzero.scene.edgeColors, HgssFieldEdgeColors.TABLE_B)
end

-- The compiled scene carries the map's base weather ID (MapCatalog.get(mapId)
-- .weather) verbatim, and the resolved global fog preset for that weather,
-- resolved through the same HgssFieldFog table the romdump-level tests
-- exercise directly -- never a hardcoded disabled placeholder. weatherId is
-- kept alongside the resolved fog preset (rather than only the preset) so a
-- future runtime weather override can start from the original ID without
-- reimporting romdump. This fixture map's real weather is 0
-- (Sunny/disabled); the assertion still calls the independent resolver
-- rather than hardcoding "disabled" so a future fixture-map change or wiring
-- bug (e.g. reading the wrong field) cannot silently pass.
function T.scene_carries_the_base_weather_id_and_its_resolved_fog_preset()
  local bundle = assert(compile())
  local weatherId = assert(MapCatalog.get(MapRomFixture.MAP_SYMBOL)).weather
  Assert.equal(bundle.scene.weatherId, weatherId)
  Assert.deepEqual(bundle.scene.fog, HgssFieldFog.runtimePreset(HgssFieldFog.resolve(weatherId)))
end

function T.a_fully_resolved_map_reports_nothing_unresolved()
  Assert.deepEqual(assert(compile()).unresolvedMaterials, {})
end

function T.records_the_building_pack_in_dependencies()
  local bundle = assert(compile())
  Assert.equal(bundle.dependencies.buildingTextureMemberId, MapRomFixture.BUILDING_TEXTURE_PACK_ID)
  Assert.notNil(bundle.dependencies.buildingTextureMemberSha1, "the building pack bytes are hashed")
  Assert.isNil(bundle.scene.source, "source identity lives in the dependency record")
end

function T.changing_the_building_texture_member_changes_the_marker()
  local base = assert(compile())
  local moved = assert(compile({ buildingTexturePackId = 9 }))
  Assert.isTrue(base.marker ~= moved.marker, "marker must track the building pack member")

  local repacked = assert(compile({
    buildingPack = {
      textures = { MapRomFixture.BUILDING_TEXTURE, "spare" },
      palettes = { MapRomFixture.BUILDING_PALETTE },
    },
  }))
  Assert.isTrue(base.marker ~= repacked.marker, "marker must track the building pack bytes")
end

function T.compile_is_deterministic()
  local first = assert(compile())
  local second = assert(compile())
  Assert.equal(first.marker, second.marker)
  Assert.equal(onlyModel(first).key, onlyModel(second).key)
end

function T.central_terrain_materials_carry_the_terrain_fields_and_matched_swaps()
  local tableMember = FieldTexAnimFixture.member({ { name = "flower01", timeline = FLOWER_TIMELINE } })
  local member1 = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) })
  local bundle = assert(compile({
    mapPack = flowerPack(),
    landModel = terrainLandModel(),
    fieldTextureAnimations = { [0] = tableMember, [1] = member1 },
  }))

  -- The fixture's dynamicTextureType is the 0xFFFF default and the
  -- field_area_texture_srt archive is absent, so a compiler that opened it
  -- would trip the fixture's missing-archive assert: the scene owns one
  -- explicit false clip and reads nothing.
  Assert.deepEqual(bundle.scene.terrainAnimations, { textureSrt = false })

  local material = bundle.scene.materials[1]
  Assert.equal(material.texWidth, 8)
  Assert.equal(material.texHeight, 8)
  Assert.equal(material.texMtxMode, 0)
  Assert.isNil(material.srt, "a terrain material without a static SRT omits the field")

  -- The flower01 record matched by texture name rides the same material: one
  -- playback step per live schedule entry, in schedule order, with the retail
  -- durations.
  Assert.equal(material.textureSwap.name, "flower01")
  Assert.equal(#material.textureSwap.steps, 4)
  local durations = {}
  for _, step in ipairs(material.textureSwap.steps) do
    durations[#durations + 1] = step.durationTicks
  end
  Assert.deepEqual(durations, FLOWER_STEP_DURATIONS)
  -- The schedule repeats source index 0, so steps 1 and 3 are the same
  -- content-addressed path.
  Assert.equal(material.textureSwap.steps[1].texture, material.textureSwap.steps[3].texture)
  Assert.isTrue(
    material.textureSwap.steps[1].texture:find("^assets/generated/maps/textures/") ~= nil,
    "swap frames are cache-relative paths"
  )

  -- The dependency record carries the table hash and the used replacement
  -- member's hash; the marker inputs are complete for a no-clip map.
  Assert.deepEqual(bundle.dependencies.fieldTextureAnimations, {
    tableSha1 = Hashing.sha1hex(tableMember),
    memberSha1s = { { memberId = 1, sha1 = Hashing.sha1hex(member1) } },
  })
  Assert.equal(bundle.dependencies.terrainTextureSrt, false)
end

function T.a_material_with_a_static_srt_carries_the_normalized_record()
  local bundle = assert(compile({
    mapPack = flowerPack(),
    landModel = terrainLandModel({ materialSrt = { scale = { s = 0x2000, t = 0x1000 } } }),
    fieldTextureAnimations = flowerAnimations(),
  }))
  local material = bundle.scene.materials[1]
  -- The normalized shape the runtime texture-matrix evaluator consumes: the
  -- absent rotation is omitted, the absent translation reads zero, and the
  -- "one" flags come from the source components' presence.
  Assert.deepEqual(material.srt, {
    transS = 0,
    transT = 0,
    scaleS = 0x2000,
    scaleT = 0x1000,
    transOne = true,
    rotOne = true,
    scaleOne = false,
  })
  Assert.isNil(material.srt.rot)
  -- The matched swap still rides the same material.
  Assert.equal(material.textureSwap.name, "flower01")
end

function T.the_selected_area_nsbta_lands_in_scene_terrain_animations()
  local srtBytes = AnimationFixture.srtWater()
  local bundle = assert(compile({
    dynamicTextureType = 0,
    fieldAreaTextureSrt = { [0] = srtBytes },
  }))
  local clip = bundle.scene.terrainAnimations.textureSrt
  Assert.isTrue(type(clip) == "table", "the selected NSBTA compiles into scene.terrainAnimations.textureSrt")
  ---@cast clip table
  Assert.equal(clip.name, "en_sp1")
  Assert.equal(clip.id, "en_sp1")
  Assert.equal(clip.category, "material")
  Assert.equal(clip.kind, "texsrt")
  Assert.equal(clip.frameCount, 8)
  Assert.deepEqual(clip.tracks, { { target = "en_sp1_3", targetIndex = 0 } })
  Assert.deepEqual(clip.semanticNames, {})
  Assert.isNil(clip.source, "the scene clip carries no physical source provenance")
  -- The payload's byte fidelity is NsbtaClipCompiler's own contract; here the
  -- selected member's target identity is checked instead.
  Assert.equal(#clip.compiled.targets, 1)
  Assert.equal(clip.compiled.targets[1].name, "en_sp1_3")
  Assert.equal(clip.compiled.targets[1].index, 0)
  -- The selected member is producer provenance in the dependency record.
  Assert.deepEqual(bundle.dependencies.terrainTextureSrt, {
    memberId = 0,
    sha1 = Hashing.sha1hex(srtBytes),
  })
  Assert.isTrue(bundle.marker ~= assert(compile()).marker, "selecting an area clip changes the completion marker")
end

function T.neighbor_terrain_compiles_against_its_own_pack_into_one_dependency_set()
  -- The central terrain matches flower02 (replacement member 2); the one
  -- neighbour cell chunk matches flower01 (member 1) against the cell's own
  -- map texture pack. Both compiles feed one map-scoped compiler, so the
  -- dependency record holds both used members sorted by member id.
  local tableMember = FieldTexAnimFixture.member({
    { name = "flower01", timeline = FLOWER_TIMELINE },
    { name = "flower02", timeline = { { 0, 12 }, { 1, 12 } } },
  })
  local member1 = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) })
  local member2 = replacementMember({ BASE_TEXEL, texels(0x22) })
  local bundle = assert(compile({
    mapPack = {
      textures = { { name = "flower02", texel = BASE_TEXEL } },
      palettes = { { name = "map_pal", palette = TF.palette(CENTRAL_PALETTE) } },
    },
    landModel = NsbmdFixture.build({
      modelName = "labo01",
      textureName = "flower02",
      paletteName = "map_pal",
      origWidth = 8,
      origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
    }),
    fieldTextureAnimations = { [0] = tableMember, [1] = member1, [2] = member2 },
    extraMembers = {
      map_matrices = {
        [MapRomFixture.MATRIX_MEMBER_ID] = MapRomFixture.gridMatrix({
          width = 3,
          height = 3,
          headers = {
            NEIGHBOR_HEADER,
            NEIGHBOR_HEADER,
            NEIGHBOR_HEADER,
            NEIGHBOR_HEADER,
            MapRomFixture.MAP_ID,
            NEIGHBOR_HEADER,
            NEIGHBOR_HEADER,
            NEIGHBOR_HEADER,
            NEIGHBOR_HEADER,
          },
          modelIds = {
            NEIGHBOR_LAND_MEMBER,
            NEIGHBOR_LAND_MEMBER,
            NEIGHBOR_LAND_MEMBER,
            NEIGHBOR_LAND_MEMBER,
            MapRomFixture.LAND_DATA_MEMBER_ID,
            NEIGHBOR_LAND_MEMBER,
            NEIGHBOR_LAND_MEMBER,
            NEIGHBOR_LAND_MEMBER,
            NEIGHBOR_LAND_MEMBER,
          },
        }),
      },
      area_data = { [NEIGHBOR_AREA_MEMBER] = neighborAreaMember() },
      land_data = { [NEIGHBOR_LAND_MEMBER] = neighborLandMember() },
      map_textures = { [NEIGHBOR_PACK_ID] = neighborPack() },
    },
  }))

  -- Central terrain: flower02's frames decode under the central palette
  -- (green at index 2).
  local central = bundle.scene.materials[1]
  Assert.equal(central.texWidth, 8)
  Assert.equal(central.texHeight, 8)
  Assert.equal(central.texMtxMode, 0)
  Assert.equal(central.textureSwap.name, "flower02")
  Assert.equal(textureAsset(central.textureSwap.steps[2].texture, bundle.textures).pixels, solidPixels(0, 255, 0))

  -- The neighbour chunk binds its own pack: flower01's frames decode under the
  -- neighbour palette (blue at index 2), never the central one.
  Assert.equal(#bundle.scene.neighbors, 8)
  local neighbor = bundle.scene.neighbors[1].materials[1]
  Assert.equal(neighbor.texWidth, 8)
  Assert.equal(neighbor.texHeight, 8)
  Assert.equal(neighbor.texMtxMode, 0)
  Assert.isNil(neighbor.srt)
  Assert.equal(neighbor.textureSwap.name, "flower01")
  local durations = {}
  for _, step in ipairs(neighbor.textureSwap.steps) do
    durations[#durations + 1] = step.durationTicks
  end
  Assert.deepEqual(durations, FLOWER_STEP_DURATIONS)
  Assert.equal(textureAsset(neighbor.textureSwap.steps[2].texture, bundle.textures).pixels, solidPixels(0, 0, 255))

  -- The one area clip is owned by the central scene only; no neighbour
  -- descriptor repeats it.
  Assert.deepEqual(bundle.scene.terrainAnimations, { textureSrt = false })
  Assert.isNil(bundle.scene.neighbors[1].terrainAnimations)

  -- One shared dependency record, sorted by member id: the neighbour's member
  -- 1 before the central's member 2 despite the central compiling first.
  Assert.deepEqual(bundle.dependencies.fieldTextureAnimations, {
    tableSha1 = Hashing.sha1hex(tableMember),
    memberSha1s = {
      { memberId = 1, sha1 = Hashing.sha1hex(member1) },
      { memberId = 2, sha1 = Hashing.sha1hex(member2) },
    },
  })
  Assert.equal(bundle.dependencies.terrainTextureSrt, false)
end

-- The fldtanime table is an unconditional map-compile dependency: a
-- malformed member 0 fails the whole compile through the public nil, err
-- boundary with the parser's structured error naming the archive/map.
function T.a_malformed_fldtanime_table_fails_the_map_compile()
  local bundle, err = compile({ fieldTextureAnimations = { [0] = "garbage" } })
  Assert.isNil(bundle, "the malformed table fails the compile")
  Assert.isTrue(Errors.is(err), "the malformed table fails with a structured error")
  err = assert(err)
  Assert.equal(err.code, FieldTextureAnimation.ERROR_SIZE)
  Assert.equal(err.context.source.alias, "field_texture_animations")
  Assert.equal(err.context.source.memberId, 0)
  Assert.equal(err.context.source.mapId, MapRomFixture.MAP_ID)
end

function T.a_no_match_map_still_carries_the_table_dependency()
  -- The table hash is unconditional; with no material matched, no replacement
  -- member is hashed and no terrain material gains a swap.
  local tableMember = FieldTexAnimFixture.member({})
  local bundle = assert(compile({ fieldTextureAnimations = { [0] = tableMember } }))
  Assert.deepEqual(bundle.dependencies.fieldTextureAnimations, {
    tableSha1 = Hashing.sha1hex(tableMember),
    memberSha1s = {},
  })
  Assert.equal(bundle.dependencies.terrainTextureSrt, false)
  Assert.isNil(bundle.scene.materials[1].textureSwap)
end

function T.animation_sources_change_the_completion_marker()
  local function compileWith(animations)
    return assert(compile({
      mapPack = flowerPack(),
      landModel = terrainLandModel(),
      fieldTextureAnimations = animations,
    }))
  end
  local base = compileWith(flowerAnimations())
  local changedTable = compileWith({
    [0] = FieldTexAnimFixture.member({
      { name = "flower01", timeline = { { 0, 19 }, { 1, 18 }, { 0, 18 }, { 2, 18 } } },
    }),
    [1] = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) }),
  })
  Assert.isTrue(base.marker ~= changedTable.marker, "the marker must track the fldtanime table bytes")
  local changedMember = compileWith({
    [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = FLOWER_TIMELINE } }),
    [1] = replacementMember({ BASE_TEXEL, texels(0x44), texels(0x33) }),
  })
  Assert.isTrue(base.marker ~= changedMember.marker, "the marker must track the used replacement member bytes")
  Assert.equal(base.marker, compileWith(flowerAnimations()).marker, "identical inputs stay deterministic")
end

-- An animated building model whose display list straddles a mid-run matrix
-- boundary compiles into a descriptor batch carrying the per-vertex source
-- provenance (the DS transforms each vertex at submission under the
-- then-current matrix, so the runtime needs both sources and the split to
-- reproduce the bend).
function T.animated_straddling_primitives_serialize_per_vertex_sources()
  local bw = require("libs.codec.src.BinaryWriter").new()
  bw:u16(0)
  bw:u16(0)
  bw:u8(1)
  bw:u8(0)
  bw:u16(0)
  bw:u32(0) -- resource id 0
  for _ = 1, 3 do
    bw:u32(0xFFFFFFFF)
  end
  assert(#bw:tostring() == 0x18)

  -- A quad display list with MTX_RESTORE slot 3 after the first two
  -- vertices: the quad straddles the boundary, so the descriptor batch must
  -- carry { leading = 2, source = "draw" } -- the pre-restore source.
  local vtx16xy = NB.vtx16xy
  local pack = NB.gxPack
  local straddlingQuad = pack({
    { { 0x40, 0x23, 0x23 }, { 1, vtx16xy(0, 0), 0, vtx16xy(1, 0), 0 } },
    { { 0x14 }, { 3 } },
    { { 0x23, 0x23, 0x41 }, { vtx16xy(1, 1), 0, vtx16xy(0, 1), 0 } },
  })

  local romFs = MapRomFixture.build({
    interiorBuildAnimList = { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = bw:tostring() },
    buildAnim = { [0] = AnimationFixture.jntDoor() },
    -- NsbmdFixture.build's default SBC draws the shape twice; a single
    -- MAT/SHP draw keeps the straddle count at exactly one per shape.
    buildingModel = NsbmdFixture.buildWithSbc(
      string.char(0x06, 0, 0, 0) -- NODEDESC root
        .. string.char(0x02, 0, 1) -- NODE node0 vis
        .. string.char(0x0B) -- POSSCALE
        .. string.char(0x04, 0) -- MAT 0
        .. string.char(0x05, 0) -- SHP 0
        .. string.char(0x01), -- RET
      {
        untextured = true,
        triangle = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, 1 } },
        displayList = straddlingQuad,
      }
    ),
  })
  local bundle = assert(MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL))
  local model = onlyModel(bundle)
  Assert.equal(model.kind, "nitro-dynamic")
  -- The straddling quad's batch carries the per-vertex source split.
  local straddles = {}
  for _, batch in ipairs(model.dynamic.batches) do
    if batch.straddle then
      straddles[#straddles + 1] = batch
    end
  end
  Assert.equal(#straddles, 1)
  Assert.deepEqual(straddles[1].straddle, { leading = 2, source = "draw" })
end

-- The animated cache round trip: compile one animated building model, write
-- the bundle through MapCacheWriter, assert readiness, and load the scene
-- through MapSceneLoader -- the exact boundary the buildcache failure
-- regressed at.
function T.animated_bundle_round_trips_through_writer_readiness_and_loader()
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
  local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")

  local bw = require("libs.codec.src.BinaryWriter").new()
  bw:u16(0)
  bw:u16(0)
  bw:u8(1)
  bw:u8(0)
  bw:u16(0)
  bw:u32(0) -- resource id 0
  for _ = 1, 3 do
    bw:u32(0xFFFFFFFF)
  end
  assert(#bw:tostring() == 0x18)
  local romFs = MapRomFixture.build({
    interiorBuildAnimList = { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = bw:tostring() },
    buildAnim = { [0] = AnimationFixture.jntDoor() },
  })
  local bundle = assert(MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL))
  local model = onlyModel(bundle)
  Assert.equal(model.schema, "g4-model-v5")
  Assert.equal(model.kind, "nitro-dynamic")
  Assert.equal(#model.animations, 1)
  Assert.equal(model.animations[1].name, "door_op")
  Assert.equal(model.animations[1].semanticNames[1], "door.open")

  local c = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = MapCacheWriter.write(c, bundle)
  Assert.isTrue(MapAssetCache.isReady(c, bundle.mapId, marker), "the written map reads ready")
  Assert.isTrue(c:exists(MapAssetCache.modelPath(model.key)), "the model descriptor is on disk")
  -- The model key is content-addressed over the descriptor: a static
  -- compile of the same member would get a different key.
  Assert.isTrue(model.key:match("^indoor:%d+:[0-9a-f]+$") ~= nil, "key embeds the descriptor hash")

  -- The loader builds one animated instance from the written descriptor.
  local scene = assert(c:loadLua(MapAssetCache.mapDir(bundle.mapId) .. "/scene.lua"))
  local meshBuilder = function()
    return { release = function() end }
  end
  local imageBuilder = function()
    return {
      setFilter = function() end,
      setWrap = function() end,
      release = function() end,
    }
  end
  local runtime = MapSceneLoader.load(c, scene, { meshBuilder = meshBuilder, imageBuilder = imageBuilder })
  Assert.equal(runtime.stats.animatedInstances, 1)
  local instance = runtime.animatedInstances[1]
  -- The door clip is scripted (door role, not ambient): the play handle
  -- drives it and the compiled clip advances.
  local handle = instance:play("door.open")
  Assert.equal(handle.clip.name, "door_op")
  runtime:updateAnimated()
  Assert.equal(handle.player.frameFx, 4096, "the compiled clip advances")
end

return { tests = T }
