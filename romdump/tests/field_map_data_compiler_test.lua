-- Deterministic field-map compilation, cache readiness/rollback, and inspector
-- output using a synthetic zone-event member.

local Assert = require("tests.support.Assert")
local Builder = require("tests.support.ZoneEventsBuilder")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMapDataInspector = require("romdump.src.digest.field.FieldMapDataInspector")
local FieldMapDataFixture = require("tests.support.FieldMapDataFixture")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local GameVersion = require("romdump.src.source.GameVersion")
local Schema = require("libs.script.src.Schema")
local Sha256 = require("libs.script.src.Sha256")

local T = {}

local function fixture()
  local member = Builder.build({
    warps = { { x = 684, z = 393, destinationMapId = 61, destinationWarpId = 0, y = 0 } },
  })
  local romFs = FieldMapDataFixture.build({ zoneEventsMember = member })
  local function sha1(bytes)
    return bytes == member and "member-sha" or "archive-sha"
  end
  local function hashLua()
    return "dependency-sha"
  end
  return romFs, sha1, hashLua
end

local function allMapsFixture()
  local romFs = FieldMapDataFixture.build()
  local function sha1()
    return "archive-sha"
  end
  local function hashLua()
    return "dependency-sha"
  end
  return romFs, sha1, hashLua
end

local function playerHouseHeader()
  return string.char(
    0x01,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
    0x06,
    0x41,
    0x03,
    0x00,
    0x07,
    0x00,
    0x06,
    0x41,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00
  )
end

function T.compiles_catalog_identity_source_and_events()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  Assert.equal(bundle.mapId, 60)
  Assert.equal(bundle.field.schema, "g4-field-map-v9")
  Assert.equal(bundle.field.mapSymbol, "MAP_NEW_BARK")
  Assert.equal(bundle.field.cameraType, 0)
  -- Source identity lives only in the dependency record; the runtime asset
  -- carries normalized events plus the semantic bank associations.
  Assert.isNil(bundle.field.source)
  Assert.equal(bundle.field.events.warps[1].x, 684)
  Assert.equal(bundle.dependencies.eventMemberId, 57)
  Assert.equal(bundle.dependencies.eventMemberSha1, "member-sha")
  Assert.equal(bundle.dependencies.eventNarc.fileId, 99)
  Assert.equal(bundle.dependencies.eventNarc.sha1, "archive-sha")
  -- The audio policy resolves through the map matrix: the matrix cell of map
  -- 60 names land member 244, whose BGS payload feeds the soundplates array.
  Assert.equal(bundle.dependencies.landDataMemberId, 244)
  Assert.equal(bundle.marker, "g4-field-map-cache-v1:rom-sha:60:dependency-sha")

  local again = assert(FieldMapDataCompiler.compile(romFs, "MAP_NEW_BARK", sha1, hashLua))
  Assert.equal(LuaWriter.encode(bundle.field), LuaWriter.encode(again.field))
end

function T.emits_strict_init_script_array_for_every_map()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  Assert.equal(bundle.field.schema, "g4-field-map-v9")
  Assert.deepEqual(bundle.field.initScripts, {})
end

function T.player_house_header_618_resolves_scripts_in_body_bank_845()
  local romFs = FieldMapDataFixture.build({ scriptHeaderMember = playerHouseHeader() })
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 63, function()
    return "archive-sha"
  end, function()
    return "dependency-sha"
  end))
  Assert.equal(bundle.field.scriptBankId, 845)
  Assert.deepEqual(bundle.field.initScripts[1].rules, {
    {
      variableId = 0x4106,
      equals = 3,
      scriptId = "vanilla.hgss.scr_seq.0845.script_006",
    },
    {
      variableId = 0x4106,
      equals = 0,
      scriptId = "vanilla.hgss.scr_seq.0845.script_000",
    },
  })
end

function T.normalizes_retail_unbound_script_markers()
  local member = Builder.build({
    objectEvents = {
      {
        objectEventId = 1,
        spriteId = 1,
        movement = 0,
        type = 0,
        eventFlag = 0,
        scriptId = 0xFFFF,
        facingDirection = 0,
        param0 = 0,
        param1 = 0,
        param2 = 0,
        xRange = 0,
        yRange = 0,
        x = 0,
        z = 0,
        y = 0,
      },
    },
  })
  local romFs = FieldMapDataFixture.build({ zoneEventsMember = member })
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, function()
    return "hash"
  end, function()
    return "dependency"
  end))
  Assert.equal(bundle.field.events.objects[1].scriptId, 0)
end

