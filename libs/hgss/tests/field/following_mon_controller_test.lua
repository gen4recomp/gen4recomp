-- Following-controller ownership: eligibility/active/visible/installed split,
-- committed-anchor trail queue, pause/wait settlement, transition
-- reconciliation, atomic lead replacement, and script queries. The actor
-- manager is real (the owned seam); the party service and player anchor
-- source are scriptable fakes at their documented contracts.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
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
    terrain = terrain(),
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

local function mon(species, personality)
  return {
    species = species or "CHIKORITA",
    form = 0,
    personality = personality or 0x12345678,
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
    partyCount = function(self)
      local count = 0
      for _ in pairs(self._mons) do
        count = count + 1
      end
      return count
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

local function world()
  local map = runtimeMap(61)
  local assets = fakeAssets({ [20153] = true, [20154] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  mgr:enterMap(map, FieldEventState.new())
  local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 5, surfaceId = 0, facing = "south" })
  local svc = service()
  local catalog = CatalogFixture.makeCatalog()
  local controller = FollowingMonController.new({
    service = svc,
    catalog = catalog,
    actors = mgr,
    playerOf = function()
      return player
    end,
  })
  return {
    mgr = mgr,
    assets = assets,
    map = map,
    player = player,
    svc = svc,
    catalog = catalog,
    controller = controller,
  }
end

local function stepSouth(w)
  Assert.isTrue(w.player:tryStep("south"), "the fixture step must commit")
  for _ = 1, 10 do
    w.player:updateFixed({})
  end
  Assert.equal(w.player.motion, "idle", "the step must settle")
end

local function tick(w, count)
  for _ = 1, count or 1 do
    w.controller:update()
  end
end

function T.eligible_lead_installs_behind_the_player()
  local w = world()
  Assert.isFalse(w.controller:isActive(), "an empty party is not active")
  Assert.isNil(w.mgr:partnerId(), "an empty party installs nothing")
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.isTrue(w.controller:isActive(), "the gifted lead is active")
  Assert.isTrue(w.controller:isVisible(), "the permitted map is visible")
  local id = w.mgr:partnerId()
  Assert.equal(id, "field:partner", "one partner installs")
  Assert.equal(w.controller:partnerActorId(), "field:partner", "the query reflects the actor")
  local actor = assert(w.mgr:getById("field:partner"))
  Assert.equal(actor.spriteId, 20153, "the Chikorita descriptor selects its visual")
  Assert.equal(actor.fieldX, 4, "initial placement is the tile behind the player")
  Assert.equal(actor.fieldZ, 4, "initial placement is the tile behind the player")
  Assert.equal(actor.facing, "south", "installation keeps the player facing")
  w.mgr:dispose()
end

function T.partner_source_state_reads_the_generated_object_parameter_nibble()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.equal(w.controller:partnerSourceState(), 4, "the source state masks the generated object parameter")
  w.mgr:dispose()
end

function T.ineligible_leads_never_install()
  local w = world()
  w.svc:setLead(0, mon("EEVEE"))
  tick(w, 2)
  Assert.isFalse(w.controller:isActive(), "a lead without a follower visual is not active")
  Assert.isNil(w.mgr:partnerId(), "no visual installs no actor")
  w.svc:clearLead()
  tick(w, 2)
  Assert.isFalse(w.controller:isActive(), "an empty party is not active")
  Assert.isNil(w.mgr:partnerId(), "clearing installs nothing")
  w.mgr:dispose()
end

function T.partner_replays_committed_anchors_and_settles()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  stepSouth(w)
  tick(w, 2)
  Assert.isFalse(w.controller:isMovementSettled(), "a queued anchor keeps the follower busy")
  tick(w, 30)
  local actor = assert(w.mgr:getById("field:partner"), "the partner survives the trail")
  Assert.equal(actor.fieldX, 4, "the partner replays the vacated tile")
  Assert.equal(actor.fieldZ, 5, "the partner replays the vacated tile")
  Assert.isTrue(w.controller:isMovementSettled(), "the drained queue settles")
  w.mgr:dispose()
end

function T.pause_retains_the_queue_and_resume_drains_it()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  w.controller:setMovementPaused(true)
  w.controller:setMovementPaused(true)
  stepSouth(w)
  tick(w, 20)
  local actor = assert(w.mgr:getById("field:partner"))
  Assert.equal(actor.fieldZ, 4, "a paused follower holds its tile")
  -- A paused queue is retained, not drained, so a wait issued while paused
  -- settles instead of hanging: settlement never means "queue empty" alone.
  Assert.isTrue(w.controller:isMovementSettled(), "a paused follower never hangs a wait")
  w.controller:setMovementPaused(false)
  tick(w, 30)
  actor = assert(w.mgr:getById("field:partner"))
  Assert.equal(actor.fieldZ, 5, "resume replays the retained anchor")
  Assert.isTrue(w.controller:isMovementSettled(), "the drained queue settles after resume")
  w.mgr:dispose()
end

function T.overlong_paused_queue_reconciles_instead_of_replaying()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  w.controller:setMovementPaused(true)
  for _ = 1, 10 do
    stepSouth(w)
    tick(w, 2)
  end
  Assert.equal(w.player.fieldZ, 15, "ten steps commit while paused")
  w.controller:setMovementPaused(false)
  tick(w, 40)
  local actor = assert(w.mgr:getById("field:partner"))
  Assert.equal(actor.fieldZ, 14, "the overlong queue snaps behind the player instead of replaying stale anchors")
  Assert.isTrue(w.controller:isMovementSettled(), "the reconciled queue settles")
  w.mgr:dispose()
end

function T.explicit_movement_takes_over_the_trail()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  stepSouth(w)
  tick(w, 2)
  w.controller:startMovement({ action = "jump", direction = "east", distance = "zero", speed = "fast" })
  tick(w, 12)
  Assert.isTrue(w.controller:isMovementSettled(), "explicit movement settles through the controller")
  local actor = assert(w.mgr:getById("field:partner"))
  Assert.equal(actor.fieldX, 4, "the scripted hop does not inherit the cleared trail")
  Assert.equal(actor.fieldZ, 4, "the scripted hop does not inherit the cleared trail")
  w.mgr:dispose()
end

function T.teleport_snaps_the_partner_and_drops_stale_anchors()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  stepSouth(w)
  tick(w, 2)
  w.player:setScriptPosition({ fieldX = 20, fieldZ = 20 })
  tick(w, 3)
  local actor = assert(w.mgr:getById("field:partner"), "the partner survives the discontinuity")
  Assert.equal(actor.fieldX, 20, "the snap lands behind the player")
  Assert.equal(actor.fieldZ, 19, "the snap lands behind the player")
  Assert.isTrue(w.controller:isMovementSettled(), "stale anchors never replay after a snap")
  w.mgr:dispose()
end

function T.map_change_clears_the_queue_and_reinstalls()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  stepSouth(w)
  tick(w, 2)
  local nextMap = runtimeMap(62)
  w.mgr:enterMap(nextMap, FieldEventState.new())
  w.player.currentMap = nextMap
  tick(w, 3)
  local actor = assert(w.mgr:getById("field:partner"), "the new map reinstalls the partner")
  Assert.equal(actor.mapId, 62, "the reinstalled actor belongs to the new map")
  Assert.isTrue(w.controller:isMovementSettled(), "the old-map queue does not survive")
  w.mgr:dispose()
end

function T.party_swap_replaces_atomically_and_keeps_pause()
  local w = world()
  w.svc:setLead(0, mon("CHIKORITA"))
  tick(w, 2)
  w.controller:setMovementPaused(true)
  w.svc:setLead(0, mon("TOTODILE"))
  tick(w, 2)
  Assert.equal(w.mgr:partnerId(), "field:partner", "exactly one partner survives the swap")
  Assert.equal(w.mgr:getById("field:partner").spriteId, 20154, "the new lead visual publishes")
  Assert.equal(w.assets.references[20153] or 0, 0, "the old visual releases after publication")
  Assert.isTrue(w.controller:isMovementSettled(), "swap clears the queue without motion")
  w.controller:setMovementPaused(false)
  w.mgr:dispose()
end

function T.lost_lead_clears_without_ghosts()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "setup installs the partner")
  w.svc:clearLead()
  tick(w, 2)
  Assert.isFalse(w.controller:isActive(), "a lost lead deactivates")
  Assert.isNil(w.mgr:partnerId(), "clearing removes the actor")
  Assert.equal(w.assets.references[20153] or 0, 0, "clearing releases the visual")
  w.mgr:dispose()
