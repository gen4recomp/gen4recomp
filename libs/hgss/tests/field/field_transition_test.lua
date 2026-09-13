-- FieldTransition tests freeze the project fade cadence, black-only swap,
-- input lock, completion event, and arrival suppression. Map protection is
-- owned by the runtime: the transition never pins or unpins maps, aborting a
-- failed transition never touches loader protection, and a commit fault
-- after the black-frame ownership transfer begins is fatal (no transition
-- rollback). The explicit door choreography facts (sourceKind, sourceDoor,
-- destinationDoor) determine the destination-egress predicate at its read
-- sites. The door choreography pins the
-- HGSS event order -- open-start, open-finished, player-step-start,
-- player-step-finished, close-start, close-finished -- with the fade
-- orthogonal where HGSS overlaps it: the ingress begins only after the
-- source door finished opening, the destination egress begins only after
-- the destination door finished opening, and the close begins only after
-- the egress movement finished. Door-kind warps with an unresolvable door
-- or ingress step, and egress steps without a terrain destination, are
-- data-contract failures and raise; a door-kind warp with NO door resolver
-- is a headless caller stating it has no door choreography and degrades to a
-- plain fade. Pre-commit failures abort to a coherent idle state; post-commit
-- faults propagate without pretending to roll back ownership. The warp kind is passed down
-- from the trigger record -- the transition never re-reads the permission
-- grid to classify the warp tile.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTransitionFade = require("libs.hgss.src.transition.FieldTransitionFade")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local function step(transition)
  local moved = transition:updateFixed()
  transition:updateSourceFrame()
  return moved
end

function T.standard_fade_uses_the_source_frame_recurrence()
  local fade = FieldTransitionFade.new({ direction = "out" })
  local coefficients = {}
  for _ = 1, 6 do
    coefficients[#coefficients + 1] = fade:updateSourceFrame()
  end
  Assert.deepEqual(coefficients, { 2, 5, 7, 10, 13, 16 })
  Assert.isTrue(fade:status().completed)
end

function T.standard_fade_out_holds_its_terminal_state_idempotently()
  local fade = FieldTransitionFade.new({ direction = "out" })
  for _ = 1, 6 do
    fade:updateSourceFrame()
  end
  Assert.equal(fade:status().coefficient, 16)
  Assert.isTrue(fade:status().completed)
  Assert.equal(fade:updateSourceFrame(), 16, "a completed outward fade must hold full black")
  Assert.equal(fade:updateSourceFrame(), 16, "a completed outward fade must stay idempotent")
  Assert.isTrue(fade:status().completed)
end

function T.standard_fade_in_uses_the_reversed_recurrence_and_holds_its_terminal_state()
  local fade = FieldTransitionFade.new({ direction = "in" })
  Assert.equal(fade:status().coefficient, 16, "an entry fade starts fully black")
  local coefficients = {}
  for _ = 1, 6 do
    coefficients[#coefficients + 1] = fade:updateSourceFrame()
  end
  Assert.deepEqual(coefficients, { 14, 11, 9, 6, 3, 0 })
  Assert.isTrue(fade:status().completed)
  Assert.equal(fade:updateSourceFrame(), 0, "a completed entry fade must hold fully revealed")
  Assert.equal(fade:updateSourceFrame(), 0, "a completed entry fade must stay idempotent")
  Assert.isTrue(fade:status().completed)
end

function T.transition_exposes_profile_presentation_state()
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    prepare = function() end,
    commit = function() end,
  })
  Assert.equal(type(transition.presentationStatus), "function")
end

function T.fixed_updates_do_not_mutate_the_source_fade()
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
  })
  transition:start({ mapId = 61 }, { warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 } }, "south")
  transition:updateFixed()
  Assert.equal(transition:presentationStatus().coefficient, 0)
  transition:updateSourceFrame()
  Assert.equal(transition:presentationStatus().coefficient, 2)
  transition:updateFixed()
  Assert.equal(transition:presentationStatus().coefficient, 2)
  transition:updateSourceFrame()
  Assert.equal(transition:presentationStatus().coefficient, 5)
end

