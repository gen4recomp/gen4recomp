-- FieldState/FieldRuntime disposal contract. Disposal releases every owned
-- resource exactly once and never persists the active game, so state
-- replacement and application quit cannot create an implicit checkpoint.

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldActorPresentation = require("game.hgss.src.field.FieldActorPresentation")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")

local T = {}

-- A fake resource whose named methods record how often they are called.
---@param ... "dispose"|"release"|"save"|"reset"
---@return table
local function fakeResource(...)
  local resource = {}
  for _, method in ipairs({ ... }) do
    resource[method] = function(self)
      self.calls = (self.calls or 0) + 1
    end
  end
  resource.calls = 0
  return resource
end

-- The actor asset provider is touched twice by disposal: the per-acquisition
-- release and the provider-level dispose.
local function fakeAssetProvider()
  local provider = fakeResource("dispose")
  provider.releaseCalls = 0
  function provider:release()
    self.releaseCalls = self.releaseCalls + 1
  end
  return provider
end

-- A session at a stable GameSave boundary can capture: player idle, no transition, no
-- modal dialogue, and a runtime map with the required terrain identity.
local function captureReadySession()
  return {
    versionId = "test",
    tick = 0,
    player = {
      motion = "idle",
      fieldX = 0,
      fieldZ = 0,
      worldY = 0,
      surfaceId = 0,
      facing = "south",
    },
    currentMap = { mapId = 0, terrainDependencyHash = "dep" },
  }
end

-- The scripts platform in the shape _save's capture touches: an empty
-- scheduler and the fingerprint/world capture edges.
local function fakeScripts()
  return {
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
        return {}
      end,
      taskRegistryFingerprint = function()
        return "task-fp"
      end,
    },
    registryFingerprint = function()
      return "registry-fp"
    end,
    worldState = {
      capture = function()
        return {}
      end,
    },
  }
end

-- A bare FieldState (no boot) with every resource the disposal path touches.
local function disposableState()
  local resources = {
    dialogue = fakeResource("dispose"),
    signpost = fakeResource("dispose"),
    dialogueRenderer = fakeResource("release"),
    signpostRenderer = fakeResource("release"),
    startMenuRenderer = fakeResource("release"),
    trainerCardRenderer = fakeResource("release"),
    fieldEntranceIndicatorRenderer = fakeResource("dispose"),
    fieldSurfRenderer = fakeResource("dispose"),
    fieldTerrainEffectRenderer = fakeResource("dispose"),
    fieldEntranceIndicatorPool = fakeResource("release"),
    fieldEmoteRenderer = fakeResource("dispose"),
    fieldEmotePool = fakeResource("release"),
    monIconProvider = fakeResource("release"),
    messageProvider = fakeResource("dispose"),
    actors = fakeResource("dispose"),
    actorAssets = fakeAssetProvider(),
    presentationActorAssets = fakeAssetProvider(),
    renderer = fakeResource("release"),
    mapLoader = fakeResource("release"),
    saveStore = fakeResource("save"),
  }
  local runtime = setmetatable({
    dialogue = resources.dialogue,
    signpost = resources.signpost,
    messageProvider = resources.messageProvider,
    actors = resources.actors,
    actorAssets = resources.actorAssets,
    mapLoader = resources.mapLoader,
    saveStore = resources.saveStore,
    session = captureReadySession(),
    scripts = fakeScripts(),
    avatar = { id = "hero" },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    auxiliaryFieldUi = {
      capture = function()
        return { requested = "shown", state = "shown" }
      end,
    },
  }, FieldRuntime)
  local presentationResources = setmetatable({
    dialogueRenderer = resources.dialogueRenderer,
    signpostRenderer = resources.signpostRenderer,
    startMenuRenderer = resources.startMenuRenderer,
    trainerCardRenderer = resources.trainerCardRenderer,
    fieldEntranceIndicatorRenderer = resources.fieldEntranceIndicatorRenderer,
    fieldSurfRenderer = resources.fieldSurfRenderer,
    fieldTerrainEffectRenderer = resources.fieldTerrainEffectRenderer,
    fieldEntranceIndicatorPool = resources.fieldEntranceIndicatorPool,
    fieldEmoteRenderer = resources.fieldEmoteRenderer,
    fieldEmotePool = resources.fieldEmotePool,
    monIconProvider = resources.monIconProvider,
    renderer = resources.renderer,
  }, FieldPresentationResources)
  local actorPresentation = FieldActorPresentation.new(runtime --[[@as FieldActorPresentationRuntime]], {
    assets = resources.presentationActorAssets --[[@as FieldActorPresentationAssets]],
  })
  local state = setmetatable({
    runtime = runtime,
    presentationResources = presentationResources,
    actorPresentation = actorPresentation,
  }, FieldState)
  return state, resources
