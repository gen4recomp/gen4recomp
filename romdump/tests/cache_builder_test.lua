-- CacheBuilder contract: per-version derived-cache compilation with the
-- machine-readable build-cache log, compile-exclusion handling, and
-- per-version failure continuation. The digest and cache modules are faked
-- through package.loaded before CacheBuilder is required, so the pipeline is
-- exercised without a ROM or filesystem.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

-- Every module CacheBuilder requires at load; each is replaced with a fake.
local FAKE_PATHS = {
  "romdump.src.build.FieldCacheBuild",
  "romdump.src.build.ScriptAudioCacheBuild",
  "romdump.src.build.MapCacheBuild",
  "romdump.src.source.RomFs",
  "libs.storage.src.CacheFs",
  "romdump.src.digest.map.MapAnalysis",
  "romdump.src.digest.map.MapAssetCompiler",
  "romdump.src.digest.map.MapCacheWriter",
  "libs.assets.src.MapAssetCache",
  "romdump.src.digest.map.WorldManifest",
  "romdump.src.digest.field.FieldCameraCompiler",
  "romdump.src.digest.field.FieldCameraCacheWriter",
  "romdump.src.digest.field.FieldMapDataCompiler",
  "romdump.src.digest.field.FieldMapDataCacheWriter",
  "libs.assets.src.field.FieldMapDataCache",
  "romdump.src.digest.actor.FieldActorCompiler",
  "romdump.src.digest.actor.FieldActorCacheWriter",
  "romdump.src.digest.FollowingMonVisualCompiler",
  "romdump.src.digest.MonCatalogCompiler",
  "romdump.src.digest.MonCacheWriter",
  "romdump.src.digest.ui.FieldMessageCompiler",
  "romdump.src.digest.ui.FieldMessageCacheWriter",
  "libs.assets.src.field.FieldMessageCache",
  "romdump.src.digest.ui.FieldFontCompiler",
  "romdump.src.digest.ui.FieldFontCacheWriter",
  "libs.assets.src.field.FieldFontCache",
  "romdump.src.digest.ui.FieldUiCompiler",
  "romdump.src.digest.ui.FieldUiCacheWriter",
  "libs.assets.src.field.FieldUiAssetCache",
  "romdump.src.digest.newgame.IntroAssetCompiler",
  "romdump.src.digest.newgame.IntroAssetCacheWriter",
  "libs.assets.src.newgame.IntroAssetCache",
  "romdump.src.digest.StarterChoiceAssetCompiler",
  "romdump.src.digest.StarterChoiceAssetCacheWriter",
  "romdump.src.digest.field.FieldWeatherCompiler",
  "romdump.src.digest.field.FieldWeatherCacheWriter",
  "romdump.src.digest.newgame.NewGameInitCompiler",
  "romdump.src.digest.newgame.NewGameInitCacheWriter",
  "romdump.src.digest.field.FieldEntranceIndicatorCompiler",
  "romdump.src.digest.field.FieldEntranceIndicatorCacheWriter",
  "libs.assets.src.field.FieldEffectAssetCache",
  "romdump.src.digest.actor.FieldActorEmoteCompiler",
  "romdump.src.digest.actor.FieldActorEmoteCacheWriter",
  "libs.assets.src.field.FieldEmoteAssetCache",
  "romdump.src.digest.script.ScriptCompiler",
  "romdump.src.digest.script.ScriptCacheWriter",
  "libs.assets.src.ScriptCache",
  "romdump.src.digest.audio.AudioCompiler",
  "romdump.src.digest.audio.AudioCacheWriter",
  "romdump.src.digest.field.FieldCellCompiler",
  "romdump.src.digest.field.FieldCellCacheWriter",
  "libs.assets.src.field.FieldCellCache",
  "romdump.src.DerivedCacheState",
  "romdump.src.ProducerFingerprint",
  "romdump.src.DerivedCacheAudit",
}

local REAL_BUILD_OWNERS = {
  ["romdump.src.build.FieldCacheBuild"] = true,
  ["romdump.src.build.ScriptAudioCacheBuild"] = true,
  ["romdump.src.build.MapCacheBuild"] = true,
}

local T = {}

local saved = {}
local env
local CacheBuilder

