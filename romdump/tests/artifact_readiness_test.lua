-- Readiness and repair for derived-cache reuse: a job is reusable only with
-- a current receipt and a usable payload, the exhaustive audit walks the
-- complete canonical inventory instead of trusting markers, and failed
-- repairs keep the last good publication. Every fixture below uses synthetic
-- data through the real family owners; no commercial bytes are committed.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ArtifactState = require("romdump.src.build.ArtifactState")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local MonCache = require("libs.assets.src.MonCache")
local ItemCache = require("libs.assets.src.ItemCache")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local DerivedCacheState = require("romdump.src.DerivedCacheState")

local T = {}

local savedModules = {}
local CacheBuilder
local builderBackend = nil

local GENERATION = "readiness-test-generation"
local SCRIPT_GEN = string.rep("e", 40)
local SCRIPT_SOURCE_HASH = string.rep("c", 40)

local function newCache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local function writeReceipt(cache, kind, key, marker)
  cache:writeLua(ArtifactState.path(kind, key), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = GENERATION,
    kind = kind,
    key = key,
    marker = marker,
  })
end

-- Marker-only completion state: every family marker plus a world manifest.
-- Payloads are added per scenario; a bare marker set must never read as
-- usable on its own.
local function writeMarkers(cache, world)
  local paths = {
    require("libs.assets.src.field.FieldActorCache").markerPath(),
    MonCache.markerPath(),
    ItemCache.markerPath(),
    require("libs.assets.src.BagCache").markerPath(),
    AudioCache.markerPath(),
    FieldCameraCache.markerPath(),
    FieldFontCache.markerPath(),
    FieldMessageCache.markerPath(),
    require("libs.assets.src.field.FieldUiAssetCache").markerPath(),
    require("libs.assets.src.newgame.IntroAssetCache").markerPath(),
    require("libs.assets.src.StarterChoiceAssetCache").markerPath(),
    require("libs.assets.src.field.FieldWeatherCache").markerPath(),
    ScriptCache.markerPath(),
    require("libs.assets.src.field.FieldEffectAssetCache").markerPath(),
    require("libs.assets.src.field.FieldEmoteAssetCache").markerPath(),
    require("libs.assets.src.newgame.NewGameInitCache").markerPath(),
    FieldCellCache.indexMarkerPath(),
  }
  for _, path in ipairs(paths) do
    cache:write(path, "complete")
  end
  cache:writeLua(MapAssetCache.worldPath(), world or { maps = {} })
end

-- Field-cell index payload: a schema-valid index with no matrices, so no
-- cell jobs exist and the index alone decides index readiness.
local function publishCellIndex(cache, marker)
  local index = { schema = FieldCellCache.INDEX_SCHEMA, matrices = {} }
  Assert.isTrue(FieldCellCache.validateIndex(index), "the synthetic index must validate")
  cache:writeLua(FieldCellCache.indexPath(), index)
  cache:write(FieldCellCache.indexMarkerPath(), marker)
  writeReceipt(cache, "field-cell-index", "global", marker)
end

-- Script family fixtures: one member with one script, published through the
-- real writer so summary readiness reflects genuine member bodies.
local function scriptCoverage(memberId, id, scriptIndex)
  return {
    source = { repository = "portemon", romSha1 = "rom-sha" },
    totals = {
      members = 1,
      scripts = 1,
      reachableInstructions = 1,
      supportedInstructions = 1,
      unsupportedInstructions = 0,
      malformedInstructions = 0,
    },
    opcodes = {},
    scripts = {
      {
        sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, scriptIndex or 0),
        publicId = id,
        status = "complete",
        unsupported = {},
      },
    },
  }
end

local function scriptResource(memberId, id, scriptIndex)
  return {
    id = id,
    member = memberId,
    scriptIndex = scriptIndex,
    sourceHash = SCRIPT_SOURCE_HASH,
    resource = {
      api = 1,
      id = id,
      metadata = {
        generated = true,
        source = { sourceHash = SCRIPT_SOURCE_HASH },
        coverage = { complete = true, unsupportedCount = 0 },
      },
      steps = { { op = "stop" } },
    },
    report = { complete = true, unsupportedCount = 0 },
  }
end

local function scriptMember(memberId, id, scriptIndex, marker)
  return {
    memberId = memberId,
    marker = marker,
    sourceHash = SCRIPT_SOURCE_HASH,
    coverage = scriptCoverage(memberId, id, scriptIndex),
    resources = { scriptResource(memberId, id, scriptIndex) },
  }
end

local function scriptPlan(marker, members)
  local planMembers, resources = {}, {}
  for _, entry in ipairs(members) do
    planMembers[#planMembers + 1] = { memberId = entry.memberId, marker = marker .. ":member:" .. entry.memberId }
    resources[#resources + 1] = { id = entry.id, member = entry.memberId, scriptIndex = entry.scriptIndex }
  end
  local plan = {
    generationKey = SCRIPT_GEN,
    marker = marker,
    version = "heartgold",
    sourcePath = "romfs/a/0/1/2",
    romSha1 = "rom-sha",
    dependencies = {
      cacheFormat = ScriptCache.FORMAT,
      versionRomSha1 = "rom-sha",
      scrSeqNarc = { path = "a/0/1/2", sha1 = "archive-sha" },
    },
    memberCount = #members,
    members = planMembers,
    resources = resources,
  }
  plan.index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = SCRIPT_GEN,
    marker = marker,
    memberCount = #members,
    scriptMemberCount = #members,
    skippedMemberCount = 0,
    scriptCount = #resources,
    resourceCount = #resources,
    resources = resources,
  }
  return plan
end

local function stageScriptMember(cache, plan, staged, stageName)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "script-member",
    key = tostring(staged.memberId),
    jobKey = "script-member:" .. tostring(staged.memberId),
    stageName = stageName,
  })
  local marker = assert(ScriptCacheWriter.stageMember(artifact, plan, staged))
  artifact:finishSuccess({ marker = marker })
  Assert.isTrue(artifact:publish({
    generationId = GENERATION,
    epoch = 1,
    kind = "script-member",
    key = tostring(staged.memberId),
    jobKey = "script-member:" .. tostring(staged.memberId),
  }))
  writeReceipt(cache, "script-member", tostring(staged.memberId), marker)
end

local function stageScriptSummary(cache, plan, stageName)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "script-summary",
    key = "global",
    jobKey = "script-summary:global",
    stageName = stageName,
  })
  local marker = assert(ScriptCacheWriter.stageSummary(artifact, plan))
  artifact:finishSuccess({ marker = marker })
  Assert.isTrue(artifact:publish({
    generationId = GENERATION,
    epoch = 1,
    kind = "script-summary",
    key = "global",
    jobKey = "script-summary:global",
  }))
  writeReceipt(cache, "script-summary", "global", marker)
  return marker
end

local function publishScriptFamily(cache, marker, members, prefix)
  local plan = scriptPlan(marker, members)
  for _, entry in ipairs(members) do
    stageScriptMember(
      cache,
      plan,
      scriptMember(entry.memberId, entry.id, entry.scriptIndex, marker .. ":member:" .. entry.memberId),
      prefix .. "-member-" .. entry.memberId
    )
  end
  return plan, stageScriptSummary(cache, plan, prefix .. "-summary")
end

-- A receipt/marker pair with no index payload is cold, and the dependent
-- cell edge still names the index first.
function T.index_marker_without_its_index_payload_is_cold()
  local cache = newCache()
  local marker = FieldCellCache.indexMarker("test-rom", "test-dep")
  cache:write(FieldCellCache.indexMarkerPath(), marker)
  writeReceipt(cache, "field-cell-index", "global", marker)

  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "field-cell-index", "global", {}),
    "an index marker without its index payload must not read ready"
  )
  local dependencies = ArtifactJobs.dependencies("field-cell", "12-5", {})
  Assert.equal(#dependencies, 2, "a cell resolves its planning prerequisites")
  Assert.equal(dependencies[1].kind, "source-plan", "the cell waits on the source inventory first")
  Assert.equal(dependencies[2].kind, "field-cell-index", "the cell waits on the index next")
end

-- A member whose script body is gone is cold even with its markers intact,
-- so the summary that depends on it cannot stay ready either.
function T.member_with_a_missing_script_body_is_cold_before_its_summary()
  local cache = newCache()
  local marker = ScriptCache.marker("rom-sha", "dep-sha")
  local members = {
    { memberId = 3, id = "common.signpost", scriptIndex = 0 },
    { memberId = 843, id = "new_bark.lab_sign", scriptIndex = 9 },
  }
  local plan, _ = publishScriptFamily(cache, marker, members, "missing-body")
  Assert.isTrue(ScriptCache.isReady(cache, marker), "the published class reads ready before damage")

  cache:remove(ScriptCache.scriptPath(SCRIPT_GEN, 843, "new_bark.lab_sign"))

  local plans = { scriptPlan = plan, scriptMemberIds = { 3, 843 } }
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "script-member", "843", plans),
    "a member with a missing script body must not read ready"
  )
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "script-summary", "global", plans),
    "the summary cannot stay ready while a member body is missing"
  )
  local found = false
  for _, dependency in ipairs(ArtifactJobs.dependencies("script-summary", "global", plans)) do
    if dependency.kind == "script-member" and dependency.key == "843" then
      found = true
    end
  end
  Assert.isTrue(found, "summary repair routes through the damaged member first")
