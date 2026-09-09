-- Follower error recovery is narrow: only a recognized physical
-- placement or step rejection may become a silent retry or a movement
-- discontinuity. Unrelated structured failures keep their exact code and
-- context through the follower layer, and a follower visual missing from
-- the compiled actor set is a data failure, never a silent absence.
--
-- The recognized rejection below exercises the coordinate-coverage code
-- the actor owner already classifies as non-placeable; the unrelated
-- probe uses a save-bucket code no placement path may interpret.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FollowingMonController = require("libs.hgss.src.field.FollowingMonController")

local T = {}

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local function flatTerrain()
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

-- A terrain stand-in whose surface lookup fails with exactly the given
-- structured error, so placement classification is observable without
-- touching real geometry. Every other terrain query delegates to the real
-- flat plate, which keeps player construction and projection intact.
---@param err Errors.Error
---@return TerrainSurface
local function failingTerrain(err)
  return setmetatable({
    candidatesAt = function()
      error(err)
    end,
  }, { __index = flatTerrain() }) --[[@as TerrainSurface]]
end

---@param mapId integer?
---@param terrain TerrainSurface?
---@return RuntimeFieldMap
local function runtimeMap(mapId, terrain)
  return {
    mapId = mapId or 61,
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
      getLocal = function()
        return { blocked = false, behavior = 0 }
      end,
    },
    terrain = terrain or flatTerrain(),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    mapSymbol = "test-map",
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
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

local function mon(species)
  return {
    species = species or "CHIKORITA",
    form = 0,
    personality = 0x12345678,
    isEgg = false,
    condition = { status = 0, currentHp = 20 },
  }
end

local function service()
  return {
    _revision = 0,
    _slot = nil,
    _mons = {},
    partyRevision = function(self)
      return self._revision
    end,
    leadAliveSlot = function(self)
      return self._slot
    end,
    partyMon = function(self, slot)
      return self._mons[slot]
    end,
    setLead = function(self, slot, record)
      self._slot = slot
      if slot ~= nil then
        self._mons[slot] = record
      end
      self._revision = self._revision + 1
    end,
    clearLead = function(self)
      self._slot = nil
      self._revision = self._revision + 1
    end,
  }
end

local function structured(code)
  local _, err = pcall(Errors.raise, code, "probe failure", { probe = true })
  return assert(err)
end

local function world(opts)
  opts = opts or {}
  local map = runtimeMap(61, opts.terrain)
  local mgr = FieldActorManager.new({ assets = fakeAssets(opts.known or { [20153] = true }), policy = POLICY })
  mgr:enterMap(map, FieldEventState.new())
  local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 5, surfaceId = 0, facing = "south" })
  local svc = service()
  local controller = FollowingMonController.new({
    service = svc,
    catalog = CatalogFixture.makeCatalog(),
    actors = mgr,
    playerOf = function()
      return player
    end,
  })
  return { mgr = mgr, map = map, player = player, svc = svc, controller = controller }
end

local function tick(w, count)
  for _ = 1, count or 1 do
    w.controller:update()
  end
end

function T.recognized_placement_rejection_retries_without_fault()
  local w = world({ terrain = failingTerrain(structured(FieldErrors.FIELD_COORDINATES_OUT_OF_COVERAGE)) })
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.isNil(w.mgr:partnerId(), "an unplaceable tile installs nothing yet")
  w.mgr:dispose()
end

function T.unrelated_surface_failures_propagate_from_installation()
  local probe = structured(FieldErrors.FIELD_SAVE_MAP_INVALID)
  local w = world({ terrain = failingTerrain(probe) })
  w.svc:setLead(0, mon())
  local err = Assert.throws(function()
    tick(w, 2)
  end)
  Assert.isTrue(Errors.is(err), "an unrelated surface failure stays structured")
  Assert.equal(err.code, probe.code, "the failure keeps its exact code")
  Assert.deepEqual(err.context, probe.context, "the failure keeps its exact context")
  w.mgr:dispose()
end

function T.recognized_step_rejection_stays_a_nonfatal_discontinuity()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "setup installs the partner")
  -- The ordinary trail begins through the same classified begin seam the
  -- removed explicit path used: fail the first begin, then delegate, so
  -- the rejection reconciles and the republished partner survives.
  local begin = w.mgr.beginScriptedAction
  local calls = 0
  w.mgr.beginScriptedAction = function(self, ...)
    calls = calls + 1
    if calls == 1 then
      error(structured(FieldErrors.FIELD_COORDINATES_OUT_OF_COVERAGE))
    end
    return begin(self, ...)
  end
  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  tick(w, 12)
  Assert.notNil(w.mgr:partnerId(), "a rejected step keeps exactly one partner installed")
  w.mgr:dispose()
end

function T.unrelated_movement_failures_propagate_unchanged()
  local probe = structured(FieldErrors.FIELD_SAVE_MAP_INVALID)
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "setup installs the partner")
  w.mgr.beginScriptedAction = function()
    error(probe)
  end
  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  local err = Assert.throws(function()
    tick(w, 2)
  end)
  Assert.isTrue(Errors.is(err), "an unrelated movement failure stays structured")
  Assert.equal(err.code, probe.code, "the failure keeps its exact code")
  Assert.deepEqual(err.context, probe.context, "the failure keeps its exact context")
  w.mgr:dispose()
end

function T.missing_partner_visual_is_a_data_failure()
  local w = world()
  -- TOTODILE carries a follower descriptor the actor set below never
  -- compiled, so installation cannot silently wait it out.
  w.svc:setLead(0, mon("TOTODILE"))
  local err = Assert.throws(function()
    tick(w, 2)
  end)
  Assert.isTrue(Errors.is(err), "a missing follower visual is a structured failure")
  Assert.equal(err.code, FieldErrors.ACTOR_PARTNER_VISUAL_MISSING, "the failure names the missing partner visual")
  w.mgr:dispose()
end

return { tests = T }
