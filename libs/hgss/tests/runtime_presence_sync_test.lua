local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
---@cast WaitTicksTask TaskImplementation
local FakeServices = require("tests.support.script.FakeServices")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local POLICY = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } }

local function terrain()
  return TerrainSurface.new({
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
  })
end

local function object(overrides)
  local event = {
    index = 0,
    objectEventId = 0,
    spriteId = 99,
    movementType = "stationary",
    type = 0,
    eventFlag = 500,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = 2,
    z = 3,
    y = 0,
  }
  for k, v in pairs(overrides or {}) do
    event[k] = v
  end
  return event
end

local function runtimeMap(objects, mapId)
  local result = {
    mapId = mapId or 61,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = terrain(),
    fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
  }
  ---@cast result RuntimeFieldMap
  return result
end

local function fakeAssets(known)
  return {
    references = {},
    knows = function(_, spriteId)
      return known[spriteId] == true
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local c = self.references[spriteId] or 0
      assert(c > 0)
      self.references[spriteId] = c - 1
    end,
  }
end

function T.clearFlag_then_showObject_materializes_in_same_tick_without_advancing_pose()
  local eventState = FieldEventState.new({ flags = { [500] = true } })
  local assets = fakeAssets({ [99] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  local map = runtimeMap({ object({ eventFlag = 500 }) })
  mgr:enterMap(map, eventState)
  Assert.isNil(mgr:getById("map:61:object:0"))

  local player = {
    position = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
    gender = function()
      return 0
    end,
    name = function()
      return "Gold"
    end,
  }
  local world = ScriptActorWorld.new(mgr --[[@as ScriptActorManager]], player)

  -- After this line the runtime must have synchronized presence so the next
  -- node sees the actor live. If the sync boundary is missing, the show will
  -- fault.
  local services = FakeServices.new()
  services.world = eventState
  services.actors = world

  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })

  local res = S.script({
    api = 1,
    id = "test.sync_show",
    steps = {
      S.clearFlag({ flag = 500 }),
      S.showObject({ actor = "map:61:object:0" }),
      S.stop(),
    },
  })
  registry:installBase(res.id, res, "generated")
  local composed = assert(composition:effective(res.id))
  local instanceId = scheduler:createForeground(composed, nil, 100)

  -- First tick executes both nodes; any fault is recorded.
  scheduler:step(100, nil)
  local fault = services.events:eventFor("script.error", instanceId)
  Assert.isNil(fault, "clearFlag -> showObject must not fault when presence is synchronized")

  local actor = assert(mgr:getById("map:61:object:0"), "actor must be live after clearFlag + sync")
  Assert.equal(actor:getPoseTick(), 0, "zero-time presence sync must not increment poseTick")

  -- Taskless actors retain their stable idle presentation; only a retained
  -- cadence advances during the manager's presentation tick.
  mgr:step(101)
  Assert.equal(actor:getPoseTick(), 0, "normal step must not advance an idle pose clock")
end

function T.genuinely_missing_actor_still_faults()
  local eventState = FieldEventState.new()
  local assets = fakeAssets({ [99] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  local map = runtimeMap({ object({ eventFlag = 500 }) })
  mgr:enterMap(map, eventState)
  -- Flag 500 is clear, so actor 0 is live; actor 99 never exists.
  local player = {
    position = function()
      return { fieldX = 0, fieldZ = 0, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
    gender = function()
      return 0
    end,
    name = function()
      return "Gold"
    end,
  }
  local world = ScriptActorWorld.new(mgr --[[@as ScriptActorManager]], player)
  local services = FakeServices.new()
  services.world = eventState
  services.actors = world
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  local res = S.script({
    api = 1,
    id = "test.missing",
    steps = {
      S.showObject({ actor = "map:61:object:99" }),
      S.stop(),
    },
  })
  registry:installBase(res.id, res, "generated")
  local composed = assert(composition:effective(res.id))
  local instanceId = scheduler:createForeground(composed, nil, 150)
  scheduler:step(150, nil)
  local err = assert(services.events:eventFor("script.error", instanceId))
  Assert.equal(err.code, "SCRIPT_ACTOR_NOT_FOUND")
end

function T.multiple_queued_flags_converge_without_duplicate_actors()
  local state = FieldEventState.new({ flags = { [500] = true, [501] = true } })
  local mgr = FieldActorManager.new({ assets = fakeAssets({ [99] = true }), policy = POLICY })
  local map = runtimeMap({
    object({ objectEventId = 0, eventFlag = 500, x = 2 }),
    object({ objectEventId = 1, eventFlag = 501, x = 4 }),
  })
  mgr:enterMap(map, state)
  Assert.isNil(mgr:getById("map:61:object:0"))
  Assert.isNil(mgr:getById("map:61:object:1"))
  state:clearFlag(500)
  state:clearFlag(501)
  state:setFlag(500)
  -- Final state: 500 set (hidden), 501 clear (visible) => only actor 1 live.
  if mgr.syncEventStateChanges then
    mgr:syncEventStateChanges()
  else
    -- If the zero-time helper is not yet split, stepping would also advance pose;
    -- verify at least no duplicate and occupancy is valid.
    -- Use a sync-like helper if available on ScriptActorWorld.
    mgr:step(999)
  end
  Assert.isNil(mgr:getById("map:61:object:0"), "flag 500 ends set, actor 0 stays hidden")
  Assert.notNil(mgr:getById("map:61:object:1"), "flag 501 ends clear, actor 1 must be live")
  -- No duplicate visual acquisition.
  local count = 0
  for _ in ipairs(mgr:drawRecords()) do
    count = count + 1
  end
  Assert.equal(count, 1)
end

function T.repeated_sync_with_unchanged_presence_is_idempotent()
  local state = FieldEventState.new({ flags = {} })
  local assets = fakeAssets({ [99] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  local map = runtimeMap({ object({ eventFlag = 500 }) })
  mgr:enterMap(map, state)
  local actor = assert(mgr:getById("map:61:object:0"), "flag clear at map entry must materialize the actor")
  local acquiredAfterEnter = assets.references[99]
  actor:numericState().poseTick = 3

  -- No flag mutation queued anything: calling the zero-time reconciler
  -- again -- as a script that touches multiple flags in one tick would --
  -- must not duplicate the actor, touch its pose, or re-acquire its visual.
  mgr:syncEventStateChanges()
  mgr:syncEventStateChanges()

  Assert.equal(mgr:getById("map:61:object:0"), actor, "the same actor instance must remain live")
  Assert.equal(actor:getPoseTick(), 3, "an idempotent reconcile must not advance poseTick")
  Assert.equal(assets.references[99], acquiredAfterEnter, "an idempotent reconcile must not re-acquire the visual")
end

return { tests = T }
