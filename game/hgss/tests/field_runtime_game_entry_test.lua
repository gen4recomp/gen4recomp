-- FieldRuntime accepts one finalized or loaded game record and does not own
-- fresh-session policy, demo manifests, or save-store loading.

local Assert = require("tests.support.Assert")
local GameSave = require("libs.hgss.src.save.GameSave")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldSaveCoordinator = require("game.hgss.src.field.FieldSaveCoordinator")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {}

---@class FieldRuntimeGameEntryTestRuntime : FieldRuntime
---@field entryLoaded boolean?
---@field mapIdOrSymbol string|integer|nil

function T.constructor_uses_the_supplied_game_entry_record()
  local originalLoad = FieldRuntime._load
  local entry = {
    saveId = "save-00000001",
    versionId = "heartgold",
    location = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    playTime = PlayTime.new(),
    worldState = {},
  }

  ---@param self FieldRuntimeGameEntryTestRuntime
  FieldRuntime._load = function(self)
    self.entryLoaded = self.game == entry
  end

  local ok, runtime = pcall(FieldRuntime.new, entry, { presentation = false })
  FieldRuntime._load = originalLoad
  Assert.isTrue(ok, tostring(runtime))
  ---@cast runtime FieldRuntimeGameEntryTestRuntime
  Assert.isTrue(runtime.entryLoaded, "the runtime must retain the supplied game entry")
  Assert.equal(runtime.versionId, "heartgold")
  Assert.isNil(runtime.mapIdOrSymbol, "the runtime must not select a default map")
end

function T.menu_bindings_are_built_from_the_field_presentation_manifest(context)
  if
    context ~= nil
    and type(context.hasCapability) == "function"
    and (not context:hasCapability("rom_dump") or not context:hasCapability("derived_cache"))
  then
    context:skip("requires rom_dump and derived_cache")
  end
  local FieldPresentation = require("data.manifests.field_presentation")
  local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
  local originalMenu = FieldPresentation.input.menu
  FieldPresentation.input.menu = { "n" }
  local game
  local ok, err = xpcall(function()
    game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
      versionId = AcceptanceHarness.defaultVersion(),
      map = "MAP_BURNED_TOWER_1F",
      save = "fresh",
    })
    Assert.equal(game.runtime.menuKeys.n, true)
    Assert.isNil(game.runtime.menuKeys.m)
  end, debug.traceback)
  FieldPresentation.input.menu = originalMenu
  if game ~= nil then
    local closeOk, closeErr = pcall(function()
      game:close()
    end)
    if ok and not closeOk then
      ok, err = false, closeErr
    end
  end
  if not ok then
    error(err, 0)
  end
end

function T.default_save_validation_uses_repository_overrides()
  local originalLoad = FieldRuntime._load
  local entry = {
    saveId = "save-00000001",
    versionId = "heartgold",
    location = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    playTime = PlayTime.new(),
    worldState = {},
  }

  FieldRuntime._load = function() end
  local ok, runtime = pcall(FieldRuntime.new, entry, { presentation = false })
  FieldRuntime._load = originalLoad

  Assert.isTrue(ok, tostring(runtime))
  local overrideManifest = runtime.saveValidation.overrideFs:read("data/scripts/manifests/overrides.lua")
  Assert.notNil(overrideManifest, "default save validation needs repository overrides")
  Assert.notNil(runtime.overrideFs, "the runtime must retain its effective repository filesystem")
  Assert.equal(
    runtime.overrideFs,
    runtime.saveValidation.overrideFs,
    "default save validation must use the runtime's effective repository filesystem"
  )
end