-- One shared environment drives every fake; tests swap in fresh state per test.
local function newEnv()
  return {
    stale = {},
    openFailures = {},
    failCompilers = {},
    compileFailures = {},
    calls = {},
    opens = {},
    closes = {},
    worldStage = nil,
    -- Derived-cache state gate: the identity comparison outcome and the
    -- fast-path availability audit. Defaults model a damaged cache under a
    -- matching identity, which runs the incremental pipeline (the existing
    -- tests below).
    stateMatches = true,
    auditAvailable = false,
    stateMatchesCalls = 0,
    auditCalls = 0,
    stateInvalidations = 0,
    statePublishes = 0,
    identityInputs = nil,
    producerComputations = 0,
    manifestRaise = nil,
    worldPublishes = 0,
    worldAborts = 0,
    mapResults = {
      {
        status = "resolved",
        id = 2,
        symbol = "s_town",
        matrixMemberId = 1,
        matrixX = 0,
        matrixZ = 1,
        matrixIndex = 2,
        landDataMemberId = 3,
        source = "direct",
        matchCount = 1,
        mapSection = "town",
        mapSectionNativeId = 126,
        followMode = "ALLOW",
      },
      {
        status = "resolved",
        id = 5,
        symbol = "s_route",
        matrixMemberId = 6,
        matrixX = 2,
        matrixZ = 3,
        matrixIndex = 4,
        landDataMemberId = 5,
        source = "matrix",
        matchCount = 2,
        mapSection = "route",
        mapSectionNativeId = 177,
        followMode = "HEIGHT_RESTRICT",
      },
    },
    mapBundles = {
      [2] = {
        mapId = 2,
        marker = "m2",
        scene = { mapSymbol = "s_town", matrix = { width = 20, height = 20 } },
        unresolvedMaterials = {},
      },
      [5] = {
        mapId = 5,
        marker = "m5",
        scene = { mapSymbol = "s_route", matrix = { width = 10, height = 10 } },
        unresolvedMaterials = {
          {
            role = "map",
            kind = "texture",
            material = "bike_02_2_lm3",
            modelName = "m_name01_00_00c",
            modelArchive = "land_data",
            modelMemberId = 280,
            name = "bike_02_2",
            source = "map_textures member 42",
          },
        },
      },
    },
    cameraBundle = { marker = "cam-v1" },
    actorBundle = { marker = "act-v1", index = { spriteIds = { 0, 1, 2 } } },
    followerBundle = { marker = "follower-v1" },
    monBundle = {
      marker = "mon-v1",
      catalog = {
        species = {
          BULBASAUR = { forms = {} },
          CHARMANDER = { forms = {} },
        },
      },
    },
    fieldBundles = {
      { mapId = 3, marker = "fd-3" },
      { mapId = 7, marker = "fd-7" },
    },
    fontBundle = { fonts = { [0] = {}, [4] = {} }, marker = "font-v1" },
    uiBundle = { marker = "ui-v1" },
    introBundle = { marker = "intro-v1" },
    starterChoiceBundle = { marker = "starter-v1" },
    weatherBundle = { marker = "weather-v1" },
    newGameInitBundle = { marker = "newgameinit-v1" },
    effectBundle = { marker = "effect-v1" },
    emoteBundle = { marker = "emote-v1" },
    messageBundle = { marker = "msg-v1", index = { bankIds = { 4, 8 } } },
    scriptBundle = { marker = "scr-v1", index = { resourceCount = 2, scriptMemberCount = 9 } },
    audioBundle = { marker = "audio-v1", index = {} },
    audioError = nil,
    fieldCellBundle = { marker = "cells-v1", index = {}, cells = {} },
  }
end