end

-- A cold leaf plus an injected staging failure keeps the previous live
-- bytes, receipts and attestation untouched; nothing partial publishes.
function T.failed_leaf_repair_keeps_the_last_good_publication()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local marker = ScriptCache.marker("rom-sha", "dep-sha")
  local members = {
    { memberId = 3, id = "common.signpost", scriptIndex = 0 },
    { memberId = 843, id = "new_bark.lab_sign", scriptIndex = 9 },
  }
  local plan, _ = publishScriptFamily(cache, marker, members, "preserve-good")
  cache:remove(ScriptCache.scriptPath(SCRIPT_GEN, 843, "new_bark.lab_sign"))

  local plans = { scriptPlan = plan, scriptMemberIds = { 3, 843 } }
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "script-member", "843", plans),
    "the damaged leaf must force its own repair"
  )

  local original = backend.write
  backend.write = function(self, path, data)
    if path:find("/scripts/", 1, true) then
      error("injected member write failure")
    end
    return original(self, path, data)
  end
  local failed = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "script-member",
    key = "843",
    jobKey = "script-member:843",
    stageName = "failed-repair-843",
  })
  local ok = pcall(
    ScriptCacheWriter.stageMember,
    failed,
    plan,
    scriptMember(843, "new_bark.lab_sign", 9, marker .. ":member:843")
  )
  failed:abort()
  backend.write = original
  Assert.isFalse(ok, "the injected staging failure must fail the repair")

  Assert.equal(
    cache:read(ScriptCache.memberMarkerPath(SCRIPT_GEN, 3)),
    marker .. ":member:3",
    "the healthy sibling marker survives the failed repair"
  )
  local sibling = cache:loadModule(ScriptCache.scriptPath(SCRIPT_GEN, 3, "common.signpost"))
  Assert.equal(sibling.id, "common.signpost", "the healthy sibling body survives the failed repair")
  Assert.equal(cache:read(ScriptCache.markerPath()), marker, "the previous summary marker survives")
  Assert.isNil(cache:read(require("romdump.src.DerivedCacheState").path), "no complete attestation publishes")
  Assert.isNil(backend:getInfo("staging/heartgold/failed-repair-843"), "the failed stage is discarded")
end

-- A matching attestation with intact markers is not a usability proof: with
-- a coarse payload deleted, common preparation must never report current.
function T.matching_attestation_with_a_damaged_coarse_payload_is_never_current()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  writeMarkers(cache, { maps = {} })
  cache:write(FieldCameraCache.profilesPath(), "payload")
  cache:write(FieldCameraCache.provenancePath(), "payload")
  cache:remove(FieldCameraCache.profilesPath())
  local Contract = require("libs.assets.src.DerivedAssetContract")
  local ScriptApi = require("libs.script.src.Schema")
  local identity = {
    schema = DerivedCacheState.schema,
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    mode = "development",
    producerId = "d" .. string.rep("1", 64),
    assetRevision = Contract.revision,
    scriptApi = ScriptApi.API_VERSION,
    generationId = "attested-generation",
  }
  DerivedCacheState.publish(cache, identity)
  Assert.isTrue(
    DerivedCacheState.matches(cache:loadLua(DerivedCacheState.path), identity),
    "the attestation matches before preparation"
  )
  builderBackend = backend
  local report = CacheBuilder.prepareVersion("heartgold", {
    identity = identity,
    requirements = { "complete" },
    log = function() end,
  })
  builderBackend = nil
  Assert.isTrue(report == nil or report.complete ~= true, "a damaged cache must never report current")
end

-- Synthetic corpus builders below: every family publishes minimal valid
-- payloads through its real owner, so the audit premise is genuine and any
-- refusal names the deliberately damaged leaf.

local function publishMessageFamily(cache, marker)
  cache:write(FieldMessageCache.markerPath(), marker)
  cache:writeLua(FieldMessageCache.indexPath(), { schema = FieldMessageCache.INDEX_SCHEMA, bankIds = {} })
  writeReceipt(cache, "message-summary", "global", marker)
end

local function publishAudioFamily(cache, marker)
  cache:write(AudioCache.markerPath(), marker)
  cache:writeLua(AudioCache.indexPath(), {
    schema = AudioCache.INDEX_SCHEMA,
    sequences = {},
    banks = {},
    players = {},
    sequenceBySymbol = {},
    bankBySymbol = {},
  })
  cache:write(AudioCache.catalogMarkerPath(), marker)
  writeReceipt(cache, "audio-catalog", "global", marker)
  writeReceipt(cache, "audio-summary", "global", marker)
end

local function publishMonFamily(cache, marker)
  local PngWriter = require("libs.assets.src.PngWriter")
  local function manifestFor(schema, pageImage, pageWidth, pageHeight, cell)
    return {
      schema = schema,
      version = { id = "heartgold", language = "english" },
      pages = {
        [0] = { pageId = 0, image = pageImage, width = pageWidth, height = pageHeight },
      },
      pageIds = { 0 },
      entries = {
        ["K/f0"] = {
          x = 0,
          y = 0,
          width = cell,
          height = cell,
          frames = { { x = 0, y = 0, width = cell, height = cell, duration = 6 } },
          pageId = 0,
        },
      },
      representative = { "K/f0" },
    }
  end
  local icons = manifestFor(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32)
  local portraits = manifestFor(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80)
  cache:writeLua(MonCache.iconManifestPath(), icons)
  cache:writeLua(MonCache.portraitManifestPath(), portraits)
  local iconPixels = string.rep("\0", 256 * 128 * 4)
  local portraitPixels = string.rep("\0", 640 * 320 * 4)
  local iconPng = PngWriter.encode(256, 128, iconPixels)
  local portraitPng = PngWriter.encode(640, 320, portraitPixels)
  cache:write(MonCache.iconPagePath(0), iconPng)
  cache:write(MonCache.portraitPagePath(0), portraitPng)
  local Contract = require("libs.assets.src.DerivedAssetContract")
  local iconMarker = MonCache.marker("test-rom", "icons-0")
  local portraitMarker = MonCache.marker("test-rom", "portraits-0")
  cache:write(MonCache.pageMarkerPath("icons", 0), iconMarker)
  cache:write(MonCache.pageMarkerPath("portraits", 0), portraitMarker)
  cache:write(MonCache.catalogPath(), "catalog")
  cache:writeLua(MonCache.indexPath(), {
    schema = Contract.mons.indexSchema,
    version = { id = "heartgold", language = "english" },
    catalogHash = string.rep("d", 40),
    catalog = MonCache.catalogPath(),
    iconManifest = MonCache.iconManifestPath(),
    portraitManifest = MonCache.portraitManifestPath(),
    iconPages = { iconMarker },
    portraitPages = { portraitMarker },
  })
  cache:write(MonCache.markerPath(), marker)
  writeReceipt(cache, "mon-summary", "global", marker)
  writeReceipt(cache, "mon-catalog", "global", MonCache.marker("test-rom", "catalog"))
  writeReceipt(cache, "mon-layout", "global", MonCache.marker("test-rom", "layout"))
  writeReceipt(cache, "mon-icon-page", "0", iconMarker)
  writeReceipt(cache, "mon-portrait-page", "0", portraitMarker)
  return {
    marker = marker,
    iconMarker = iconMarker,
    portraitMarker = portraitMarker,
    iconWidth = 256,
    iconHeight = 128,
    portraitWidth = 640,
    portraitHeight = 320,
    iconPixels = iconPixels,
    portraitPixels = portraitPixels,
    iconPng = iconPng,
    portraitPng = portraitPng,
  }
