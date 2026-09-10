-- TerrainAnimationCompiler: contract tests for the map-scoped compiler that
-- annotates fldtanime-matched terrain materials (`data/fldtanime.narc` in
-- pret/pokeheartgold, dump alias `field_texture_animations`) with
-- textureSwap.steps records, decodes every referenced replacement frame from
-- the replacement member's texels under the base material's palette, compiles
-- the area NSBTA selected by the area record's dynamicTextureType (archive
-- `field_area_texture_srt`), and accumulates deterministic dependency hashes.
-- The compiler is exercised through ModelAssetCompiler.compileModel with the
-- terrain compiler in the context, the production route, then through
-- compileTextureSrt() and dependencies().

local Assert = require("tests.support.Assert")
local AnimationFixture = require("tests.support.AnimationFixture")
local FieldTexAnimFixture = require("tests.support.FieldTextureAnimationFixture")
local ffi = require("ffi")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapRomFixture = require("tests.support.MapRomFixture")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NsbmdDynamicModel = require("romdump.src.digest.model.NsbmdDynamicModel")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local PngWriter = require("libs.assets.src.PngWriter")
local TF = require("tests.support.TextureFixtures")
local Tex0Fixture = require("tests.support.Tex0Fixture")
local TerrainAnimationCompiler = require("romdump.src.digest.map.TerrainAnimationCompiler")

local T = {}

local MAP_ID = MapRomFixture.MAP_ID
local PACK_ID = MapRomFixture.MAP_TEXTURE_PACK_ID
local LAND_MEMBER_ID = MapRomFixture.LAND_DATA_MEMBER_ID

-- Base map texture: 8x8 palette16 whose texels are all index 1, over a
-- palette with distinct colours at indices 1-3 so an alternate frame's texel
-- and palette provenance is observable in the decoded pixels.
local BASE_TEXEL = string.rep(string.char(0x11), 32)
local BASE_PALETTE = { TF.BLACK, TF.RED, TF.GREEN, TF.BLACK }
-- The replacement pack's own palette marks index 2 blue; a compiler that
-- decoded alternates with the replacement palette instead of the base one
-- would produce blue frames and fail the pixel assertions.
local REPLACEMENT_PALETTE = { TF.BLACK, TF.BLUE, TF.BLUE, TF.BLUE }

local FLOWER_TIMELINE = { { 0, 18 }, { 1, 18 }, { 0, 18 }, { 2, 18 } }

local function texels(pattern)
  return string.rep(string.char(pattern), 32)
end

-- A replacement BTX0 member whose dictionary textures, in order, are the
-- swap frames; the palette is deliberately the replacement's own.
local function replacementMember(texelList)
  local textures = {}
  for i, texel in ipairs(texelList) do
    textures[#textures + 1] = { name = "alt" .. i, texel = texel }
  end
  return Tex0Fixture.btx0({
    textures = textures,
    palettes = { { name = "alt_pal", palette = TF.palette(REPLACEMENT_PALETTE) } },
  })
end

local function flowerAnimations()
  return {
    [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = FLOWER_TIMELINE } }),
    [1] = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) }),
  }
end

local function basePack()
  return {
    textures = { { name = "flower01", texel = BASE_TEXEL } },
    palettes = { { name = "map_pal", palette = TF.palette(BASE_PALETTE) } },
  }
end

-- Fixture options that wire the animation defaults: the base pack the map
-- material binds and the fldtanime table plus its replacement member.
local function animationSceneOpts()
  return { mapPack = basePack(), fieldTextureAnimations = flowerAnimations() }
end

-- One decoded terrain model whose material binds `textureName` with the
-- 8x8 fixture texture geometry.
local function terrainModel(opts)
  opts = opts or {}
  local bytes = NsbmdFixture.build({
    modelName = "map0",
    materialName = opts.materialName or "m_flower01",
    textureName = opts.textureName or "flower01",
    paletteName = "map_pal",
    origWidth = 8,
    origHeight = 8,
    triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
  })
  return assert(Nsbmd.decode(bytes, { alias = "land_data", memberId = LAND_MEMBER_ID })).models[1]
end