local function captureRuntime(overrides)
  local runtime = setmetatable({
    game = {
      saveId = "save-00000001",
      versionId = "heartgold",
    },
    saveId = "save-00000001",
    versionId = "heartgold",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    session = {
      tick = 42,
      player = {
        motion = "idle",
        fieldX = 684,
        fieldZ = 393,
        worldY = 1.5,
        surfaceId = 2,
        facing = "south",
      },
      currentMap = { mapId = 60, terrainDependencyHash = "terrain-heartgold", effectiveWeatherId = 11 },
    },
    scripts = {
      worldState = {
        capture = function(_, objects)
          return { flags = { [960] = true }, variables = {}, objects = objects, rng = { state = 1, calls = 2 } }
        end,
      },
      scheduler = {},
      registryFingerprint = function()
        return "registry-fingerprint"
      end,
    },
    actors = {
      captureObjects = function()
        return { schema = "g4-field-objects-v1", rng = { state = 7, calls = 3 }, actors = {} }
      end,
    },
    auxiliaryFieldUi = {
      capture = function()
        return { requested = "shown", state = "shown" }
      end,
    },
    audio = {
      musicOverride = function()
        return 123
      end,
    },
    playTime = PlayTime.new(17),
    monService = {
      capture = function()
        return require("libs.mons.src.MonsSave").empty("test-catalog-fingerprint", 7)
      end,
    },
    saveValidation = {
      contexts = {},
      contextLoader = function()
        return {}
      end,
      validate = function(_, record)
        return record
      end,
    },
  }, FieldRuntime)
  for key, value in pairs(overrides or {}) do
    runtime[key] = value
  end
  if runtime.saveCoordinator == nil then
    runtime.saveCoordinator = FieldSaveCoordinator.new(runtime)
  end
  return runtime
end

function T.captureGameSave_returns_a_strict_snapshot_without_storage_io()
  local runtime = captureRuntime()
  local validationCalls = 0
  runtime.saveValidation = {
    contexts = {},
    contextLoader = function()
      return {}
    end,
    validate = function(_, record)
      validationCalls = validationCalls + 1
      return record
    end,
  }
  local scriptCaptureCalls = 0
  local originalCapture = require("libs.script.src.ScriptSave").capture
  require("libs.script.src.ScriptSave").capture = function(_, tick, options)
    scriptCaptureCalls = scriptCaptureCalls + 1
    Assert.equal(tick, 42)
    Assert.equal(options.registryFingerprint, "registry-fingerprint")
    return { schema = "g4-script-save-v1", capturedAtSimulationTick = tick }
  end

  local ok, result = pcall(function()
    return runtime:captureGameSave()
  end)
  require("libs.script.src.ScriptSave").capture = originalCapture

  Assert.isTrue(ok, tostring(result))
  local valid = assert(GameSave.validate(result))
  Assert.equal(valid.saveId, "save-00000001")
  Assert.equal(valid.versionId, "heartgold")
  Assert.equal(valid.mapId, 60)
  Assert.equal(valid.fieldX, 684)
  Assert.equal(valid.fieldZ, 393)
  Assert.equal(valid.surfaceId, 2)
  Assert.equal(valid.worldY, 1.5)
  Assert.equal(valid.playTimeSeconds, 17)
  Assert.equal(valid.audio.fieldMusicOverride, 123)
  Assert.equal(valid.weatherId, 11)
  Assert.equal(valid.world.objects.schema, "g4-field-objects-v1")
  Assert.equal(valid.mons.schema, "g4-mons-save-v1", "every save captures the mons bucket")
  Assert.equal(scriptCaptureCalls, 1)
  Assert.equal(validationCalls, 1)
end

function T.captureGameSave_refuses_an_unstable_boundary_without_mutating_state()
  local runtime = captureRuntime()
  runtime.session.player.motion = "walking"
  local snapshot, reason = runtime:captureGameSave()
  Assert.isNil(snapshot)
  Assert.isTrue(type(reason) == "string" and reason ~= "")
  Assert.equal(runtime.session.player.motion, "walking")
end

function T.warp_completion_does_not_request_an_implicit_save()
  local saveRequests = 0
  local completionConsumed = false
  local runtime = setmetatable({
    scripts = {},
    session = {
      accumulator = 0,
      updateFixed = function() end,
    },
    transition = {
      error = nil,
      phase = "idle",
      updateSourceFrame = function() end,
      consumeCompleted = function()
        completionConsumed = true
        return true
      end,
    },
    applicationHost = {
      error = function()
        return nil
      end,
    },
    playTime = {
      advance = function() end,
    },
  }, FieldRuntime)
  runtime:update(0)

  Assert.isTrue(completionConsumed, "the transition completion edge is consumed")
  Assert.equal(saveRequests, 0, "completing a warp must not publish or request a checkpoint")
end

