-- Owns field save capture and publication coordination for one runtime.

local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldAudioSave = require("libs.hgss.src.audio.FieldAudioSave")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local GameSave = require("libs.hgss.src.save.GameSave")
local ScriptSave = require("libs.script.src.ScriptSave")

---@class FieldSaveCoordinator
---@field runtime FieldRuntime
local FieldSaveCoordinator = {}
FieldSaveCoordinator.__index = FieldSaveCoordinator

---@param runtime FieldRuntime
---@return FieldSaveCoordinator
function FieldSaveCoordinator.new(runtime)
  return setmetatable({ runtime = runtime }, FieldSaveCoordinator)
end

---@param session FieldSession
---@param allowMenu boolean
---@return boolean
local function canCapture(session, allowMenu)
  return session
    and session.player
    and session.player.motion == "idle"
    and (not session.transition or session.transition.phase == FieldTransition.PHASES.idle)
    and (not session.dialogue or not session.dialogue:isModal())
    and (not session.signpost or not session.signpost:isModal())
    and (
      not session.applicationHost
      or not session.applicationHost:isActive()
      or (allowMenu and session.applicationHost:status().phase == FieldApplicationHost.PHASES.menu)
    )
end

---@param self FieldSaveCoordinator
---@param allowMenu boolean
---@return table<string, unknown>?, string|table<string, unknown>?
function FieldSaveCoordinator:capture(allowMenu)
  local runtime = self.runtime
  if not canCapture(runtime.session, allowMenu == true) then
    return nil, "Save deferred: movement, transition, or modal state is active"
  end
  if runtime.playerAvatar and not runtime.playerAvatar:isStableForSave() then
    return nil, "Save deferred: avatar transition state is not stable"
  end

  local session = runtime.session
  local player = session.player
  local runtimeMap = session.currentMap
  assert(type(runtimeMap.terrainDependencyHash) == "string", "runtime map terrain dependency identity required")

  local world = runtime.scripts.worldState:capture(runtime.actors:captureObjects())
  local weatherState = runtimeMap --[[@as table]]
  local snapshot = {
    schema = GameSave.SCHEMA,
    saveId = runtime.saveId,
    versionId = runtime.versionId,
    mapId = runtimeMap.mapId,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    worldY = player.worldY,
    surfaceId = player.surfaceId,
    terrainDependencyHash = runtimeMap.terrainDependencyHash,
    facing = player.facing,
    weatherId = assert(weatherState.effectiveWeatherId, "active runtime weather is required"),
    playTimeSeconds = runtime.playTime:seconds(),
    playerData = runtime.playerData,
    world = world,
    scripts = ScriptSave.capture(runtime.scripts.scheduler, session.tick, {
      registryFingerprint = runtime.scripts:registryFingerprint(),
    }),
    auxiliaryUi = runtime.auxiliaryFieldUi:capture(),
    audio = FieldAudioSave.capture(runtime.audio),
    mons = runtime.monService:capture(),
  }
  if runtime.playerAvatar then
    snapshot.avatar = runtime.playerAvatar:capture()
  end

  local valid, validationErr = runtime.saveValidation:validate(snapshot)
  if not valid then
    return nil, validationErr
  end
  return valid
end

---@param self FieldSaveCoordinator
---@return table<string, unknown>?, string|table<string, unknown>?
function FieldSaveCoordinator:captureManual()
  local runtime = self.runtime
  if not canCapture(runtime.session, true) then
    return nil, "Save deferred: the field is not stable"
  end
  return self:capture(true)
end

function FieldSaveCoordinator:save()
  local runtime = self.runtime
  assert(runtime.saveStore, "manual Save requires a save store")
  -- Keep this call on the runtime facade so test/runtime subclasses may
  -- replace the menu-specific capture policy without owning persistence.
  local record, reason = runtime:_captureManualSaveFromMenu()
  assert(record, reason)
  if runtime.savePublished then
    runtime.saveStore:save(record)
  else
    runtime.saveStore:publishFirst(record)
    runtime.savePublished = true
  end
end

return FieldSaveCoordinator