-- Fixture romFs + decoded map pack + one map-scoped compiler.
local function buildScene(opts)
  opts = opts or {}
  local romFs, members = MapRomFixture.build(opts)
  local pack = assert(Nsbtx.decode(members.map_textures[PACK_ID], { alias = "map_textures", memberId = PACK_ID }))
  local dynamicTextureType = opts.dynamicTextureType
  if dynamicTextureType == nil then
    dynamicTextureType = 0xFFFF
  end
  local compiler = TerrainAnimationCompiler.new(romFs, {
    mapId = MAP_ID,
    dynamicTextureType = dynamicTextureType,
  })
  return { romFs = romFs, members = members, pack = pack, compiler = compiler }
end

-- The full production route: compile one central terrain model through
-- ModelAssetCompiler.compileModel with the terrain compiler attached.
local function compileScene(opts)
  opts = opts or {}
  local scene = buildScene(opts)
  local meshes, textures = {}, {}
  scene.compiled = ModelAssetCompiler.compileModel(terrainModel(opts), scene.pack, meshes, textures, {
    mapId = MAP_ID,
    role = "map",
    textureArchive = "map_textures",
    textureMemberId = PACK_ID,
    modelArchive = "land_data",
    modelMemberId = LAND_MEMBER_ID,
    modelName = "map0",
    terrainAnimationCompiler = scene.compiler,
  })
  scene.meshes = meshes
  scene.textures = textures
  return scene
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.equal(err.code, code)
  return err
end

local function textureAsset(path, textures)
  for sha1, asset in pairs(textures) do
    if MapAssetCache.texturePath(sha1) == path then
      return asset
    end
  end
  error("no compiled texture for " .. path)
end

local function solidPixels(r, g, b)
  return string.rep(string.char(r, g, b, 255), 64)
end

local function texturePng(path, textures)
  local asset = textureAsset(path, textures)
  Assert.isNil(asset.pixels, "compiled textures retain only finalized PNG Data")
  return ffi.string(asset.data:getFFIPointer(), asset.data:getSize())
end