function T.manual_save_keeps_publication_state_across_menu_openings()
  local calls = {}
  local runtime = setmetatable({
    savePublished = false,
    saveStore = {
      publishFirst = function(_, record)
        calls[#calls + 1] = { kind = "publish", record = record }
      end,
      save = function(_, record)
        calls[#calls + 1] = { kind = "update", record = record }
      end,
    },
  }, FieldRuntime)
  runtime.saveCoordinator = FieldSaveCoordinator.new(runtime)
  runtime._captureManualSaveFromMenu = function()
    return { saveId = "save-00000001" }
  end
  runtime:_saveCheckpoint()
  runtime:_saveCheckpoint()
  Assert.equal(runtime.savePublished, true)
  Assert.deepEqual({ calls[1].kind, calls[2].kind }, { "publish", "update" })
end

function T.failed_first_manual_save_remains_retryable_as_first_publication()
  local attempts = 0
  local runtime = setmetatable({
    savePublished = false,
    saveStore = {
      publishFirst = function()
        attempts = attempts + 1
        if attempts == 1 then
          error("publication failed")
        end
      end,
    },
  }, FieldRuntime)
  runtime.saveCoordinator = FieldSaveCoordinator.new(runtime)
  runtime._captureManualSaveFromMenu = function()
    return { saveId = "save-00000001" }
  end
  Assert.throws(function()
    runtime:_saveCheckpoint()
  end)
  Assert.equal(runtime.savePublished, false)
  runtime:_saveCheckpoint()
  Assert.equal(runtime.savePublished, true)
  Assert.equal(attempts, 2)
end

function T.dispose_releases_runtime_without_capturing_or_persisting()
  local captures = 0
  local runtime = captureRuntime()
  runtime.captureGameSave = function()
    captures = captures + 1
    error("dispose must not capture")
  end
  runtime._releaseAll = function(self)
    self.session = nil
  end
  runtime:dispose()
  Assert.equal(captures, 0)
  Assert.isNil(runtime.session)
end

function T.captureGameSave_writes_the_stable_durable_avatar_state()
  local runtime = captureRuntime({
    playerAvatar = {
      isStableForSave = function()
        return true
      end,
      capture = function()
        return { state = "cycling" }
      end,
    },
    -- The script bucket capture is production behavior; the scheduler fake
    -- conforms to its required interface so the avatar assertions below
    -- observe the real capture path.
    scripts = {
      worldState = {
        capture = function(_, objects)
          return { flags = { [960] = true }, variables = {}, objects = objects, rng = { state = 1, calls = 2 } }
        end,
      },
      scheduler = {
        liveInstances = function()
          return {}
        end,
        environments = function()
          return {}
        end,
        tasks = function()
          return {}
        end,
        counters = function()
          return { nextEnvironmentId = 0, nextInstanceId = 0, nextTaskId = 0 }
        end,
        taskRegistryFingerprint = function()
          return "tasks"
        end,
      },
      registryFingerprint = function()
        return "registry-fingerprint"
      end,
    },
  })
  local snapshot, reason = runtime:captureGameSave()
  Assert.notNil(snapshot, "a stable avatar must not defer capture: " .. tostring(reason))
  Assert.deepEqual(snapshot.avatar, { state = "cycling" })
end

function T.captureGameSave_defers_while_avatar_state_is_unstable()
  local pending = captureRuntime({
    playerAvatar = {
      isStableForSave = function()
        return false
      end,
      capture = function()
        error("unstable avatar state must never be serialized")
      end,
    },
  })
  local snapshot, reason = pending:captureGameSave()
  Assert.isNil(snapshot)
  Assert.isTrue(type(reason) == "string" and reason ~= "", "an unstable avatar must defer with a reason")

  local temporary = captureRuntime({
    playerAvatar = {
      isStableForSave = function()
        return false
      end,
      capture = function()
        error("a temporary visual must never be serialized")
      end,
    },
  })
  temporary.session.player.motion = "idle"
  local tempSnapshot, tempReason = temporary:captureGameSave()
  Assert.isNil(tempSnapshot)
  Assert.isTrue(type(tempReason) == "string" and tempReason ~= "")
end

function T.constructor_applies_defaults_and_keeps_injected_identities()
  local originalLoad = FieldRuntime._load
  FieldRuntime._load = function() end
  local function validEntry()
    return {
      saveId = "save-00000001",
      versionId = "heartgold",
      location = {
        mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
        fieldX = 6,
        fieldZ = 6,
        facing = "south",
      },
      playerData = {
        profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
        options = { textSpeed = "mid", textFrame = 0 },
      },
      playTime = PlayTime.new(),
      worldState = {},
    }
  end
  local ok, err = xpcall(function()
    local WindowConfig = require("game.src.WindowConfig")
    local defaulted = FieldRuntime.new(validEntry())
    Assert.equal(defaulted.viewportWidth, WindowConfig.REFERENCE_WIDTH)
    Assert.equal(defaulted.viewportHeight, WindowConfig.REFERENCE_HEIGHT)
    Assert.equal(defaulted.presentation, false)
    Assert.notNil(defaulted.overrideFs)
    Assert.notNil(defaulted.saveValidation)
    Assert.notNil(defaulted.localClock)
    Assert.notNil(defaulted.zoom)
    Assert.notNil(defaulted.saveCoordinator)
    Assert.notNil(defaulted.worldSwapCoordinator)
    Assert.equal(
      defaulted.saveValidation.overrideFs,
      defaulted.overrideFs,
      "the default validation dependency must share the effective repository filesystem"
    )

    local overrideFs = { injectedOverride = true }
    local saveValidation = { injectedValidation = true }
    local localClock = { injectedClock = true }
    local injected = FieldRuntime.new(validEntry(), {
      overrideFs = overrideFs,
      saveValidation = saveValidation,
      localClock = localClock,
      viewportWidth = 800,
      viewportHeight = 600,
      presentation = true,
    })
    Assert.equal(injected.overrideFs, overrideFs)
    Assert.equal(injected.saveValidation, saveValidation)
    Assert.equal(injected.localClock, localClock)
    Assert.equal(injected.viewportWidth, 800)
    Assert.equal(injected.viewportHeight, 600)
    Assert.equal(injected.presentation, true)

    Assert.throws(function()
      FieldRuntime.new(nil, {})
    end, "a missing game must fail construction")
    Assert.throws(function()
      FieldRuntime.new({}, {})
    end, "a game without a version must fail construction")
    Assert.throws(function()
      FieldRuntime.new({ versionId = "" }, {})
    end, "a game with a blank version must fail construction")
  end, debug.traceback)
  FieldRuntime._load = originalLoad
  if not ok then
    error(err, 0)
  end
end

function T.required_coordinators_are_reused_and_never_rebuilt_after_construction()
  local saveCalls = 0
  local abortCalls = 0
  local saveCoordinator = {
    save = function(_)
      saveCalls = saveCalls + 1
    end,
  }
  local worldSwapCoordinator = {
    abort = function(_, resolution, prepared)
      abortCalls = abortCalls + 1
      Assert.isNil(resolution)
      Assert.isNil(prepared)
    end,
  }
  local runtime = setmetatable({
    saveCoordinator = saveCoordinator,
    worldSwapCoordinator = worldSwapCoordinator,
  }, FieldRuntime)
  runtime:_saveCheckpoint()
  runtime:_disposePreparedSwap(nil, nil)
  Assert.equal(saveCalls, 1)
  Assert.equal(abortCalls, 1)
  Assert.equal(runtime.saveCoordinator, saveCoordinator, "repeated saves must reuse the constructed coordinator")
  Assert.equal(
    runtime.worldSwapCoordinator,
    worldSwapCoordinator,
    "repeated swaps must reuse the constructed coordinator"
  )

  runtime.saveCoordinator = nil
  runtime._captureManualSaveFromMenu = function()
    return { saveId = "save-00000001" }
  end
  runtime.saveStore = {
    publishFirst = function() end,
    save = function() end,
  }
  runtime.savePublished = false
  Assert.throws(function()
    runtime:_saveCheckpoint()
  end, "a missing save coordinator must fail instead of rebuilding a replacement")

  runtime.worldSwapCoordinator = nil
  Assert.throws(function()
    runtime:_disposePreparedSwap(nil, nil)
  end, "a missing world-swap coordinator must fail instead of rebuilding a replacement")
end

return { tests = T }
