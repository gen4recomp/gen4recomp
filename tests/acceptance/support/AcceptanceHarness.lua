-- Production-composed, non-rendering field acceptance harness. It owns an
-- isolated save namespace and a temporary graphics trap around each runtime,
-- while FieldRuntime remains the sole owner of maps, scripts, actors, and saves.

local SaveFs = require("libs.storage.src.SaveFs")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local App = require("app.src.App")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local LocalClock = require("game.src.LocalClock")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RecordingScriptHosts = require("tests.acceptance.support.RecordingScriptHosts")
local AcceptanceScriptFs = require("tests.acceptance.support.AcceptanceScriptFs")
local RepoFs = require("game.src.RepoFs")
local FieldMovement = require("tests.acceptance.support.FieldMovement")

---@class AcceptanceHarness
---@field versions string[]
---@field runtimeFactory fun(game: table, runtimeOptions: table|nil): table
---@field gameFactory fun(versionId: string, map: string|integer|nil): table
---@field saveNamespace fun(versionId: string, serial: integer): string
---@field removeSaveNamespace fun(namespace: string)
---@field primaryVersion fun(self: AcceptanceHarness): string
---@field defaultVersion fun(): string
local AcceptanceHarness = {}
AcceptanceHarness.__index = AcceptanceHarness

local serial = 0
local TRACE_LIMIT = 32

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function defaultNamespace(versionId, index)
  return string.format("acceptance/%s/%d", versionId, index)
end

-- `love.filesystem.remove` only removes a file or an already-empty directory,
-- so a shallow call silently leaves every namespace's catalog/games files
-- behind on disk. Across process runs the numeric save-namespace serial
-- restarts at 1, so a left-behind namespace directory is silently reused by
-- the next run and its stale catalog corrupts save-cardinality assertions
-- (an old run's higher-numbered save records reappear as if freshly
-- published). Recurse depth-first so every acceptance boot leaves a
-- genuinely empty namespace behind.
local function removeNamespace(path)
  local fs = love.filesystem
  local info = fs.getInfo(path)
  if info == nil then
    return
  end
  if info.type == "directory" then
    for _, item in ipairs(fs.getDirectoryItems(path)) do
      removeNamespace(path .. "/" .. item)
    end
  end
  fs.remove(path)
end