local function stepDurations(swap)
  local out = {}
  for _, step in ipairs(swap.steps) do
    out[#out + 1] = step.durationTicks
  end
  return out
end

-- Matching is by the decoded material's textureName, never its material
-- name: the material is named m_flower01 while the record names the texture
-- flower01. The swap carries direct playback steps in schedule order.
function T.texture_name_match_annotates_the_terrain_material()
  local scene = assert(compileScene(animationSceneOpts()))
  local material = scene.compiled.materials[1]
  Assert.equal(material.name, "m_flower01")
  Assert.equal(material.textureSwap.name, "flower01")
  Assert.equal(#material.textureSwap.steps, 4)
  Assert.deepEqual(stepDurations(material.textureSwap), { 18, 18, 18, 18 })
  local steps = material.textureSwap.steps
  for i, step in ipairs(steps) do
    Assert.isTrue(
      type(step.texture) == "string" and step.texture:find("^assets/generated/maps/textures/") ~= nil,
      "step " .. i .. " is a cache-relative path"
    )
  end
  -- Repeated source indices repeat the same content-addressed path.
  Assert.equal(steps[1].texture, steps[3].texture)
  Assert.isTrue(steps[1].texture ~= steps[2].texture)
  Assert.isTrue(steps[2].texture ~= steps[4].texture)
end

function T.an_unmatched_material_stays_static_and_reads_no_replacement_member()
  -- The table names flower01 and its replacement member 1, which the fixture
  -- does NOT provide: any read of it would trip the fixture's missing-member
  -- assert. The material binds map_tex, which no record names, so it must
  -- compile unannotated without touching the archive.
  local tableMember = FieldTexAnimFixture.member({ { name = "flower01", timeline = FLOWER_TIMELINE } })
  local scene = assert(compileScene({
    textureName = "map_tex",
    fieldTextureAnimations = { [0] = tableMember },
  }))
  local material = scene.compiled.materials[1]
  Assert.isNil(material.textureSwap)
  Assert.notNil(material.texture, "the unmatched material still binds its base texture")
  local deps = scene.compiler:dependencies()
  Assert.deepEqual(deps.fieldTextureAnimations.memberSha1s, {})
  Assert.equal(deps.fieldTextureAnimations.tableSha1, Hashing.sha1hex(tableMember))
end

-- The base material decodes texel index 1 -> the base palette's red; the
-- alternate frames decode from the replacement texels under the BASE palette
-- (green at index 2, black at index 3), never the replacement's own palette.
function T.alters_decode_with_the_base_palette_and_replacement_texels()
  local scene = assert(compileScene(animationSceneOpts()))
  local material = scene.compiled.materials[1]
  Assert.equal(texturePng(material.texture, scene.textures), PngWriter.encode(8, 8, solidPixels(255, 0, 0)))
  Assert.equal(
    texturePng(material.textureSwap.steps[2].texture, scene.textures),
    PngWriter.encode(8, 8, solidPixels(0, 255, 0))
  )
  Assert.equal(
    texturePng(material.textureSwap.steps[4].texture, scene.textures),
    PngWriter.encode(8, 8, solidPixels(0, 0, 0))
  )
end

-- The base material's image is the map pack's initially bound texture; the
-- schedule's first replacement entry is a distinct asset compiled from the
-- replacement member's own texels. The runtime shows the base until the first
-- schedule switch, so the two must never be forced equal.
function T.a_divergent_replacement_zero_compiles_as_its_own_asset()
  local scene = assert(compileScene({
    mapPack = {
      textures = { { name = "flower01", texel = BASE_TEXEL } },
      palettes = { { name = "map_pal", palette = TF.palette({ TF.BLACK, TF.RED, TF.GREEN, TF.BLUE }) } },
    },
    fieldTextureAnimations = {
      [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 1 }, { 1, 1 } } } }),
      -- Dictionary index 0 is green texels, index 1 blue: neither equals the
      -- base's red texels.
      [1] = replacementMember({ texels(0x22), texels(0x33) }),
    },
  }))
  local material = scene.compiled.materials[1]
  Assert.equal(texturePng(material.texture, scene.textures), PngWriter.encode(8, 8, solidPixels(255, 0, 0)))
  Assert.equal(#material.textureSwap.steps, 2)
  Assert.equal(material.textureSwap.steps[1].durationTicks, 1)
  Assert.equal(material.textureSwap.steps[2].durationTicks, 1)
  Assert.isTrue(material.textureSwap.steps[1].texture ~= material.texture, "step zero is not the base image")
  Assert.equal(
    texturePng(material.textureSwap.steps[1].texture, scene.textures),
    PngWriter.encode(8, 8, solidPixels(0, 255, 0))
  )
  Assert.equal(
    texturePng(material.textureSwap.steps[2].texture, scene.textures),
    PngWriter.encode(8, 8, solidPixels(0, 0, 255))
  )
end

-- Compatibility is checked only for the replacement dictionary entries the
-- live schedule actually references: an unused incompatible entry is
-- irrelevant to playback and must not fail the compile.
function T.only_referenced_replacement_entries_are_validated()
  local incompatible = { { name = "alt3", width = 16, height = 8 } }
  local function compileWithTimeline(timeline)
    return compileScene({
      mapPack = basePack(),
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = timeline } }),
        [1] = Tex0Fixture.btx0({
          textures = {
            { name = "alt1", texel = BASE_TEXEL },
            { name = "alt2", texel = texels(0x22) },
            incompatible[1],
          },
          palettes = { { name = "alt_pal", palette = TF.palette(REPLACEMENT_PALETTE) } },
        }),
      },
    })
  end
  -- The schedule references only entries 0 and 1; the incompatible entry 2
  -- is never touched.
  local scene = assert(compileWithTimeline({ { 0, 18 }, { 1, 18 } }))
  Assert.equal(#scene.compiled.materials[1].textureSwap.steps, 2)
  -- Once the schedule references entry 2, the incompatibility is diagnosed.
  local err = throwsCode(TerrainAnimationCompiler.ERROR_TEXTURE_INCOMPATIBLE, function()
    return compileWithTimeline({ { 0, 18 }, { 2, 18 } })
  end)
  Assert.isTrue(tostring(err.message):find("flower01") ~= nil, "the error names the record")
end

function T.an_out_of_range_schedule_index_fails()
  local err = throwsCode(TerrainAnimationCompiler.ERROR_TEXTURE_INDEX, function()
    return compileScene({
      mapPack = basePack(),
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 3, 18 } } } }),
        [1] = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) }),
      },
    })
  end)
  Assert.isTrue(tostring(err.message):find("flower01") ~= nil, "the error names the record")
end

