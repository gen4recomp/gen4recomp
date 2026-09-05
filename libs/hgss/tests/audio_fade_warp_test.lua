-- Audio, fade, and warp adapter tests :
-- sound waits with completing and faulting backends, the fade task, the
-- warp task integrated with the maps service, blocking music fades, and
-- the same-tick music and camera operations. Imported fade/warp nodes have
-- stable semantics.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
local SoundWaitTask = require("libs.hgss.src.script.tasks.SoundWaitTask")
local FadeTask = require("libs.hgss.src.script.tasks.FadeTask")
local WarpTask = require("libs.hgss.src.script.tasks.WarpTask")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local FakeServices = require("tests.support.script.FakeServices")
---@cast WaitTicksTask TaskImplementation
---@cast SoundWaitTask TaskImplementation
---@cast FadeTask TaskImplementation
---@cast WarpTask TaskImplementation

local T = {}

---@class FakeAudioBackend
---@field playing table<string, boolean>
---@field music { current: string|nil }
---@field calls table[]
---@field fadeActive boolean|nil
---@field processSoundplate fun(self: FakeAudioBackend)|nil
local FakeAudioBackend = {}
FakeAudioBackend.__index = FakeAudioBackend

function FakeAudioBackend.new()
  return setmetatable(
    { playing = {}, music = {}, calls = {}, fadeActive = nil, processSoundplate = nil },
    FakeAudioBackend
  )
end