local function recordingLoader()
  local protections = {}
  return {
    protections = protections,
    requestWarp = function()
      return true
    end,
    protectMap = function(_, mapId, protected)
      protections[#protections + 1] = { mapId, protected }
    end,
  }
end

local function destinationResult()
  return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
end

-- The source map stub: the transition receives the warp kind from the trigger
-- record and never reads the map's permission grid, so the stub is just a map
-- identity.
local function sourceMap()
  return { mapId = 61 }
end

local function advanceTo(transition, phase, maxTicks)
  for _ = 1, maxTicks do
    if transition.phase == phase then
      return
    end
    step(transition)
  end
  Assert.equal(transition.phase, phase)
end

function T.fades_loads_swaps_while_black_and_completes()
  local source = sourceMap()
  local destination = { mapId = 60 }
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0 }
  local protections, prepares, commits = {}, {}, {}
  local loader = {
    protectMap = function(_, mapId, protected)
      protections[#protections + 1] = { mapId, protected }
    end,
    requestWarp = function()
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = function()
      return {
        destinationMap = destination,
        fieldX = 684,
        fieldZ = 393,
        surfaceId = 0,
        worldY = 0,
        suppression = { mapId = 60, fieldX = 684, fieldZ = 393 },
      }
    end,
    prepare = function(result, facing)
      prepares[#prepares + 1] = { result = result, facing = facing }
      return { payload = result.destinationMap }
    end,
    commit = function(result, facing, prepared)
      commits[#commits + 1] = { result = result, facing = facing, prepared = prepared }
    end,
  })

  transition:start(source, { warp = warp, transition = { mode = "fixed", profile = 0 } }, "south")
  Assert.equal(transition.phase, "fade_out")
  Assert.isTrue(transition.locked)
  local coefficients = {}
  for _ = 1, 6 do
    step(transition)
    coefficients[#coefficients + 1] = transition:presentationStatus().coefficient
  end

  Assert.deepEqual(coefficients, { 2, 5, 7, 10, 13, 16 })
  Assert.equal(transition.phase, "fade_out", "the fixed stage consumes completion on the following tick")
  Assert.equal(transition.fadeAlpha, 1)
  Assert.equal(#prepares, 0)
  Assert.equal(#commits, 0)

  transition:updateFixed()
  Assert.equal(transition.phase, "load_destination")
  Assert.equal(transition.fadeAlpha, 1)
  transition:updateSourceFrame()
  Assert.equal(transition:presentationStatus().coefficient, 16)

  step(transition)
  Assert.equal(transition.phase, "swap_map")
  Assert.equal(#prepares, 1)
  Assert.equal(prepares[1].facing, "south")
  Assert.equal(#commits, 0)

  step(transition)
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(transition.fadeAlpha, 14 / 16)
  Assert.equal(transition:presentationStatus().coefficient, 14)
  Assert.equal(#commits, 1)
  Assert.equal(commits[1].facing, "south")
  Assert.equal(commits[1].prepared.payload.mapId, 60)

  local ticks = 0
  while transition.phase ~= "idle" and ticks < 16 do
    step(transition)
    ticks = ticks + 1
  end
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(transition.fadeAlpha, 0)
  Assert.deepEqual(transition:consumeCompleted(), {
    sourceMapId = 61,
    destinationMapId = 60,
    sourceWarpId = 0,
  })
  Assert.isNil(transition:consumeCompleted())
  Assert.deepEqual(protections, {})
end

-- The default resolver is WarpSystem.resolveDestination: a transition built
-- without a custom resolver must resolve a scripted direct warp record (the
-- production wiring FieldRuntime relies on) through the moved branch. The
-- loader needs no protectMap surface: protection is not transition-owned.
function T.default_resolver_handles_direct_warp_records()
  local destination = {
    mapId = 60,
    coordinateOrigin = { x = 672, z = 384 },
    fieldData = { events = { warps = {} } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local loader = {
    load = function()
      return destination
    end,
    requestWarp = function()
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    prepare = function() end,
    commit = function() end,
  })
  transition:start(
    sourceMap(),
    { warp = { index = 0, destinationMapId = 60, destinationWarpId = 0, x = 688, z = 392, direct = true } },
    "south"
  )
  advanceTo(transition, "swap_map", 32)
  Assert.equal(transition.phase, "swap_map")
  Assert.equal(transition.resolution.fieldX, 688)
  Assert.equal(transition.resolution.fieldZ, 392)
  Assert.equal(transition.resolution.destinationWarp.direct, true)
  Assert.deepEqual(transition.suppression, { mapId = 60, fieldX = 688, fieldZ = 392 })
end

-- A pending destination demand holds the covered transition: the source
-- stays authoritative and input stays locked while compilation continues,
-- and readiness runs the existing resolution/preparation/commit exactly
-- once. A demand failure uses the existing abort path.
function T.pending_destination_demand_holds_the_cover_until_ready()
  local gate = "pending"
  local prepares, commits = {}, {}
  local loader = {
    requestWarp = function()
      if gate == "pending" then
        return false
      end
      if gate == "error" then
        return false, "destination closure failed"
      end
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = function()
      return {
        destinationMap = { mapId = 60 },
        fieldX = 684,
        fieldZ = 393,
        surfaceId = 0,
        worldY = 0,
        suppression = { mapId = 60, fieldX = 684, fieldZ = 393 },
      }
    end,
    prepare = function(result)
      prepares[#prepares + 1] = result
      return {}
    end,
    commit = function(result, facing)
      commits[#commits + 1] = { result = result, facing = facing }
    end,
  })
  transition:start(
    sourceMap(),
    { warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0 } },
    "south"
  )
  advanceTo(transition, "load_destination", 32)
  for _ = 1, 10 do
    step(transition)
    Assert.equal(transition.phase, "load_destination", "pending demand holds the covered transition")
    Assert.isTrue(transition.locked, "input stays locked while the destination compiles")
  end
  Assert.deepEqual(prepares, {}, "no preparation runs while the destination is pending")
  Assert.deepEqual(commits, {}, "no commit runs while the destination is pending")
  gate = "ready"
  advanceTo(transition, "idle", 32)
  Assert.equal(#prepares, 1, "readiness runs existing preparation exactly once")
  Assert.equal(#commits, 1, "readiness commits exactly once")
end

function T.destination_demand_failure_aborts_with_source_ownership()
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return false, "destination closure failed"
      end,
    },
    resolveDestination = function()
      error("resolution must not run before demand readiness", 0)
    end,
    prepare = function()
      error("preparation must not run before demand readiness", 0)
    end,
    commit = function()
      error("commit must not run before demand readiness", 0)
    end,
  })
  transition:start(
    sourceMap(),
    { warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0 } },
    "south"
  )
  advanceTo(transition, "idle", 32)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(tostring(transition.error), "destination closure failed")
  Assert.isNil(transition.sourceMap, "aborted demand keeps no source reference")
  Assert.deepEqual(transition.warpContext, {
    sourceMapId = 61,
    sourceWarpId = 0,
    destinationMapId = 60,
    destinationWarpId = 0,
  })
end

-- A failed resolution aborts to a coherent idle state: unlocked, source
-- state cleared, and the error recorded separately. Loader protection is
-- never touched, so an aborted transition can never release the current
-- source map's runtime-owned protection. A later start must run a full
-- transition to completion.
function T.resolve_failure_aborts_and_a_second_transition_succeeds()
  local loader = recordingLoader()
  local failures = 1
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = function()
      if failures > 0 then
        failures = failures - 1
        error("resolve failed", 0)
      end
      return destinationResult()
    end,
    prepare = function() end,
    commit = function() end,
  })

  transition:start(
    sourceMap(),
    { warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0 } },
    "south"
  )
  advanceTo(transition, "idle", 32)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(transition.fadeAlpha, 0)
  Assert.equal(tostring(transition.error), "resolve failed")
  Assert.isNil(transition.sourceMap)
  Assert.isNil(transition.sourceWarp)
  Assert.isNil(transition.resolution)
  Assert.isNil(transition:consumeCompleted())
  Assert.deepEqual(loader.protections, {}, "an aborted transition never touches map protection")

  transition:start(
    sourceMap(),
    { warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0 } },
    "south"
  )
  advanceTo(transition, "idle", 32)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.isNil(transition.error)
  Assert.deepEqual(transition:consumeCompleted(), {
    sourceMapId = 61,
    destinationMapId = 60,
    sourceWarpId = 0,
  })
  Assert.deepEqual(loader.protections, {})
end

-- A failed prepare aborts the same way: destination player/camera
-- construction is fallible preparation that must run while the source map
-- remains the authoritative current map, so a failure leaves source
-- protection untouched and records the error.
function T.prepare_failure_aborts_with_source_protection_untouched()
  local loader = recordingLoader()
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = destinationResult,
    prepare = function()
      error("prepare failed", 0)
    end,
    commit = function() end,
  })
  transition:start(
    sourceMap(),
    { warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0 } },
    "south"
  )
  advanceTo(transition, "idle", 32)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(tostring(transition.error), "prepare failed")
  Assert.isNil(transition.resolution)
  Assert.deepEqual(loader.protections, {})
