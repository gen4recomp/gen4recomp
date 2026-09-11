-- FieldTerrainEffectController tests ownership and fixed-tick lifetime
-- independently from GPU rendering.

local Assert = require("tests.support.Assert")
local FieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController")
local FieldTerrainResponse = require("libs.hgss.src.world.FieldTerrainResponse")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = { metadata = { capabilities = {} }, tests = {} }

local function updateWithOwner(effects, owner)
  local update = effects.updateFixed
  ---@cast update fun(self: table, owner: table)
  return update(effects, owner)
end

local function definition(kind)
  return {
    definition = "renderer-" .. kind,
    lifecycle = {
      mode = "hold_until_owner_moves",
      holdFrame = 12,
    },
    placementOffset = { x = 0.25, y = 0, z = -0.5 },
    model = { kind = "nitro-dynamic", animations = { { name = "grass", frameCount = 13 } } },
  }
end

local function genericDefinition(kind)
  kind = kind or "tall_grass"
  return {
    definition = "renderer-" .. kind,
    lifecycle = {
      mode = "hold_until_owner_moves",
      holdFrame = 3,
    },
    placementOffset = { x = 0.25, y = 0, z = -0.5 },
    model = { kind = "nitro-dynamic", animations = { { name = "grass", frameCount = 4 } } },
  }
end

local function controller(players, definitions)
  definitions = definitions
    or {
      tall_grass = definition("tall_grass"),
      very_tall_grass = definition("very_tall_grass"),
    }
  local function factory(_, source)
    local player = {
      frameFx = 0,
      frameCount = source.model.animations[1].frameCount,
      complete = false,
      updateCount = 0,
    }
    function player:updateFixed()
      self.updateCount = self.updateCount + 1
      self.frameFx = self.frameFx + 4096
      if self.frameFx >= self.frameCount * 4096 then
        self.frameFx = self.frameCount * 4096
        self.complete = true
      end
    end
    function player:isComplete()
      return self.complete
    end
    local instance = {}
    function instance:play()
      return { player = player }
    end
    function instance:updateFixed()
      player:updateFixed()
    end
    if players then
      players[#players + 1] = player
    end
    return instance
  end
  return FieldTerrainEffectController.new({
    effects = definitions,
    modelFactory = factory,
  })
end

T.tests["instances retain distinct semantic anchors"] = function()
  local effects = controller()
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 2, worldY = 4, direction = "east" })
  effects:emit({ kind = "tall_grass", fieldX = 2, fieldZ = 2, worldY = 4, direction = "east" })
  Assert.equal(#effects:status().instances, 2)
  Assert.equal(effects:status().instances[1].fieldX, 1)
  Assert.equal(effects:status().instances[2].fieldX, 2)
end

T.tests["grass instances retain stable source-surface identity"] = function()
  local effects = controller()
  effects:emit({
    kind = "tall_grass",
    fieldX = 34,
    fieldZ = 5,
    worldY = 7,
    direction = "north",
    cellKey = "1:0",
    sourceSurfaceId = 3,
  })
  local instance = effects:status().instances[1]
  Assert.equal(instance.cellKey, "1:0")
  Assert.equal(instance.sourceSurfaceId, 3)
end

T.tests["discontinuous clear disposes all transient instances"] = function()
  local effects = controller()
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "south" })
  effects:clear()
  Assert.equal(#effects:status().instances, 0)
end

T.tests["grass intro completes before owner displacement retires it"] = function()
  for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
    local players = {}
    local effects = controller(players, { [kind] = genericDefinition(kind) })
    effects:emit({ kind = kind, fieldX = 7, fieldZ = 9, worldY = 3.5, direction = "north" })

    updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "north" })
    local first = effects:status().instances[1]
    Assert.notNil(first)
    Assert.equal(first.age, 1)
    Assert.equal(first.frame, 1)

    for tick = 2, 3 do
      updateWithOwner(effects, { fieldX = 8, fieldZ = 9, facing = "north" })
      local instance = effects:status().instances[1]
      Assert.notNil(instance)
      Assert.equal(instance.age, tick)
      Assert.equal(instance.frame, tick)
    end
    Assert.equal(players[1].updateCount, 3)

    updateWithOwner(effects, { fieldX = 8, fieldZ = 9, facing = "north" })
    Assert.equal(#effects:status().instances, 0)
  end
end

T.tests["explicit directional grass responses retire on facing changes"] = function()
  for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
    local players = {}
    local effects = controller(players, { [kind] = genericDefinition(kind) })
    effects:emit({ kind = kind, fieldX = 7, fieldZ = 9, worldY = 3.5, direction = "north" })

    for tick = 1, 3 do
      updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "east" })
      local instance = effects:status().instances[1]
      Assert.notNil(instance)
      Assert.equal(instance.age, tick)
      Assert.equal(instance.frame, tick)
    end
    Assert.equal(players[1].updateCount, 3)

    updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "north" })
    local held = effects:status().instances[1]
    Assert.notNil(held)
    Assert.equal(held.frame, 3)
    Assert.equal(players[1].updateCount, 3)

    updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "east" })
    Assert.equal(#effects:status().instances, 0)
  end
end

T.tests["ordinary grass responses survive turns and retire after displacement"] = function()
  local behaviors = {
    { behavior = MetatileBehavior.BEHAVIOR.TALL_GRASS, kind = "tall_grass" },
    { behavior = MetatileBehavior.BEHAVIOR.VERY_TALL_GRASS, kind = "very_tall_grass" },
  }
  for _, grass in ipairs(behaviors) do
    local effects = controller(nil, { [grass.kind] = genericDefinition(grass.kind) })
    local responses = FieldTerrainResponse.resolve({
      committed = true,
      destination = {
        behavior = grass.behavior,
        fieldX = 7,
        fieldZ = 9,
        worldY = 3.5,
        cellKey = "1:2",
        sourceSurfaceId = 4,
      },
      direction = "north",
    })
    Assert.equal(#responses, 1)
    effects:emitAll(responses)

    for tick = 1, 3 do
      local facing = tick % 2 == 0 and "east" or "north"
      updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = facing })
      local instance = effects:status().instances[1]
      Assert.notNil(instance)
      Assert.equal(instance.age, tick)
      Assert.equal(instance.frame, tick)
    end

    updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "east" })
    Assert.equal(#effects:status().instances, 1)

    updateWithOwner(effects, { fieldX = 8, fieldZ = 9, facing = "east" })
    Assert.equal(#effects:status().instances, 0)
  end
end

T.tests["held grass removals do not skip neighboring instances"] = function()
  local effects = controller(nil, { tall_grass = genericDefinition("tall_grass") })
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "north" })
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "east" })
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "south" })

  for _ = 1, 3 do
    updateWithOwner(effects, { fieldX = 1, fieldZ = 1, facing = "north" })
  end
  updateWithOwner(effects, { fieldX = 1, fieldZ = 1, facing = "north" })

  local instances = effects:status().instances
  Assert.equal(#instances, 1)
  Assert.equal(instances[1].fieldX, 1)
end

T.tests["dynamic grass instances change pose independently from their semantic age"] = function()
  local clip = NitroModelFixture.doorOpenClip()
  local effectDefinition = {
    lifecycle = { mode = "hold_until_owner_moves", holdFrame = 12 },
    placementOffset = { x = 0.25, y = 0, z = -0.5 },
    model = { kind = "nitro-dynamic", animations = { { name = clip.name, frameCount = 13 } } },
  }
  local effects = FieldTerrainEffectController.new({
    effects = { tall_grass = effectDefinition },
    modelFactory = function()
      local instance = ModelInstance.new(NitroModelFixture.doorDefinition({ clip }))
      instance.renderMeshesById = { ["draw0.seg0"] = {} }
      return instance
    end,
  })
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "east" })
  local first = effects:status().instances[1].modelInstance
  first:evaluatePose()
  -- The draw list is a live view overwritten by each evaluation, so capture
  -- the numbers before advancing: retaining the table would observe the next
  -- frame.
  local firstItem = first:drawItems(first.renderMeshesById)[1]
  local firstCell1, firstCell3 = firstItem.transform[1], firstItem.transform[3]
  Assert.equal(effects:status().instances[1].frame, 0)

  effects:updateFixed({ fieldX = 1, fieldZ = 1, facing = "east" })
  local second = effects:status().instances[1].modelInstance
  second:evaluatePose()
  local secondTransform = second:drawItems(second.renderMeshesById)[1].transform
  Assert.isFalse(firstCell1 == secondTransform[1] and firstCell3 == secondTransform[3])