function FakeAudioBackend:play(id)
  self.playing[id] = true
  self.calls[#self.calls + 1] = { op = "play", id = id }
end

function FakeAudioBackend:stop(id)
  self.playing[id] = nil
  self.calls[#self.calls + 1] = { op = "stop", id = id }
end

function FakeAudioBackend:playMusic(id)
  self.music.current = id
  self.calls[#self.calls + 1] = { op = "playMusic", id = id }
end

function FakeAudioBackend:stopMusic(id)
  self.music.current = nil
  self.calls[#self.calls + 1] = { op = "stopMusic", id = id }
end

function FakeAudioBackend:resetMusic()
  self.calls[#self.calls + 1] = { op = "resetMusic" }
end

function FakeAudioBackend:temporaryMusic(id)
  self.calls[#self.calls + 1] = { op = "temporaryMusic", id = id }
end

function FakeAudioBackend:fadeMusicOut(spec)
  self.fadeActive = true
  self.calls[#self.calls + 1] = { op = "fadeMusicOut", spec = spec }
end

function FakeAudioBackend:fadeMusicIn(spec)
  self.fadeActive = true
  self.calls[#self.calls + 1] = { op = "fadeMusicIn", spec = spec }
end

function FakeAudioBackend:isMusicFadeActive()
  self.calls[#self.calls + 1] = { op = "isMusicFadeActive" }
  return self.fadeActive == true
end

function FakeAudioBackend:isEffectPlaying(id)
  self.calls[#self.calls + 1] = { op = "isEffectPlaying", id = id }
  return self.playing[id] == true
end

function FakeAudioBackend:isEffectWaitComplete(id)
  self.calls[#self.calls + 1] = { op = "isEffectWaitComplete", id = id }
  return self.playing[id] ~= true
end

function FakeAudioBackend:isCryFinished()
  self.calls[#self.calls + 1] = { op = "isCryFinished" }
  return self:currentCry() == nil
end

function FakeAudioBackend:isFanfarePlaying()
  self.calls[#self.calls + 1] = { op = "isFanfarePlaying" }
  return self:currentFanfare() ~= nil
end

function FakeAudioBackend:playCry(species, pattern)
  local token = "cry:" .. tostring(species)
  self.playing[token] = true
  self.calls[#self.calls + 1] = { op = "playCry", species = species, pattern = pattern }
end

function FakeAudioBackend:currentCry()
  for id in pairs(self.playing) do
    if id:sub(1, 4) == "cry:" then
      return id
    end
  end
  return nil
end

function FakeAudioBackend:playFanfare(fanfare)
  local token = "fanfare:" .. tostring(fanfare)
  self.playing[token] = true
  self.calls[#self.calls + 1] = { op = "playFanfare", fanfare = fanfare }
end

function FakeAudioBackend:currentFanfare()
  for id in pairs(self.playing) do
    if id:sub(1, 8) == "fanfare:" then
      return id
    end
  end
  return nil
end

-- Engine-owned async: sounds stop and fades finish after their catalog
-- duration.
function FakeAudioBackend:advance()
  for id in pairs(self.playing) do
    self.playing[id] = nil
  end
  self.fadeActive = nil
end

---@class FakeScreenBackend
---@field fading boolean
---@field calls table[]
local FakeScreenBackend = {}
FakeScreenBackend.__index = FakeScreenBackend

function FakeScreenBackend.new()
  return setmetatable({ fading = false, calls = {} }, FakeScreenBackend)
end

function FakeScreenBackend:startFade(spec)
  self.fading = true
  self.calls[#self.calls + 1] = { op = "startFade", spec = spec }
end

function FakeScreenBackend:advance()
  self.fading = false
end

function FakeScreenBackend:fadeDone()
  return not self.fading
end

---@class FakeCameraBackend
---@field calls table[]
local FakeCameraBackend = {}
FakeCameraBackend.__index = FakeCameraBackend

function FakeCameraBackend.new()
  return setmetatable({ calls = {} }, FakeCameraBackend)
end

function FakeCameraBackend:startShake(spec)
  self.calls[#self.calls + 1] = { op = "startShake", spec = spec }
end

---@class FakeMapsBackend
---@field warping boolean
---@field calls table[]
local FakeMapsBackend = {}
FakeMapsBackend.__index = FakeMapsBackend

function FakeMapsBackend.new()
  return setmetatable({ warping = false, calls = {} }, FakeMapsBackend)
end

function FakeMapsBackend:startWarp(target)
  self.warping = true
  self.calls[#self.calls + 1] = { op = "startWarp", target = target }
end

function FakeMapsBackend:advance()
  self.warping = false
end

function FakeMapsBackend:warpDone()
  return not self.warping
end

function FakeMapsBackend:pendingError()
  return nil
end

---@class AwsHarness
---@field services FakeServices
---@field registry Registry
---@field composition Composition
---@field taskRegistry TaskRegistry
---@field scheduler Scheduler
---@field audio FakeAudioBackend|nil
---@field camera FakeCameraBackend|nil
---@field screen FakeScreenBackend|nil
---@field maps FakeMapsBackend|nil

---@param opts table|nil
---@return AwsHarness
local function harness(opts)
  opts = opts or {}
  local services = FakeServices.new(opts)
  local audio = opts.audio and FakeAudioBackend.new() or nil
  local camera = opts.camera and FakeCameraBackend.new() or nil
  local screen = opts.screen and FakeScreenBackend.new() or nil
  local maps = opts.maps and FakeMapsBackend.new() or nil
  services.audio = audio
  services.camera = camera
  services.screen = screen
  services.maps = maps
  services.advanceAsync = function()
    if audio then
      audio:advance()
    end
    if screen then
      screen:advance()
    end
    if maps then
      maps:advance()
    end
  end
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register(WaitTicksTask.type, WaitTicksTask.version, WaitTicksTask)
  taskRegistry:register(SoundWaitTask.type, SoundWaitTask.version, SoundWaitTask)
  taskRegistry:register(FadeTask.type, FadeTask.version, FadeTask)
  taskRegistry:register(WarpTask.type, WarpTask.version, WarpTask)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    taskRegistry = taskRegistry,
    scheduler = scheduler,
    audio = audio,
    camera = camera,
    screen = screen,
    maps = maps,
  }
end

---@param h AwsHarness
---@param resource table
---@param tick integer
---@return string instanceId
local function startForeground(h, resource, tick)
  if h.registry:base(resource.id) == nil then
    h.registry:installBase(resource.id, resource, "generated")
  end
  local composed = assert(h.composition:effective(resource.id))
  return h.scheduler:createForeground(composed, nil, tick)
end

local function script(id, steps)
  return S.script({ api = 1, id = id, steps = steps })
end

-- The recorded operation of the Nth audio-service call, or nil when the
-- call never happened (used to pin polling contracts).
---@param calls table[]
---@param index integer
---@return string|nil
local function callOp(calls, index)
  local call = calls[index]
  return call and call.op or nil
end

-- 1. Sound wait with a completing backend: PlaySE at T, the wait completes
-- when the backend reports the effect finished, continuation one tick later.
T["sound wait backend completion"] = function()
  local h = harness({ audio = true })
  local resource = script("test.se", {
    S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.waitSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.audio.calls[1].op, "play")
  Assert.equal(h.audio.calls[1].id, "SEQ_SE_DP_SELECT")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  -- The engine-owned async phase ends the effect before 101's poll, which
  -- completes the wait; the successful poll must not continue the graph in
  -- its own tick.
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the successful poll must not continue the graph same tick")
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 2. A wait whose backend cannot report completion faults instead of
-- inventing a simulated duration; the faulting case needs no backend at all.
T["sound wait without backend faults"] = function()
  local h = harness({ audio = false })
  local resource = script("test.sefault", {
    S.waitSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_SERVICE_MISSING")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
end

-- 2b. The audio service contract is strict: polls return booleans, never
-- nil. A nil result is a programming fault, never a recoverable task error
-- (the tasks carry no capability-detection branches for the defined audio
-- interface).
T["sound wait polls never accept a nil result"] = function()
  local cases = {
    effect = {
      node = { op = "wait_sound", sound = "SEQ_SE_DP_SELECT" },
      audio = {
        isEffectPlaying = function()
          return false
        end,
        isEffectWaitComplete = function()
          return nil
        end,
      },
    },
    cry = {
      node = { op = "wait_cry" },
      audio = {
        isCryFinished = function()
          return nil
        end,
      },
    },
    fanfare = {
      node = { op = "wait_fanfare" },
      audio = {
        isFanfarePlaying = function()
          return nil
        end,
      },
    },
  }
  for name, case in pairs(cases) do
    local state = SoundWaitTask.create(
      { node = case.node },
      { services = { audio = case.audio }, instance = { scriptId = "probe" }, semantics = RuntimeValues }
    )
    local err = Assert.throws(function()
      SoundWaitTask.poll(state, { services = { audio = case.audio }, semantics = RuntimeValues })
    end)
    Assert.isFalse(
      Errors.is(err),
      "a nil " .. name .. " poll result is a programming fault, not a recoverable task error"
    )
  end
end

T["cry wait blocks until the cry finishes"] = function()
  local h = harness({ audio = true })
  local resource = script("test.cry", {
    S.playCry({ species = "SPECIES_CYNDAQUIL", pattern = 0 }),
    S.waitCry(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  Assert.notNil(h.audio:currentCry(), "the cry plays under its own playing key")
  -- The engine-owned async phase ends the cry before the next tick's poll.
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 3. Fade: fade_screen starts the fade same-tick; wait_fade blocks until the
-- screen backend reports completion.
T["fade and wait fade"] = function()
  local h = harness({ screen = true })
  local resource = script("test.fade", {
    S.fadeScreen({ duration = 6, speed = 1, direction = "out", color = "black" }),
    S.waitFade(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.screen.calls[1].op, "startFade")
  Assert.equal(h.screen.calls[1].spec.duration, 6)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 4. Warp: the warp task starts the transition through the maps service and
-- completes when the transition finishes; continuation follows the handoff.
T["warp task"] = function()
  local h = harness({ maps = true })
  local resource = script("test.warp", {
    S.warp({
      map = "MAP_NEW_BARK",
      warp = 0,
      fieldX = 684,
      fieldZ = 393,
      facing = "south",
    }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local target = h.maps.calls[1].target
  Assert.equal(target.map, "MAP_NEW_BARK")
  Assert.equal(target.fieldX, 684)
  Assert.equal(target.facing, "south")
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 4b. The real maps service drives a scripted warp through a colon-method
-- loader: the destination coordinates are rebased by the destination map's
-- origin, and a loader that raises for an unknown map is a re-raised fault
-- (never a silent "not found").
T["real maps service warp"] = function()
  local ScriptMapsService = require("libs.hgss.src.script.ScriptMapsService")
  local started = nil
  local loader = {}
  loader.load = function(self, symbol)
    assert(self == loader, "load is a colon method")
    if symbol == "MAP_NEW_BARK" then
      return { mapId = 60, coordinateOrigin = { x = 680, z = 390 } }
    end
    Errors.raise("FIELD_MAP_UNKNOWN", "no runtime map for " .. tostring(symbol), {})
  end
  local transition = {
    start = function(_, _, trigger, facing)
      started = { warp = trigger.warp, facing = facing }
    end,
  }
  local maps = ScriptMapsService.new({
    transition = transition,
    loader = loader,
    sourceMap = { mapId = 57 },
  })
  maps:startWarp({ map = "MAP_NEW_BARK", warp = 0, fieldX = 4, fieldZ = 3, facing = "north" })
  started = started --[[@as { warp: { destinationMapId: integer, x: integer, z: integer }, facing: string }]]
  Assert.equal(started.warp.destinationMapId, 60)
  Assert.equal(started.warp.x, 684, "destination-local x rebased by the map origin")
  Assert.equal(started.warp.z, 393)
  Assert.equal(started.facing, "north")
  Assert.isNil(maps:resolve("MAP_MISSING"))
  local maps2 = ScriptMapsService.new({
    transition = transition,
    loader = loader,
    sourceMap = { mapId = 57 },
  })
  local ok, err = pcall(maps2.startWarp, maps2, { map = "MAP_MISSING" })
  Assert.isFalse(ok)
  ---@cast err Errors.Error
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_MAP_UNKNOWN",
    "a loader fault re-raises instead of becoming a missing map"
  )
end

-- 4c. Variable-backed warp operands: map, warp id, coordinates, and facing
-- are scalar_or_value fields and must be evaluated against the world before
-- the task forwards its target to the maps service.
T["warp task evaluates variable-backed operands"] = function()
  local h = harness({ maps = true })
  local resource = script("test.warpvars", {
    S.setVar({ variable = "VAR_WARP_MAP", value = 41 }),
    S.setVar({ variable = "VAR_WARP_ID", value = 3 }),
    S.setVar({ variable = "VAR_WARP_X", value = 700 }),
    S.setVar({ variable = "VAR_WARP_Z", value = 420 }),
    S.setVar({ variable = "VAR_WARP_FACING", value = "east" }),
    S.warp({
      map = S.var("VAR_WARP_MAP"),
      warp = S.var("VAR_WARP_ID"),
      fieldX = S.var("VAR_WARP_X"),
      fieldZ = S.var("VAR_WARP_Z"),
      facing = S.var("VAR_WARP_FACING"),
    }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local target = h.maps.calls[1].target
  Assert.equal(target.map, 41, "variable-backed map resolves to its world value")
  Assert.equal(target.warp, 3)
  Assert.equal(target.fieldX, 700)
  Assert.equal(target.fieldZ, 420)
  Assert.equal(target.facing, "east")
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 4d. A malformed warp operand (an unset local) faults the owning script with
-- attribution instead of reaching the maps service arithmetic.
T["warp task faults a malformed operand"] = function()
  local h = harness({ maps = true })
  local resource = S.script({
    api = 1,
    id = "test.warpbad",
    locals = { never_set = "integer" },
    steps = {
      S.warp({
        map = "MAP_NEW_BARK",
        warp = 0,
        fieldX = S.local_("never_set"),
        fieldZ = 3,
        facing = "north",
      }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local fault = assert(h.services.events:eventFor("script.error", instanceId))
  Assert.equal(fault.code, "SCRIPT_INVALID_REFERENCE")
  Assert.equal(#h.maps.calls, 0, "the maps service must never see a malformed target")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
end

-- 4e. A failed scripted warp faults the script: the transition error is
-- reported as a faulted task result, so the graph never continues as though
-- the warp succeeded.
T["failed scripted warp faults the script"] = function()
  local ScriptMapsService = require("libs.hgss.src.script.ScriptMapsService")
  local transition = {
    phase = "idle",
    error = nil,
    sourceMap = nil,
  }
  transition.start = function(self, sourceMap, warp, _)
    self.phase = "fade_out"
    self.sourceMap = sourceMap
    self.startedWarp = warp
  end
  local loader = {
    load = function(_, symbol)
      if symbol == "MAP_NEW_BARK" then
        return { mapId = 60, coordinateOrigin = { x = 680, z = 390 } }
      end
      Errors.raise("FIELD_MAP_UNKNOWN", "no runtime map for " .. tostring(symbol), {})
    end,
  }
  local maps = ScriptMapsService.new({
    transition = transition,
    loader = loader,
    sourceMap = { mapId = 57 },
  })
  local h = harness({ maps = false })
  h.services.maps = maps
  local resource = script("test.warpfail", {
    S.warp({
      map = "MAP_NEW_BARK",
      warp = 0,
      fieldX = 4,
      fieldZ = 3,
      facing = "north",
    }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.notNil(transition.startedWarp)
  -- The destination resolution fails while the screen is black.
  transition.error = Errors.new("FIELD_DESTINATION_MAP_UNKNOWN", "destination map is unavailable", {
    sourceMapId = 57,
    destinationMapId = 60,
  })
  transition.phase = "idle"
  transition.sourceMap = nil
  h.scheduler:step(101, nil)
  local fault = assert(h.services.events:eventFor("script.error", instanceId))
  Assert.equal(fault.code, "FIELD_DESTINATION_MAP_UNKNOWN")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the script must not continue as though the warp succeeded")
end

-- 5. Music and camera operations are same-tick passthroughs (fades are
-- blocking and covered by the music fade tests below).
T["music and camera same tick"] = function()
  local h = harness({ audio = true, camera = true })
  local resource = script("test.music", {
    S.playMusic({ music = "SEQ_GS_NEW_BARK" }),
    S.stopMusic(),
    S.temporaryMusic({ music = "SEQ_GS_EVENT" }),
    S.resetMusic(),
    S.shakeCamera({ amplitudeX = 2, amplitudeY = 0, intervalTicks = 2, count = 8 }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  local ops = {}
  for _, call in ipairs(h.audio.calls) do
    ops[#ops + 1] = call.op
  end
  Assert.deepEqual(ops, { "playMusic", "stopMusic", "temporaryMusic", "resetMusic" })
  Assert.equal(h.camera.calls[1].op, "startShake")
  Assert.equal(h.camera.calls[1].spec.count, 8)
end

-- 6. A warp from a background script is forbidden.
T["background cannot warp"] = function()
  local h = harness({ maps = true })
  local resource = script("test.bgwarp", {
    S.warp({ map = "MAP_NEW_BARK", warp = 0, fieldX = 1, fieldZ = 1, facing = "north" }),
    S.stop(),
  })
  h.registry:installBase(resource.id, resource, "generated")
  local composed = assert(h.composition:effective(resource.id))
  local instanceId = h.scheduler:createBackground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_BACKGROUND_FORBIDDEN")
end

-- 7. set_object_position accepts variable-backed coordinates: the scalar_or_
-- value fields are evaluated against the world before reaching the actors.
T["set object position evaluates variable-backed coordinates"] = function()
  local h = harness()
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 5, worldY = 0, facing = "north" })
  local resource = S.script({
    api = 1,
    id = "test.objpos",
    locals = { z = "integer" },
    steps = {
      S.setVar({ variable = "VAR_X", value = 12 }),
      S.setVar({ variable = "VAR_Y", value = 2.5 }),
      S.setLocal({ name = "z", value = 7 }),
      S.setObjectPosition({
        actor = "elm",
        fieldX = S.var("VAR_X"),
        fieldZ = S.local_("z"),
        worldY = S.var("VAR_Y"),
      }),
      S.stop(),
    },
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local position = h.services.actors:getPosition("elm")
  Assert.equal(position.fieldX, 12)
  Assert.equal(position.fieldZ, 7)
  Assert.equal(position.worldY, 2.5)
end

-- 8. music fades are blocking operations. The fade node starts the fade
-- in its execution tick and blocks until the backend reports the global
-- music fade inactive; the following node runs only after the blocking
-- task's normal scheduler handoff. FadeInBGM blocks the same way.
T["music fades block until the backend reports the fade inactive"] = function()
  local h = harness({ audio = true })
  h.services.advanceAsync = nil
  local MusicFadeTask = require("libs.hgss.src.script.tasks.MusicFadeTask")
  h.taskRegistry:register("music_fade", 1, MusicFadeTask --[[@as TaskImplementation]])
  local resource = script("test.fadeblock", {
    S.fadeMusicOut({ target = 0, durationTicks = 30 }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.fadeMusicIn({ durationTicks = 30 }),
    S.setVar({ variable = "VAR_SECOND", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  -- The fade starts in the command's execution tick and blocks.
  h.scheduler:step(100, nil)
  Assert.equal(h.audio.calls[1].op, "fadeMusicOut")
  Assert.equal(h.audio.calls[1].spec.durationTicks, 30)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "fade out blocks; the following node must not run same tick")
  -- While the backend reports the fade active the graph stays blocked.
  h.scheduler:step(101, nil)
  Assert.equal(h.audio.calls[2].op, "isMusicFadeActive")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "VAR_AFTER stays unchanged while the fade is active")
  -- The fade ends; the poll completes, but continuation follows only the
  -- scheduler handoff on the next tick.
  h.audio.fadeActive = false
  h.scheduler:step(102, nil)
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    0,
    "completion during a poll must not continue the graph same tick"
  )
  h.scheduler:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "the continuation runs after the blocking task's handoff")
  -- FadeInBGM starts in its execution tick and blocks the same way.
  Assert.equal(h.audio.calls[4].op, "fadeMusicIn")
  Assert.equal(h.services.world:getVar("VAR_SECOND"), 0)
  h.scheduler:step(104, nil)
  Assert.equal(h.services.world:getVar("VAR_SECOND"), 0, "fade in blocks while active")
  h.audio.fadeActive = false
  h.scheduler:step(105, nil)
  h.scheduler:step(106, nil)
  Assert.equal(h.services.world:getVar("VAR_SECOND"), 1)
  local ops = {}
  for _, call in ipairs(h.audio.calls) do
    ops[#ops + 1] = call.op
  end
  Assert.deepEqual(ops, {
    "fadeMusicOut",
    "isMusicFadeActive",
    "isMusicFadeActive",
    "fadeMusicIn",
    "isMusicFadeActive",
    "isMusicFadeActive",
  })
end

-- 8b. A fade without an audio service faults instead of starting
-- silently: the task owns the service boundary and never fabricates a
-- completed fade.
T["music fade without backend faults"] = function()
  local h = harness({ audio = false })
  local MusicFadeTask = require("libs.hgss.src.script.tasks.MusicFadeTask")
  h.taskRegistry:register("music_fade", 1, MusicFadeTask --[[@as TaskImplementation]])
  local resource = script("test.fadefault", {
    S.fadeMusicOut({ target = 0, durationTicks = 30 }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_SERVICE_MISSING")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
end

-- 8b2. The music-fade poll follows the same strict audio contract: the
-- service's isMusicFadeActive result is boolean, so a nil result is a
-- programming fault, never a recoverable task error.
T["music fade polls never accept a nil result"] = function()
  local MusicFadeTask = require("libs.hgss.src.script.tasks.MusicFadeTask")
  local audio = {
    isMusicFadeActive = function()
      return nil
    end,
  }
  local err = Assert.throws(function()
    MusicFadeTask.poll({ op = "fade_music_out" }, { services = { audio = audio } })
  end)
  Assert.isFalse(Errors.is(err), "a nil fade poll result is a programming fault, not a recoverable task error")
end

-- 8b2. The fade task against the REAL GameSound: the fade starts in the
-- command's execution tick and the task completes exactly when the fade
-- reaches its target -- the isMusicFadeActive poll flips at the target tick,
-- never before -- for the fade-out and the fade-in path alike.
T["music fade task completes exactly when the real fade reaches its target"] = function()
  local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
  local AudioFixture = require("tests.support.AudioFixture")
  local GameSound = require("libs.hgss.src.audio.GameSound")
  local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
  local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(AudioFixture.bundle()))
  local mixer = VoiceMixer.new({ sampleRate = 48000 })
  local player = SequencePlayer.new({
    sampleRate = 48000,
    mixer = mixer,
    provider = provider,
  })
  local sound = GameSound.new({ provider = provider, player = player })
  local h = harness({ audio = false })
  h.services.audio = sound
  h.services.advanceAsync = function()
    sound:updateSoundFrame()
  end
  local MusicFadeTask = require("libs.hgss.src.script.tasks.MusicFadeTask")
  h.taskRegistry:register("music_fade", 1, MusicFadeTask --[[@as TaskImplementation]])
  local resource = script("test.fadereal", {
    S.playMusic({ music = "SEQ_TEST_A" }),
    S.fadeMusicOut({ target = 0, durationTicks = 30 }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.fadeMusicIn({ durationTicks = 20 }),
    S.setVar({ variable = "VAR_SECOND", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.isTrue(sound:isMusicFadeActive(), "the fade starts in the command's execution tick")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  for tick = 101, 129 do
    h.scheduler:step(tick, nil)
  end
  Assert.isTrue(sound:isMusicFadeActive(), "the fade still blocks before its target tick")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(130, nil)
  Assert.isFalse(sound:isMusicFadeActive(), "the fade completes at exactly its requested duration")
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    0,
    "completion during a poll must not continue the graph same tick"
  )
  h.scheduler:step(131, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "the continuation runs the tick after the fade completes")
  Assert.isTrue(sound:isMusicFadeActive(), "the fade-in starts in its execution tick")
  for tick = 132, 150 do
    h.scheduler:step(tick, nil)
  end
  Assert.isTrue(sound:isMusicFadeActive(), "the fade-in still blocks before its target tick")
  Assert.equal(h.services.world:getVar("VAR_SECOND"), 0)
  h.scheduler:step(151, nil)
  Assert.isFalse(sound:isMusicFadeActive(), "the fade-in completes at exactly its requested duration")
  h.scheduler:step(152, nil)
  Assert.equal(h.services.world:getVar("VAR_SECOND"), 1, "the fade-in continuation runs through the script layer")
end

-- 8c. wait_sound resolves a value-reference operand before the first
-- poll: the backend sees the resolved sequence id, never the reference.
T["wait sound evaluates a value reference before polling"] = function()
  local h = harness({ audio = true })
  h.services.advanceAsync = nil
  local resource = script("test.sewaitvar", {
    S.setVar({ variable = "VAR_SE", value = 1500 }),
    S.playSound({ sound = S.var("VAR_SE") }),
    S.waitSound({ sound = S.var("VAR_SE") }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(101, nil)
  Assert.equal(callOp(h.audio.calls, 2), "isEffectWaitComplete")
  Assert.equal(h.audio.calls[2].id, 1500, "the wait polls the resolved sequence")
  h.audio.playing[1500] = nil
  h.scheduler:step(102, nil)
  h.scheduler:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 9. wait_sound carries the resolved sequence and polls
-- isEffectWaitComplete(sequence); completion keeps the scheduler handoff.
T["wait sound polls the resolved sequence effect state"] = function()
  local h = harness({ audio = true })
  h.services.advanceAsync = nil
  local resource = script("test.secsem", {
    S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.waitSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  -- The wait stays blocked while the backend reports the effect playing.
  h.scheduler:step(101, nil)
  Assert.equal(callOp(h.audio.calls, 2), "isEffectWaitComplete")
  Assert.equal(h.audio.calls[2].id, "SEQ_SE_DP_SELECT")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  -- Ending the effect completes the poll; continuation follows the handoff.
  h.audio.playing["SEQ_SE_DP_SELECT"] = nil
  h.scheduler:step(102, nil)
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    0,
    "completion during a poll must not continue the graph same tick"
  )
  h.scheduler:step(103, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 10. wait_cry polls isCryFinished and wait_fanfare polls
-- isFanfarePlaying; both stay blocked until their semantic state flips.
T["cry and fanfare waits poll semantic completion states"] = function()
  local h = harness({ audio = true })
  h.services.advanceAsync = nil
  local resource = script("test.cryfan", {
    S.playCry({ species = "SPECIES_CYNDAQUIL", pattern = 0 }),
    S.waitCry(),
    S.playFanfare({ fanfare = "SEQ_ME_POKEGET" }),
    S.waitFanfare(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  -- The cry wait polls isCryFinished and blocks while the cry is active.
  h.scheduler:step(101, nil)
  Assert.equal(callOp(h.audio.calls, 2), "isCryFinished")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  -- The cry ends; the wait completes and hands off one tick later.
  h.audio.playing["cry:SPECIES_CYNDAQUIL"] = nil
  h.scheduler:step(102, nil)
  h.scheduler:step(103, nil)
  -- The fanfare plays in the promotion tick; its wait polls isFanfarePlaying
  -- from the next tick and blocks while playing.
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(104, nil)
  Assert.equal(callOp(h.audio.calls, 5), "isFanfarePlaying")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.audio.playing["fanfare:SEQ_ME_POKEGET"] = nil
  h.scheduler:step(105, nil)
  h.scheduler:step(106, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 11. the audio handlers evaluate value references before calling the
-- service, for effects, cries (both operands), and fanfares alike.
T["audio handlers evaluate value references before the service call"] = function()
  local h = harness({ audio = true })
  local resource = script("test.audioval", {
    S.setVar({ variable = "VAR_SE", value = 1500 }),
    S.setVar({ variable = "VAR_SPECIES", value = 25 }),
    S.setVar({ variable = "VAR_PATTERN", value = 1 }),
    S.setVar({ variable = "VAR_FANFARE", value = 42 }),
    S.playSound({ sound = S.var("VAR_SE") }),
    S.stopSound({ sound = S.var("VAR_SE") }),
    S.playCry({ species = S.var("VAR_SPECIES"), pattern = S.var("VAR_PATTERN") }),
    S.playFanfare({ fanfare = S.var("VAR_FANFARE") }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.audio.calls[1].id, 1500, "play_sound resolves the sequence reference")
  Assert.equal(h.audio.calls[2].id, 1500, "stop_sound resolves the sequence reference")
  Assert.equal(h.audio.calls[3].species, 25, "play_cry resolves the species reference")
  Assert.equal(h.audio.calls[3].pattern, 1, "play_cry resolves the pattern reference")
  Assert.equal(h.audio.calls[4].fanfare, 42, "play_fanfare resolves the fanfare reference")
end

T["process soundplate calls forced processing once and continues same tick"] = function()
  local h = harness({ audio = true })
  local processCalls = 0
  h.audio.processSoundplate = function(_)
    processCalls = processCalls + 1
  end
  local resource = script("test.soundplate", {
    S.processSoundplate(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(processCalls, 1, "forced soundplate must be called exactly once")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "following node must run in the same tick")
  Assert.isTrue(assert(h.services.events:eventFor("script.ended", "script-00000001")).completed)
  Assert.equal(#h.scheduler:tasks(), 0, "process_soundplate must not create a task")
end

T["consecutive process soundplate calls run twice in one tick"] = function()
  local h = harness({ audio = true })
  local processCalls = 0
  h.audio.processSoundplate = function(_)
    processCalls = processCalls + 1
  end
  local resource = script("test.double", {
    S.processSoundplate(),
    S.processSoundplate(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(processCalls, 2, "consecutive forced processing must not be coalesced")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

T["process soundplate without audio service faults with attribution"] = function()
  local h = harness({ audio = false })
  local resource = script("test.missingsoundplate", {
    S.processSoundplate(),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_SERVICE_MISSING")
end

T["process soundplate after flag change sees updated event state"] = function()
  local h = harness({ audio = true })
  local seenFlag = nil
  h.audio.processSoundplate = function(_)
    seenFlag = h.services.world:isFlagSet("FLAG_WATERFALL_DONE")
  end
  local resource = script("test.flagbefore", {
    S.setFlag({ flag = "FLAG_WATERFALL_DONE" }),
    S.processSoundplate(),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.isTrue(seenFlag, "forced processing must see flags set earlier in the same tick")
end

-- 12. stop_music takes no operand (the StopBGM operand is an erasure at
-- lowering): the node calls the service's stopMusic with no arguments and
-- the currently playing BGM is stopped.
T["stop music stops the current bgm without arguments"] = function()
  local h = harness({ audio = true })
  local resource = script("test.stopbgm", {
    S.playMusic({ music = "SEQ_GS_NEW_BARK" }),
    S.stopMusic(),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.audio.calls[1].op, "playMusic")
  Assert.equal(h.audio.calls[1].id, "SEQ_GS_NEW_BARK")
  Assert.equal(h.audio.calls[2].op, "stopMusic")
  Assert.equal(h.audio.calls[2].id, nil, "stop_music never forwards a sound id to the service")
  Assert.isNil(h.audio.music.current, "the currently playing BGM is stopped")
end

return { tests = T }