end

function T.preparation_failure_disposes_transition_owned_resources()
  local releases = 0
  local staged = {
    release = function()
      releases = releases + 1
    end,
  }
  local disposedResolution
  local disposedPrepared
  local transition = FieldTransition.new({
    loader = recordingLoader(),
    resolveDestination = function()
      return {
        destinationMap = { mapId = 60 },
        fieldX = 0,
        fieldZ = 0,
        surfaceId = 0,
        worldY = 0,
        physical = { coverage = staged, replacement = true, state = "prepared" },
      }
    end,
    prepare = function()
      error("destination preparation failed", 0)
    end,
    disposePrepared = function(resolution, prepared)
      disposedResolution = resolution
      disposedPrepared = prepared
      resolution.physical.coverage:release()
      resolution.physical.state = "released"
    end,
    commit = function()
      error("preparation failure must not commit", 0)
    end,
  })

  transition:start(sourceMap(), { warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 } }, "south")
  advanceTo(transition, "idle", 32)

  Assert.equal(releases, 1)
  Assert.notNil(disposedResolution)
  Assert.isNil(disposedPrepared)
  Assert.equal(transition.phase, "idle")
  Assert.equal(tostring(transition.error), "destination preparation failed")
end

-- A fault inside the commit (the irreversible black-frame ownership
-- transfer) is a fatal programming error: it propagates out of updateFixed
-- and the transition does not pretend to roll back arbitrary partially
-- mutated game state by aborting to idle.
function T.commit_fault_propagates_as_fatal()
  local loader = recordingLoader()
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = destinationResult,
    prepare = function() end,
    commit = function()
      error("commit failed", 0)
    end,
  })
  transition:start(
    sourceMap(),
    { warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0 } },
    "south"
  )
  advanceTo(transition, "swap_map", 32)
  Assert.equal(transition.phase, "swap_map")
  local ok, err = pcall(transition.updateFixed, transition)
  Assert.isFalse(ok)
  Assert.equal(tostring(err), "commit failed")
  Assert.equal(transition.phase, "swap_map")
  Assert.isNil(transition.error, "commit faults are not transition errors")
  Assert.deepEqual(loader.protections, {})
end

-- The failed-warp context is recorded with the error: the destination and
-- source ids survive the abort for diagnostics, separate from live state.
function T.abort_records_the_failed_warp_context()
  local loader = recordingLoader()
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = function()
      error("resolve failed", 0)
    end,
    prepare = function() end,
    commit = function() end,
  })
  transition:start(
    sourceMap(),
    { warp = { index = 4, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 2 } },
    "south"
  )
  advanceTo(transition, "idle", 32)
  Assert.equal(transition.phase, "idle")
  Assert.deepEqual(transition.warpContext, {
    sourceMapId = 61,
    sourceWarpId = 4,
    destinationMapId = 60,
    destinationWarpId = 2,
  })
end
-- ---- door source/destination choreography ----