end

local function publishMapDataRecord(cache, mapId, marker)
  local FieldMapData = FieldMapDataCache
  cache:writeLua(FieldMapData.fieldPath(mapId), {
    schema = FieldMapData.FIELD_SCHEMA,
    mapId = mapId,
    events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    music = {},
    soundplates = {},
    initScripts = {},
    transitionEnvironment = "outdoors",
  })
  cache:writeLua(FieldMapData.dependenciesPath(mapId), { generated = true })
  cache:write(FieldMapData.markerPath(mapId), marker)
  writeReceipt(cache, "map-data", tostring(mapId), marker)
end

local function publishCameraFamily(cache, marker)
  cache:write(FieldCameraCache.profilesPath(), "profiles")
  cache:write(FieldCameraCache.provenancePath(), "provenance")
  cache:write(FieldCameraCache.markerPath(), marker)
  writeReceipt(cache, "field-camera", "global", marker)
end

local function publishFontFamily(cache, marker)
  local FontCache = require("libs.assets.src.field.FieldFontCache")
  for _, fontId in ipairs(FontCache.REQUIRED_FONT_IDS) do
    cache:write(FontCache.defPath(fontId), "def")
    cache:write(FontCache.atlasPath(fontId), "atlas")
    cache:write(FontCache.maskAtlasPath(fontId), "mask")
    cache:write(FontCache.focusIndicatorsPath(fontId), "focus")
  end
  cache:write(FontCache.markerPath(), marker)
  writeReceipt(cache, "field-font", "global", marker)
end

