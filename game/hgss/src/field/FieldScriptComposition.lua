-- Builds the concrete field script hosts and scheduler-facing adapters.

local FieldScripts = require("game.hgss.src.field.FieldScripts")
local ScriptSave = require("libs.script.src.ScriptSave")

---@class FieldScriptCompositionResult
---@field scripts FieldScripts
---@field restore fun()
---@class FieldScriptCompositionOptions
---@field cacheFs CacheFs
---@field layoutMessage fun(formatted: table<string, unknown>): table<string, unknown>
---@field fontDef table<string, unknown>
---@field audioService table<string, unknown>
---@field loadedGame table<string, unknown>?
---@field mons table<string, unknown>? live HGSS mon service for mon/party script operations and text
local FieldScriptComposition = {}

---@param runtime FieldRuntime
---@param options FieldScriptCompositionOptions
---@return FieldScriptCompositionResult
function FieldScriptComposition.compose(runtime, options)
  assert(type(options) == "table", "field script composition options are required")
  local function requestStartMenuReopen()
    runtime.applicationHost:requestReopen()
  end
  local function applyAvatarTransitionsForScripts()
    return runtime:applyAvatarTransitions()
  end
  local function changeWeather(_, weatherId)
    runtime:_setLiveWeather(assert(runtime.runtimeMap), weatherId)
  end
  local scripts = FieldScripts.new({
    cacheFs = options.cacheFs,
    overrideFs = runtime.overrideFs,
    eventState = runtime.eventState,
    actors = runtime.actors,
    player = runtime.player,
    playerAvatar = runtime.playerAvatar,
    avatarApplier = applyAvatarTransitionsForScripts,
    profile = runtime.playerData.profile,
    dialogue = runtime.dialogue,
    messageProvider = runtime.messageProvider,
    layout = options.layoutMessage,
    fontDef = options.fontDef,
    frameIndex = runtime.playerData.options.textFrame,
    signpost = runtime.signpost,
    windowStyles = runtime.windowStyles,
    transition = runtime.transition,
    mapLoader = runtime.mapLoader,
    sourceMap = runtime.runtimeMap,
    seedText = runtime.versionId .. ":" .. runtime.runtimeMap.mapId,
    effects = runtime.fieldTerrainEffectController,
    audio = options.audioService,
    weather = { change = changeWeather },
    camera = runtime.scriptHosts and runtime.scriptHosts.camera,
    screen = runtime.screenFade,
    events = runtime.scriptHosts and runtime.scriptHosts.events,
    auxiliaryUi = runtime.auxiliaryFieldUi,
    contextChoice = runtime.contextChoiceProvider,
    menu = runtime.menuHost,
    startMenuReopen = { request = requestStartMenuReopen },
    mons = options.mons,
  })
  local function restore()
    if options.loadedGame then
      ScriptSave.restore(options.loadedGame.scripts, scripts.scheduler, 0, {
        expectedRegistryFingerprint = scripts:registryFingerprint(),
      })
      scripts.worldState:restoreRng(options.loadedGame.world)
    end
  end
  return {
    scripts = scripts,
    restore = restore,
  }
end

return FieldScriptComposition