end

T.tests["one-shot reveal retires after exactly seven fixed frames"] = function()
  local effects = controller(nil, {
    trainer_reveal = {
      definition = "renderer-trainer_reveal",
      lifecycle = { mode = "once", frameCount = 7 },
      placementOffset = { x = 0, y = 0, z = 0.5 },
      model = { kind = "nitro-dynamic", animations = { { name = "reveal", frameCount = 7 } } },
    },
  })
  effects:emit({ kind = "trainer_reveal", fieldX = 2, fieldZ = 5, worldY = 3 })
  for tick = 1, 6 do
    updateWithOwner(effects, { fieldX = 2, fieldZ = 5, facing = "south" })
    local instance = effects:status().instances[1]
    Assert.notNil(instance, "reveal must stay live through frame " .. tick)
    Assert.equal(instance.age, tick)
  end
  updateWithOwner(effects, { fieldX = 2, fieldZ = 5, facing = "south" })
  Assert.equal(#effects:status().instances, 0)
end

T.tests["failed second emission preserves the live instance"] = function()
  local calls = 0
  local function factory(kind, _)
    calls = calls + 1
    if calls > 1 then
      error("boom-model-" .. kind)
    end
    local player = { frameFx = 0, frameCount = 7, complete = false }
    function player:isComplete()
      return self.complete
    end
    local instance = {}
    function instance:play()
      return { player = player }
    end
    function instance:updateFixed() end
    return instance
  end
  local effects = FieldTerrainEffectController.new({
    effects = {
      trainer_reveal = {
        definition = "renderer-trainer_reveal",
        lifecycle = { mode = "once", frameCount = 7 },
        placementOffset = { x = 0, y = 0, z = 0.5 },
        model = { kind = "nitro-dynamic", animations = { { name = "reveal", frameCount = 7 } } },
      },
    },
    modelFactory = factory,
  })
  local firstId = effects:emit({ kind = "trainer_reveal", fieldX = 2, fieldZ = 5, worldY = 3 })
  local ok, err = pcall(function()
    effects:emit({ kind = "trainer_reveal", fieldX = 2, fieldZ = 5, worldY = 3 })
  end)
  Assert.isFalse(ok, "the second emission must raise")
  Assert.notNil(err)
  local instances = effects:status().instances
  Assert.equal(#instances, 1, "a failed emission must not destroy the live instance")
  Assert.equal(instances[1].id, firstId)
end

return T