local function publishActorFamily(cache)
  local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
  local Writer = require("romdump.src.digest.actor.FieldActorCacheWriter")
  local Fixture = require("tests.support.FieldActorFixture")
  local states = {
    "walking",
    "cycling",
    "surfing",
    "rocket",
    "watering",
    "fishing",
    "poketch",
    "saving",
    "heal",
    "ladder",
    "rocket_heal",
    "rocket_saving",
    "pokeathlon",
    "apricorn_shake",
  }
  local function capability(id, gender, spriteIds)
    local named = {}
    for i, name in ipairs(states) do
      named[name] = spriteIds[((i - 1) % #spriteIds) + 1]
    end
    return { id = id, gender = gender, states = named }
  end
  local bundle = {
    marker = FieldActorCache.marker("test-rom", "test-dep"),
    index = {
      schema = FieldActorCache.INDEX_SCHEMA,
      romVersion = "heartgold",
      spriteIds = { 0 },
      variableSprites = {},
      recordCount = 3,
      runtime = {
        avatars = { capability("hero", 0, { 0 }), capability("heroine", 1, { 0 }) },
        variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
      },
    },
    visuals = { [0] = Fixture.visual(0, { frameCount = 8 }) },
    atlases = { [0] = { width = 4, height = 1, pixels = string.rep("\0", 16) } },
    provenance = { schema = "g4-field-actor-provenance-v1" },
    dependencies = {},
  }
  Assert.equal(Writer.write(cache, bundle), bundle.marker)
  Assert.isTrue(FieldActorCache.isReady(cache, bundle.marker), "the synthetic actor class must read ready")
  writeReceipt(cache, "actors", "global", bundle.marker)
end

local function publishItemFamily(cache)
  local Writer = require("romdump.src.digest.items.ItemCacheWriter")
  local Hashing = require("romdump.src.digest.Hashing")
  local PngWriter = require("libs.assets.src.PngWriter")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local marker = ItemCache.marker("test-rom", "test-dep")
  local pixels = string.rep("\0", 32 * 32 * 4)
  local catalog = ItemFixture.buildAssetRoot()
  local entries = {}
  for key in pairs(catalog.items) do
    entries[key] = { x = 0, y = 0, width = 32, height = 32 }
  end
  local bundle = {
    marker = marker,
    index = {
      schema = "g4-item-index-v1",
      version = { id = "heartgold", language = "en" },
      catalogHash = Hashing.hashLua(catalog),
      iconHash = Hashing.sha1hex(PngWriter.encode(32, 32, pixels)),
      catalog = ItemCache.catalogPath(),
      icons = ItemCache.iconImagePath(),
      iconManifest = ItemCache.iconManifestPath(),
    },
    catalog = catalog,
    icons = { width = 32, height = 32, pixels = pixels },
    iconManifest = {
      schema = "g4-item-icons-v1",
      atlas = ItemCache.iconImagePath(),
      entries = entries,
      representative = { "POTION" },
    },
    provenance = {},
  }
  Writer.write(cache, bundle)
  Assert.isTrue(ItemCache.isReady(cache, marker), "the synthetic item class must read ready")
  writeReceipt(cache, "items", "global", marker)
end

local function publishEmoteFamily(cache)
  local EmoteCache = require("libs.assets.src.field.FieldEmoteAssetCache")
  local Writer = require("romdump.src.digest.actor.FieldActorEmoteCacheWriter")
  local ModelAsset = require("libs.assets.src.model.ModelAsset")
  local marker = "field-emotes-cache-v2:test-rom:test-dep"
  local modelAsset = {
    schema = ModelAsset.SCHEMA,
    key = "field-emote:exclamation",
    kind = "static",
    batches = {
      {
        geometry = EmoteCache.geometryPath("mesh-key"),
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
        name = "exclamation",
        texture = EmoteCache.texturePath("texture-key"),
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
  local PngWriter = require("libs.assets.src.PngWriter")
  local ok, err = pcall(Writer.write, cache, {
    marker = marker,
    model = {
      schema = "g4-field-emote-v1",
      anchorOffset = { x = 0, y = 2, z = 0.0625 },
      model = modelAsset,
    },
    meshes = {
      ["mesh-key"] = {
        getSize = function()
          return 12
        end,
        getString = function()
          return "encoded-mesh"
        end,
      },
    },
    textures = { ["texture-key"] = { width = 1, height = 1, data = PngWriter.encode(1, 1, "rgba") } },
  })
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(EmoteCache.isReady(cache, marker), "the synthetic emote class must read ready")
  writeReceipt(cache, "field-emotes", "global", marker)
end

local function publishWeatherFamily(cache)
  local WeatherCache = require("libs.assets.src.field.FieldWeatherCache")
  local Compiler = require("romdump.src.digest.field.FieldWeatherCompiler")
  local Writer = require("romdump.src.digest.field.FieldWeatherCacheWriter")
  local bundle = assert(Compiler.compile())
  Assert.isTrue(Writer.write(cache, bundle))
  Assert.isTrue(WeatherCache.isReady(cache, bundle.marker), "the compiled weather class must read ready")
  writeReceipt(cache, "field-weather", "global", bundle.marker)
end

local function publishBagFamily(cache)
  local BagCache = require("libs.assets.src.BagCache")
  local BagSchema = require("libs.assets.src.BagAssetSchema")
  local Writer = require("romdump.src.digest.ui.BagCacheWriter")
  local ModelAsset = require("libs.assets.src.model.ModelAsset")
  local function constantChannel()
    return { source = "constant", value = 0 }
  end
  local function trsClip(id, semanticName)
    return {
      id = id,
      name = id,
      category = "joint",
      kind = "trs",
      frameCount = 4,
      tracks = { { target = 0, targetIndex = 0 } },
      semanticNames = { semanticName },
      compiled = {
        anmFlags = 0,
        rotData = {},
        pivotData = { { 0, 0, 0, 0, 0 } },
        targets = {
          {
            nodeIndex = 0,
            channels = {
              trans = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
              rot = constantChannel(),
              scale = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
            },
          },
        },
      },
    }
  end
  local function dynamicMaterial()
    return {
      id = 0,
      name = "widget",
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
      texWidth = 64,
      texHeight = 64,
      wrap = { x = "clamp", y = "clamp" },
      flip = { x = false, y = false },
      diffuse = { r = 255, g = 255, b = 255, a = 255 },
    }
  end
  local function heroDescriptor(gender)
    local clips = {}
    for _, pocket in ipairs(BagSchema.POCKETS) do
      clips[#clips + 1] = trsClip(gender .. ".pose." .. pocket, "pocket." .. pocket .. ".pose")
      clips[#clips + 1] = trsClip(gender .. ".pattern." .. pocket, "pocket." .. pocket .. ".pattern")
    end
    clips[#clips + 1] = trsClip(gender .. ".material", "bag.material")
    return {
      schema = ModelAsset.SCHEMA,
      kind = "nitro-dynamic",
      dynamic = { nodes = {}, transformProgram = {}, batches = {} },
      materials = { dynamicMaterial() },
      animations = clips,
    }
  end
  local states = {}
  for _, pocket in ipairs(BagSchema.POCKETS) do
    states[#states + 1] =
      { pocket = pocket, pose = "pocket." .. pocket .. ".pose", pattern = "pocket." .. pocket .. ".pattern" }
  end
  local tabs = {}
  for i = 0, 7 do
    tabs[#tabs + 1] = { x = i * 32, y = 0, width = 32, height = 32 }
  end
  local function pocketBackgrounds(state)
    local pockets = {}
    for _, pocket in ipairs(BagSchema.POCKETS) do
      pockets[pocket] =
        { image = "assets/generated/bag/background-" .. state .. "-" .. pocket .. ".png", width = 256, height = 192 }
    end
    return pockets
  end
  local function framingRecord(angleXDegrees, angleYDegrees, distance, modelY)
    return { angleXDegrees = angleXDegrees, angleYDegrees = angleYDegrees, distance = distance, modelY = modelY }
  end
  local function framingPockets(baseAngle)
    local pockets = {}
    for index, pocket in ipairs(BagSchema.POCKETS) do
      pockets[pocket] = framingRecord(baseAngle + index, baseAngle - index, 339.9, -48 + index)
    end
    return pockets
  end
  local function browseBackgrounds()
    local pockets = {}
    for _, pocket in ipairs(BagSchema.POCKETS) do
      local variants = {}
      for i = 1, 7 do
        variants[i] = {
          image = "assets/generated/bag/background-browse-" .. pocket .. "-" .. i .. ".png",
          width = 256,
          height = 192,
        }
      end
      pockets[pocket] = variants
    end
    return pockets
  end
  local function tabStrips()
    local strips = {}
    for _, pocket in ipairs(BagSchema.POCKETS) do
      strips[pocket] = { image = "assets/generated/bag/tab-strip-" .. pocket .. ".png", width = 256, height = 32 }
    end
    return strips
  end
  local function focusTargets(count, y)
    local targets = {}
    for i = 1, count do
      targets[i] = { x = i * 8, y = y }
    end
    return targets
  end
  local edgeColors = {}
  for i = 1, 8 do
    edgeColors[i] = { r = i - 1, g = (i * 3) % 32, b = (i * 7) % 32 }
  end
  local slots = {
    {
      rect = { x = 0, y = 32, width = 128, height = 42 },
      textRect = { x = 32, y = 40, width = 88, height = 32 },
      iconCenter = { x = 48, y = 56 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = { x = 128, y = 32, width = 128, height = 42 },
      textRect = { x = 160, y = 40, width = 88, height = 32 },
      iconCenter = { x = 176, y = 56 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = { x = 0, y = 74, width = 128, height = 44 },
      textRect = { x = 32, y = 80, width = 88, height = 32 },
      iconCenter = { x = 48, y = 96 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = { x = 128, y = 74, width = 128, height = 44 },
      textRect = { x = 160, y = 80, width = 88, height = 32 },
      iconCenter = { x = 176, y = 96 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = { x = 0, y = 118, width = 128, height = 36 },
      textRect = { x = 32, y = 120, width = 88, height = 32 },
      iconCenter = { x = 48, y = 136 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
    {
      rect = { x = 128, y = 118, width = 128, height = 36 },
      textRect = { x = 160, y = 120, width = 88, height = 32 },
      iconCenter = { x = 176, y = 136 },
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    },
  }
  local manifest = {
    schema = BagSchema.SCHEMA,
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = { image = "assets/generated/bag/upper-backdrop-male.png", width = 256, height = 256 },
        female = { image = "assets/generated/bag/upper-backdrop-female.png", width = 256, height = 256 },
      },
      description = {
        frame = {
          image = "assets/generated/bag/upper-base.png",
          alternateImage = "assets/generated/bag/upper-alternate.png",
          rect = { x = 0, y = 144, width = 256, height = 48 },
        },
        textRect = { x = 20, y = 144, width = 236, height = 48 },
      },
      model = { male = heroDescriptor("male"), female = heroDescriptor("female") },
      animations = { states = states, material = { male = "male.material", female = "female.material" } },
      presentation = {
        camera = {
          target = { x = 0, y = 0, z = 0 },
          distance = 339.9,
          angleXDegrees = 328.4,
          angleYDegrees = 28.3,
          perspectiveType = 0,
          perspectiveAngle = 256,
          clipNear = 123.0,
          clipFar = 1700.0,
        },
        transform = {
          translation = { x = 0, y = -48, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
        lights = {
          count = 4,
          color = { r = 31, g = 31, b = 31 },
          vectors = {
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
          },
        },
        materials = {
          diffuse = { r = 15, g = 15, b = 15 },
          ambient = { r = 10, g = 10, b = 10 },
          specular = { r = 15, g = 15, b = 15 },
          emission = { r = 15, g = 15, b = 15 },
        },
        framing = {
          transitionTicks = 7,
          baseline = { male = framingRecord(328.4, 28.3, 339.9, -48), female = framingRecord(328.4, 28.3, 339.9, -48) },
          byGender = { male = framingPockets(328.4), female = framingPockets(328.4) },
        },
        edgeColors = edgeColors,
      },
    },
    interactive = {
      backgrounds = {
        browse = browseBackgrounds(),
        action = pocketBackgrounds("action"),
        quantity = pocketBackgrounds("quantity"),
        confirmation = pocketBackgrounds("confirmation"),
      },
      pocketTabs = {
        rects = tabs,
        strips = tabStrips(),
      },
      itemSlots = {
        slots = slots,
        registration = {
          slot1 = { image = "assets/generated/bag/registration-slot-1.png", width = 40, height = 16 },
          slot2 = { image = "assets/generated/bag/registration-slot-2.png", width = 40, height = 16 },
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      focus = {
        tabs = {
          visual = { image = "assets/generated/bag/focus-tabs.png", width = 16, height = 16 },
          targets = focusTargets(8, 16),
        },
        items = {
          visual = { image = "assets/generated/bag/focus-items.png", width = 16, height = 16 },
          targets = focusTargets(6, 64),
        },
        cancel = {
          visual = { image = "assets/generated/bag/focus-cancel.png", width = 16, height = 16 },
          target = { x = 224, y = 180 },
        },
        actions = {
          visual = { image = "assets/generated/bag/focus-actions.png", width = 16, height = 16 },
          targets = focusTargets(4, 144),
        },
      },
      cancel = {
        rect = { x = 192, y = 168, width = 64, height = 24 },
        textRect = { x = 192, y = 168, width = 56, height = 16 },
        labelRect = { x = 196, y = 168, width = 56, height = 16 },
      },
      text = {
        actions = {
          toss = "TOSS",
          move = "MOVE",
          register = "REGISTER",
          unregister = "DESELECT",
          cancel = "CANCEL",
          confirm = "YES",
        },
        movePrompt = {
          segments = { { kind = "text", value = "Move " }, { kind = "item" }, { kind = "text", value = "." } },
        },
        tossQuantity = {
          segments = { { kind = "text", value = "Toss " }, { kind = "item" }, { kind = "text", value = "?" } },
        },
        tossConfirm = {
          segments = {
            { kind = "text", value = "Toss " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "?" },
          },
        },
      },
      overlays = {
        actionMenu = {
          buttons = {
            { x = 8, y = 136, width = 80, height = 16 },
            { x = 104, y = 136, width = 80, height = 16 },
            { x = 8, y = 168, width = 80, height = 16 },
            { x = 104, y = 168, width = 80, height = 16 },
          },
        },
        quantity = {
          digits = {
            { x = 128, y = 112, width = 16, height = 24 },
            { x = 160, y = 112, width = 16, height = 24 },
            { x = 192, y = 112, width = 16, height = 24 },
          },
        },
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
      },
    },
  }
  local marker = BagCache.marker("test-rom", "test-dep")
  BagSchema.assertManifest(manifest)
  local assets = {}
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    assets[path] = "payload:" .. path
  end
  local ok, err = pcall(Writer.write, cache, {
    marker = marker,
    manifest = manifest,
    dependencies = { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA, fixture = true },
    assets = assets,
  })
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(BagCache.isReady(cache, marker), "the synthetic bag class must read ready")
  writeReceipt(cache, "bag", "global", marker)
end

local function publishEffectFamily(cache)
  local EffectCache = require("libs.assets.src.field.FieldEffectAssetCache")
  local Writer = require("romdump.src.digest.field.FieldEntranceIndicatorCacheWriter")
  local ModelAsset = require("libs.assets.src.model.ModelAsset")
  local MeshWriter = require("libs.assets.src.model.MeshWriter")
  local PngWriter = require("libs.assets.src.PngWriter")
  local Contract = require("libs.assets.src.DerivedAssetContract")
  local function staticModel(key)
    return {
      schema = ModelAsset.SCHEMA,
      key = key,
      kind = "static",
      batches = {
        {
          geometry = EffectCache.geometryPath("mesh-key"),
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
          name = "effect",
          texture = EffectCache.texturePath("texture-key"),
          textureFormat = 3,
          wrap = { x = "clamp", y = "clamp" },
          flip = { x = false, y = false },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
    }
  end
  local function dynamicModel(key)
    return {
      schema = ModelAsset.SCHEMA,
      key = key,
      kind = "nitro-dynamic",
      dynamic = { nodes = {}, transformProgram = {}, batches = {} },
      materials = {
        {
          id = 0,
          name = "effect",
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
          texWidth = 64,
          texHeight = 64,
          wrap = { x = "clamp", y = "clamp" },
          flip = { x = false, y = false },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
      animations = {
        {
          id = key .. ".clip",
          name = key .. ".clip",
          category = "joint",
          kind = "trs",
          frameCount = 4,
          tracks = { { target = 0, targetIndex = 0 } },
          semanticNames = { key .. ".clip" },
          compiled = {
            anmFlags = 0,
            rotData = {},
            pivotData = { { 0, 0, 0, 0, 0 } },
            targets = {
              {
                nodeIndex = 0,
                channels = {
                  trans = {
                    x = { source = "constant", value = 0 },
                    y = { source = "constant", value = 0 },
                    z = { source = "constant", value = 0 },
                  },
                  rot = { source = "constant", value = 0 },
                  scale = {
                    x = { source = "constant", value = 0 },
                    y = { source = "constant", value = 0 },
                    z = { source = "constant", value = 0 },
                  },
                },
              },
            },
          },
        },
      },
    }
  end
  local marker = EffectCache.marker("test-rom", "test-dep")
  local bundle = {
    marker = marker,
    index = {
      schema = Contract.fieldEffects.indexSchema,
      effects = {
        warp_entrance = {
          path = EffectCache.definitionPath("warp_entrance"),
          definition = "warp_entrance",
          kind = "model",
        },
        tall_grass = {
          path = EffectCache.definitionPath("tall_grass"),
          definition = "tall_grass",
          kind = "animated_model",
        },
        very_tall_grass = {
          path = EffectCache.definitionPath("very_tall_grass"),
          definition = "very_tall_grass",
          kind = "animated_model",
        },
        trainer_reveal = {
          path = EffectCache.definitionPath("trainer_reveal"),
          definition = "trainer_reveal",
          kind = "animated_model",
        },
        surf_attachment = {
          path = EffectCache.definitionPath("surf_attachment"),
          definition = "surf_attachment",
          kind = "model",
        },
        follower_transition = {
          path = EffectCache.definitionPath("follower_transition"),
          definition = "follower_transition",
          kind = "transition",
        },
      },
    },
    effects = {
      warp_entrance = { model = staticModel("field-effect:warp-entrance"), lifetime = 1 },
      tall_grass = {
        model = dynamicModel("field-effect:tall-grass"),
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 2 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      very_tall_grass = {
        model = dynamicModel("field-effect:very-tall-grass"),
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 2 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      trainer_reveal = {
        model = dynamicModel("field-effect:trainer-reveal"),
        lifecycle = { mode = "once", frameCount = 4 },
        placementOffset = { x = 0, y = 0, z = 0.5 },
      },
      surf_attachment = {
        model = staticModel("field-effect:surf-attachment"),
        presentation = {
          initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
          oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
          playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
          attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
          yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
        },
      },
      follower_transition = {
        models = { staticModel("field-effect:transition-companion"), dynamicModel("field-effect:transition-lead") },
        lifecycle = { mode = "once", frameCount = 4, preludeTicks = 2 },
        placementOffset = { x = 0, y = 0.375, z = 0 },
      },
    },
    meshes = { ["mesh-key"] = {} },
    textures = { ["texture-key"] = { width = 1, height = 1, data = PngWriter.encode(1, 1, "rgba") } },
  }
  local oldEncode = MeshWriter.encode
  MeshWriter.encode = function()
    return "encoded-mesh"
  end
  local ok, err = pcall(Writer.write, cache, bundle)
  MeshWriter.encode = oldEncode
  Assert.isTrue(ok, tostring(err))
  local ready, readyErr = EffectCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  writeReceipt(cache, "field-effects", "global", marker)
end

local function publishUiFamily(cache)
  local UiCache = require("libs.assets.src.field.FieldUiAssetCache")
  local FieldUiFixture = require("tests.support.FieldUiFixture")
  local manifest = FieldUiFixture.manifest()
  manifest.reference = { width = 256, height = 192 }
  FieldUiFixture.addStartMenuIconContract(manifest)
  FieldUiFixture.addNamingSemantics(manifest)
  local valid, manifestErr = UiCache.validateManifest(manifest)
  Assert.isTrue(valid, "the current field-UI fixture validates: " .. tostring(manifestErr and manifestErr.message))
  local marker = UiCache.marker("test-rom", "test-dep")
  cache:writeLua(UiCache.manifestPath(), manifest)
  for _, entry in pairs(manifest.assets) do
    cache:write(entry.image, "png")
  end
  cache:write(UiCache.markerPath(), marker)
  local ready, readyErr = UiCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  writeReceipt(cache, "field-ui", "global", marker)
end

local function publishIntroFamily(cache)
  local IntroCache = require("libs.assets.src.newgame.IntroAssetCache")
  local playback = {
    ball_open = true,
    marill_appear = true,
    marill = true,
    gender_male = true,
    gender_female = true,
    naming_male = true,
    naming_female = true,
  }
  local centered = { gender_male = true, gender_female = true, ball_open = true, marill_appear = true, marill = true }
  local widgets = {}
  for _, id in ipairs(IntroCache.REQUIRED_ASSETS) do
    local image = "assets/generated/intro/" .. id .. ".png"
    local widget = {
      image = image,
      width = 8,
      height = 8,
      sampling = "nearest",
      anchor = { x = 0, y = 0 },
      sourceBounds = { x = 0, y = 0, width = 8, height = 8 },
      frames = {
        { image = image, width = 8, height = 8, duration = 1 },
      },
    }
    if centered[id] then
      widget.sourceCenter = { x = 10, y = 10 }
    end
    if playback[id] then
      widget.playMode = "forward"
      widget.loopStartFrameIdx = 0
      widget.frames[1].element = id .. ".element"
      widget.frames[1].translateX = 0
      widget.frames[1].translateY = 0
      widget.frames[1].scaleX = 1
      widget.frames[1].scaleY = 1
      widget.frames[1].rotation = 0
    end
    widgets[id] = widget
  end
  local backgroundImage = "assets/generated/intro/background.png"
  local manifest = {
    schemaVersion = IntroCache.SCHEMA_VERSION,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = { image = backgroundImage, width = 1, height = 192, sampling = "linear" },
    genderSelector = {
      defaultTone = { r = 0, g = 0, b = 0 },
      buttons = {
        male = { bounds = { x = 0, y = 0, width = 10, height = 10 } },
        female = { bounds = { x = 20, y = 0, width = 10, height = 10 } },
      },
    },
    widgets = widgets,
  }
  local marker = IntroCache.marker("test-rom", "test-dep")
  cache:writeLua(IntroCache.manifestPath(), manifest)
  cache:writeLua(IntroCache.provenancePath(), { schema = IntroCache.PROVENANCE_SCHEMA, source = {}, dependencies = {} })
  cache:write(backgroundImage, "png")
  for _, widget in pairs(widgets) do
    cache:write(widget.image, "png")
  end
  cache:write(IntroCache.markerPath(), marker)
  local ready, readyErr = IntroCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  writeReceipt(cache, "intro", "global", marker)
end

-- Lower-level leaf coverage: receipts prove nothing without usable
-- payloads, whatever the family.

-- A receipt from another generation is cold even with a usable payload,
-- while the current receipt over the same payload is usable.
function T.stale_generation_receipt_is_cold_but_current_receipt_is_usable()
  local cache = newCache()
  local marker = "g4-field-camera-cache-v1:test-rom:test-dep"
  publishCameraFamily(cache, marker)
  cache:writeLua(ArtifactState.path("field-camera", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = "previous-generation",
    kind = "field-camera",
    key = "global",
    marker = marker,
  })
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "field-camera", "global", {}),
    "a stale-generation receipt must not read ready"
  )
  writeReceipt(cache, "field-camera", "global", marker)
  Assert.isTrue(
    ArtifactJobs.validate(cache, GENERATION, "field-camera", "global", {}),
    "the current receipt over a usable payload reads ready"
  )
end

-- A receipt that does not parse is cold, never a validation pass.
function T.corrupt_receipt_shape_is_cold()
  local cache = newCache()
  local marker = "g4-field-camera-cache-v1:test-rom:test-dep"
  publishCameraFamily(cache, marker)
  cache:write(ArtifactState.path("field-camera", "global"), "not a lua receipt{{{")
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "field-camera", "global", {}),
    "a corrupt receipt must not read ready"
  )
end

-- A coarse payload deleted under an intact marker and receipt is cold at
-- the dispatcher level, not just through the builder.
function T.coarse_payload_damage_is_cold()
  local cache = newCache()
  local marker = "g4-field-camera-cache-v1:test-rom:test-dep"
  publishCameraFamily(cache, marker)
  writeReceipt(cache, "field-camera", "global", marker)
  Assert.isTrue(
    ArtifactJobs.validate(cache, GENERATION, "field-camera", "global", {}),
    "the intact coarse payload reads ready before damage"
  )
  cache:remove(FieldCameraCache.profilesPath())
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "field-camera", "global", {}),
    "a coarse payload deleted under its marker must not read ready"
  )
end

-- A layout marker with manifests but no generation-bound private page
-- plans is cold: page jobs would have nothing exact to consume.
function T.layout_without_private_source_plans_is_cold()
  local cache = newCache()
  local marker = MonCache.marker("test-rom", "test-dep")
  cache:writeLua(MonCache.iconManifestPath(), {})
  cache:writeLua(MonCache.portraitManifestPath(), {})
  cache:write(MonCache.layoutMarkerPath(), marker)
  writeReceipt(cache, "mon-layout", "global", marker)
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "mon-layout", "global", {}),
    "a layout without its private source plans must not read ready"
  )
end

-- A staged source inventory under the current marker is usable only when
-- the full record validates against the caller-supplied identity; a
-- receipt alone or a schema-only record is cold.
function T.staged_source_inventory_with_current_marker_is_usable()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local producerId = "d" .. string.rep("1", 64)
  local identity = { versionId = "heartgold", generationId = GENERATION, producerId = producerId }
  local cache = newCache()
  writeReceipt(cache, "source-plan", "global", SourcePlan.marker(GENERATION))
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "source-plan", "global", {}, identity),
    "a source-plan receipt without its staged record must not read ready"
  )
  cache:writeLua(SourcePlan.PATH, { schema = SourcePlan.SCHEMA, generationId = GENERATION })
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "source-plan", "global", {}, identity),
    "a schema-only staged record must not read ready"
  )
  cache:writeLua(SourcePlan.PATH, {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    generationId = GENERATION,
    producerId = producerId,
    world = { maps = {}, analysis = { excluded = {} } },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
    scriptPlan = { members = {}, generationKey = "synthetic-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
    messageBankIds = FieldMessageCompiler.requiredBankIds(),
    mapDataIds = FieldMapDataCompiler.supportedMapIds(),
    mapCellKeys = {},
  })
  Assert.isTrue(
    ArtifactJobs.validate(cache, GENERATION, "source-plan", "global", {}, identity),
    "the staged source inventory under its current marker reads ready"
  )
end

-- Direct source-plan validation carries its expected identity: a staged
-- record that disagrees with the caller-supplied identity is not ready,
-- and a missing required identity is a programming error, never a silent
-- pass. The expected identity always comes from the caller, never from
-- the record being validated.
function T.source_plan_validation_requires_its_expected_identity()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local producerId = "d" .. string.rep("1", 64)
  local cache = newCache()
  writeReceipt(cache, "source-plan", "global", SourcePlan.marker(GENERATION))
  cache:writeLua(SourcePlan.PATH, {
    schema = SourcePlan.SCHEMA,
    generationId = GENERATION,
    producerId = producerId,
  })
  local matching = { versionId = "heartgold", generationId = GENERATION, producerId = producerId }
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "source-plan", "global", {}, matching),
    "a schema-only record is not ready even with a matching identity"
  )
  local foreign = { versionId = "heartgold", generationId = GENERATION, producerId = "d" .. string.rep("2", 64) }
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "source-plan", "global", {}, foreign),
    "a record disagreeing with the expected identity is not ready"
  )
  local missingOk = pcall(ArtifactJobs.validate, cache, GENERATION, "source-plan", "global", {})
  Assert.isFalse(missingOk, "a missing required source identity fails instead of silently passing")
end

-- The audit premise: every family the walk reaches before map-data is
-- genuinely usable, the inventory carries a record the world does not
-- stage, and that record's payload is the only thing missing.
function T.audit_covers_inventory_map_data_missing_from_the_world()
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local supported = FieldMapDataCompiler.supportedMapIds()
  Assert.isTrue(#supported >= 2, "the source rule keeps supported records")
  local present, missing = supported[1], supported[2]

  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  writeMarkers(cache, { maps = {} })
  local messageMarker = FieldMessageCache.marker("test-rom", "test-dep")
  publishMessageFamily(cache, messageMarker)
  local audioMarker = AudioCache.marker("test-rom", "test-dep")
  publishAudioFamily(cache, audioMarker)
  local scriptMarker = ScriptCache.marker("rom-sha", "dep-sha")
  local publishedPlan, _ = publishScriptFamily(cache, scriptMarker, {
    { memberId = 3, id = "common.signpost", scriptIndex = 0 },
  }, "audit-script")
  local monMarker = MonCache.marker("test-rom", "test-dep")
  publishMonFamily(cache, monMarker)
  local indexMarker = FieldCellCache.indexMarker("test-rom", "test-dep")
  publishCellIndex(cache, indexMarker)
  local recordMarker = FieldMapDataCache.marker("test-rom", present, "test-dep")
  publishMapDataRecord(cache, present, recordMarker)
  local cameraMarker = "g4-field-camera-cache-v1:test-rom:test-dep"
  publishCameraFamily(cache, cameraMarker)
  local fontMarker = require("libs.assets.src.field.FieldFontCache").marker("test-rom", "test-dep")
  publishFontFamily(cache, fontMarker)
  publishActorFamily(cache)
  publishItemFamily(cache)
  publishEmoteFamily(cache)
  publishWeatherFamily(cache)
  publishBagFamily(cache)
  publishEffectFamily(cache)
  publishUiFamily(cache)
  publishIntroFamily(cache)
  writeReceipt(cache, "source-plan", "global", "source-plan-marker")
  writeReceipt(cache, "new-game-init", "global", "new-game-init-marker")
  writeReceipt(cache, "starter-choice", "global", "starter-choice-marker")
  writeReceipt(cache, "world-catalog", "global", "world-catalog-marker")
  cache:writeLua(MapAssetCache.worldPath(), {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = {},
    byId = {},
    bySymbol = {},
    analysis = { mapHeaderCount = 0, excluded = {} },
  })

  local plans = {
    indexBundle = { index = { matrices = {} } },
    scriptPlan = {
      generationKey = SCRIPT_GEN,
      members = { { memberId = 3, marker = scriptMarker .. ":member:3" } },
      resources = { { id = "common.signpost", member = 3, scriptIndex = 0 } },
    },
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = { 3 },
    iconPageIds = { 0 },
    portraitPageIds = { 0 },
    mapDataIds = { present, missing },
    mapIds = {},
  }
  Assert.equal(publishedPlan.generationKey, SCRIPT_GEN, "the audit plans use the published script generation")

  for _, premise in ipairs({
    { kind = "audio-summary", key = "global" },
    { kind = "bag", key = "global" },
    { kind = "field-camera", key = "global" },
    { kind = "field-cell-index", key = "global" },
    { kind = "field-effects", key = "global" },
    { kind = "field-emotes", key = "global" },
    { kind = "field-font", key = "global" },
    { kind = "field-ui", key = "global" },
    { kind = "field-weather", key = "global" },
    { kind = "intro", key = "global" },
    { kind = "items", key = "global" },
    { kind = "actors", key = "global" },
    { kind = "message-summary", key = "global" },
    { kind = "script-summary", key = "global" },
    { kind = "mon-summary", key = "global" },
    { kind = "map-data", key = tostring(present) },
  }) do
    Assert.isTrue(
      ArtifactJobs.validate(cache, GENERATION, premise.kind, premise.key, plans),
      "premise job must be usable: " .. premise.kind .. ":" .. premise.key
    )
  end

  local seen = {}
  for _, job in ipairs(ArtifactJobs.completeJobs(plans)) do
    seen[job.jobKey] = true
  end
  Assert.isTrue(seen["map-data:" .. present], "the canonical inventory covers the published record")
  Assert.isTrue(seen["map-data:" .. missing], "the canonical inventory covers the non-world record")

  local function snapshot()
    local copy = {}
    for path, data in pairs(backend.files) do
      copy[path] = data
    end
    return copy
  end
  local before = snapshot()
  local identity = { versionId = "heartgold", generationId = GENERATION, producerId = "readiness-producer" }
  local available, reason = DerivedCacheAudit.isAvailable(cache, identity, plans)
  Assert.deepEqual(snapshot(), before, "a read-only audit performs no writes")
  Assert.isFalse(available, "the audit must fail on the missing inventory record")
  Assert.isTrue(
    reason ~= nil and reason:find("map-data:" .. missing, 1, true) ~= nil,
    "the failure names the exact map-data key, got: " .. tostring(reason)
  )
end

-- Mon page byte damage: the page boundary and the dispatcher boundary share
-- one structural guard, so empty and truncated PNG bodies are unusable even
-- with exact markers and current receipts. Offsets below follow the encoder's
-- single-IHDR/single-IDAT/IEND layout: an 8-byte signature, a 25-byte IHDR
-- chunk, then the IDAT length word.
local function pngU32(png, position)
  local a, b, c, d = string.byte(png, position, position + 3)
  assert(a ~= nil and d ~= nil, "the synthetic PNG must carry its chunk header")
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Empty, header-only, mid-IDAT-truncated, and missing-IEND damage over one
-- valid page. Markers and receipts stay intact; only the bytes change.
local function pngDamageVariants(png)
  local idatLength = pngU32(png, 34)
  return {
    { name = "empty", bytes = "" },
    { name = "header-only", bytes = png:sub(1, 33) },
    { name = "mid-idat-truncated", bytes = png:sub(1, 42 + math.floor(idatLength / 2)) },
    { name = "missing-iend", bytes = png:sub(1, #png - 12) },
  }
end

local function packU32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function pngCrc32(bytes)
  local bit = require("bit")
  local table_ = {}
  for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
      if bit.band(c, 1) == 1 then
        c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
      else
        c = bit.rshift(c, 1)
      end
    end
    table_[n] = c
  end
  local crc = bit.bnot(0)
  for i = 1, #bytes do
    crc = bit.bxor(bit.rshift(crc, 8), table_[bit.band(bit.bxor(crc, string.byte(bytes, i)), 0xFF)])
  end
  return bit.bnot(crc) % 4294967296
end

local function pngChunk(chunkType, data)
  return packU32(#data) .. chunkType .. data .. packU32(pngCrc32(chunkType .. data))
end

-- A structurally valid envelope with split IDAT chunks and one ancillary
-- chunk, built from a valid page by reusing its IHDR and IEND chunks
-- verbatim. Returns the rebuilt bytes plus the offset where the first IDAT
-- chunk ends, so truncation can land exactly on a chunk boundary.
local function splitIdatWithAncillary(png)
  local signature = png:sub(1, 8)
  local ihdr = png:sub(9, 33)
  local idatLength = pngU32(png, 34)
  local idatData = png:sub(42, 42 + idatLength - 1)
  local iend = png:sub(42 + idatLength + 4)
  assert(iend:sub(5, 8) == "IEND", "the synthetic PNG must end with its IEND chunk")
  local half = math.floor(#idatData / 2)
  local prefix = signature .. ihdr .. pngChunk("tEXt", "Title\0synthetic")
  local first = pngChunk("IDAT", idatData:sub(1, half))
  local second = pngChunk("IDAT", idatData:sub(half + 1))
  return prefix .. first .. second .. iend, #prefix + #first
end

-- A valid synthetic page with its receipt and exact marker reads ready, but
-- only the intact bytes do: every damage variant is rejected at both the page
-- boundary and the dispatcher boundary while the untouched sibling stays ready.
function T.truncated_mon_page_images_are_not_ready()
  local cache = newCache()
  local family = publishMonFamily(cache, MonCache.marker("test-rom", "test-dep"))
  local plans = {}
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, family.iconMarker), "the valid icon page reads ready")
  Assert.isTrue(
    MonCache.isPageReady(cache, "portraits", 0, family.portraitMarker),
    "the valid portrait page reads ready"
  )
  Assert.isTrue(ArtifactJobs.validate(cache, GENERATION, "mon-icon-page", "0", plans), "the valid icon job validates")
  Assert.isTrue(
    ArtifactJobs.validate(cache, GENERATION, "mon-portrait-page", "0", plans),
    "the valid portrait job validates"
  )
  local pages = {
    { kind = "icons", jobKind = "mon-icon-page", marker = family.iconMarker, png = family.iconPng },
    { kind = "portraits", jobKind = "mon-portrait-page", marker = family.portraitMarker, png = family.portraitPng },
  }
  for _, page in ipairs(pages) do
    for _, variant in ipairs(pngDamageVariants(page.png)) do
      cache:write(MonCache.pageImagePath(page.kind, 0), variant.bytes)
      Assert.isFalse(
        MonCache.isPageReady(cache, page.kind, 0, page.marker),
        "a " .. variant.name .. " " .. page.kind .. " page must not read ready"
      )
      Assert.isFalse(
        ArtifactJobs.validate(cache, GENERATION, page.jobKind, "0", plans),
        "a " .. variant.name .. " " .. page.kind .. " job must not validate"
      )
    end
    cache:write(MonCache.pageImagePath(page.kind, 0), page.png)
    Assert.isTrue(
      MonCache.isPageReady(cache, page.kind, 0, page.marker),
      "the restored " .. page.kind .. " page reads ready"
    )
  end
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, family.iconMarker), "the icon page survives portrait damage")
  Assert.isTrue(
    MonCache.isPageReady(cache, "portraits", 0, family.portraitMarker),
    "the portrait page survives icon damage"
  )
end

-- Truncation exactly at a chunk boundary is still unusable, while a valid
-- split-IDAT envelope with an ancillary chunk stays usable: the guard is
-- structural, not an encoder fingerprint.
function T.mon_page_chunk_boundary_truncation_is_cold_but_split_idat_stays_ready()
  local cache = newCache()
  local family = publishMonFamily(cache, MonCache.marker("test-rom", "test-dep"))
  local split, firstChunkEnd = splitIdatWithAncillary(family.iconPng)
  cache:write(MonCache.iconPagePath(0), split)
  Assert.isTrue(
    MonCache.isPageReady(cache, "icons", 0, family.iconMarker),
    "a split-IDAT page with an ancillary chunk reads ready"
  )
  cache:write(MonCache.iconPagePath(0), split:sub(1, firstChunkEnd))
  Assert.isFalse(
    MonCache.isPageReady(cache, "icons", 0, family.iconMarker),
    "a page ending exactly at a chunk boundary without its IEND must not read ready"
  )
  cache:write(MonCache.iconPagePath(0), split:sub(1, firstChunkEnd + 5))
  Assert.isFalse(
    MonCache.isPageReady(cache, "icons", 0, family.iconMarker),
    "a page with a partial chunk header must not read ready"
  )
  cache:write(MonCache.iconPagePath(0), family.iconPng)
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, family.iconMarker), "the restored page reads ready")
end

-- One damaged page rejects the summary and the controlled audit with its exact
-- key, and the real page writer restores exactly that leaf: the controlled
-- audit passes again with the sibling bytes and receipts untouched. The
-- controlled inventory proves audit delegation and read-only rejection, not
-- full-corpus completeness.
function T.damaged_mon_page_fails_controlled_audit_until_the_leaf_is_restored()
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local summaryMarker = MonCache.marker("test-rom", "test-dep")
  local family = publishMonFamily(cache, summaryMarker)
  local plans = {
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = { 0 },
    portraitPageIds = { 0 },
    mapDataIds = {},
    indexBundle = { index = { matrices = {} } },
    mapIds = {},
  }
  local seen = {}
  for _, job in ipairs(ArtifactJobs.completeJobs(plans)) do
    seen[job.jobKey] = true
  end
  Assert.isTrue(seen["mon-icon-page:0"], "the canonical inventory covers the icon page")
  Assert.isTrue(seen["mon-portrait-page:0"], "the canonical inventory covers the portrait page")
  Assert.isTrue(seen["mon-summary:global"], "the canonical inventory covers the mon summary")
  Assert.isTrue(MonCache.isReady(cache, summaryMarker), "the intact family reads ready before damage")
  Assert.isTrue(
    ArtifactJobs.validate(cache, GENERATION, "mon-summary", "global", plans),
    "the intact summary validates before damage"
  )

  local siblingBytes = cache:read(MonCache.portraitPagePath(0))
  local iconReceipt = cache:read(ArtifactState.path("mon-icon-page", "0"))
  local portraitReceipt = cache:read(ArtifactState.path("mon-portrait-page", "0"))
  local summaryReceipt = cache:read(ArtifactState.path("mon-summary", "global"))

  local limitedJobs = {
    { kind = "mon-icon-page", key = "0", jobKey = "mon-icon-page:0" },
    { kind = "mon-portrait-page", key = "0", jobKey = "mon-portrait-page:0" },
    { kind = "mon-summary", key = "global", jobKey = "mon-summary:global" },
  }
  local identity = { versionId = "heartgold", generationId = GENERATION, producerId = "readiness-producer" }
  local function controlledAudit()
    local realCompleteJobs = ArtifactJobs.completeJobs
    ArtifactJobs.completeJobs = function(_)
      return limitedJobs
    end
    local ok, available, reason = pcall(DerivedCacheAudit.isAvailable, cache, identity, plans)
    ArtifactJobs.completeJobs = realCompleteJobs
    assert(ok, "the controlled audit must run to a boolean verdict")
    return available, reason
  end

  local availableBefore, reasonBefore = controlledAudit()
  Assert.isTrue(availableBefore, "the controlled audit passes before damage, got: " .. tostring(reasonBefore))

  cache:write(MonCache.iconPagePath(0), "")
  Assert.isFalse(MonCache.isPageReady(cache, "icons", 0, family.iconMarker), "the emptied page must not read ready")
  Assert.isFalse(MonCache.isReady(cache, summaryMarker), "the summary must not stay ready over an emptied page")
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "mon-summary", "global", plans),
    "the damaged summary must not validate"
  )
  local availableDamaged, reasonDamaged = controlledAudit()
  Assert.isFalse(availableDamaged, "the controlled audit must reject the damaged page")
  Assert.isTrue(
    reasonDamaged ~= nil and reasonDamaged:find("mon-icon-page:0", 1, true) ~= nil,
    "the audit names the exact damaged page, got: " .. tostring(reasonDamaged)
  )

  local leaf = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "mon-icon-page",
    key = "0",
    jobKey = "mon-icon-page:0",
    stageName = "restore-icon-page",
  })
  local restoredMarker = MonCacheWriter.stagePage(leaf, {
    kind = "icons",
    pageId = 0,
    width = family.iconWidth,
    height = family.iconHeight,
    pixels = family.iconPixels,
    marker = family.iconMarker,
  })
  Assert.equal(restoredMarker, family.iconMarker, "restoration keeps the staged page identity")
  leaf:finishSuccess({ marker = restoredMarker })
  Assert.isTrue(
    leaf:publish({
      generationId = GENERATION,
      epoch = 1,
      kind = "mon-icon-page",
      key = "0",
      jobKey = "mon-icon-page:0",
    }),
    "the restored leaf publishes"
  )

  Assert.equal(cache:read(MonCache.iconPagePath(0)), family.iconPng, "the restored bytes match the staged image")
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, family.iconMarker), "the restored page reads ready")
  Assert.isTrue(MonCache.isReady(cache, summaryMarker), "the family reads ready after the leaf repair")
  local availableAfter, reasonAfter = controlledAudit()
  Assert.isTrue(availableAfter, "the controlled audit passes after the leaf repair, got: " .. tostring(reasonAfter))
  Assert.equal(cache:read(MonCache.portraitPagePath(0)), siblingBytes, "the sibling bytes survive the leaf repair")
  Assert.equal(
    cache:read(ArtifactState.path("mon-icon-page", "0")),
    iconReceipt,
    "the icon receipt survives the leaf repair"
  )
  Assert.equal(
    cache:read(ArtifactState.path("mon-portrait-page", "0")),
    portraitReceipt,
    "the sibling receipt survives the leaf repair"
  )
  Assert.equal(
    cache:read(ArtifactState.path("mon-summary", "global")),
    summaryReceipt,
    "the summary receipt survives the leaf repair"
  )
end

local module = {
  beforeAll = function()
    for _, path in ipairs({
      "libs.storage.src.CacheFs",
      "romdump.src.build.InteractiveCacheBuild",
      "romdump.src.build.CompilerPool",
    }) do
      savedModules[path] = package.loaded[path]
      package.loaded[path] = nil
    end
    local RealCacheFs = require("libs.storage.src.CacheFs")
    package.loaded["libs.storage.src.CacheFs"] = setmetatable({
      forVersion = function(versionId)
        return RealCacheFs.forVersion(versionId, builderBackend or FakeCache.new())
      end,
    }, { __index = RealCacheFs })
    package.loaded["romdump.src.build.InteractiveCacheBuild"] = {
      new = function(options)
        assert(type(options) == "table", "generation session options are required")
        assert(type(options.identity) == "table", "generation session identity is required")
        assert(type(options.epoch) == "number", "generation session epoch is required")
        assert(type(options.pool) == "table", "generation session requires the process-owned pool")
        assert(type(options.sweepEnabled) == "boolean", "generation session sweep choice is required")
        local session = { requested = {}, completed = {}, retired = false }
        function session:requestJob(kind, key, urgency)
          assert(type(kind) == "string" and type(key) == "string", "job needs its canonical kind and key")
          assert(urgency == "required" or urgency == "near" or urgency == "sweep", "unknown urgency")
          local jobKey = kind .. ":" .. key
          self.requested[#self.requested + 1] = jobKey
          self.completed[jobKey] = true
          return true, nil
        end
        function session:requestMilestone(name, urgency)
          assert(name == "bootstrap" or name == "field-core", "milestones accept only bootstrap or field-core")
          assert(urgency == "required" or urgency == "near" or urgency == "sweep", "unknown urgency")
          return true, nil
        end
        function session:update()
          assert(not self.retired, "generation session is retired")
        end
        function session:status()
          local ready = 0
          for _ in pairs(self.completed) do
            ready = ready + 1
          end
          return {
            ready = ready,
            queued = 0,
            running = 0,
            failed = 0,
            failures = {},
            enumerated = #self.requested,
            enumerationComplete = true,
            settled = true,
            planningPending = false,
          }
        end
        function session:retire()
          self.retired = true
        end
        function session:outcomes()
          local list = {}
          local seen = {}
          for _, jobKey in ipairs(self.requested) do
            if seen[jobKey] == nil then
              seen[jobKey] = true
              local kind, key = jobKey:match("^([^:]+):(.+)$")
              list[#list + 1] = {
                kind = kind,
                key = key,
                jobKey = jobKey,
                state = "successful",
                reused = false,
                error = nil,
                causeJobKey = nil,
                failureClass = nil,
              }
            end
          end
          table.sort(list, function(left, right)
            return left.jobKey < right.jobKey
          end)
          return list
        end
        return session
      end,
    }
    package.loaded["romdump.src.build.CompilerPool"] = {
      new = function(_)
        return {
          drain = function() end,
          shutdown = function() end,
        }
      end,
    }
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = require("romdump.src.CacheBuilder")
  end,
  afterAll = function()
    for _, path in ipairs({
      "libs.storage.src.CacheFs",
      "romdump.src.build.InteractiveCacheBuild",
      "romdump.src.build.CompilerPool",
    }) do
      package.loaded[path] = savedModules[path]
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = nil
    builderBackend = nil
  end,
  tests = T,
}

return module