function T.publishes_semantic_object_movement_without_raw_source_movement()
  local member = Builder.build({
    objectEvents = {
      {
        objectEventId = 21,
        spriteId = 22,
        movement = 3,
        type = 24,
        eventFlag = 25,
        scriptId = 26,
        facingDirection = 0,
        param0 = 27,
        param1 = 28,
        param2 = 29,
        xRange = 30,
        yRange = 31,
        x = 32,
        z = 33,
        y = 34,
      },
    },
  })
  local romFs = FieldMapDataFixture.build({ zoneEventsMember = member })
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, function()
    return "hash"
  end, function()
    return "dependency"
  end))
  local object = bundle.field.events.objects[1]
  Assert.equal(object.movementType, "wander_around")
  Assert.isNil(object.movement)
  Assert.deepEqual(object, {
    index = 0,
    objectEventId = 21,
    spriteId = 22,
    movementType = "wander_around",
    type = 24,
    eventFlag = 25,
    scriptId = 26,
    facingDirectionRaw = 0,
    facingDirection = "north",
    param0 = 27,
    param1 = 28,
    param2 = 29,
    xRange = 30,
    yRange = 31,
    x = 32,
    z = 33,
    y = 34,
  })
end

function T.rejects_unknown_object_movement_with_map_and_object_context()
  local member = Builder.build({
    objectEvents = {
      {
        objectEventId = 91,
        spriteId = 1,
        movement = 57,
        type = 0,
        eventFlag = 0,
        scriptId = 0,
        facingDirection = 0,
        param0 = 0,
        param1 = 0,
        param2 = 0,
        xRange = 0,
        yRange = 0,
        x = 0,
        z = 0,
        y = 0,
      },
    },
  })
  local romFs = FieldMapDataFixture.build({ zoneEventsMember = member })
  local bundle, err = FieldMapDataCompiler.compile(romFs, 60, function()
    return "hash"
  end, function()
    return "dependency"
  end)
  Assert.isNil(bundle)
  err = assert(err)
  Assert.equal(err.code, "FIELD_MAP_UNKNOWN_OBJECT_MOVEMENT")
  Assert.equal(err.context.mapId, 60)
  Assert.equal(err.context.mapSymbol, "MAP_NEW_BARK")
  Assert.equal(err.context.objectEventIndex, 0)
  Assert.equal(err.context.objectEventId, 91)
  Assert.equal(err.context.movement, 57)
end

function T.compiles_map_header_types_to_transition_environments_and_rejects_unknown_types()
  local cases = {
    { sourceType = "CAVE", expected = "cave" },
    { sourceType = "CITY_TOWN", expected = "outdoors" },
    { sourceType = "ROUTE", expected = "outdoors" },
    { sourceType = "INTERIOR", expected = "building" },
    { sourceType = "POKEMON_CENTER", expected = "building" },
  }
  for _, case in ipairs(cases) do
    local record = MapCatalog.require(60)
    local originalMapType = record.mapType
    record.mapType = case.sourceType
    local romFs, sha1, hashLua = fixture()
    local ok, bundle = pcall(function()
      return assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
    end)
    record.mapType = originalMapType
    assert(ok, bundle)
    Assert.equal(bundle.field.transitionEnvironment, case.expected, case.sourceType)
  end

  local record = MapCatalog.require(60)
  local originalMapType = record.mapType
  for _, sourceType in ipairs({ "UNDERGROUND", "UNKNOWN" }) do
    record.mapType = sourceType
    local ok, bundle, err = pcall(function()
      local romFs, sha1, hashLua = fixture()
      return FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua)
    end)
    record.mapType = originalMapType
    Assert.isTrue(ok, "unmapped map types must cross the compiler error boundary")
    Assert.isNil(bundle, sourceType)
    Assert.notNil(err, sourceType)
    err = assert(err)
    Assert.equal(err.code, "FIELD_MAP_UNKNOWN_MAP_TYPE", sourceType)
    Assert.equal(err.context.mapId, 60, sourceType)
    Assert.equal(err.context.mapSymbol, "MAP_NEW_BARK", sourceType)
    Assert.equal(err.context.mapType, sourceType, sourceType)
  end
end

