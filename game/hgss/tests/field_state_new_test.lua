-- FieldState composition contract: the state builds the FieldRuntime options
-- table explicitly from the documented runtime contract -- state-only options
-- (topologyProvider) never reach the runtime, while the development
-- product-mode flag crosses as a runtime option -- and update drives the
-- runtime directly, so a disposed state is a programming error, never a
-- silent no-op.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local PngWriter = require("libs.assets.src.PngWriter")
local MonCache = require("libs.assets.src.MonCache")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local FieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldState = require("game.hgss.src.field.FieldState")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")

local T = {}

-- A cache serving everything the presentation boot reads: the compiled font
-- definition and atlas the dialogue renderer opens, the generated field-UI
-- class (manifest + dialogue frame strip, signpost strip/wayfinding, Start
-- Menu surface, and Trainer Card front) the renderers draw, the actor
-- index the presentation asset provider loads, and the mon icon class the
-- party screen draws.
local function presentationCache()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:write(FieldUiFixture.TRAINER_CARD_PATH, FieldUiFixture.cardBytes())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    image = MonCache.iconImagePath(),
    entries = {
      ["TEST/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
      },
    },
    representative = { "TEST/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(255, 0, 0, 255)
  end
  cache:write(MonCache.iconImagePath(), PngWriter.encode(64, 64, table.concat(pixels)))
  cache:write(
    FieldActorCache.indexPath(),
    LuaWriter.encode({ schema = FieldActorCache.INDEX_SCHEMA, spriteIds = { 0 } })
  )
  cache:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0))
  cache:write(FieldActorCache.atlasPath(0), FieldDialogueFixture.atlasBytes())
  return cache
end