function T.incompatible_referenced_replacement_textures_fail()
  local cases = {
    width = { { name = "alt1", format = 3, width = 16, height = 8 } },
    height = { { name = "alt1", format = 3, width = 8, height = 16 } },
    format = { { name = "alt1", format = 2, width = 8, height = 8 } },
    texel = { { name = "alt1", texel = string.rep("\0", 16) } },
  }
  for name, textures in pairs(cases) do
    local err = Assert.throws(function()
      return compileScene({
        mapPack = basePack(),
        fieldTextureAnimations = {
          [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 } } } }),
          -- Only the texel-length case ends the pack at the texel region; the
          -- others carry a full palette block.
          [1] = Tex0Fixture.btx0({
            textures = textures,
            palettes = name == "texel" and {} or { { name = "alt_pal", palette = TF.palette(REPLACEMENT_PALETTE) } },
          }),
        },
      })
    end, "incompatibility case " .. name)
    Assert.equal(err.code, TerrainAnimationCompiler.ERROR_TEXTURE_INCOMPATIBLE)
  end

  -- Auxiliary/index-data length: the base is compressed4x4 with an 8-byte
  -- control-word region; the replacement is compressed4x4 with a 4-byte one.
  local err = Assert.throws(function()
    return compileScene({
      mapPack = {
        textures = { { name = "flower01", format = 5, plttIdx = string.rep("\0", 8) } },
        palettes = { { name = "map_pal", palette = TF.palette(BASE_PALETTE) } },
      },
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 } } } }),
        [1] = Tex0Fixture.btx0({
          textures = { { name = "alt1", format = 5, plttIdx = string.rep("\0", 4) } },
          palettes = {},
        }),
      },
    })
  end, "auxiliary-data incompatibility")
  Assert.equal(err.code, TerrainAnimationCompiler.ERROR_TEXTURE_INCOMPATIBLE)
end

function T.dynamic_texture_type_ffff_reads_no_nsbta_member()
  -- The fixture provides no field_area_texture_srt archive at all, so any
  -- read would trip the missing-archive assert; the no-animation selection
  -- must compile without touching it.
  local scene = assert(compileScene({ dynamicTextureType = 0xFFFF }))
  Assert.equal(scene.compiler:compileTextureSrt(), false)
  Assert.equal(scene.compiler:dependencies().terrainTextureSrt, false)
end

function T.a_selected_nsbta_compiles_the_existing_clip_shape_without_source_fields()
  local srtBytes = AnimationFixture.srtWater()
  local scene = assert(compileScene({
    dynamicTextureType = 0,
    fieldAreaTextureSrt = { [0] = srtBytes },
  }))
  local clip = scene.compiler:compileTextureSrt()
  assert(clip ~= false, "a selected NSBTA must compile a clip")
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
  -- The selected member is recorded as producer provenance in the deps.
  Assert.deepEqual(scene.compiler:dependencies().terrainTextureSrt, {
    memberId = 0,
    sha1 = Hashing.sha1hex(srtBytes),
  })
end

-- A member with several decoded animations drives the clip from animation
-- index zero, exactly like HGSS; there is no ambiguity error.
function T.a_multi_animation_nsbta_selects_index_zero()
  local scene = assert(compileScene({
    dynamicTextureType = 0,
    fieldAreaTextureSrt = { [0] = AnimationFixture.srtMember({ "first", "second" }) },
  }))
  local clip = scene.compiler:compileTextureSrt()
  assert(clip ~= false, "a selected NSBTA must compile a clip")
  Assert.equal(clip.name, "first", "the first decoded animation is selected")
  Assert.equal(clip.id, "first")
end

function T.an_invalid_selected_nsbta_member_fails()
  local function srtErr(dynamicTextureType, fieldAreaTextureSrt)
    return Assert.throws(function()
      local scene = compileScene({ dynamicTextureType = dynamicTextureType, fieldAreaTextureSrt = fieldAreaTextureSrt })
      return scene.compiler:compileTextureSrt()
    end)
  end
  -- Out of range: the archive has one member, the area selects member 5.
  Assert.equal(
    srtErr(5, { [0] = AnimationFixture.srtWater() }).code,
    TerrainAnimationCompiler.ERROR_SRT_MEMBER_OUT_OF_RANGE
  )
  -- Wrong Nitro format: a BTX0 member is not an animation resource.
  Assert.equal(
    srtErr(0, { [0] = Tex0Fixture.btx0({ textures = { "x" }, palettes = { "y" } }) }).code,
    "ANM_UNKNOWN_FILE_MAGIC"
  )
  -- A valid animation of the wrong kind: NSBCA is not the NSBTA the area
  -- texture-SRT selection requires.
  Assert.equal(srtErr(0, { [0] = AnimationFixture.jntDoor() }).code, TerrainAnimationCompiler.ERROR_SRT_NOT_NSBTA)
  -- An empty animation set cannot drive a clip.
  Assert.equal(srtErr(0, { [0] = AnimationFixture.srtMember({}) }).code, TerrainAnimationCompiler.ERROR_EMPTY_SET)
