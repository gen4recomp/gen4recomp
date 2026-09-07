-- Script maps service : the warp adapter between the
-- script runtime's `maps` service and the field transition subsystem. A
-- script warp targets a map symbol plus destination-local coordinates; the
-- service loads the destination map, converts the coordinates to the global
-- field space the transition expects, synthesizes a direct warp record, and
-- starts a covered scripted swap under the source-authored screen cover
-- (fade_screen/wait_fade), never the ordinary generic-fade transition
-- lifecycle -- source `Warp` owns no fade of its own. Completion is observed
-- through the transition returning to idle after the application consumed
-- the finished swap, so the warp task's poll cadence stays deterministic.
-- The service also holds the source special-spawn setter's semantic state
-- (opcode 582): a named record, not a hidden side effect. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")

---@class ScriptMapsService
---@field private _transition table<string, unknown> FieldTransition-shaped
---@field private _loader table<string, unknown> FieldMapLoader-shaped
---@field private _sourceMap table<string, unknown> RuntimeFieldMap
---@field private _screen table<string, unknown>|nil screen-fade-cover-shaped: isOpaque(): boolean
---@field private pendingWarp table<string, unknown>|nil
---@field private _error unknown|nil
---@field private _specialSpawn table<string, unknown>|nil
local ScriptMapsService = {}
ScriptMapsService.__index = ScriptMapsService

-- `opts.screen` is optional at this narrow constructor: production always
-- supplies one (FieldScripts wires FieldRuntime's screen-fade controller
-- unconditionally), so a real scripted `Warp` always performs a covered
-- swap. A caller with no screen cover (only exercised where a test's
-- contract is unrelated to warp fade behavior) falls back to the ordinary
-- transition lifecycle instead of asserting a capability it does not need.
---@param opts table<string, unknown> { transition, loader, sourceMap, screen? }
---@return ScriptMapsService
function ScriptMapsService.new(opts)
  assert(
    type(opts) == "table" and opts.transition and opts.loader and opts.sourceMap,
    "script maps service requires a transition, loader, and source map"
  )
  return setmetatable({
    _transition = opts.transition,
    _loader = opts.loader,
    _sourceMap = opts.sourceMap,
    _screen = opts.screen,
    pendingWarp = nil,
    _error = nil,
    _specialSpawn = nil,
  }, ScriptMapsService)
end

function ScriptMapsService:currentId()
  return self._sourceMap.mapId
end

-- Rebind the source map after a map swap (the transition replaced it).
---@param sourceMap table<string, unknown> RuntimeFieldMap
function ScriptMapsService:setSourceMap(sourceMap)
  self._sourceMap = sourceMap
end

-- Resolve a map symbol to its runtime map; nil only for the known
-- not-found case (FIELD_MAP_UNKNOWN). Any other loader failure is an
-- internal fault and re-raises with attribution.
---@param ref unknown
---@return table<string, unknown>|nil
function ScriptMapsService:resolve(ref)
  if type(ref) ~= "string" then
    return nil
  end
  local ok, map = pcall(self._loader.load, self._loader, ref)
  if ok then
    if map ~= nil and map.mapId ~= nil then
      return map
    end
    return nil
  end
  if Errors.is(map) then
    local err = map --[[@as Errors.Error]]
    if err.code == FieldErrors.FIELD_MAP_UNKNOWN then
      return nil
    end
    Errors.raise(err.code, err.message, err.context)
  end
  error(map, 0)
end

function ScriptMapsService:has(ref)
  return self:resolve(ref) ~= nil
end

-- Record the player's spawn point for field re-entry. The spawn id is
-- observable through `spawn()`; the field layer consumes it when it rebuilds
-- the player after leaving a scripted map.
---@param spawn string
function ScriptMapsService:setSpawn(spawn)
  self._spawn = spawn
end

-- The recorded spawn point, or nil before any `set_spawn` ran.
---@return string|nil
function ScriptMapsService:spawn()
  return self._spawn
end

-- Start a scripted warp. `target` is the graph node's warp descriptor:
-- { map = "<symbol>", warp = index, fieldX, fieldZ, facing } with the
-- destination coordinates in the destination map's local cell space.
---@param target table<string, unknown>
function ScriptMapsService:startWarp(target)
  assert(self.pendingWarp == nil, "a scripted warp is already in progress")
  local destination, loadErr = self._loader:load(target.map)
  if destination == nil or destination.mapId == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "warp target map is unavailable: "
        .. tostring(target.map)
        .. (loadErr and (" (" .. tostring(loadErr) .. ")") or ""),
      { map = target.map }
    )
  end
  destination = destination --[[@as table]]
  local origin = destination.coordinateOrigin --[[@as { x: integer, z: integer }]]
  if origin == nil or origin.x == nil or origin.z == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "warp destination has no coordinate origin: " .. tostring(target.map),
      { map = target.map }
    )
  end
  origin = origin --[[@as { x: integer, z: integer }]]
  local warpId = target.warp or 0
  local warp = {
    index = warpId,
    x = origin.x + target.fieldX,
    z = origin.z + target.fieldZ,
    destinationMapId = destination.mapId,
    destinationWarpId = warpId,
    direct = true,
  }
  self.pendingWarp = warp
  self._error = nil
  -- A scripted warp carries no trigger classification: it is a plain fade
  -- record ({ kind = nil, warp = warp }), never a door or stair choreography.
  local trigger = { warp = warp }
  if self._screen ~= nil then
    -- Source `Warp` owns no fade of its own: the source-authored
    -- FadeScreen/WaitFade already owns visual cover, so the covered swap
    -- must not synthesize a second ordinary fade pair. A source path that
    -- reaches the warp without opaque cover is a script sequencing fault,
    -- not a silently-inserted fade.
    assert(self._screen:isOpaque(), "a covered scripted swap requires the screen cover to be fully opaque")
    self._transition:startCoveredSwap(self._sourceMap, trigger, target.facing)
  else
    self._transition:start(self._sourceMap, trigger, target.facing)
  end
end

-- Record the source special-spawn location (opcode 582): a named semantic
-- setter, never a hidden side effect folded into the lowering. Full
-- LocalFieldData persistence is out of scope; this state is only observable
-- through `specialSpawn()`.
---@param spawn { map: unknown, fieldX: integer, fieldZ: integer, warpId: integer, direction: string }
function ScriptMapsService:setSpecialSpawn(spawn)
  self._specialSpawn = spawn
end

-- The recorded special-spawn location, or nil before the source setter ran.
---@return table<string, unknown>|nil
function ScriptMapsService:specialSpawn()
  return self._specialSpawn
end

-- True when the started warp has run its course: the application consumed
-- the finished swap and the transition returned to idle (or faulted). A
-- transition failure is captured so the warp task can fault its script.
---@return boolean
function ScriptMapsService:warpDone()
  if self.pendingWarp == nil then
    return false
  end
  local transition = self._transition
  if transition.error ~= nil then
    self._error = transition.error
    self.pendingWarp = nil
    return true
  end
  if transition.phase == FieldTransition.PHASES.idle and transition.sourceMap == nil then
    self.pendingWarp = nil
    return true
  end
  return false
end

-- The captured failure of the pending warp, or nil on success. The warp task
-- converts it into a faulted task result.
---@return unknown|nil
function ScriptMapsService:pendingError()
  return self._error
end

return ScriptMapsService