-- The terrain-effect bundle the real terrain renderer acquires during the
-- boot: one synthetic triangle mesh per effect kind, written into the same
-- presentation cache the boot reads through.
local function terrainEffects(cache)
  cache:write(
    "test/terrain-grass.mesh",
    MeshWriter.encode({
      vertices = {
        {
          x = 0,
          y = 0,
          z = 0,
          u = 0,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 1,
          y = 0,
          z = 0,
          u = 1,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
        {
          x = 0,
          y = 0,
          z = 1,
          u = 0,
          v = 1,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 255,
          g = 255,
          b = 255,
          a = 255,
          colorSource = 0,
        },
      },
      indices = { 0, 1, 2 },
    })
  )
  local function effect()
    return {
      model = {
        dynamic = {
          nodes = {
            { name = "root", translation = { 0, 0, 0 }, rotation = { 0, 0, 0 }, scale = { 1, 1, 1 } },
          },
          batches = {
            {
              id = "grass",
              nodeIndex = 0,
              materialIndex = 0,
              geometry = "test/terrain-grass.mesh",
              alphaClass = "cutout",
              cullMode = "back",
              polygonAlpha = 31,
              polygonMode = "modulation",
              polygonId = 0,
              translucentDepthWrite = false,
              depthEqual = false,
              lightMask = 15,
              fogEnabled = false,
            },
          },
        },
        materials = { { id = 0, name = "grass", wrap = { x = "clamp", y = "clamp" } } },
        animations = {},
      },
      placementOffset = { x = 0, y = 0, z = 0 },
    }
  end
  return {
    tall_grass = effect(),
    very_tall_grass = effect(),
    trainer_reveal = effect(),
  }
end

-- The stubbed presentation runtime every FieldState boot reads: the cache
-- and manifest the renderers draw through, the entrance bundle carrying the
-- compiled surf attachment, and the actor/player edges the draw sync uses.
local function stubPresentationRuntime(cache)
  cache = cache or presentationCache()
  local effects = terrainEffects(cache)
  return setmetatable({
    cacheFs = cache,
    uiManifest = FieldUiFixture.manifest(),
    fieldEntranceIndicatorAsset = {
      model = { batches = {}, materials = {} },
      effects = {
        surf_attachment = {
          model = { batches = {}, materials = {} },
          presentation = { yawDegrees = { north = 180, south = 0, west = 270, east = 90 } },
        },
      },
    },
    fieldEmoteModels = {
      exclamation = {
        schema = "g4-field-emote-v1",
        anchorOffset = { x = 0, y = 2, z = 0.0625 },
        model = { batches = {}, materials = {} },
      },
    },
    fieldEffectAssets = { effects = effects },
    fieldTerrainEffectController = FieldTerrainEffectController.new({
      effects = effects,
      modelFactory = function()
        error("the terrain model factory is installed by presentation resources", 0)
      end,
    }),
    windowStyles = {
      resolve = function() end,
    },
    menuHost = {
      setScreenTopology = function() end,
      setPresentationMetrics = function() end,
    },
    actors = {
      visualRevision = function()
        return 0
      end,
      collectSpriteIds = function() end,
    },
    playerVisual = { spriteId = 0 },
    startMenuPlacement = nil,
    resizePresentation = function() end,
    dispose = function() end,
  }, FieldRuntime)
end

-- Boot FieldState for real (the presentation resources are acquired against
-- the host) with FieldRuntime.new stubbed to capture the options table.
---@param options FieldStateOptions
---@param cache CacheFs? the presentation cache the stubbed runtime serves
---@return FieldState state
---@return table captured
---@return table game
local function bootWithCapturedRuntimeOptions(options, cache)
  local captured
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(game, runtimeOptions)
    captured = { game = game, options = runtimeOptions }
    return stubPresentationRuntime(cache)
  end
  local game = { saveId = "save-00000001", versionId = "heartgold" }
  local ok, state = pcall(FieldState.new, game, options)
  FieldRuntime.new = originalNew
  if not ok then
    error(state, 0)
  end
  return state, captured, game
end

-- The composition: FieldState constructs the signpost, Start Menu, and
-- Trainer Card renderers against the runtime's cache and immutable window
-- style catalogue, so their GPU resources are owned and released by the state
-- (never by controllers or the catalogue).
local function fieldStateOptions()
  return {
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
  }
end

-- Only the documented runtime contract crosses the state boundary: adding a
-- state-only option must not silently become a runtime option. The
-- development flag is a state-only presentation option (the playtest HUD and
-- developer binds), so it stays behind the boundary.
function T.only_documented_runtime_options_reach_the_runtime()
  local options = fieldStateOptions()
  local saveValidation = GameSaveValidation.new({
    contextLoader = function()
      return {}
    end,
  })
  options.saveValidation = saveValidation
  options.zoomConfig = { mode = "test" }
  options.development = true
  local state, captured, game = bootWithCapturedRuntimeOptions(options)
  Assert.deepEqual(captured.options, {
    zoomConfig = { mode = "test" },
    presentation = true,
    saveValidation = saveValidation,
  })
  Assert.equal(captured.game, game)
  Assert.equal(state.development, true, "the state keeps the development flag for its own presentation")
  state:dispose()
end

function T.state_constructs_the_field_ui_renderers()
  local state = bootWithCapturedRuntimeOptions(fieldStateOptions())
  Assert.notNil(state.presentationResources.signpostRenderer, "the state constructs the signpost renderer")
  Assert.notNil(state.presentationResources.startMenuRenderer, "the state constructs the start menu renderer")
  Assert.notNil(state.presentationResources.trainerCardRenderer, "the state constructs the trainer card renderer")
  state:dispose()
end

function T.state_composes_explicit_presentation_owners()
  local state = bootWithCapturedRuntimeOptions(fieldStateOptions())
  Assert.notNil(state.presentationResources, "FieldState owns a presentation resource aggregate")
  Assert.notNil(state.actorPresentation, "FieldState owns an actor presentation aggregate")
  state:dispose()
end

-- Valid production-shaped construction installs the terrain model factory on
-- the runtime controller: the installed factory resolves through the real
-- terrain renderer instead of the boot placeholder.
function T.state_construction_installs_the_terrain_model_factory()
  local state = bootWithCapturedRuntimeOptions(fieldStateOptions())
  local factory = state.runtime.fieldTerrainEffectController.modelFactory
  Assert.isTrue(type(factory) == "function", "presentation construction installs the terrain model factory")
  local ok, err = pcall(factory, "missing-kind")
  Assert.isFalse(ok, "the installed factory resolves through the real terrain renderer")
  Assert.isTrue(
    tostring(err):find("terrain renderer is missing", 1, true) ~= nil,
    "the installed factory resolves through the real terrain renderer: " .. tostring(err)
  )
  state:dispose()
end

function T.update_forwards_to_the_runtime()
  local updates = 0
  local state = setmetatable({
    runtime = {
      update = function()
        updates = updates + 1
      end,
      actors = {
        visualRevision = function()
          return 0
        end,
        collectSpriteIds = function() end,
      },
      playerVisual = { spriteId = 0 },
    },
    actorPresentation = {
      sync = function(self)
        self.synced = true
      end,
    },
  }, FieldState)
  state:update(0.016)
  Assert.equal(updates, 1)
  Assert.isTrue((state.actorPresentation --[[@as any]]).synced)
end

-- A presentation boot with a missing generated UI asset is a typed error: a
-- half-composed state is never returned. Each renderer's own release-on-
-- failure contract is unit-pinned; the state contract is that the typed
-- failure propagates from construction.
function T.state_construction_fails_typed_when_a_ui_asset_is_missing()
  local options = fieldStateOptions()
  local cardCache = presentationCache()
  cardCache:remove(FieldUiFixture.TRAINER_CARD_PATH)
  local cardErr = Assert.throws(function()
    bootWithCapturedRuntimeOptions(options, cardCache)
  end)
  Assert.isTrue(
    Errors.is(cardErr) and cardErr.code == "FIELD_UI_TRAINER_CARD_FRONT_MISSING",
    "a missing trainer card front is a typed construction failure: " .. tostring(cardErr)
  )

  local signpostCache = presentationCache()
  signpostCache:remove(FieldUiFixture.SIGNPOST_TILES_PATH)
  local signpostErr = Assert.throws(function()
    bootWithCapturedRuntimeOptions(options, signpostCache)
  end)
  Assert.isTrue(
    Errors.is(signpostErr) and signpostErr.code == "FIELD_UI_SIGNPOST_TILES_MISSING",
    "a missing signpost strip is a typed construction failure: " .. tostring(signpostErr)
  )
end

-- A ready cache without the compiled surf attachment is a loud boot
-- failure: the state never draws a world with an invisibly missing surf.
function T.state_construction_fails_when_the_surf_attachment_is_missing()
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, _)
    local runtime = stubPresentationRuntime(presentationCache())
    runtime.fieldEntranceIndicatorAsset.effects = nil
    return runtime
  end
  local game = { saveId = "save-00000001", versionId = "heartgold" }
  local ok, err = pcall(FieldState.new, game, fieldStateOptions())
  FieldRuntime.new = originalNew
  Assert.isFalse(ok, "a missing surf attachment must fail the boot")
  Assert.isTrue(
    tostring(err):find("field-effect cache is missing surf_attachment", 1, true) ~= nil,
    "a missing surf attachment must fail loudly: " .. tostring(err)
  )