-- Acceptance owns the save-root host boundary: every SaveFs path below the
-- normal `saves/<versionId>/` root is remapped into the per-boot acceptance
-- namespace, so an acceptance run can never touch the user's real saves and
-- the production SaveFs constructor needs no test-only rooting mode. The
-- wrapper also injects one scoped write or read failure without changing the
-- runtime's real save composition.
local function saveBackend(faults, lifecycle, namespace, versionId)
  local fs = love.filesystem
  local function remap(path)
    local versionPrefix = "saves/" .. versionId .. "/"
    local rest
    if path:sub(1, #versionPrefix) == versionPrefix then
      rest = "version/" .. path:sub(#versionPrefix + 1)
    else
      rest = "global/" .. path:gsub("^saves/", "")
    end
    local remapped = namespace .. "/" .. rest:gsub("^/", "")
    return (remapped:gsub("/$", ""))
  end
  return {
    write = function(_, path, data)
      lifecycle.saveWrites = lifecycle.saveWrites + 1
      if faults.failWrite then
        faults.failWrite = false
        return false, "acceptance injected save write failure"
      end
      return fs.write(remap(path), data)
    end,
    read = function(_, path)
      lifecycle.saveReads = lifecycle.saveReads + 1
      if faults.failRead then
        faults.failRead = false
        return nil, "acceptance injected save read failure"
      end
      return fs.read(remap(path))
    end,
    getInfo = function(_, path)
      return fs.getInfo(remap(path))
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(remap(path))
    end,
    remove = function(_, path)
      return fs.remove(remap(path))
    end,
    replace = function(_, sourcePath, destinationPath)
      return os.rename(
        fs.getSaveDirectory() .. "/" .. remap(sourcePath),
        fs.getSaveDirectory() .. "/" .. remap(destinationPath)
      )
    end,
  }
end

-- The render trap wraps process-global graphics functions, so it cannot be
-- owned per game: a second boot while a first game is live would capture the
-- first game's trapped functions as its "originals", and closing in the wrong
-- order would leave the namespace trapped forever. The real functions are
-- therefore captured once per process and restored by the first close; any
-- boot/close sequence leaves the namespace untrapped.
local TRAPPED_FUNCTIONS = { "newShader", "newCanvas", "newImage", "newMesh", "newQuad", "draw" }
local graphicsOriginals = nil

local function installRenderTrap()
  local graphics = love and love.graphics
  if not graphics then
    return { attempts = 0, restore = function() end }
  end
  if graphicsOriginals == nil then
    graphicsOriginals = {}
    for _, name in ipairs(TRAPPED_FUNCTIONS) do
      graphicsOriginals[name] = graphics[name]
    end
  end
  local trap = { attempts = 0 }
  for _, name in ipairs(TRAPPED_FUNCTIONS) do
    graphics[name] = function()
      trap.attempts = trap.attempts + 1
      error("acceptance runtime attempted love.graphics." .. name, 2)
    end
  end
  function trap:restore()
    if graphicsOriginals == nil then
      return
    end
    for name, value in pairs(graphicsOriginals) do
      graphics[name] = value
    end
    graphicsOriginals = nil
  end
  return trap
end

local function abortBoot(runtime, trap, removeSaveNamespace, namespace)
  local disposeErr
  if runtime then
    local ok, err = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      disposeErr = err
    end
  end
  trap:restore()
  removeSaveNamespace(namespace)
  if disposeErr then
    error(disposeErr, 0)
  end
end

---@class AcceptanceGame
---@field runtime FieldRuntime
---@field saveNamespace string
---@field removeSaveNamespace fun(path: string)
---@field trap table
---@field timeline table[]
---@field hosts table
---@field closed boolean?
---@field runtimeDisposed boolean?
---@field disposeErr any
---@field lifecycle { saveWrites: integer, saveReads: integer, runtimeDisposals: integer }
---@field worldProbe { flags: table<integer, boolean>, variables: table<integer, integer> }
---@field faults { failWrite: boolean?, failRead: boolean? }
---@field harness AcceptanceHarness
---@field versionId string
---@field map string|integer|nil
---@field waitForFieldEntry fun(self: AcceptanceGame): table
---@field fieldOptions table|nil
---@field saveStatus string?
---@field ownsNamespace boolean
---@field hostEvents fun(self: AcceptanceGame): table
local Game = {}
Game.__index = Game

function AcceptanceHarness:_newRuntime(game, namespace, faults, lifecycle, fieldOptions, reserveSave)
  local versionId = assert(game.versionId, "acceptance game version required")
  local runtimeOptions = {}
  for key, value in pairs(fieldOptions or {}) do
    runtimeOptions[key] = value
  end
  runtimeOptions.localClock = runtimeOptions.localClock
    or LocalClock.new(function()
      return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
    end)
  runtimeOptions.saveFs = SaveFs.forVersion(versionId, saveBackend(faults, lifecycle, namespace, versionId))
  if fieldOptions and fieldOptions.acceptanceScripts ~= nil then
    runtimeOptions.overrideFs =
      AcceptanceScriptFs.new(RepoFs.new(love.filesystem.getSourceBaseDirectory()), fieldOptions.acceptanceScripts)
  end
  if fieldOptions == nil or fieldOptions.saveStore ~= false then
    ---@type { reserve: fun(self: table): string }
    local saveStore = GameSaveStore.new(SaveFs.global(saveBackend(faults, lifecycle, namespace, versionId)))
    runtimeOptions.saveStore = saveStore
    if reserveSave and game.schema == nil then
      local reservedSaveId = saveStore:reserve()
      game.saveId = reservedSaveId
    end
  end
  if fieldOptions and fieldOptions.recordingScriptHosts == true then
    runtimeOptions.scriptHosts = RecordingScriptHosts.new({ audio = fieldOptions.audioHost ~= "production" })
  end
  if fieldOptions and fieldOptions.acceptanceScripts then
    runtimeOptions.overrideFs =
      AcceptanceScriptFs.new(RepoFs.new(love.filesystem.getSourceBaseDirectory()), fieldOptions.acceptanceScripts)
  end
  return self.runtimeFactory(game, runtimeOptions)
end

local function gameFor(
  harness,
  runtime,
  namespace,
  trap,
  versionId,
  map,
  fieldOptions,
  faults,
  lifecycle,
  ownsNamespace
)
  return setmetatable({
    runtime = runtime,
    saveNamespace = namespace,
    removeSaveNamespace = harness.removeSaveNamespace,
    trap = trap,
    timeline = {},
    hosts = runtime.scriptHosts or {},
    lifecycle = lifecycle,
    worldProbe = { flags = {}, variables = {} },
    faults = faults,
    harness = harness,
    map = map,
    fieldOptions = fieldOptions,
    versionId = versionId,
    saveStatus = runtime.saveStatus,
    ownsNamespace = ownsNamespace,
  }, Game)
end

function Game:_disposeRuntime()
  if self.runtimeDisposed then
    return
  end
  self.runtimeDisposed = true
  local runtime = self.runtime
  if not runtime then
    return
  end
  self.lifecycle.runtimeDisposals = self.lifecycle.runtimeDisposals + 1
  local ok, err = pcall(function()
    runtime:dispose()
  end)
  self.saveStatus = runtime.saveStatus or self.saveStatus
  if not ok then
    self.disposeErr = err
  end
end

function Game:restart(options)
  options = options or {}
  local game = assert(self.runtime:captureGameSave(), "acceptance restart requires a stable captured game")
  self:_disposeRuntime()
  if self.disposeErr then
    error(self.disposeErr, 0)
  end
  local previousSaveStatus = self.saveStatus
  local ok, runtime = pcall(
    self.harness._newRuntime,
    self.harness,
    game,
    self.saveNamespace,
    self.faults,
    self.lifecycle,
    self.fieldOptions,
    false
  )
  if not ok then
    error(runtime, 0)
  end
  assert(
    runtime and type(runtime.captureGameSave) == "function",
    "acceptance restart runtime boot failed: " .. tostring(runtime and runtime.errorText)
  )
  self.runtime = runtime --[[@as FieldRuntime]]
  self.map = options.map or self.map
  self.hosts = runtime.scriptHosts or {}
  self.runtimeDisposed = false
  self.disposeErr = nil
  self.saveStatus = previousSaveStatus and previousSaveStatus:find("Save failed:", 1, true) and previousSaveStatus
    or runtime.saveStatus
  return self
end

function Game:snapshot()
  local runtime = self.runtime
  local player = runtime.player or {}
  local camera = runtime.camera
  local dialogue = runtime.dialogue
  local scheduler = runtime.scripts and runtime.scripts.scheduler
  local actors, occupancy = {}, {}
  if runtime.actors and runtime.runtimeMap then
    for _, actor in ipairs(runtime.actors:actorsOf(runtime.runtimeMap.mapId)) do
      actors[actor.actorId] = {
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        surfaceId = actor.surfaceId,
        facing = actor.facing,
      }
      if actor.solid then
        occupancy[actor.fieldX .. ":" .. actor.fieldZ] = actor.actorId
      end
    end
  end
  local appHostStatus = runtime.applicationHost and runtime.applicationHost:status() or {}
  return {
    versionId = runtime.versionId,
    mapId = runtime.runtimeMap and runtime.runtimeMap.mapId,
    mapSymbol = runtime.runtimeMap and runtime.runtimeMap.mapSymbol,
    tick = runtime.session and runtime.session.tick,
    player = {
      fieldX = player.fieldX,
      fieldZ = player.fieldZ,
      localX = player.localX,
      localZ = player.localZ,
      worldX = player.worldX,
      worldY = player.worldY,
      worldZ = player.worldZ,
      previousWorldX = player.previousWorldX,
      previousWorldY = player.previousWorldY,
      previousWorldZ = player.previousWorldZ,
      surfaceId = player.surfaceId,
      facing = player.facing,
      motion = player.motion,
    },
    camera = camera and {
      sourceTarget = {
        x = camera.sourceTarget.x,
        y = camera.sourceTarget.y,
        z = camera.sourceTarget.z,
      },
      target = { x = camera.target.x, y = camera.target.y, z = camera.target.z },
      previousTarget = { x = camera.previousTarget.x, y = camera.previousTarget.y, z = camera.previousTarget.z },
      eye = { x = camera.eye.x, y = camera.eye.y, z = camera.eye.z },
      previousEye = { x = camera.previousEye.x, y = camera.previousEye.y, z = camera.previousEye.z },
    } or nil,
    playerVisual = runtime.playerVisual and runtime.playerVisual:status() or nil,
    dialogue = dialogue and dialogue:status() or { modal = false },
    menu = appHostStatus.menu or (runtime.menuHost and runtime.menuHost:snapshot()) or nil,
    -- Combined ownership (explicit lock OR field-interaction claim), not
    -- explicit lock alone: an interaction root such as the New Bark -> Elm
    -- Lab route owns the field without ever executing LOCK_PLAYER/LockAll.
    fieldLocked = scheduler and scheduler:playerInputOwned() or false,
    mapEntryStage = runtime.session and runtime.session.mapEntryStage,
    foregroundScript = scheduler and scheduler:foregroundScriptId(),
    transition = { phase = runtime.transition and runtime.transition.phase },
    -- The production script screen-fade controller (fade_screen/wait_fade),
    -- distinct from the ordinary FieldTransition fade. Synthetic
    -- harness-mechanics fakes (game/hgss/tests/acceptance_harness_self_test.lua)
    -- do not model it; a real FieldRuntime always does.
    screenFade = runtime.screenFade and runtime.screenFade:status() or nil,
    avatarId = runtime.avatar and runtime.avatar.id,
    coverage = runtime.runtimeMap and runtime.runtimeMap.coverage and runtime.runtimeMap.coverage:status() or nil,
    zoneChange = runtime.lastZoneChange and {
      oldMapId = runtime.lastZoneChange.oldMapId,
      newMapId = runtime.lastZoneChange.newMapId,
      mapSectionChanged = runtime.lastZoneChange.mapSectionChanged,
    } or nil,
    terrainEffects = runtime.fieldTerrainEffectController and runtime.fieldTerrainEffectController:status() or nil,
    world = self.worldProbe,
    actors = actors,
    occupancy = occupancy,
  }
end

function Game:save()
  assert(self.runtime:captureGameSave(), "acceptance save requires a stable captured game")
  return self:snapshot()
end

function Game:warpDestination(warpIndex)
  assert(type(warpIndex) == "number", "acceptance warp index required")
  local warps = assert(self.runtime.runtimeMap.fieldData.events.warps, "production warp data is required")
  local warp = assert(warps[warpIndex + 1], "acceptance warp index is unavailable")
  return {
    fieldX = warp.x or warp.fieldX,
    fieldZ = warp.z or warp.fieldZ,
    mapId = warp.destinationMapId,
    warpId = warp.destinationWarpId,
  }
end

function Game:actor(actorId)
  assert(type(actorId) == "string", "acceptance actor id required")
  return self:snapshot().actors[actorId]
end

function Game:setWorldState(change)
  assert(type(change) == "table", "acceptance world-state change required")
  local world = assert(self.runtime.scripts and self.runtime.scripts.worldState, "field world state unavailable")
  if change.flag ~= nil then
    world:setFlag(change.flag)
    self.worldProbe.flags[change.flag] = true
  end
  if change.value ~= nil then
    assert(change.variable ~= nil, "acceptance world-state value requires a variable id")
    world:setVar(change.variable, change.value)
    self.worldProbe.variables[change.variable] = change.value
  end
end

function Game:setActorRemovalFlag(actorId)
  assert(type(actorId) == "string", "acceptance actor id required")
  local actor = assert(self.runtime.actors:getById(actorId), "actor is not visible: " .. actorId)
  local eventFlag = assert(actor.sourceEvent.eventFlag, "actor has no removal flag")
  assert(eventFlag ~= 0, "actor has no removal flag")
  self.runtime.eventState:setFlag(eventFlag)
end

function Game:failNextSave()
  self.faults.failWrite = true
end

function Game:failNextRead()
  self.faults.failRead = true
end

local function interactionFor(runtime)
  local player = runtime.player
  if not player or not runtime.interactionResolver then
    return nil
  end
  return runtime.interactionResolver:resolve({
    runtimeMap = runtime.runtimeMap,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    surfaceId = player.surfaceId,
    worldY = player.worldY,
    facing = player.facing,
    tick = runtime.session and runtime.session.tick + 1 or 0,
  })
end

function Game:interaction()
  local interaction = self.lastInteraction or {}
  local actor = interaction.actorId and self.runtime.actors:getById(interaction.actorId) or nil
  return {
    kind = interaction.kind,
    actorId = interaction.actorId,
    scriptId = interaction.scriptId,
    scriptSource = interaction.scriptSource,
    actorFacing = actor and actor.facing or nil,
    actorFacingOverride = actor and actor.interactionFacingOverride or nil,
  }
end

function Game:pressAction()
  local runtime = self.runtime
  local intent = interactionFor(runtime)
  local interaction = { kind = intent and intent.kind }
  if intent and intent.object then
    interaction.actorId = intent.object.actorId
  end
  local hit = intent and runtime.scripts.client:resolve(intent) or nil
  if hit then
    interaction.scriptId = hit.trigger.scriptId
    interaction.scriptSource = "vanilla"
    for _, entry in ipairs(hit.composed.entries) do
      if entry.operation == "override" or (entry.script.metadata and entry.script.metadata.override) then
        interaction.scriptSource = "override"
      end
    end
  end
  self.lastInteraction = interaction
  runtime:pressAction()
  self:step()
  runtime:releaseAction()
  return self:snapshot()
end

function Game:advanceDialogue()
  local confirmed = false
  for _ = 1, 480 do
    local snapshot = self:snapshot()
    if not snapshot.dialogue.modal and not snapshot.fieldLocked then
      break
    end
    self.runtime:pressAction()
    self:step()
    self.runtime:releaseAction()
    confirmed = true
  end
  local final = self:snapshot()
  assert(not final.dialogue.modal and not final.fieldLocked, "dialogue did not close after semantic confirm edges")
  return { confirmed = confirmed, snapshot = self:snapshot() }
end

function Game:hostEffects()
  assert(
    self.hosts.effects,
    "recording hosts are disabled; boot with fieldOptions.recordingScriptHosts = true to inspect host effects"
  )
  return self.hosts.effects
end

function Game:hostEvents()
  assert(
    self.hosts.events,
    "recording hosts are disabled; boot with fieldOptions.recordingScriptHosts = true to inspect host events"
  )
  return self.hosts.events
end

-- Start a real ROM-derived script through the production FieldScripts
-- composition and scheduler. Acceptance uses this only for scripts without a
-- map binding; it never supplies a synthetic graph or substitutes services.
function Game:startScript(scriptId)
  assert(type(scriptId) == "string", "acceptance script id required")
  local scripts = assert(self.runtime.scripts, "field scripts unavailable")
  local composed = assert(scripts.composition:effective(scriptId), "generated script is unavailable: " .. scriptId)
  local instanceId = scripts.scheduler:startInteraction(
    { kind = "acceptance", scriptId = scriptId },
    composed,
    assert(self.runtime.session, "field session unavailable").tick,
    true
  )
  assert(instanceId, "foreground script already owns the field")
  self:_record()
  return self:snapshot()
end

-- The runtime owns this logical status even when its presentation option is
-- false, which is the non-rendering acceptance composition.
function Game:auxiliaryUiStatus()
  local auxiliary = assert(self.runtime.auxiliaryFieldUi, "field runtime does not expose auxiliary field UI")
  return auxiliary:status()
end

-- Context choices are a distinct script-owned flow. This narrow test adapter
-- observes the production provider without constructing a menu or script host.
function Game:contextChoiceStatus()
  local provider = self.runtime.contextChoiceProvider
  return provider and provider:status() or nil
end

function Game:failForegroundScript(scriptId)
  assert(type(scriptId) == "string", "foreground script id required")
  local runtime = self.runtime
  if scriptId == "elms_lab.elm" then
    self:moveTo({ fieldX = 6, fieldZ = 6 })
    self:face("north")
  end
  self:pressAction()
  assert(self.lastInteraction.scriptId == scriptId, "foreground script does not match interaction")
  local scheduler = runtime.scripts.scheduler
  local environmentId = assert(scheduler:foregroundEnvironmentId(), "foreground script did not start")
  scheduler:cancelEnvironment(environmentId, "acceptance injected failure for " .. scriptId)
  return { error = "acceptance injected failure for " .. scriptId }
end

function Game:_record()
  local snapshot = self:snapshot()
  if self.lastSnapshot and self.lastSnapshot.mapId ~= snapshot.mapId and not self.lastTransition then
    self.lastTransition = { source = self.lastSnapshot, destination = snapshot }
  end
  self.lastSnapshot = snapshot
  self.timeline[#self.timeline + 1] = snapshot
  if #self.timeline > TRACE_LIMIT then
    table.remove(self.timeline, 1)
  end
end

function Game:trace()
  return self.timeline
end

function Game:step(input)
  if input and input.direction then
    self.runtime:press(input.direction)
  end
  self.runtime:update((self.runtime.session and self.runtime.session.FIXED_DT) or (1 / 30))
  if input and input.direction then
    self.runtime:release(input.direction)
  end
  self:_record()
  return self:snapshot()
end

function Game:move(direction)
  self:step({ direction = direction })
end

-- Drive one production movement step and wait for the step to resolve.
-- `expected`, when given, is the production-resolved destination the caller
-- already asked `FieldMovement.route` for. Returns `snapshot, matched`
-- rather than asserting: a route is planned once against a point-in-time
-- read of live actor occupancy (`FieldMovement.route`'s own contract says as
-- much), so a wandering actor stepping onto a planned tile between planning
-- and arrival is an expected, real possibility, not a corrupt plan -- the
-- caller decides whether to replan rather than this treating it as fatal. A
-- turn-in-place (facing changed, coordinates unchanged) is never `matched`.
function Game:_moveOne(direction, expected)
  self:move(direction)
  local after = self:advanceUntil("movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  if not expected then
    return after, true
  end
  local matched = after.player.fieldX == expected.fieldX and after.player.fieldZ == expected.fieldZ
  if matched and expected.surfaceId ~= nil then
    matched = after.player.surfaceId == expected.surfaceId
  end
  return after, matched
end

-- Drives one planned edge: a direction the route planner named is only ever
-- a walkable step, but HGSS input still turns in place before it walks
-- whenever the pressed direction is not the player's current facing.
-- `face()` settles that turn instantly (the same domain operation a
-- script's `turn` performs), so `_moveOne` always observes real production
-- arrival, never a turn-in-place standing in for it.
function Game:_driveStep(direction, expected)
  if self:snapshot().player.facing ~= direction then
    self:face(direction)
  end
  return self:_moveOne(direction, expected)
end

-- Plans and drives a route to `target` through production movement
-- resolution only (`FieldMovement.route`, backed by
-- `FieldPlayer:resolveStep`): map collision, terrain/surface, and live actor
-- occupancy. `stopMapId`, when given, returns as soon as a seamless
-- logical-zone change lands the player on that map, without requiring the
-- literal target coordinate to be reached inside it.
--
-- Two situations invalidate a planned route mid-drive, and both are
-- resolved the same way -- replan from wherever the player actually is now,
-- up to a bounded number of attempts (a target that stays unreachable after
-- that many replans is a real routing failure, not a slow one):
-- - A target beyond the resident physical-coverage region cannot be planned
--   in one pass (`FieldMovement.route` returns a `boundary` instead): only a
--   real committed step, followed by the engine's own
--   `FieldNavigationBoundary:afterCommittedMove` recenter, resolves the next
--   region, so this drives up to the edge and takes that one crossing step
--   for real before replanning the remainder.
-- - A planned edge can land somewhere other than the plan expected if a
--   live actor the plan assumed stationary has since moved onto it; the
--   route was correct when it was drawn, so this just re-asks for a fresh
--   one from the player's real, current position.
function Game:moveTo(target, stopMapId)
  assert(type(target) == "table", "movement target required")
  assert(type(target.fieldX) == "number" and type(target.fieldZ) == "number", "integer field target required")
  if target.surfaceId ~= nil then
    assert(type(target.surfaceId) == "number" and target.surfaceId % 1 == 0, "target surfaceId must be an integer")
  end
  self:waitForFieldEntry()
  local targetLabel = target.fieldX .. ":" .. target.fieldZ
  if target.surfaceId ~= nil then
    targetLabel = targetLabel .. ":" .. target.surfaceId
  end
  for _ = 1, 20 do
    local route, boundary = FieldMovement.route(self, target)
    if route then
      local blocked = false
      for _, step in ipairs(route) do
        local snapshot, matched = self:_driveStep(step.direction, step)
        if not matched then
          blocked = true
          break
        end
        if stopMapId ~= nil and snapshot.mapId == stopMapId then
          return snapshot
        end
      end
      if not blocked then
        return self:snapshot()
      end
    else
      assert(boundary, "no production movement route to " .. targetLabel)
      local blocked = false
      for _, step in ipairs(boundary.route) do
        local snapshot, matched = self:_driveStep(step.direction, step)
        if not matched then
          blocked = true
          break
        end
        if stopMapId ~= nil and snapshot.mapId == stopMapId then
          return snapshot
        end
      end
      if not blocked then
        -- The crossing step's destination is only resolved by the real
        -- recenter it triggers, so it cannot be asserted against an
        -- expected coordinate the way a within-region step can.
        local snapshot = self:_driveStep(boundary.direction)
        if stopMapId ~= nil and snapshot.mapId == stopMapId then
          return snapshot
        end
      end
    end
  end
  error("moveTo could not resolve a route to " .. targetLabel .. " after repeated replans")
end

function Game:moveUntilBlocked(direction)
  local before = self:snapshot()
  self:_moveOne(direction)
  local after = self:snapshot()
  assert(
    after.player.fieldX == before.player.fieldX and after.player.fieldZ == before.player.fieldZ,
    "expected production movement to be blocked"
  )
  return after
end

-- Turn-only facing setup: uses the public `FieldPlayer:turn` domain
-- operation (the same facing-only mutation the script `turn` service
-- performs), so it can never walk into an adjacent tile.
function Game:face(direction)
  self:advanceUntil("prior movement resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  local before = self:snapshot()
  self.runtime.player:turn(direction)
  local after = self:snapshot()
  assert(after.player.facing == direction, "face() must change facing to " .. direction)
  assert(
    after.player.fieldX == before.player.fieldX
      and after.player.fieldZ == before.player.fieldZ
      and after.player.surfaceId == before.player.surfaceId,
    "face() must not change field coordinates or surface"
  )
  return after
end

-- Map-swap boundary: returns as soon as the destination map identity first
-- changes. Half-transition state (fade still running, door choreography
-- still mid-egress) may still be in effect; only a test intentionally
-- inspecting that in-progress state should use this instead of
-- `waitForTransition`.
function Game:waitForMapSwap()
  local source = self.lastTransition and self.lastTransition.source or self:snapshot()
  local destination = self:advanceUntil("map swap", function(snapshot)
    return snapshot.mapId ~= source.mapId
  end, 480)
  return { source = source, destination = destination }
end

-- Transition-completion boundary: the destination has swapped and
-- `FieldTransition` itself is idle (not merely "field not locked" -- the
-- scheduler's foreground-script lock is a separate concept a destination
-- on-transition/on-resume lifecycle script may still legitimately hold).
-- This never drives dialogue: an unrelated destination lifecycle owning the
-- field is a fact this boundary observes, not one it resolves.
function Game:waitForTransition()
  local source = self.lastTransition and self.lastTransition.source or self:snapshot()
  local destination = self:advanceUntil("transition completes", function(snapshot)
    return snapshot.mapId ~= source.mapId and snapshot.transition.phase == "idle"
  end, 480)
  if self.runtime.camera and self.runtime.camera.collapseRenderInterpolation then
    self.runtime.camera:collapseRenderInterpolation()
  end
  self.lastTransition = nil
  return { source = source, destination = destination }
end

-- Field-readiness boundary: the transition is settled, map-entry staging is
-- complete, no foreground script/modal owns the field, and ordinary player
-- input can proceed. This observes only; a caller whose scenario requires
-- driving destination dialogue or seeding source progression to reach this
-- boundary does so explicitly before/after calling it. A caller that only
-- wants that diagnosis without waiting may pass `maxTicks = 0`.
function Game:waitForFieldReady(maxTicks)
  return self:advanceUntil("field ready for ordinary input", function(snapshot)
    return snapshot.transition.phase == "idle"
      and snapshot.mapEntryStage == nil
      and not snapshot.fieldLocked
      and not snapshot.dialogue.modal
  end, maxTicks or 480)
end

function Game:ownership()
  local runtime = self.runtime
  local mapProtections = 0
  local mapProtectedIds = {}
  for mapId in pairs(runtime.mapLoader.protectedMaps) do
    mapProtections = mapProtections + 1
    mapProtectedIds[#mapProtectedIds + 1] = mapId
  end
  table.sort(mapProtectedIds)
  local activeActorMaps = 0
  for _ in pairs(runtime.actors.maps) do
    activeActorMaps = activeActorMaps + 1
  end
  return {
    mapProtections = mapProtections,
    mapProtectedIds = mapProtectedIds,
    activeActorMaps = activeActorMaps,
    sessionReferences = runtime.session and 1 or 0,
  }
end

function Game:advanceUntil(label, predicate, maxTicks)
  assert(type(label) == "string" and label ~= "", "advanceUntil label required")
  assert(type(predicate) == "function", "advanceUntil predicate required")
  assert(
    type(maxTicks) == "number" and maxTicks >= 0 and maxTicks < math.huge and maxTicks == math.floor(maxTicks),
    "advanceUntil maxTicks must be a finite non-negative integer"
  )
  for _ = 0, maxTicks do
    local snapshot = self:snapshot()
    if predicate(snapshot) then
      return snapshot
    end
    if _ < maxTicks then
      self:step()
    end
  end
  error(
    "timed out waiting for "
      .. label
      .. "; trace="
      .. tostring(#self.timeline)
      .. " snapshots; last tick="
      .. tostring(self:snapshot().tick)
      .. "; state="
      .. tostring(self:snapshot().mapSymbol)
      .. ":"
      .. tostring(self:snapshot().player.fieldX)
      .. ","
      .. tostring(self:snapshot().player.fieldZ)
      .. "/"
      .. tostring(self:snapshot().player.facing)
      .. ":"
      .. tostring(self:snapshot().player.motion)
      .. ", transition="
      .. tostring(self:snapshot().transition.phase)
      .. ", locked="
      .. tostring(self:snapshot().fieldLocked)
      .. ", entry="
      .. tostring(self:snapshot().mapEntryStage)
      .. ", foreground="
      .. tostring(self:snapshot().foregroundScript)
      .. ", dialogueModal="
      .. tostring(self:snapshot().dialogue.modal),
    2
  )
end

-- Named host-event records (`hostEvents()` payloads), in emission order.
-- Requires recording hosts (`fieldOptions.recordingScriptHosts = true`).
function Game:recordsNamed(name)
  assert(type(name) == "string", "acceptance record name required")
  local records = {}
  for _, record in ipairs(self:hostEvents().records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

-- Records for one canonical script identity, filtering by exact `scriptId`
-- rather than total activity, so an unrelated startup/lifecycle script start
-- cannot be mistaken for the trigger under test.
function Game:recordsForScript(scriptId, name)
  assert(type(scriptId) == "string", "acceptance script id required")
  local records = {}
  for _, record in ipairs(self:recordsNamed(name or "script.started")) do
    if record.payload and record.payload.scriptId == scriptId then
      records[#records + 1] = record
    end
  end
  return records
end

-- Production input must start only after the map-entry lifecycle reaches its
-- settled boundary. The runtime intentionally returns before that lifecycle
-- finishes, so callers that drive a field flow use this semantic wait rather
-- than assuming a fixed number of setup ticks.
function Game:waitForFieldEntry()
  return self:advanceUntil("field entry ready for production input", function()
    return self.runtime.session.mapEntryStage == nil
  end, 120)
end

function Game:renderAttempts()
  return self.trap.attempts
end

function Game:replay(inputs, options)
  assert(type(inputs) == "table", "acceptance replay inputs required")
  options = options or {}
  local replay = self.harness:boot({
    versionId = self.versionId,
    map = options.map or self.map,
    save = options.save or "fresh",
  })
  local ok, result = xpcall(function()
    for _, input in ipairs(inputs) do
      if input == "action" then
        replay:pressAction()
      else
        replay:move(input)
      end
    end
    return { trace = replay:trace() }
  end, debug.traceback)
  replay:close()
  if not ok then
    error(result, 0)
  end
  return result
end

function Game:replaceApplicationState()
  local replaced = self
  local previousState = {
    dispose = function()
      replaced:_disposeRuntime()
    end,
  }
  local activeState = {}
  App.setState(previousState)
  App.setState(activeState)
  if replaced.disposeErr then
    error(replaced.disposeErr, 0)
  end

  local activeLifecycle = { saveWrites = 0, saveReads = 0, runtimeDisposals = 0 }
  local ok, runtime = pcall(
    self.harness._newRuntime,
    self.harness,
    assert(self.runtime:captureGameSave(), "application replacement requires a stable captured game"),
    self.saveNamespace,
    self.faults,
    activeLifecycle,
    self.fieldOptions
  )
  if not ok then
    App.setState(nil)
    error(runtime, 0)
  end
  assert(
    runtime and type(runtime.captureGameSave) == "function",
    "acceptance replacement runtime boot failed: " .. tostring(runtime and runtime.errorText)
  )
  local active = gameFor(
    self.harness,
    runtime,
    self.saveNamespace,
    self.trap,
    self.versionId,
    self.map,
    self.fieldOptions,
    self.faults,
    activeLifecycle,
    false
  )
  activeState.dispose = function()
    active:_disposeRuntime()
  end
  App.quit()
  if active.disposeErr then
    error(active.disposeErr, 0)
  end
  return {
    replaced = { lifecycle = replaced.lifecycle, saveStatus = replaced.saveStatus },
    active = { lifecycle = active.lifecycle, saveStatus = active.saveStatus },
  }
end

function Game:close()
  if self.closed then
    return
  end
  self:_disposeRuntime()
  self.trap:restore()
  if self.ownsNamespace then
    self.removeSaveNamespace(self.saveNamespace)
  end
  self.closed = true
  if self.disposeErr then
    error(self.disposeErr, 0)
  end
end

---@param options table|nil
---@return AcceptanceHarness
function AcceptanceHarness.new(options)
  options = options or {}
  return setmetatable({
    versions = options.versions or readyVersions(),
    runtimeFactory = options.runtimeFactory or function(game, runtimeOptions)
      return FieldRuntime.new(game, runtimeOptions)
    end,
    gameFactory = options.gameFactory or function(versionId, map)
      -- The required mons bucket resolves through the warmed version
      -- cache. Fake versions (exercised with stub runtimes that never
      -- read it) have no cache entry, so the bucket is best-effort here;
      -- a real runtime still asserts its presence loudly at boot.
      local mons = nil
      local monBucketOk, monBucket = pcall(function()
        return require("tests.support.MonBucket").emptyForVersion(versionId)
      end)
      if monBucketOk then
        mons = monBucket
      end
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = {
          mapSymbol = map or "MAP_BURNED_TOWER_1F",
          -- The rebuilt New Bark collision makes the old town fixture (6,6)
          -- blocked. This is the first passable town cell with an open route
          -- south/east in the generated map.
          fieldX = 10,
          fieldZ = 10,
          facing = "south",
        },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = mons,
      }
    end,
    saveNamespace = options.saveNamespace or defaultNamespace,
    removeSaveNamespace = options.removeSaveNamespace or removeNamespace,
  }, AcceptanceHarness)
end

function AcceptanceHarness:forEachVersion(fn)
  for _, versionId in ipairs(self.versions) do
    fn(versionId)
  end
end

---@return string
function AcceptanceHarness.defaultVersion()
  local versions = readyVersions()
  assert(#versions > 0, "acceptance harness requires a ready game version")
  return versions[1]
end

---@return string
function AcceptanceHarness:primaryVersion()
  assert(#self.versions > 0, "acceptance harness requires at least one selected version")
  return self.versions[1]
end

---@param options table
---@return AcceptanceGame
function AcceptanceHarness:boot(options)
  assert(options and type(options.versionId) == "string", "acceptance boot version required")
  serial = serial + 1
  local namespace = self.saveNamespace(options.versionId, serial)
  local trap = installRenderTrap()
  local faults = {}
  local lifecycle = { saveWrites = 0, saveReads = 0, runtimeDisposals = 0 }
  local game = self.gameFactory(options.versionId, options.map)
  local ok, runtime = pcall(self._newRuntime, self, game, namespace, faults, lifecycle, options.fieldOptions, true)
  if not ok then
    abortBoot(nil, trap, self.removeSaveNamespace, namespace)
    error("acceptance runtime boot failed: " .. tostring(runtime), 0)
  end
  if not runtime or type(runtime.captureGameSave) ~= "function" then
    local errorText = runtime and runtime.errorText
    abortBoot(runtime, trap, self.removeSaveNamespace, namespace)
    error("acceptance runtime boot failed: " .. tostring(errorText), 0)
  end
  return gameFor(
    self,
    runtime,
    namespace,
    trap,
    options.versionId,
    options.map,
    options.fieldOptions,
    faults,
    lifecycle,
    true
  )
end

function AcceptanceHarness:bootWithCorruptArtifact(versionId, artifact)
  assert(type(versionId) == "string" and type(artifact) == "string", "version and artifact required")
  local originalFactory = self.runtimeFactory
  local disposeCount = 0
  self.runtimeFactory = function()
    return {
      errorText = "required " .. artifact .. " artifact is corrupt",
      dispose = function()
        disposeCount = disposeCount + 1
      end,
    }
  end
  local ok, err = pcall(function()
    self:boot({ versionId = versionId, save = "fresh" })
  end)
  self.runtimeFactory = originalFactory
  assert(not ok, "corrupt artifact boot must fail")
  return { error = tostring(err), disposeCount = disposeCount }
end

return AcceptanceHarness