local function makeFakes()
  local fakes = {}
  for _, path in ipairs(FAKE_PATHS) do
    local name = path:match("([^%.]+)$")
    local m = {}
    -- WorldManifest's real surface is stage/publish/abort only, not the
    -- shared stale-gate pair: CacheBuilder never writes it directly.
    if name ~= "WorldManifest" then
      -- isReady is the stale gate shared by every cache class; write records
      -- and publishes the artifact, so a later identical build sees it as
      -- current.
      m.isReady = function()
        return not env.stale[name]
      end
      m.write = function()
        env.calls[#env.calls + 1] = name .. ".write"
        env.stale[name] = nil
      end
    end
    fakes[name] = m
  end

  fakes.RomFs.open = function(version)
    if env.openFailures[version] ~= nil then
      return nil, env.openFailures[version]
    end
    env.opens[#env.opens + 1] = version
    return {
      version = version,
      close = function()
        env.closes[#env.closes + 1] = version
      end,
    }
  end
  fakes.CacheFs.forVersion = function(version)
    env.calls[#env.calls + 1] = "CacheFs.forVersion:" .. version
    return {
      version = version,
      versionId = version,
      read = function(_, path)
        if path == "rom-dump.complete" then
          return "g4-rom-dump-v1:" .. version .. ":deadbeef"
        end
        return nil
      end,
      loadLua = function()
        return env.stateStored
      end,
    }
  end
  fakes.DerivedCacheState = {
    path = "data/generated/build.lua",
    current = function(inputs)
      env.identityInputs = inputs
      env.calls[#env.calls + 1] = "DerivedCacheState.current"
      return { identity = true }
    end,
    matches = function()
      env.stateMatchesCalls = env.stateMatchesCalls + 1
      return env.stateMatches
    end,
    invalidate = function()
      env.stateInvalidations = env.stateInvalidations + 1
      env.calls[#env.calls + 1] = "DerivedCacheState.invalidate"
    end,
    publish = function()
      env.statePublishes = env.statePublishes + 1
      env.calls[#env.calls + 1] = "DerivedCacheState.publish"
    end,
  }
  fakes.ProducerFingerprint = {
    appBackend = function()
      return {}
    end,
    compute = function()
      env.producerComputations = env.producerComputations + 1
      return "producer-fingerprint"
    end,
  }
  fakes.DerivedCacheAudit = {
    isAvailable = function()
      env.auditCalls = env.auditCalls + 1
      return env.auditAvailable
    end,
  }
  fakes.MapAnalysis.analyze = function()
    return env.mapResults
  end
  fakes.MapAssetCompiler.compile = function(_, mapId)
    if env.compileFailures[mapId] ~= nil then
      return nil, env.compileFailures[mapId]
    end
    return env.mapBundles[mapId]
  end
  fakes.FieldCameraCompiler.compile = function(romFs)
    if env.failCompilers[romFs.version] ~= nil then
      local failure = env.failCompilers[romFs.version]
      if Errors.is(failure) then
        return nil, failure
      end
      error(failure, 0)
    end
    return env.cameraBundle
  end
  fakes.FieldActorCompiler.compile = function()
    return env.actorBundle
  end
  fakes.FollowingMonVisualCompiler = {
    compile = function()
      return env.followerBundle
    end,
    mergeIntoActorBundle = function(actor, follower)
      actor.mergedFollower = follower
    end,
  }
  fakes.MonCatalogCompiler = {
    compileAll = function()
      return env.monBundle
    end,
  }
  fakes.FieldMapDataCompiler.compileAll = function()
    return env.fieldBundles
  end
  fakes.FieldFontCompiler.compile = function()
    return env.fontBundle
  end
  fakes.FieldUiCompiler.compile = function(romFs)
    if env.failCompilers[romFs.version] ~= nil then
      local failure = env.failCompilers[romFs.version]
      if Errors.is(failure) then
        return nil, failure
      end
      error(failure, 0)
    end
    return env.uiBundle
  end
  fakes.IntroAssetCompiler.compile = function()
    return env.introBundle
  end
  fakes.StarterChoiceAssetCompiler = {
    compile = function()
      return env.starterChoiceBundle
    end,
  }
  fakes.FieldMessageCompiler.compile = function()
    return env.messageBundle
  end
  fakes.FieldWeatherCompiler = {
    compile = function()
      return env.weatherBundle
    end,
  }
  fakes.FieldEntranceIndicatorCompiler = {
    compile = function()
      return env.effectBundle
    end,
  }
  fakes.FieldActorEmoteCompiler = {
    compile = function()
      return env.emoteBundle
    end,
  }
  fakes.NewGameInitCompiler = {
    compileFromRom = function(romFs)
      if env.failCompilers[romFs.version] ~= nil then
        local failure = env.failCompilers[romFs.version]
        if Errors.is(failure) then
          return nil, failure
        end
        error(failure, 0)
      end
      return env.newGameInitBundle
    end,
  }
  fakes.FieldWeatherCacheWriter = {
    isReady = function()
      return not env.stale.FieldWeatherCacheWriter
    end,
    write = function()
      env.calls[#env.calls + 1] = "FieldWeatherCacheWriter.write"
      env.stale.FieldWeatherCacheWriter = nil
    end,
  }
  fakes.ScriptCompiler.compile = function()
    return env.scriptBundle
  end
  fakes.AudioCompiler.compile = function()
    return env.audioBundle, env.audioError
  end
  fakes.FieldCellCompiler.compile = function()
    return env.fieldCellBundle
  end
  fakes.WorldManifest.stage = function(cacheFs, entries, excluded, compileExcluded)
    if env.manifestRaise ~= nil then
      error(env.manifestRaise, 0)
    end
    env.calls[#env.calls + 1] = "WorldManifest.stage"
    env.worldStage = { entries = entries, excluded = excluded, compileExcluded = compileExcluded }
    return {
      version = cacheFs.versionId,
      publish = function()
        env.worldPublishes = env.worldPublishes + 1
        env.calls[#env.calls + 1] = "WorldManifest.publish"
      end,
      abort = function()
        env.worldAborts = env.worldAborts + 1
        env.calls[#env.calls + 1] = "WorldManifest.abort"
      end,
    }
  end
  return fakes
end

local function collectLog()
  local lines = {}
  return {
    lines = lines,
    log = function(line)
      lines[#lines + 1] = line
    end,
  }
end

local module = {
  beforeAll = function()
    for _, path in ipairs(FAKE_PATHS) do
      saved[path] = package.loaded[path]
      package.loaded[path] = nil
    end
    env = newEnv()
    local fakes = makeFakes()
    for _, path in ipairs(FAKE_PATHS) do
      if not REAL_BUILD_OWNERS[path] then
        package.loaded[path] = fakes[path:match("([^%.]+)$")]
      end
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = require("romdump.src.CacheBuilder")
  end,
  afterAll = function()
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = saved[path]
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
  end,
  tests = T,
}

-- Every current class is logged in pipeline order, the staged world receives
-- the resolved map records, and the strict build publishes it and reports a
-- complete build.
function T.current_build_logs_every_class_and_stages_and_publishes_the_world_manifest()
  env = newEnv()
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.deepEqual(capture.lines, {
    "build-cache: heartgold field cameras current",
    "build-cache: heartgold field actors current",
    "build-cache: heartgold mons current",
    "build-cache: heartgold map 3 field data current",
    "build-cache: heartgold map 7 field data current",
    "build-cache: heartgold field font current",
    "build-cache: heartgold field ui current",
    "build-cache: heartgold intro assets current",
    "build-cache: heartgold starter choice assets current",
    "build-cache: heartgold warp entrance field effect current",
    "build-cache: heartgold field emote indicator current",
    "build-cache: heartgold field weather current",
    "build-cache: heartgold fresh-game startup initializer current",
    "build-cache: heartgold field messages current",
    "build-cache: heartgold scripts current",
    "build-cache: heartgold audio current",
    "build-cache: heartgold physical field cells current",
    "build-cache: heartgold map 2 current",
    "build-cache: heartgold map 5 current",
    "build-cache: heartgold map 5 unresolved map texture: material bike_02_2_lm3 of m_name01_00_00c land_data:280 wants bike_02_2 from map_textures member 42",
    "build-cache: heartgold world.lua staged (2 maps, 0 unresolved cells, 0 compile-excluded)",
    "build-cache: heartgold world.lua published",
  })
  Assert.equal(env.worldPublishes, 1, "a strict build publishes the staged world")
  Assert.equal(env.worldAborts, 0, "a strict build never discards the staged world")
  Assert.deepEqual(env.worldStage.entries, {
    {
      id = 2,
      symbol = "s_town",
      mapSection = "town",
      mapSectionNativeId = 126,
      followMode = "ALLOW",
      width = 20,
      height = 20,
      matrix = { memberId = 1, x = 0, z = 1, index = 2, landDataMemberId = 3, selection = "direct", matchCount = 1 },
    },
    {
      id = 5,
      symbol = "s_route",
      mapSection = "route",
      mapSectionNativeId = 177,
      followMode = "HEIGHT_RESTRICT",
      width = 10,
      height = 10,
      matrix = { memberId = 6, x = 2, z = 3, index = 4, landDataMemberId = 5, selection = "matrix", matchCount = 2 },
    },
  })
end

-- Running the cache build twice with identical dependencies must take the
-- actor "current" path on the second run and perform no actor rewrite: the
-- build never invalidates live artifacts before its readiness check.
function T.unchanged_second_build_rewrites_nothing()
  env = newEnv()
  env.stale.FieldActorCacheWriter = true
  local first = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = first.log })
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.isTrue(first.lines[2]:find("field actors compiled", 1, true) ~= nil, first.lines[2])
  local function actorWrites()
    local count = 0
    for _, call in ipairs(env.calls) do
      if call == "FieldActorCacheWriter.write" then
        count = count + 1
      end
    end
    return count
  end
  Assert.equal(actorWrites(), 1, "the first build publishes the actor artifact")

  local second = collectLog()
  local report2, err2 = CacheBuilder.buildVersions({ "heartgold" }, { log = second.log })
  Assert.isNil(err2)
  Assert.deepEqual(report2, { published = true, complete = true, exclusionCount = 0 })
  Assert.isTrue(second.lines[2]:find("field actors current", 1, true) ~= nil, second.lines[2])
  Assert.equal(actorWrites(), 1, "an unchanged second build must not rewrite actor assets")
end

-- A stale class is compiled through its writer and logged with its counts;
-- writer order follows the class order of the pipeline.
function T.stale_classes_compile_with_counts_in_pipeline_order()
  env = newEnv()
  env.stale = {
    FieldCameraCacheWriter = true,
    FieldActorCacheWriter = true,
    MonCacheWriter = true,
    StarterChoiceAssetCacheWriter = true,
    FieldMapDataCache = true,
    FieldFontCacheWriter = true,
    FieldUiCacheWriter = true,
    FieldWeatherCacheWriter = true,
    NewGameInitCacheWriter = true,
    FieldMessageCacheWriter = true,
    ScriptCacheWriter = true,
    AudioCacheWriter = true,
    FieldCellCacheWriter = true,
    MapAssetCache = true,
  }
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.deepEqual(capture.lines, {
    "build-cache: heartgold field cameras compiled",
    "build-cache: heartgold field actors compiled (3 sprites)",
    "build-cache: heartgold mons compiled (2 species)",
    "build-cache: heartgold map 3 field data compiled",
    "build-cache: heartgold map 7 field data compiled",
    "build-cache: heartgold field font compiled",
    "build-cache: heartgold field ui compiled",
    "build-cache: heartgold intro assets current",
    "build-cache: heartgold starter choice assets compiled",
    "build-cache: heartgold warp entrance field effect current",
    "build-cache: heartgold field emote indicator current",
    "build-cache: heartgold field weather compiled",
    "build-cache: heartgold fresh-game startup initializer compiled",
    "build-cache: heartgold field messages compiled (2 banks)",
    "build-cache: heartgold scripts compiled (2 resources, 9 members)",
    "build-cache: heartgold audio compiled",
    "build-cache: heartgold physical field cells compiled",
    "build-cache: heartgold map 2 compiled",
    "build-cache: heartgold map 5 compiled",
    "build-cache: heartgold map 5 unresolved map texture: material bike_02_2_lm3 of m_name01_00_00c land_data:280 wants bike_02_2 from map_textures member 42",
    "build-cache: heartgold world.lua staged (2 maps, 0 unresolved cells, 0 compile-excluded)",
    "build-cache: heartgold world.lua published",
  })
  Assert.equal(env.stateInvalidations, 1, "the damaged attestation is invalidated before the rebuild")
  Assert.equal(env.statePublishes, 1, "a strict rebuild publishes the new identity")
end

-- A structured compile rejection is recorded in the manifest, logged, and
-- fails the build unless the caller accepts compile exclusions. An unaccepted
-- exclusion build never publishes its staged world; an accepted one publishes
-- it but reports an explicit partial status.
function T.compile_exclusions_fail_the_build_unless_allowed()
  env = newEnv()
  env.compileFailures[5] = Errors.new("MAP_SCHEMA_INVALID", "injected compile rejection")
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(capture.lines[15], "build-cache: heartgold scripts current")
  Assert.equal(capture.lines[16], "build-cache: heartgold audio current")
  Assert.equal(capture.lines[17], "build-cache: heartgold physical field cells current")
  Assert.equal(capture.lines[18], "build-cache: heartgold map 2 current")
  Assert.equal(
    capture.lines[19],
    "build-cache: heartgold map 5 excluded: MAP_SCHEMA_INVALID: injected compile rejection"
  )
  Assert.deepEqual(env.worldStage.compileExcluded, {
    {
      id = 5,
      symbol = "s_route",
      errorCode = "MAP_SCHEMA_INVALID",
      message = "injected compile rejection",
      context = {},
    },
  })
  Assert.equal(
    capture.lines[20],
    "build-cache: heartgold world.lua staged (1 maps, 0 unresolved cells, 1 compile-excluded)"
  )
  Assert.equal(
    capture.lines[21],
    "build-cache: compile exclusions remain; " .. "rerun with --allow-compile-exclusions to accept them"
  )
  Assert.equal(env.worldPublishes, 0, "an unaccepted-exclusion build must never publish its staged world")
  Assert.equal(env.worldAborts, 1, "the staged world of a failed build is discarded")

  local accepted = collectLog()
  local report2, err2 = CacheBuilder.buildVersions(
    { "heartgold" },
    { allowCompileExclusions = true, log = accepted.log }
  )
  Assert.isNil(err2)
  Assert.deepEqual(report2, { published = true, complete = false, exclusionCount = 1 })
  Assert.equal(
    accepted.lines[20],
    "build-cache: heartgold world.lua staged (1 maps, 0 unresolved cells, 1 compile-excluded)"
  )
  Assert.equal(accepted.lines[21], "build-cache: heartgold world.lua published")
  Assert.equal(env.worldPublishes, 1, "an accepted-exclusion build publishes its staged world")
  -- A build that accepted compile exclusions is not a strict success and must
  -- never publish the successful-build attestation.
  Assert.equal(env.statePublishes, 0, "an exclusion-accepting build must not publish state")
end

-- One version whose source data fails to compile is reported, its RomFs
-- handle is still closed, and the remaining versions run to completion. The
-- whole batch failed, so the successfully built version's staged world must
-- never become authoritative: the last-known-good world.lua stays live.
function T.a_failed_version_continues_and_closes_its_romfs()
  env = newEnv()
  env.failCompilers.heartgold = Errors.new("FIELD_CAMERA_VERSION_UNSUPPORTED", "injected compile failure")
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold", "soulsilver" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(
    capture.lines[1],
    "build-cache: heartgold failed: FIELD_CAMERA_VERSION_UNSUPPORTED: injected compile failure"
  )
  Assert.equal(capture.lines[2], "build-cache: soulsilver field cameras current")
  Assert.deepEqual(env.closes, { "heartgold", "soulsilver" })
  Assert.equal(env.worldPublishes, 0, "a later version failure must keep the staged world unpublished")
  Assert.equal(env.worldAborts, 1, "the staged world of the failed batch is discarded")
end

-- A typed field-UI compile failure is an ordinary per-version source-data
-- failure: the version reports the typed code, no field-UI class is written,
-- the staged world is discarded, and the remaining versions run to
-- completion.
function T.a_failed_ui_compile_reports_and_skips_the_ui_publish()
  env = newEnv()
  env.failCompilers.heartgold = Errors.new("FIELD_UI_SOURCE_INVALID", "unsupported cursor geometry")
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold", "soulsilver" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(capture.lines[1], "build-cache: heartgold failed: FIELD_UI_SOURCE_INVALID: unsupported cursor geometry")
  Assert.equal(capture.lines[2], "build-cache: soulsilver field cameras current")
  for _, call in ipairs(env.calls) do
    Assert.isTrue(call ~= "FieldUiCacheWriter.write", "a failed UI compile must never publish a field-UI class")
  end
  Assert.equal(env.worldPublishes, 0, "a later version failure must keep the staged world unpublished")
  Assert.equal(env.worldAborts, 1, "the staged world of the failed batch is discarded")
end

-- A typed audio compile failure is reported by the audio stage rather than
-- being mistaken for the earlier script stage's (nil) error.
function T.a_failed_audio_compile_reports_and_skips_the_remaining_stages()
  env = newEnv()
  env.audioBundle = nil
  env.audioError = Errors.new("AUDIO_SOURCE_INVALID", "unsupported sample data")
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(capture.lines[15], "build-cache: heartgold scripts current")
  Assert.equal(capture.lines[16], "build-cache: heartgold failed: AUDIO_SOURCE_INVALID: unsupported sample data")
  Assert.equal(env.worldPublishes, 0, "a failed audio compile must not publish a world")
  Assert.equal(env.worldAborts, 0, "a failed audio compile stages no world to discard")
end

-- An open failure is logged like any per-version failure, closes nothing, and
-- does not stop the remaining versions.
function T.open_failure_is_reported_and_closes_nothing()
  env = newEnv()
  env.openFailures.heartgold = Errors.new("ROMFS_LOAD_FAILED", "injected open failure", { path = "rom_metadata.lua" })
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold", "soulsilver" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.isTrue(capture.lines[1]:find("injected open failure", 1, true) ~= nil, capture.lines[1])
  Assert.equal(capture.lines[2], "build-cache: soulsilver field cameras current")
  Assert.deepEqual(env.opens, { "soulsilver" })
  Assert.deepEqual(env.closes, { "soulsilver" })
end

-- A programming fault inside a version's build is rethrown after the version's
-- RomFs is closed: it must never be flattened into a normal failed-version
-- report, and the remaining versions must not run.
function T.a_programming_fault_aborts_the_batch_after_closing_the_romfs()
  env = newEnv()
  env.failCompilers.heartgold = "boom"
  local capture = collectLog()
  local raised = Assert.throws(function()
    CacheBuilder.buildVersions({ "heartgold", "soulsilver" }, { log = capture.log })
  end)
  Assert.equal(raised, "boom", "the original fault must propagate unchanged")
  Assert.deepEqual(env.opens, { "heartgold" }, "the batch must stop at the faulting version")
  Assert.deepEqual(env.closes, { "heartgold" }, "the version's RomFs is closed before the fault rethrows")
  Assert.deepEqual(capture.lines, {}, "a programming fault must not become a failed-version report")
end

-- A structured error raised directly by a writer (a cache write failure or a
-- duplicate world-manifest id) is not a per-version source-data failure: it
-- indicates a broken builder/cache invariant and must abort the batch, not be
-- flattened into a failed-version report.
function T.a_raised_structured_error_aborts_the_batch()
  env = newEnv()
  env.manifestRaise = Errors.new("WORLD_MANIFEST_DUP_ID", "duplicate map id 2", { id = 2 })
  local raised = Assert.throws(function()
    CacheBuilder.buildVersions({ "heartgold", "soulsilver" }, { log = collectLog().log })
  end)
  Assert.equal(raised.code, "WORLD_MANIFEST_DUP_ID", "the structured error must propagate unchanged")
  Assert.deepEqual(env.opens, { "heartgold" }, "the batch must stop at the faulting version")
  Assert.deepEqual(env.closes, { "heartgold" }, "the version's RomFs is closed before the fault rethrows")
end

-- An empty version list is part of the function contract: no build runs and
-- the caller-facing error names the empty selection.
function T.empty_version_list_returns_no_ready_version_to_compile()
  env = newEnv()
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({}, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "no ready version to compile")
  Assert.deepEqual(capture.lines, { "build: no ready version to compile" })
end

-- The log option defaults to print, the plain-Lua output of the CLI.
function T.log_defaults_to_print()
  env = newEnv()
  local lines = {}
  local realPrint = print
  _G.print = function(line)
    lines[#lines + 1] = tostring(line)
  end
  local ok, report, err = pcall(CacheBuilder.buildVersions, { "heartgold" })
  _G.print = realPrint
  Assert.isTrue(ok, tostring(report))
  Assert.equal(err, nil)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.equal(lines[1], "build-cache: heartgold field cameras current")
end

-- A matching identity with a fully available cache must short-circuit: zero
-- compiler functions, zero RomFs opens, no state mutation, and the
-- current-style report line. This is the regression test for the original
-- performance problem (expensive compilation before marker checks).
function T.matching_identity_with_available_cache_invokes_no_compilers_and_no_romfs()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = true
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.deepEqual(capture.lines, { "build-cache: heartgold current" })
  Assert.deepEqual(env.opens, {}, "the fast path must never open the ROM")
  Assert.equal(env.stateMatchesCalls, 1, "the stored identity must be compared exactly once")
  Assert.equal(env.auditCalls, 1, "the availability audit is the fast-path gate")
  Assert.equal(env.stateInvalidations, 0, "a current cache must not be invalidated")
  Assert.equal(env.statePublishes, 0, "a current cache must not be republished")
  Assert.equal(env.worldPublishes, 0, "a fast-path build must not republish the world")
  Assert.equal(env.worldAborts, 0, "a fast-path build stages nothing to discard")
  Assert.equal(env.producerComputations, 1, "the producer fingerprint is part of the identity")
  Assert.equal(
    env.identityInputs.dump,
    "g4-rom-dump-v1:heartgold:deadbeef",
    "the identity carries the published dump marker"
  )
end

-- An identity mismatch forces every writer even though the ordinary marker
-- checks would say current; the state is invalidated before any mutation
-- begins; and the strict rebuild publishes the new identity.
function T.producer_mismatch_forces_every_writer_and_publishes_after_strict_success()
  env = newEnv()
  env.stateMatches = false
  env.stale = {}
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  for _, line in ipairs(capture.lines) do
    Assert.isTrue(line:find(" current$") == nil, "a forced rebuild must not log 'current': " .. line)
  end
  local writes = {}
  for _, call in ipairs(env.calls) do
    if call:find(".write$") ~= nil or call == "WorldManifest.stage" then
      writes[#writes + 1] = call
    end
  end
  table.sort(writes)
  Assert.deepEqual(writes, {
    "AudioCacheWriter.write",
    "FieldActorCacheWriter.write",
    "FieldActorEmoteCacheWriter.write",
    "FieldCameraCacheWriter.write",
    "FieldCellCacheWriter.write",
    "FieldEntranceIndicatorCacheWriter.write",
    "FieldFontCacheWriter.write",
    "FieldMapDataCacheWriter.write",
    "FieldMapDataCacheWriter.write",
    "FieldMessageCacheWriter.write",
    "FieldUiCacheWriter.write",
    "FieldWeatherCacheWriter.write",
    "IntroAssetCacheWriter.write",
    "MapCacheWriter.write",
    "MapCacheWriter.write",
    "MonCacheWriter.write",
    "NewGameInitCacheWriter.write",
    "ScriptCacheWriter.write",
    "StarterChoiceAssetCacheWriter.write",
    "WorldManifest.stage",
  }, "every class must regenerate despite current-looking markers")
  local invalidateIndex, firstWriteIndex
  for index, call in ipairs(env.calls) do
    if call == "DerivedCacheState.invalidate" then
      invalidateIndex = index
    end
    if firstWriteIndex == nil and (call:find(".write$") ~= nil or call == "WorldManifest.stage") then
      firstWriteIndex = index
    end
  end
  Assert.isTrue(
    invalidateIndex ~= nil and invalidateIndex < firstWriteIndex,
    "the state must be invalidated before any artifact mutation"
  )
  Assert.equal(env.statePublishes, 1, "a fully strict rebuild publishes the new identity")
  Assert.equal(env.worldPublishes, 1, "a fully strict rebuild publishes the new world")
  Assert.equal(env.worldAborts, 0, "a fully strict rebuild never discards the staged world")
end

-- A failed build must never publish the state; it was already invalidated
-- before mutation began, and nothing reaches the authoritative world index.
function T.a_failed_build_does_not_publish_state()
  env = newEnv()
  env.failCompilers.heartgold = Errors.new("FIELD_CAMERA_VERSION_UNSUPPORTED", "injected compile failure")
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(env.stateInvalidations, 1, "the stale/missing state is invalidated before the build")
  Assert.equal(env.statePublishes, 0, "a failed build must never publish state")
  Assert.equal(env.worldPublishes, 0, "a failed build must never publish the world")
  Assert.equal(env.worldAborts, 0, "the failing version staged no world to discard")
end

-- A matching identity with a damaged cache must enter the incremental repair
-- path (marker checks decide what to rewrite) instead of fast-pathing, and a
-- strict repair republishes the state.
function T.matching_identity_with_damaged_cache_repairs_incrementally()
  env = newEnv()
  env.stateMatches = true
  env.auditAvailable = false
  env.stale = { FieldCameraCacheWriter = true }
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(err)
  Assert.deepEqual(report, { published = true, complete = true, exclusionCount = 0 })
  Assert.equal(capture.lines[1], "build-cache: heartgold field cameras compiled")
  Assert.equal(capture.lines[2], "build-cache: heartgold field actors current")
  Assert.deepEqual(env.opens, { "heartgold" }, "repair must open the ROM")
  Assert.equal(env.stateInvalidations, 1, "the damaged attestation is invalidated before repair")
  Assert.equal(env.statePublishes, 1, "a strict repair republishes the state")
  Assert.equal(env.worldPublishes, 1, "a strict repair publishes the repaired world")
end

return module