-- A door handle stub with the MapDoor contract: `instance` present for
-- animated doors (the transition waits on their clips), absent for static
-- ones (nothing to wait for). `advance(ticks)` simulates the session
-- advancing the scene's animated instances: an open or close clip lasts
-- `frames` ticks, and isFinished() reports false while it runs, true once
-- it reaches its end, and nil for a static door. Every clip event lands in
-- `events`, and in `trace` when one is shared across stubs.
local function doorStub(opts)
  opts = opts or {}
  local door = {
    instance = opts.animated ~= false and {} or nil,
    frames = opts.frames or 8,
    opened = 0,
    closed = 0,
    events = {},
    trace = opts.trace,
    role = nil,
    remaining = 0,
  }
  local function record(self, event)
    self.events[#self.events + 1] = event
    if self.trace then
      self.trace[#self.trace + 1] = event
    end
  end
  function door:open()
    self.opened = self.opened + 1
    if not self.instance then
      return
    end
    record(self, "open-start")
    self.role = "door.open"
    self.remaining = self.frames
  end
  function door:close()
    self.closed = self.closed + 1
    if not self.instance then
      return
    end
    record(self, "close-start")
    self.role = "door.close"
    self.remaining = self.frames
  end
  function door:advance(ticks)
    for _ = 1, ticks do
      if self.remaining > 0 then
        self.remaining = self.remaining - 1
        if self.remaining == 0 then
          record(self, self.role == "door.open" and "open-finished" or "close-finished")
        end
      end
    end
  end
  function door:isFinished()
    if not self.instance or not self.role then
      return nil
    end
    return self.remaining == 0
  end
  return door
end

-- A player stub with the locomotion contract the choreography drives:
-- scriptedStep begins a scripted walk lasting `stepTicks` ticks, updateFixed
-- advances it and reports the commit like FieldPlayer (true only on the
-- final tick), and the step start/finish land in `trace` when shared.
-- `stepTicks` may be a number or a per-step list (e.g. a short ingress and
-- a long egress), so a test can stretch only the step it is probing.
local function stubPlayer(opts)
  opts = opts or {}
  local p = {
    motion = "idle",
    facing = "south",
    steps = {},
    updates = 0,
    stepTicks = opts.stepTicks or 8,
    remaining = 0,
    trace = opts.trace,
    scriptedStep = function(self, direction)
      assert(self.motion == "idle", "cannot begin a scripted step while walking")
      self.steps[#self.steps + 1] = direction
      local duration = self.stepTicks
      if type(duration) == "table" then
        duration = duration[#self.steps] or duration[#duration]
      end
      self.remaining = duration
      self.motion = "walking"
      self.facing = direction
      if self.trace then
        self.trace[#self.trace + 1] = "step-start"
      end
      return true
    end,
    beginTransitionStep = function(self, direction)
      return self:scriptedStep(direction)
    end,
    updateFixed = function(self)
      assert(self.motion == "walking", "the choreography advances a moving player")
      self.updates = self.updates + 1
      self.remaining = self.remaining - 1
      if self.remaining <= 0 then
        self.motion = "idle"
        self.remaining = 0
        if self.trace then
          self.trace[#self.trace + 1] = "step-finished"
        end
        return true
      end
      return false
    end,
  }
  return p
end

-- A choreography transition over stub maps: `opts.kind` is the trigger
-- classification passed down at start ("door" by default); `opts.doorAt`
-- resolves source/destination doors (nil for stair warps, which carry no
-- doors); playSound records the stair sound; the resolution carries a
-- coordinate suppression token.
local function transitionFixture(opts)
  opts = opts or {}
  local source = sourceMap()
  local destination = { mapId = 60 }
  local loader = opts.loader
    or {
      load = function()
        return destination
      end,
      protectMap = function() end,
      requestWarp = function()
        return true
      end,
    }
  local swaps = {}
  local sounds = {}
  local transition = FieldTransition.new({
    loader = loader,
    doorAt = opts.doorAt,
    onStart = opts.onStart,
    playSound = function(soundId)
      sounds[#sounds + 1] = soundId
    end,
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 684, z = 393 },
        fieldX = 684,
        fieldZ = 393,
        surfaceId = 0,
        worldY = 0,
        suppression = { mapId = 60, fieldX = 684, fieldZ = 393 },
      }
    end,
    prepare = function(result)
      return result
    end,
    commit = function(result, facing)
      swaps[#swaps + 1] = { result = result, facing = facing }
    end,
  })
  if opts.player then
    transition.player = opts.player
  end
  return transition, source, destination, swaps, sounds
end

-- One choreography tick: the transition advances first, then the door
-- stubs' clips advance -- mirroring the session, which advances the
-- transition and then the scene's animated instances.
local function tick(transition, doors)
  step(transition)
  for _, door in ipairs(doors or {}) do
    door:advance(1)
  end
end

-- Advance the choreography until `predicate` holds or the tick budget runs
-- out; asserts the budget did not.
local function runUntil(transition, doors, predicate, maxTicks)
  local ticks = 0
  while not predicate() and ticks < maxTicks do
    tick(transition, doors)
    ticks = ticks + 1
  end
  Assert.isTrue(predicate(), "the choreography reaches the awaited state within the tick budget")
end

local DOOR_WARP = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }

-- The warp trigger record the session hands to the transition: the classified
-- kind plus the warp. A plain fade passes kind nil ({ warp = warp }).
local function makeTrigger(kind, warp)
  return { kind = kind, warp = warp }
end

-- The full door warp as the review's ordered event trace: open-start,
-- open-finished, player-step-start, player-step-finished, close-start,
-- close-finished -- in that order on each side, with the swap between the
-- two sides and the fade orthogonal.
function T.door_choreography_runs_the_hgss_event_order()
  local trace = {}
  local sourceDoor = doorStub({ trace = trace })
  local destinationDoor = doorStub({ trace = trace })
  local player = stubPlayer({ trace = trace })
  local transition
  local source
  transition, source = transitionFixture({
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return destinationDoor
    end,
    player = player,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  runUntil(transition, { sourceDoor, destinationDoor }, function()
    return transition.phase == "idle"
  end, 300)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  local observedTrace = table.concat(trace, ",")
  Assert.equal(
    observedTrace,
    "open-start,open-finished,step-start,step-finished,"
      .. "open-start,open-finished,step-start,step-finished,"
      .. "close-start,close-finished",
    "the door choreography follows the HGSS event order (got: " .. observedTrace .. ")"
  )
end

function T.source_door_waits_for_the_open_before_the_ingress()
  local sourceDoor = doorStub()
  local player = stubPlayer()
  local transition
  local source
  local swaps
  local _
  transition, source, _, swaps = transitionFixture({
    doorAt = function(runtimeMap, _, _)
      if runtimeMap == source then
        return sourceDoor
      end
      return nil
    end,
    player = player,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  Assert.equal(transition.phase, "fade_out")
  Assert.isTrue(transition.locked)
  Assert.equal(transition.sourceKind, "door")
  Assert.equal(transition.sourceDoor, sourceDoor)
  Assert.isNil(transition.destinationDoor, "the destination door is not resolved before load")
  Assert.equal(sourceDoor.opened, 1, "the source door opens at transition start")
  Assert.equal(sourceDoor.closed, 0, "the source door never closes on the source side")
  Assert.equal(#player.steps, 0, "the ingress waits for the door to finish opening")
  Assert.equal(player.motion, "idle")
  Assert.isNil(transition.destinationChoreo, "egress need is decided at load")

  -- The opening clip runs inside the fade; the player stays at the anchor
  -- and the transition reports no locomotion while it runs.
  for _ = 1, sourceDoor.frames do
    Assert.isFalse(step(transition), "the open wait reports no locomotion")
    sourceDoor:advance(1)
    Assert.equal(transition.phase, "fade_out")
    Assert.isTrue(transition.fadeAlpha > 0, "the source fade runs while the door opens")
    Assert.equal(#player.steps, 0, "the player does not step while the door opens")
    Assert.equal(player.updates, 0)
  end
  Assert.equal(sourceDoor.events[#sourceDoor.events], "open-finished", "the opening clip reached its end")
  Assert.equal(transition.fadeAlpha, 1, "the source fade reaches black before ingress")

  step(transition)
  Assert.deepEqual(player.steps, { "north" }, "the ingress begins only after the door finished opening")
  Assert.equal(player.motion, "walking")
  Assert.equal(transition.fadeAlpha, 1, "the ingress begins at full black")

  local walkingTicks = 0
  while player.motion == "walking" and walkingTicks < 64 do
    Assert.isTrue(step(transition), "a walking tick reports locomotion")
    sourceDoor:advance(1)
    walkingTicks = walkingTicks + 1
  end
  Assert.equal(walkingTicks, player.stepTicks, "the ingress walks a full step")

  -- The swap waits for the completed ingress at full black.
  runUntil(transition, { sourceDoor }, function()
    return transition.phase == "swap_map"
  end, 200)
  Assert.equal(transition.fadeAlpha, 1, "the map swaps only at full black")
  Assert.equal(player.motion, "idle", "the ingress finished before the swap")
  Assert.equal(#swaps, 0, "no swap before the choreography completes")
  step(transition)
  Assert.isTrue(transition.sourceKind == "door" or transition.destinationDoor ~= nil, "a door source always egresses")
  step(transition)
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(#swaps, 1)
  Assert.equal(swaps[1].facing, "south")

  runUntil(transition, {}, function()
    return transition.phase == "idle"
  end, 200)
  Assert.isFalse(transition.locked)
  Assert.isNil(transition.sourceDoor)
  Assert.equal(sourceDoor.closed, 0, "the source door never closes; the map is discarded")
  Assert.deepEqual(
    player.steps,
    { "north", "south" },
    "the destination egress walks off the anchor even without a door"
  )
  Assert.equal(player.updates, 2 * player.stepTicks, "both scripted steps walk to completion")
  Assert.notNil(transition:consumeCompleted())
end

function T.door_choreography_requires_a_player_for_ingress()
  local sourceDoor = doorStub()
  local transition, source = transitionFixture({
    doorAt = function(runtimeMap)
      return runtimeMap.mapId == 61 and sourceDoor or nil
    end,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "north")
  for _ = 1, sourceDoor.frames do
    step(transition)
    sourceDoor:advance(1)
  end

  local ok, err = pcall(step, transition)
  Assert.isFalse(ok, "a door ingress cannot run without a player")
  Assert.isTrue(tostring(err):find("door ingress player required", 1, true) ~= nil)
end

function T.destination_door_waits_for_the_open_then_the_egress_then_closes()
  -- The destination sequence is fully ordered: the door opens at the swap,
  -- the egress begins only after the opening finished, the close begins
  -- only after the egress movement finished (not at the end of the
  -- fade-in), and the close completion gates the unlock. The egress step
  -- is made longer than the fade-in so the close-vs-movement ordering is
  -- observable even when the movement outlasts the fade.
  local sourceDoor = doorStub()
  local destinationDoor = doorStub()
  -- A short ingress (so the current implementation reaches the swap at
  -- rest) and an egress longer than the fade-in, so the close-vs-movement
  -- ordering is observable even when the movement outlasts the fade.
  local player = stubPlayer({ stepTicks = { 8, 30 } })
  local transition
  local source
  transition, source = transitionFixture({
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return destinationDoor
    end,
    player = player,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  runUntil(transition, { sourceDoor, destinationDoor }, function()
    return transition.phase == "swap_map"
  end, 200)
  Assert.equal(transition.destinationDoor, destinationDoor, "the destination door is resolved at load")
  step(transition)
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(destinationDoor.opened, 1, "the destination door opens at the swap")
  Assert.equal(#player.steps, 1, "the egress waits for the destination door to finish opening")
  Assert.equal(player.motion, "idle")

  for _ = 1, destinationDoor.frames do
    tick(transition, { sourceDoor, destinationDoor })
    Assert.equal(#player.steps, 1, "the egress still waits while the door opens")
  end
  Assert.equal(
    destinationDoor.events[#destinationDoor.events],
    "open-finished",
    "the destination opening reached its end"
  )

  tick(transition, { sourceDoor, destinationDoor })
  Assert.deepEqual(player.steps, { "north", "south" }, "the egress begins after the destination door finished opening")
  Assert.equal(player.motion, "walking")

  -- The movement outlasts the fade-in: the close must still wait for it.
  runUntil(transition, { sourceDoor, destinationDoor }, function()
    return transition.fadeAlpha == 0
  end, 100)
  Assert.equal(player.motion, "walking", "the egress movement outlasts the fade-in")
  Assert.equal(destinationDoor.closed, 0, "the close waits for the egress movement, not the fade")

  runUntil(transition, { sourceDoor, destinationDoor }, function()
    return destinationDoor.closed == 1
  end, 100)
  Assert.equal(player.motion, "idle", "the close begins only after the egress movement finished")
  Assert.equal(transition.phase, "choreo_hold", "the close completion gates the unlock")
  Assert.isTrue(transition.locked, "input stays locked while the door closes")

  for _ = 1, destinationDoor.frames - 1 do
    tick(transition, { sourceDoor, destinationDoor })
    Assert.equal(transition.phase, "choreo_hold", "the unlock waits for the close animation")
  end
  tick(transition, { sourceDoor, destinationDoor })
  Assert.equal(destinationDoor.events[#destinationDoor.events], "close-finished", "the closing clip reached its end")
  tick(transition, { sourceDoor, destinationDoor })
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.notNil(transition:consumeCompleted())
end

function T.destination_door_alone_activates_the_choreography()
  -- The Elm Lab exit pattern: the source warp tile is an entrance (101), not
  -- a door, but the destination tile resolves a door -- the choreography
  -- activates at load and the destination sequence still runs in order.
  local destinationDoor = doorStub()
  local player = stubPlayer()
  local transition
  local source
  transition, source = transitionFixture({
    kind = "directional",
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return nil
      end
      return destinationDoor
    end,
    player = player,
  })
  transition:start(source, makeTrigger("directional", DOOR_WARP), "south")
  Assert.equal(transition.sourceKind, "directional", "an entrance source is not a door")
  Assert.equal(#player.steps, 0, "no ingress step without a source door")
  runUntil(transition, { destinationDoor }, function()
    return transition.phase == "swap_map"
  end, 100)
  Assert.equal(transition.fadeAlpha, 1)
  step(transition)
  Assert.equal(transition.phase, "fade_in")
  Assert.equal(destinationDoor.opened, 1, "the destination door opens at the swap")
  Assert.equal(#player.steps, 0, "the egress waits for the destination door to finish opening")
  Assert.equal(player.motion, "idle")

  for _ = 1, destinationDoor.frames do
    tick(transition, { destinationDoor })
    Assert.equal(#player.steps, 0, "the egress still waits while the door opens")
  end
  tick(transition, { destinationDoor })
  Assert.deepEqual(player.steps, { "south" }, "the egress begins after the door finished opening")

  runUntil(transition, { destinationDoor }, function()
    return transition.phase == "idle"
  end, 100)
  Assert.equal(destinationDoor.closed, 1, "the door closes after the egress")
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.notNil(transition:consumeCompleted())
end

function T.static_destination_door_does_not_block_the_unlock()
  local sourceDoor = doorStub()
  local staticDoor = doorStub({ animated = false })
  -- A short ingress and an egress longer than the fade-in, so the
  -- close-vs-movement ordering is observable for the static door too.
  local player = stubPlayer({ stepTicks = { 8, 30 } })
  local transition
  local source
  transition, source = transitionFixture({
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return staticDoor
    end,
    player = player,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  runUntil(transition, { sourceDoor }, function()
    return transition.phase == "swap_map"
  end, 200)
  step(transition)
  Assert.equal(transition.phase, "fade_in")
  -- A static door (no animation) has nothing to wait for: the egress begins
  -- at the swap.
  Assert.deepEqual(player.steps, { "north", "south" }, "the egress begins at the swap for a static door")

  runUntil(transition, {}, function()
    return transition.fadeAlpha == 0
  end, 100)
  Assert.equal(player.motion, "walking", "the egress movement outlasts the fade-in")
  Assert.equal(staticDoor.closed, 0, "the close waits for the egress movement, not the fade")

  runUntil(transition, {}, function()
    return transition.phase == "idle"
  end, 100)
  Assert.equal(player.motion, "idle", "the static egress finishes before unlock")
  Assert.equal(staticDoor.closed, 0, "a static destination has no close animation to attempt")
  Assert.isFalse(transition.locked, "a static destination has nothing to wait for")
end

function T.missing_source_door_is_a_data_contract_failure()
  local transition
  local source
  transition, source = transitionFixture({
    doorAt = function()
      return nil
    end,
    player = stubPlayer(),
  })
  local ok, err = pcall(transition.start, transition, source, makeTrigger("door", DOOR_WARP), "south")
  Assert.isFalse(ok, "a door-kind warp without a resolvable door raises")
  Assert.equal(type(err) == "table" and err.code or err, "MAP_TRANSITION_UNRESOLVED_SOURCE_DOOR")
end

function T.failed_ingress_step_is_a_data_contract_failure()
  -- The ingress step is attempted only after the source door finished
  -- opening, so the failure surfaces when the choreography reaches the
  -- ingress -- not at transition start. The failure aborts to a coherent
  -- idle state: unlocked, the source pin released, and the error recorded
  -- with its warp context for FieldRuntime reporting.
  local loader = recordingLoader()
  local sourceDoor = doorStub()
  local transition
  local source
  transition, source = transitionFixture({
    loader = loader,
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return nil
    end,
    player = {
      motion = "idle",
      facing = "south",
      scriptedStep = function()
        return false
      end,
    },
  })
  local okStart, errStart = pcall(transition.start, transition, source, makeTrigger("door", DOOR_WARP), "south")
  Assert.isTrue(okStart, "the door opens before the ingress is attempted")
  Assert.isNil(errStart)
  for _ = 1, sourceDoor.frames do
    tick(transition, { sourceDoor })
  end
  local ok, err = pcall(transition.updateFixed, transition)
  Assert.isFalse(ok, "an ingress step with no terrain destination raises")
  Assert.equal(type(err) == "table" and err.code or err, "MAP_TRANSITION_INGRESS_FAILED")
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(transition.fadeAlpha, 0)
  Assert.equal(transition.error.code, "MAP_TRANSITION_INGRESS_FAILED")
  Assert.deepEqual(transition.warpContext, {
    sourceMapId = 61,
    sourceWarpId = 0,
    destinationMapId = 60,
    destinationWarpId = 0,
  })
  Assert.isNil(transition:consumeCompleted())
  Assert.equal(transition.error, err)
  Assert.deepEqual(loader.protections, {}, "a pre-commit failure does not touch runtime-owned protection")
end

function T.failed_egress_step_is_a_data_contract_failure()
  -- The egress step is attempted only after the destination door finished
  -- opening, so the failure surfaces when the choreography reaches it on the
  -- destination side -- not at the swap. Because this is after the ownership
  -- commit, it propagates as a fatal fault instead of pretending to roll back.
  local loader = recordingLoader()
  local sourceDoor = doorStub()
  local destinationDoor = doorStub()
  local player = stubPlayer()
  local innerStep = player.scriptedStep
  player.scriptedStep = function(self, direction)
    if #self.steps == 1 then
      return false
    end
    return innerStep(self, direction)
  end
  local transition
  local source
  transition, source = transitionFixture({
    loader = loader,
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return destinationDoor
    end,
    player = player,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  runUntil(transition, { sourceDoor, destinationDoor }, function()
    return transition.phase == "swap_map"
  end, 200)
  step(transition)
  Assert.equal(transition.phase, "fade_in")
  for _ = 1, destinationDoor.frames do
    tick(transition, { sourceDoor, destinationDoor })
  end
  local ok, err = pcall(transition.updateFixed, transition)
  Assert.isFalse(ok, "an egress step with no terrain destination raises")
  Assert.equal(type(err) == "table" and err.code or err, "MAP_TRANSITION_EGRESS_FAILED")
  Assert.equal(transition.phase, "choreo_hold")
  Assert.isNil(transition.error)
  Assert.isTrue(transition.locked)
  Assert.isNil(transition:consumeCompleted())
  Assert.deepEqual(loader.protections, {}, "a post-commit fault does not transfer map ownership")
end

-- A throwing source door:open() occurs before the commit, so it aborts to a
-- coherent idle state without touching runtime-owned map protection. The
-- error propagates, and a later start can run a full choreography.
function T.source_door_open_failure_aborts_idle_without_touching_map_protection()
  local loader = recordingLoader()
  local sourceDoor = doorStub()
  local originalOpen = sourceDoor.open
  local opens = 0
  sourceDoor.open = function(self)
    opens = opens + 1
    if opens == 1 then
      error("door open failed", 0)
    end
    originalOpen(self)
  end
  local transition
  local source
  transition, source = transitionFixture({
    loader = loader,
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return nil
    end,
    player = stubPlayer(),
  })
  local ok, _ = pcall(transition.start, transition, source, makeTrigger("door", DOOR_WARP), "south")
  Assert.isFalse(ok, "a throwing source door open propagates out of start")
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(transition.fadeAlpha, 0)
  Assert.equal(tostring(transition.error), "door open failed")
  Assert.deepEqual(transition.warpContext, {
    sourceMapId = 61,
    sourceWarpId = 0,
    destinationMapId = 60,
    destinationWarpId = 0,
  })
  Assert.isNil(transition.sourceMap)
  Assert.deepEqual(loader.protections, {})

  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  runUntil(transition, { sourceDoor }, function()
    return transition.phase == "idle"
  end, 300)
  Assert.isFalse(transition.locked)
  Assert.notNil(transition:consumeCompleted())
end

-- Destination choreography starts after the irreversible commit. A throwing
-- door open propagates without pretending to restore the source state.
function T.destination_door_open_failure_propagates_after_commit()
  local loader = recordingLoader()
  local sourceDoor = doorStub()
  local destinationDoor = doorStub()
  local originalOpen = destinationDoor.open
  local opens = 0
  destinationDoor.open = function(self)
    opens = opens + 1
    if opens == 1 then
      error("door open failed", 0)
    end
    originalOpen(self)
  end
  local player = stubPlayer()
  local transition
  local source
  transition, source = transitionFixture({
    loader = loader,
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return destinationDoor
    end,
    player = player,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  runUntil(transition, { sourceDoor }, function()
    return transition.phase == "swap_map"
  end, 200)
  local ok, err = pcall(transition.updateFixed, transition)
  Assert.isFalse(ok, "a throwing destination door open propagates out of the swap tick")
  Assert.equal(tostring(err), "door open failed")
  Assert.equal(transition.phase, "swap_map")
  Assert.isTrue(transition.locked)
  Assert.equal(transition.fadeAlpha, 1)
  Assert.isNil(transition.error)
  Assert.notNil(transition.sourceMap)
  Assert.notNil(transition.resolution)
  Assert.deepEqual(loader.protections, {})
end

-- A throwing destination close is also post-commit and therefore fatal; live
-- state remains in its current transition phase for diagnostics.
function T.destination_door_close_failure_propagates_after_commit()
  local loader = recordingLoader()
  local sourceDoor = doorStub()
  local destinationDoor = doorStub()
  local originalClose = destinationDoor.close
  local closes = 0
  destinationDoor.close = function(self)
    closes = closes + 1
    if closes == 1 then
      error("door close failed", 0)
    end
    originalClose(self)
  end
  local player = stubPlayer()
  local transition
  local source
  transition, source = transitionFixture({
    loader = loader,
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return destinationDoor
    end,
    player = player,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  -- The close is attempted on the tick that completes the egress movement.
  runUntil(transition, { sourceDoor, destinationDoor }, function()
    return #player.steps == 2 and player.motion == "walking" and player.remaining == 1
  end, 200)
  local ok, err = pcall(transition.updateFixed, transition)
  Assert.isFalse(ok, "a throwing destination door close propagates out of the choreography")
  Assert.equal(tostring(err), "door close failed")
  Assert.equal(transition.phase, "choreo_hold")
  Assert.isTrue(transition.locked)
  Assert.isNil(transition.error)
  Assert.notNil(transition.sourceMap)
  Assert.notNil(transition.resolution)
  Assert.deepEqual(loader.protections, {})
end

-- Completion leaves map protection entirely to the runtime owner.
function T.finish_does_not_touch_map_protection()
  local protections = {}
  local loader = {
    protectMap = function(_, mapId, protected)
      protections[#protections + 1] = { mapId, protected }
      if not protected then
        error("release failed", 0)
      end
    end,
    requestWarp = function()
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = destinationResult,
    prepare = function() end,
    commit = function() end,
  })
  transition:start(
    sourceMap(),
    { warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0 } },
    "south"
  )
  advanceTo(transition, "idle", 32)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.isNil(transition.error)
  Assert.notNil(transition:consumeCompleted())
  Assert.deepEqual(protections, {})
end

function T.door_warps_skip_coordinate_suppression()
  local sourceDoor = doorStub()
  local transition
  local source
  transition, source = transitionFixture({
    player = stubPlayer(),
    doorAt = function(runtimeMap)
      if runtimeMap == source then
        return sourceDoor
      end
      return nil
    end,
  })
  transition:start(source, makeTrigger("door", DOOR_WARP), "south")
  runUntil(transition, { sourceDoor }, function()
    return transition.phase == "load_destination"
  end, 200)
  Assert.isNil(transition.suppression, "door warps re-arm immediately after egress")
end

function T.generic_warps_keep_coordinate_suppression()
  local transition, source = transitionFixture({ kind = "generic", player = stubPlayer() })
  transition:start(
    source,
    makeTrigger("generic", { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }),
    "north"
  )
  advanceTo(transition, "swap_map", 32)
  Assert.deepEqual(transition.suppression, { mapId = 60, fieldX = 684, fieldZ = 393 })
end

function T.plain_warps_never_drive_the_player()
  local player = stubPlayer()
  local transition, source = transitionFixture({ kind = "generic", player = player })
  transition:start(
    source,
    makeTrigger("generic", { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }),
    "north"
  )
  local ticks = 0
  while transition.phase ~= "idle" and ticks < 32 do
    Assert.isFalse(step(transition), "a plain fade never reports locomotion")
    ticks = ticks + 1
  end
  Assert.equal(#player.steps, 0)
  Assert.equal(player.updates, 0)
  Assert.equal(transition.phase, "idle")
  Assert.equal(transition.sourceKind, "generic")
end

-- ---- stair choreography ----

-- Stairs require a player (human decision): production FieldRuntime always
-- binds one before any start, so a stair warp without a player is a
-- programming fault -- it aborts loudly to a coherent idle state, never a
-- silent degradation into an ordinary fade.
function T.stair_warp_without_a_player_raises_and_aborts()
  local loader = recordingLoader()
  local transition
  local source
  transition, source = transitionFixture({ loader = loader, kind = "stairs" })
  local ok, err = pcall(transition.start, transition, source, makeTrigger("stairs", DOOR_WARP), "west")
  Assert.isFalse(ok, "a stair warp without a player raises")
  Assert.isTrue(tostring(err):find("stair transition step required", 1, true) ~= nil, tostring(err))
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.equal(transition.fadeAlpha, 0)
  Assert.isNil(transition.sourceMap)
  Assert.deepEqual(loader.protections, {})
end

function T.stair_source_climb_drives_the_player_locked_movement()
  -- Profile 3 owns the locked source step. It must not fall back to a
  -- duplicate presentation movement.
  local player = stubPlayer()
  local transition, source, _, _, sounds = transitionFixture({ kind = "stairs", player = player })
  transition:start(source, makeTrigger("stairs", DOOR_WARP), "west")
  Assert.isNil(transition.sourceDoor, "stairs never activate the door choreography")
  Assert.equal(transition.sourceKind, "stairs")
  Assert.equal(player.motion, "walking", "the source stair transition starts the locked step")
  Assert.deepEqual(player.steps, { "west" })
  for _ = 1, player.stepTicks do
    step(transition)
  end
  Assert.equal(#sounds, 1, "the stair sound fires when the source step completes")
  Assert.equal(
    sounds[1],
    FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.HORIZONTAL_STAIRS].exitSound,
    "the HGSS stair-climb sound id"
  )
  Assert.equal(player.motion, "idle", "the source step finished")
  Assert.equal(transition.phase, "fade_out", "the climb finishes inside the fade")
end

function T.stair_source_step_failure_aborts_with_ingress_error()
  local player = {
    motion = "idle",
    beginTransitionStep = function()
      return false
    end,
  }
  local transition, source = transitionFixture({ kind = "stairs", player = player })
  local ok, err = pcall(transition.start, transition, source, makeTrigger("stairs", DOOR_WARP), "west")
  Assert.isFalse(ok)
  Assert.equal(type(err) == "table" and err.code or err, "MAP_TRANSITION_INGRESS_FAILED")
  Assert.equal(transition.error.code, "MAP_TRANSITION_INGRESS_FAILED")
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
  Assert.isFalse(transition.fadeStarted)
  Assert.deepEqual(transition.suppression, nil)
end

function T.plain_warps_never_play_the_stair_choreography()
  local player = stubPlayer()
  local transition, source, _, _, sounds = transitionFixture({ kind = "generic", player = player })
  transition:start(source, {
    kind = "generic",
    warp = DOOR_WARP,
    transition = { mode = "panel" },
  }, "north")
  advanceTo(transition, "idle", 32)
  Assert.equal(transition.phase, "idle")
  Assert.equal(transition.sourceKind, "generic")
  Assert.deepEqual(sounds, {}, "plain warps play no stair sound")
  Assert.deepEqual(player.steps, {})
end

-- The onStart callback fires exactly once per transition start, before any
-- ownership change (the beginWarp pre-fade hook the runtime binds); a second
-- start fires it again, and a raising callback aborts the start coherently
-- (the same pre-commit failure path as destination preparation).
function T.on_start_callback_fires_once_per_transition_start_before_ownership_changes()
  local starts = 0
  local transition, source = transitionFixture({})
  transition.onStart = function(cbSource, trigger, facing)
    starts = starts + 1
    Assert.equal(cbSource, source, "the callback receives the source map")
    Assert.equal(trigger.warp.x, 4, "the callback receives the warp trigger")
    Assert.equal(facing, "south", "the callback receives the facing")
  end
  transition:start(source, makeTrigger("generic", DOOR_WARP), "south")
  Assert.equal(starts, 1, "the callback fires exactly once for the first start")
  -- Complete the first transition back to idle before starting a second one:
  -- the transition is single-flight, so a second start is legal only after
  -- the first runs its full fade cycle.
  advanceTo(transition, "idle", 32)
  Assert.equal(transition.phase, "idle", "the completed transition returns to idle")
  transition:start(source, makeTrigger("generic", DOOR_WARP), "south")
  Assert.equal(starts, 2, "a second start fires the callback again")
end

function T.a_raising_on_start_callback_aborts_the_start_coherently()
  local transition, source = transitionFixture({
    onStart = function()
      error("injected onStart failure")
    end,
  })
  transition:start(source, makeTrigger("generic", DOOR_WARP), "south")
  Assert.equal(transition.phase, "idle", "a failed onStart aborts back to idle")
  Assert.isFalse(transition.locked)
  Assert.notNil(transition.error, "the abort records the callback failure")
  Assert.notNil(transition.warpContext, "the abort records the warp context")
end

-- A door-kind warp with no door resolver at all must fail the same way a
-- resolver that returns no door fails: it is missing semantic door data, not
-- a valid "headless, no choreography" composition. It must not degrade to a
-- plain fade while still emitting the door-open sound and completing the
-- swap, because that observes audio without proving semantic door ingress.
function T.absent_door_resolver_is_a_data_contract_failure_not_a_synthetic_success()
  local transition, source, _, swaps, sounds = transitionFixture({ player = stubPlayer() })
  local ok, err = pcall(transition.start, transition, source, makeTrigger("door", DOOR_WARP), "north")
  Assert.isFalse(ok, "a door-kind warp with no door resolver must not silently succeed")
  Assert.equal(type(err) == "table" and err.code or err, "MAP_TRANSITION_UNRESOLVED_SOURCE_DOOR")
  Assert.equal(#sounds, 0, "no synthetic door-open sound may be emitted when door data cannot resolve")
  Assert.equal(#swaps, 0, "no map swap may occur when door data cannot resolve")
end

return { tests = T }