end

function T.dependencies_carry_the_table_hash_and_only_used_member_hashes()
  local tableMember = FieldTexAnimFixture.member({
    { name = "flower01", timeline = FLOWER_TIMELINE },
    { name = "flower02", timeline = { { 0, 12 }, { 1, 12 } } },
    { name = "flower03", timeline = { { 0, 6 } } },
  })
  local member1 = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) })
  local member2 = replacementMember({ BASE_TEXEL, texels(0x22) })
  local member3 = replacementMember({ BASE_TEXEL }) -- present but never used
  local scene = buildScene({
    mapPack = {
      textures = {
        { name = "flower01", texel = BASE_TEXEL },
        { name = "flower02", texel = BASE_TEXEL },
      },
      palettes = { { name = "map_pal", palette = TF.palette(BASE_PALETTE) } },
    },
    fieldTextureAnimations = {
      [0] = tableMember,
      [1] = member1,
      [2] = member2,
      [3] = member3,
    },
  })
  local function compileModel(textureName, role)
    local meshes, textures = {}, {}
    local compiled =
      ModelAssetCompiler.compileModel(terrainModel({ textureName = textureName }), scene.pack, meshes, textures, {
        mapId = MAP_ID,
        role = role,
        textureArchive = "map_textures",
        textureMemberId = PACK_ID,
        modelArchive = "land_data",
        modelMemberId = LAND_MEMBER_ID,
        modelName = "map0",
        terrainAnimationCompiler = scene.compiler,
      })
    return compiled
  end
  -- The central terrain matches flower02 (member 2); the neighbor chunk
  -- matches flower01 (member 1). Both compile into one map-scoped compiler,
  -- so the recorded member list is sorted by member id: 1 before 2.
  local central = compileModel("flower02", "map")
  local neighbor = compileModel("flower01", "neighbor")
  Assert.equal(central.materials[1].textureSwap.name, "flower02")
  Assert.equal(neighbor.materials[1].textureSwap.name, "flower01")

  local deps = scene.compiler:dependencies()
  Assert.deepEqual(deps.fieldTextureAnimations, {
    tableSha1 = Hashing.sha1hex(tableMember),
    memberSha1s = {
      { memberId = 1, sha1 = Hashing.sha1hex(member1) },
      { memberId = 2, sha1 = Hashing.sha1hex(member2) },
    },
  })
  Assert.equal(deps.terrainTextureSrt, false)
end

-- The texture-matrix fields are a terrain-material contract: compileModel
-- emits them for the map and neighbor roles, and never for placed-building
-- models -- the fields are role-scoped while the textureSwap annotation is
-- option-scoped (context.terrainAnimationCompiler presence).
function T.terrain_fields_are_scoped_to_terrain_roles()
  local scene = buildScene(animationSceneOpts())
  local function compileModel(role)
    local meshes, textures = {}, {}
    return ModelAssetCompiler.compileModel(terrainModel(), scene.pack, meshes, textures, {
      mapId = MAP_ID,
      role = role,
      textureArchive = "map_textures",
      textureMemberId = PACK_ID,
      modelArchive = "land_data",
      modelMemberId = LAND_MEMBER_ID,
      modelName = "map0",
    })
  end
  local terrain = compileModel("map")
  Assert.equal(terrain.materials[1].texWidth, 8)
  Assert.equal(terrain.materials[1].texHeight, 8)
  Assert.equal(terrain.materials[1].texMtxMode, 0)
  Assert.isNil(terrain.materials[1].srt, "a material without a static SRT omits the field")
  local building = compileModel("building")
  Assert.isNil(building.materials[1].texWidth, "building models never carry terrain fields")
  Assert.isNil(building.materials[1].texHeight)
  Assert.isNil(building.materials[1].texMtxMode)
  Assert.isNil(building.materials[1].srt)
end

