-- Partner-actor lifecycle: the one dynamic follower actor the following
-- controller owns through the narrow manager seam. Installation pins the
-- source partner object id, stays non-solid, and remains discoverable;
-- replacement acquires before it releases; clearing releases exactly once.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

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

local function runtimeMap(mapId)
  return {
    mapId = mapId or 61,
    mapSection = "test-section",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 40 and z >= 0 and z < 32
      end,
    },
    terrain = terrain(),
    mapSymbol = "test-map",
    sceneRuntime = nil,
    scene = {},
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 4,
    fieldData = { events = { objects = {}, background = {}, warps = {}, coordinates = {} } },
    release = function() end,
    updateAnimated = function() end,
  }
end

local function fakeAssets(known)
  local assets = {
    references = {},
    knows = function(_, spriteId)
      return known[spriteId] == true
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced release of spriteId " .. spriteId)
      self.references[spriteId] = count - 1
    end,
  }
  return assets
end

local function manager(mapId, known)
  local assets = fakeAssets(known or { [20153] = true, [20154] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  local map = runtimeMap(mapId)
  mgr:enterMap(map, FieldEventState.new())
  return mgr, assets, map
end

local function spec(mapId, overrides)
  local record = {
    numericId = 253,
    visualId = 20153,
    mapId = mapId or 61,
    fieldX = 4,
    fieldZ = 5,
    facing = "north",
  }
  for key, value in pairs(overrides or {}) do
    rawset(record, key, value)
  end
  return record
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

function T.installs_the_reserved_partner_as_a_real_non_solid_actor()
  local mgr = manager()
  Assert.isNil(mgr:partnerId(), "no partner is installed before the controller places one")
  local id = mgr:installPartner(spec())
  Assert.equal(id, "field:partner", "the partner keeps its stable actor identity")
  Assert.equal(mgr:partnerId(), "field:partner", "the script lookup reflects the dynamic partner")
  Assert.equal(mgr:numericId("field:partner"), 253, "the partner keeps the source numeric id")
  local actor = assert(mgr:getById("field:partner"), "the partner is a live actor")
  Assert.isFalse(actor.solid, "the partner never blocks tiles")
  Assert.isNil(
    mgr:getCollisionAt(61, { fieldX = 4, fieldZ = 5, surfaceId = actor.surfaceId }),
    "collision ignores the non-solid partner"
  )
  Assert.equal(
    mgr:getAt(61, { fieldX = 4, fieldZ = 5, surfaceId = actor.surfaceId }).actorId,
    "field:partner",
    "interaction discovery still finds the partner by tile"
  )
  local found = false
  for _, listed in ipairs(mgr:actorsOf(61)) do
    if listed.actorId == "field:partner" then
      found = true
    end
  end
  Assert.isTrue(found, "the partner stays in the actor set")
  mgr:dispose()
end

function T.rejects_partner_specs_that_misuse_the_seam()
  local mgr = manager()
  throwsCode("ACTOR_PARTNER_MAP_MISMATCH", function()
    mgr:installPartner(spec(62))
  end)
  throwsCode("ACTOR_PARTNER_ID_INVALID", function()
    mgr:installPartner(spec(nil, { numericId = 7 }))
  end)
  throwsCode("ACTOR_PARTNER_SOLID_INVALID", function()
    mgr:installPartner(spec(nil, { solid = true }))
  end)
  Assert.isNil(mgr:partnerId(), "rejected installs publish nothing")
  mgr:dispose()
end

function T.unknown_visuals_fail_before_any_actor_exists()
  local mgr, assets = manager()
  throwsCode("ACTOR_PARTNER_VISUAL_MISSING", function()
    mgr:installPartner(spec(nil, { visualId = 424242 }))
  end)
  Assert.isNil(mgr:partnerId(), "a failed install publishes no actor")
  Assert.isNil(assets.references[424242], "a failed install acquires no visual")
  mgr:dispose()
end

function T.replacement_acquires_first_and_releases_old_after_publish()
  local mgr, assets = manager()
  mgr:installPartner(spec())
  local id = mgr:updatePartner(spec(nil, { visualId = 20154 }))
  Assert.equal(id, "field:partner", "replacement keeps the stable identity")
  Assert.equal(mgr:getById("field:partner").spriteId, 20154, "the new visual is live")
  Assert.equal(assets.references[20153] or 0, 0, "the old visual is released after publication")
  Assert.equal(assets.references[20154], 1, "the new visual has exactly one reference")
  throwsCode("ACTOR_PARTNER_VISUAL_MISSING", function()
    mgr:updatePartner(spec(nil, { visualId = 424242 }))
  end)
  Assert.equal(mgr:getById("field:partner").spriteId, 20154, "a failed replacement keeps the old actor")
  Assert.equal(assets.references[20154], 1, "a failed replacement keeps the old visual")
  mgr:dispose()
end

function T.clearing_releases_exactly_once_and_stays_idempotent()
  local mgr, assets = manager()
  mgr:installPartner(spec())
  mgr:clearPartner()
  Assert.isNil(mgr:partnerId(), "clearing removes the script lookup")
  Assert.isNil(mgr:getById("field:partner"), "clearing removes the live actor")
  Assert.equal(assets.references[20153] or 0, 0, "clearing releases the visual once")
  mgr:clearPartner()
  Assert.equal(assets.references[20153] or 0, 0, "a second clear releases nothing")
  mgr:dispose()
end

function T.map_transitions_retire_the_partner_without_leaking_the_visual()
  local mgr, assets = manager()
  mgr:installPartner(spec())
  local nextMap = runtimeMap(62)
  mgr:enterMap(nextMap, FieldEventState.new())
  Assert.isNil(mgr:partnerId(), "the old-map partner does not survive the transition")
  Assert.equal(assets.references[20153] or 0, 0, "the transition releases the visual once")
  local id = mgr:installPartner(spec(62))
  Assert.equal(id, "field:partner", "the new map accepts a fresh installation")
  mgr:dispose()
end

function T.saved_actor_snapshots_never_carry_the_partner()
  local mgr = manager()
  mgr:installPartner(spec())
  local captured = mgr:captureObjects()
  Assert.isNil(captured.actors["field:partner"], "follower presentation is derived, never persisted")
  mgr:dispose()
end

return { tests = T }