end

function T.dispose_releases_each_resource_without_saving()
  local state, resources = disposableState()
  local runtime = state.runtime --[[@as any]]
  state:dispose()
  Assert.equal(resources.dialogue.calls, 1)
  Assert.equal(resources.signpost.calls, 1, "disposal cancels the signpost controller once")
  Assert.equal(resources.dialogueRenderer.calls, 1)
  Assert.equal(resources.signpostRenderer.calls, 1, "disposal releases the signpost renderer once")
  Assert.equal(resources.startMenuRenderer.calls, 1, "disposal releases the start menu renderer once")
  Assert.equal(resources.trainerCardRenderer.calls, 1, "disposal releases the trainer card renderer once")
  Assert.equal(resources.monIconProvider.calls, 1, "disposal releases the party icon atlas once")
  Assert.equal(resources.messageProvider.calls, 1)
  Assert.equal(resources.actors.calls, 1)
  Assert.equal(resources.actorAssets.releaseCalls, 0, "no fixed simulation-side avatar reference remains to release")
  Assert.equal(resources.actorAssets.calls, 1)
  Assert.equal(resources.presentationActorAssets.releaseCalls, 0, "presentation ownership has no fixed actor reference")
  Assert.equal(resources.presentationActorAssets.calls, 1, "presentation actor assets are disposed by their owner")
  Assert.equal(resources.renderer.calls, 1)
  Assert.equal(resources.mapLoader.calls, 1)
  Assert.equal(resources.saveStore.calls, 0, "disposal never writes a checkpoint")
  Assert.isNil(runtime.session)
end

function T.dispose_is_a_no_op_on_repeat_calls()
  local state, resources = disposableState()
  state:dispose()
  state:dispose()
  Assert.equal(resources.dialogue.calls, 1)
  Assert.equal(resources.signpost.calls, 1, "repeat disposal never releases the signpost twice")
  Assert.equal(resources.renderer.calls, 1)
  Assert.equal(resources.saveStore.calls, 0)
  Assert.equal(resources.signpostRenderer.calls, 1, "repeat disposal never releases the signpost renderer twice")
  Assert.equal(resources.startMenuRenderer.calls, 1, "repeat disposal never releases the start menu renderer twice")
  Assert.equal(resources.trainerCardRenderer.calls, 1, "repeat disposal never releases the trainer card renderer twice")
end

function T.dispose_without_a_live_session_skips_the_save()
  local state, resources = disposableState()
  state.runtime.session = nil
  state:dispose()
  Assert.equal(resources.saveStore.calls, 0)
  Assert.equal(resources.renderer.calls, 1)
end

function T.dispose_releases_runtime_and_presentation_resources_once()
  local state, resources = disposableState()
  local runtime = fakeResource("dispose")
  state.runtime = runtime --[[@as FieldRuntime]]
  state:dispose()
  Assert.equal(runtime.calls, 1)
  Assert.equal(resources.renderer.calls, 1)
end

return { tests = T }
