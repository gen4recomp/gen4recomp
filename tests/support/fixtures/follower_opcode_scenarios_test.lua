-- Production-boundary scenarios for follower source state and visibility.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FollowingMonTransitionController = require("libs.hgss.src.field.FollowingMonTransitionController")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local PARTNER_ID = "field:partner"
local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local function var(id)
  return { value = "var", id = id }
end

local function runWithSourceState(sourceState)
  local stored = {}
  local followingMon = {
    partnerActorId = function()
      return PARTNER_ID
    end,
    partnerSourceState = function()
      return sourceState
    end,
  }
  return {
    instance = { scriptId = "test.follower", locals = {}, textArgs = {} },
    services = {
      followingMon = followingMon,
      world = {
        getVar = function(_, id)
          return stored[id]
        end,
        setVar = function(_, id, value)
          stored[id] = value
        end,
      },
    },
    semantics = RuntimeValues,
    scheduler = {},
    tick = 1,
    input = {},
  },
    stored
end

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

local function runtimeMap()
  return {
    mapId = 61,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = { events = { objects = {}, background = {}, warps = {}, coordinates = {} } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = terrain(),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    mapSymbol = "test-map",
    release = function() end,
    updateAnimated = function() end,
  }
end

local function actorAssets()
  local assets = {
    references = {},
    knows = function(_, spriteId)
      return spriteId == 20153 or spriteId == 20154
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced partner visual release")
      self.references[spriteId] = count - 1
    end,
  }
  return assets
end

local function actorManager()
  local manager = FieldActorManager.new({ assets = actorAssets(), policy = POLICY })
  manager:enterMap(runtimeMap(), FieldEventState.new())
  return manager
end

local function partner(visualId)
  return {
    numericId = 253,
    visualId = visualId or 20153,
    mapId = 61,
    fieldX = 4,
    fieldZ = 5,
    facing = "north",
  }
end

local function definition()
  return {
    models = {
      { kind = "static" },
      { kind = "nitro-dynamic", animations = { { name = "transition", frameCount = 5 } } },
    },
    lifecycle = { mode = "once", preludeTicks = 2, frameCount = 5 },
    placementOffset = { x = 0, y = 6, z = 0 },
  }
end

local function modelFactory(part, descriptor)
  local frameCount = part == "animated" and descriptor.animations[1].frameCount or 0
  local player = { frame = 0, frameCount = frameCount, disposed = false }
  function player:updateFixed()
    self.frame = self.frame + 1
  end
  function player:isComplete()
    return self.frame >= self.frameCount
  end
  function player:reset()
    self.frame = 0
  end
  function player:dispose()
    self.disposed = true
  end
  return player
end

local function transition(manager, factory)
  return FollowingMonTransitionController.new({
    actors = manager,
    definition = definition(),
    modelFactory = factory or modelFactory,
  })
end

function T.partner_state_reports_source_object_param_nibble()
  local descriptor = { objectParam = 0x0307 }
  local sourceNibble = math.floor(descriptor.objectParam / 256) % 16
  local run, stored = runWithSourceState(sourceNibble)
  Assert.equal(
    Runtime.executeNode({ op = "follower_partner_state", result = var(0x800C) }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(stored[0x800C], 3, "the source parameter nibble reaches the script variable")
end

function T.transition_hides_then_reveals_captured_partner()
  local actors = actorManager()
  local ok, err = pcall(function()
    actors:installPartner(partner())
    local transitions = transition(actors)
    Assert.isTrue(actors:isVisible(PARTNER_ID), "ordinary partner installation is visible")
    Assert.isTrue(transitions:start(), "a live partner starts one instance")
    Assert.isFalse(actors:isVisible(PARTNER_ID), "the captured partner hides at transition start")
    transitions:updateFixed()
    Assert.isFalse(actors:isVisible(PARTNER_ID), "the partner stays hidden through the prelude")
    transitions:updateFixed()
    Assert.isTrue(actors:isVisible(PARTNER_ID), "the captured partner reveals at the prelude boundary")
    Assert.equal(#transitions:status().instances, 1, "the transition remains live after revealing")
  end)
  actors:dispose()
  if not ok then
    error(err, 0)
  end
end

function T.stale_transition_does_not_mutate_replacement_partner()
  local actors = actorManager()
  local ok, err = pcall(function()
    actors:installPartner(partner())
    local captured = assert(actors:getById(PARTNER_ID))
    local transitions = transition(actors)
    Assert.isTrue(transitions:start(), "a live partner starts one instance")
    Assert.equal(actors:updatePartner(partner(20154)), PARTNER_ID, "replacement keeps the partner identity")
    local replacement = assert(actors:getById(PARTNER_ID))
    Assert.isFalse(captured.visible, "the captured generation was hidden before replacement")
    Assert.isTrue(replacement.visible, "the replacement keeps ordinary visible installation")
    transitions:updateFixed()
    Assert.equal(#transitions:status().instances, 0, "the stale transition retires before reveal")
    Assert.isTrue(actors:isVisible(PARTNER_ID), "stale cleanup does not hide the replacement")
  end)
  actors:dispose()
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