end

-- A disposed state (runtime cleared) has no zombie mode: driving it after
-- disposal is a programming error, not a silently ignored update.
function T.update_after_dispose_is_a_programming_error()
  local state = setmetatable({ runtime = nil }, FieldState)
  Assert.throws(function()
    state:update(0.016)
  end)
end

-- Presentation construction requires the real terrain-effect collaborators:
-- a runtime without field-effect assets and the terrain-effect controller is
-- a loud boot failure, never a world with silently missing terrain effects.
function T.state_construction_fails_when_terrain_effect_collaborators_are_missing()
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, _)
    local runtime = stubPresentationRuntime(presentationCache())
    runtime.fieldEffectAssets = nil
    runtime.fieldTerrainEffectController = nil
    return runtime
  end
  local game = { saveId = "save-00000001", versionId = "heartgold" }
  local ok, err = pcall(FieldState.new, game, fieldStateOptions())
  FieldRuntime.new = originalNew
  Assert.isFalse(ok, "missing terrain-effect collaborators must fail the boot")
  Assert.isTrue(
    tostring(err):find("terrain-effect", 1, true) ~= nil or tostring(err):find("terrain effect", 1, true) ~= nil,
    "a missing terrain-effect collaborator must fail loudly: " .. tostring(err)
  )
end

return { tests = T }