end

function T.script_queries_read_live_state()
  local w = world()
  Assert.equal(w.controller:isEventTrigger(1, 0), false, "no trigger without a partner")
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.equal(w.controller:isEventTrigger(1, 0), true, "an idle installed partner triggers")
  Assert.equal(w.controller:isEventTrigger(9, 0), false, "unknown trigger kinds stay false")
  w.player:turn("north")
  w.controller:facePlayer()
  Assert.equal(w.mgr:getById("field:partner").facing, "south", "face turns the partner toward the player")
  w.mgr:dispose()
end

function T.failed_replacement_raises_and_keeps_the_old_actor()
  local w = world()
  local assets = fakeAssets({ [20153] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  local map = runtimeMap(61)
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
  svc:setLead(0, mon("CHIKORITA"))
  controller:update()
  controller:update()
  Assert.notNil(mgr:partnerId(), "setup installs the partner")
  -- TOTODILE carries a follower descriptor the actor set never compiled, so
  -- the replacement is a data failure, never a silent retry.
  svc:setLead(0, mon("TOTODILE"))
  local err = Assert.throws(function()
    controller:update()
  end)
  Assert.isTrue(Errors.is(err), "a missing replacement visual is a structured failure")
  Assert.equal(err.code, FieldErrors.ACTOR_PARTNER_VISUAL_MISSING, "the failure names the missing partner visual")
  Assert.equal(mgr:getById("field:partner").spriteId, 20153, "the old actor survives the failed acquisition")
  Assert.equal(assets.references[20153], 1, "the old visual keeps its single reference")
  mgr:dispose()
  w.mgr:dispose()
end

return { tests = T }