-- The module enforces its own boundary: even when a terrain animation
-- compiler is supplied, a building role never acquires a textureSwap and the
-- collaborator is never invoked -- no replacement member is read.
function T.a_building_role_never_acquires_a_terrain_swap()
  local scene = assert(buildScene(animationSceneOpts()))
  local meshes, textures = {}, {}
  local compiled = ModelAssetCompiler.compileModel(terrainModel(), scene.pack, meshes, textures, {
    mapId = MAP_ID,
    role = "building",
    textureArchive = "map_textures",
    textureMemberId = PACK_ID,
    modelArchive = "land_data",
    modelMemberId = LAND_MEMBER_ID,
    modelName = "map0",
    terrainAnimationCompiler = scene.compiler,
  })
  Assert.isNil(compiled.materials[1].textureSwap, "building models never carry textureSwap")
  Assert.deepEqual(scene.compiler:dependencies().fieldTextureAnimations.memberSha1s, {})
end

-- The static terrain material's normalized srt and the dynamic model base
-- material's srt come from one shared conversion: the same decoded
-- material yields the same evaluator-consumed record on both paths, never a
-- second, slightly different copy.
function T.the_static_terrain_srt_matches_the_dynamic_base_material_conversion()
  local function srtModel()
    local bytes = NsbmdFixture.build({
      modelName = "map0",
      materialName = "m_flower01",
      textureName = "flower01",
      paletteName = "map_pal",
      origWidth = 8,
      origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
      materialSrt = { scale = { s = 0x2000, t = 0x1000 }, trans = { s = 0x40, t = 0x80 } },
    })
    return assert(Nsbmd.decode(bytes, { alias = "land_data", memberId = LAND_MEMBER_ID })).models[1]
  end
  local scene = buildScene(animationSceneOpts())
  local meshes, textures = {}, {}
  local static = ModelAssetCompiler.compileModel(srtModel(), scene.pack, meshes, textures, {
    mapId = MAP_ID,
    role = "map",
    textureArchive = "map_textures",
    textureMemberId = PACK_ID,
    modelArchive = "land_data",
    modelMemberId = LAND_MEMBER_ID,
    modelName = "map0",
  })
  local dynamic = NsbmdDynamicModel.compile(srtModel())
  Assert.deepEqual(static.materials[1].srt, dynamic.materials[1].srt)
  Assert.deepEqual(static.materials[1].srt, {
    transS = 0x40,
    transT = 0x80,
    scaleS = 0x2000,
    scaleT = 0x1000,
    transOne = false,
    rotOne = true,
    scaleOne = false,
  })
end

function T.error_contexts_name_the_record_schedule_and_source_member()
  local err = throwsCode(TerrainAnimationCompiler.ERROR_TEXTURE_INDEX, function()
    return compileScene({
      mapPack = basePack(),
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 }, { 3, 18 } } } }),
        [1] = replacementMember({ BASE_TEXEL, texels(0x22), texels(0x33) }),
      },
    })
  end)
  Assert.equal(err.context.record, "flower01")
  Assert.equal(err.context.recordIndex, 0)
  Assert.equal(err.context.scheduleIndex, 1)
  Assert.equal(err.context.textureIndex, 3)
  Assert.equal(err.context.dictionarySize, 3)
  Assert.equal(err.context.source.alias, "field_texture_animations")
  Assert.equal(err.context.source.memberId, 1)
  Assert.equal(err.context.source.mapId, MAP_ID)
end

function T.error_contexts_name_material_texture_and_source_member()
  local err = throwsCode(TerrainAnimationCompiler.ERROR_TEXTURE_INCOMPATIBLE, function()
    return compileScene({
      mapPack = basePack(),
      fieldTextureAnimations = {
        [0] = FieldTexAnimFixture.member({ { name = "flower01", timeline = { { 0, 18 } } } }),
        [1] = Tex0Fixture.btx0({
          textures = { { name = "alt1", width = 16, height = 8 } },
          palettes = {},
        }),
      },
    })
  end)
  Assert.equal(err.context.record, "flower01")
  Assert.equal(err.context.recordIndex, 0)
  Assert.equal(err.context.material, "m_flower01")
  Assert.equal(err.context.texture, "flower01")
  Assert.equal(err.context.source.alias, "field_texture_animations")
  Assert.equal(err.context.source.memberId, 1)
  Assert.equal(err.context.source.mapId, MAP_ID)
end

return { tests = T }