function T.map_header_music_fields_are_emitted_as_canonical_sequence_references()
  -- The frozen catalog's dayMusic/nightMusic become canonical audio sequence
  -- references (map 60 = SEQ_GS_T_WAKABA, map 61 = SEQ_GS_UTSUGI_RABO) in the
  -- generated field record, so runtime music policy never branches on map ids
  -- and never decorates a bare source suffix. The music record also carries
  -- the generated policy blocks: ordered flag overrides (empty for maps with
  -- no source rule) and the source surfing traversal override on every record.
  local romFs, sha1, hashLua = fixture()
  local newBark = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  Assert.deepEqual(newBark.field.music, {
    day = "SEQ_GS_T_WAKABA",
    night = "SEQ_GS_T_WAKABA",
    flagOverrides = {},
    traversalOverrides = {
      { traversal = "surfing", sequence = "SEQ_GS_NAMINORI", unlessFlagId = 0x99A },
    },
  })
  Assert.deepEqual(newBark.field.soundplates, {}, "an empty land BGS payload emits no soundplates")
  local elmsLab = assert(FieldMapDataCompiler.compile(romFs, 61, sha1, hashLua))
  Assert.equal(elmsLab.field.music.day, "SEQ_GS_UTSUGI_RABO")
  Assert.equal(elmsLab.field.music.night, "SEQ_GS_UTSUGI_RABO")
end

function T.map_header_message_and_script_banks_are_emitted()
  -- Maps 60/61 associate to message banks 542/543 through the frozen map
  -- catalog (src/data/map_headers.h); the artifact must carry them so runtime
  -- code never branches on map ids.
  local romFs, sha1, hashLua = fixture()
  local newBark = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  Assert.equal(newBark.field.messageBankId, 542)
  Assert.equal(newBark.field.scriptBankId, 842)
  local elmsLab = assert(FieldMapDataCompiler.compile(romFs, 61, sha1, hashLua))
  Assert.equal(elmsLab.field.messageBankId, 543)
  Assert.equal(elmsLab.field.scriptBankId, 843)
end

function T.writer_commits_marker_last_and_inspector_is_stable()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.equal(FieldMapDataCacheWriter.write(cache, bundle), bundle.marker)
  Assert.isTrue(FieldMapDataCache.isReady(cache, 60, bundle.marker))
  Assert.isFalse(FieldMapDataCache.isReady(cache, 60, bundle.marker .. "-old"))

  local report = FieldMapDataInspector.inspect(bundle.field, bundle.dependencies)
  Assert.deepEqual(report.counts, { background = 0, objects = 0, warps = 1, coordinates = 0 })
  local lines = FieldMapDataInspector.lines(report)
  Assert.equal(lines[1], "field-map\tmap=60\tsymbol=MAP_NEW_BARK\tcamera=0\tmember=57\tcounts=0/0/1/0")
  Assert.equal(lines[2], "warp\tmap=60\tindex=0\tx=684\tz=393\ty=0\tdestination=61:0")
end

function T.writer_failure_rolls_back_only_its_map()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  local backend = FakeCache.new()
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("dependencies.lua", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:write("rom-dump.complete", "raw")
  Assert.throws(function()
    FieldMapDataCacheWriter.write(cache, bundle)
  end)
  Assert.isFalse(cache:exists(FieldMapDataCache.mapDir(60)))
  Assert.isTrue(cache:exists("rom-dump.complete"))
end

function T.failed_rebuild_preserves_the_previous_record()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldMapDataCacheWriter.write(cache, first)
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("field.lua", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(FieldMapDataCompiler.compile(romFs, 60, sha1, hashLua))
  second.marker = FieldMapDataCache.marker(sha1, 60, "new-dep-hash")
  Assert.throws(function()
    FieldMapDataCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldMapDataCache.isReady(cache, 60, first.marker), "the previous record remains ready")
  Assert.equal(cache:read(FieldMapDataCache.markerPath(60)), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-map-data-60"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldMapDataCacheWriter.write(cache, second)
  Assert.isTrue(FieldMapDataCache.isReady(cache, 60, second.marker), "a retry publishes the new record")
end

function T.compile_all_skips_non_field_placeholders_but_keeps_actual_records()
  local romFs, sha1, hashLua = allMapsFixture()
  local bundles, compileErr = FieldMapDataCompiler.compileAll(romFs, sha1, hashLua)
  assert(bundles ~= nil, compileErr)
  ---@cast bundles table
  Assert.equal(#bundles, 538)

  local byId = {}
  for _, bundle in ipairs(bundles) do
    byId[bundle.mapId] = bundle
  end
  Assert.isNil(byId[1], "MAP_NOTHING is a catalog placeholder, not a field record")
  Assert.isNil(byId[3], "MAP_UNDERGROUND has no field data, not a field record")
  Assert.notNil(byId[0])
  Assert.notNil(byId[2])
end

local HEARTGOLD_SHA1 = GameVersion.VERSIONS.heartgold.sha1

local function generationIdFor(producerBody)
  local identity = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "development",
    producerId = "d" .. producerBody,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  return assert(identity.generationId)
end

-- One worker source session compiles maps one at a time: each record matches
-- the one-shot normalization exactly, repeated compiles stay independent (no
-- shared per-map mutation leaks between bundles), and the session closes
-- idempotently and compiles nothing afterwards.
function T.field_map_data_session_compiles_one_map_at_a_time()
  Assert.equal(type(FieldMapDataCompiler.newSession), "function", "per-map production reuses one source session")
  local romFs = FieldMapDataFixture.build()
  local session = assert(FieldMapDataCompiler.newSession(romFs))
  local first = assert(session:compile(60))
  local direct = assert(FieldMapDataCompiler.compile(romFs, 60))
  Assert.equal(LuaWriter.encode(first.field), LuaWriter.encode(direct.field), "one-map field record matches")
  Assert.equal(
    LuaWriter.encode(first.dependencies),
    LuaWriter.encode(direct.dependencies),
    "one-map dependencies match"
  )
  local bySymbol = assert(session:compile("MAP_NEW_BARK"))
  Assert.equal(LuaWriter.encode(bySymbol.field), LuaWriter.encode(first.field), "symbol and id resolve alike")
  first.field.events.warps = "mutated"
  local fresh = assert(session:compile(60))
  Assert.equal(LuaWriter.encode(fresh.field), LuaWriter.encode(direct.field), "bundles share no per-map mutation")
  session:close()
  session:close()
  local ok, leftover = pcall(function()
    return session:compile(60)
  end)
  Assert.isTrue(not ok or leftover == nil, "a closed session compiles nothing")
end

-- The writer stages exactly its normalized field record through a
-- caller-owned stage: field, dependencies, and marker land under the map's
-- own directory with readback validation, never a sibling map's, and a
-- malformed record fails the stage while the previous publication stands.
function T.field_map_data_stage_writes_exactly_its_own_map_record()
  Assert.equal(type(FieldMapDataCacheWriter.stage), "function", "field records stage through the stage-only boundary")
  local romFs = FieldMapDataFixture.build()
  local bundle = assert(FieldMapDataCompiler.compile(romFs, 60))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local generation = generationIdFor(Sha256.hex("field map data stage"))
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "map-data",
    key = "60",
    jobKey = "map-data:60",
    stageName = "map-data-60",
  })
  FieldMapDataCacheWriter.stage(artifact, bundle)
  local stage = artifact:stageFs()
  Assert.deepEqual(stage:loadLua(FieldMapDataCache.fieldPath(60)), bundle.field, "the staged record matches")
  Assert.deepEqual(
    stage:loadLua(FieldMapDataCache.dependenciesPath(60)),
    bundle.dependencies,
    "the staged dependencies match"
  )
  Assert.equal(stage:read(FieldMapDataCache.markerPath(60)), bundle.marker, "the marker stages with the record")
  Assert.isFalse(stage:exists(FieldMapDataCache.mapDir(61)), "no sibling map record is staged")
  artifact:finishSuccess({ marker = bundle.marker })
  artifact:publish({
    generationId = generation,
    epoch = 1,
    kind = "map-data",
    key = "60",
    jobKey = "map-data:60",
  })
  Assert.isTrue(FieldMapDataCache.isReady(cache, 60, bundle.marker), "the staged record publishes ready")

  local malformed = {
    mapId = 60,
    marker = "malformed-marker",
    field = { schema = "not-a-field-schema", mapId = 60 },
    dependencies = {},
  }
  local retry = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "map-data",
    key = "60",
    jobKey = "map-data:60",
    stageName = "field-map-data-60-retry",
  })
  local ok, stageErr = pcall(FieldMapDataCacheWriter.stage, retry, malformed)
  Assert.isFalse(ok, "a malformed record fails its stage: " .. tostring(stageErr))
  retry:abort()
  Assert.isTrue(
    FieldMapDataCache.isReady(cache, 60, bundle.marker),
    "the failed stage leaves the previous record ready"
  )
  Assert.equal(cache:read(FieldMapDataCache.markerPath(60)), bundle.marker, "no malformed marker leaked")
end

-- A session rejection is a per-map diagnostic, not session poison: an
-- unknown map fails with its structured identity and the same session keeps
-- compiling known maps afterwards.
function T.field_map_data_session_rejects_unknown_maps_without_poisoning_the_session()
  local romFs = FieldMapDataFixture.build()
  local session = assert(FieldMapDataCompiler.newSession(romFs))
  local missing, err = session:compile("MAP_DOES_NOT_EXIST")
  Assert.isNil(missing)
  err = assert(err)
  Assert.equal(err.code, "MAP_CATALOG_UNKNOWN")
  local bundle = assert(session:compile(60))
  Assert.equal(bundle.mapId, 60, "the session stays usable after a rejection")
  session:close()
end

return { tests = T }
