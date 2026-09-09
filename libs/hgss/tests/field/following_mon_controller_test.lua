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

local function world(options)
  options = options or {}
  local map = runtimeMap(61)
  local assets = fakeAssets({ [20153] = true, [20154] = true })
  local mgr = FieldActorManager.new({ assets = assets, policy = POLICY })
  mgr:enterMap(map, FieldEventState.new())
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = options.fieldX or 4,
    fieldZ = options.fieldZ or 5,
    surfaceId = 0,
    facing = options.facing or "south",
  })
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

-- A stationary follower owns no presentation action: idling never starts a
-- scripted movement, never leaves an in-flight obligation, and never makes
-- the controller report busy. The partner actor animates through its own
-- visual clock instead.
function T.stationary_follower_owns_no_presentation_action()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 3)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  Assert.isNil(w.controller._action, "a stationary follower holds no movement obligation")
  Assert.isTrue(w.controller:isMovementSettled(), "a stationary follower stays settled")
  local actor = assert(w.mgr:getById(partnerId), "the partner actor is required")
  Assert.equal(actor.pose, "idle", "a stationary follower presents idle, never locomotion")
  Assert.isNil(actor:scriptedMotionState(), "no scripted presentation owns the stationary partner")
  tick(w, 10)
  Assert.isNil(w.controller._action, "idle ticks start no presentation action")
  Assert.isTrue(w.controller:isMovementSettled(), "the follower stays settled while idle")
  w.mgr:dispose()
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

function T.mid_map_lead_birth_installs_hidden_but_map_entry_stays_visible()
  local mapEntry = world()
  mapEntry.svc:setLead(0, mon())
  tick(mapEntry, 2)
  local visible = assert(mapEntry.mgr:getById("field:partner"), "a map-entry lead installs a partner")
  Assert.isTrue(visible.visible, "normal map-entry reconstruction remains visible")
  mapEntry.mgr:dispose()

  local midMap = world()
  tick(midMap, 1)
  midMap.svc:setLead(0, mon())
  tick(midMap, 2)
  local hidden = assert(midMap.mgr:getById("field:partner"), "the mid-map lead birth installs a partner")
  Assert.isFalse(hidden.visible, "a newly published mid-map lead starts hidden")
  midMap.mgr:dispose()
end

function T.hidden_birth_retries_after_placement_rejection()
  local w = world({ fieldX = 0, facing = "east" })
  tick(w, 1)
  w.svc:setLead(0, mon())
  tick(w, 1)
  Assert.isNil(w.mgr:partnerId(), "an unplaceable hidden birth remains unpublished")

  w.player.facing = "south"
  tick(w, 1)
  local actor = assert(w.mgr:getById("field:partner"), "the hidden birth retries on a later tick")
  Assert.isFalse(actor.visible, "the retry keeps the hidden publication intent")
  w.mgr:dispose()
end

function T.invalidated_hidden_birth_does_not_apply_to_a_replacement_lead()
  local w = world({ fieldX = 0, facing = "east" })
  tick(w, 1)
  w.svc:setLead(0, mon("CHIKORITA"))
  tick(w, 1)
  Assert.isNil(w.mgr:partnerId(), "the first lead is still waiting for placement")

  w.player.facing = "south"
  w.svc:setLead(0, mon("TOTODILE"))
  tick(w, 1)
  local actor = assert(w.mgr:getById("field:partner"), "the replacement lead publishes")
  Assert.isTrue(actor.visible, "a replacement lead does not inherit stale hidden intent")
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

-- The follower movement mode is controller-owned runtime state: a new
-- controller free-follows, each semantic mode sets without starting actor
-- movement by itself, repeats are idempotent, the latest set wins, and
-- anything outside the semantic trio is a programmer fault.
function T.movement_mode_defaults_to_free_follow()
  local w = world()
  Assert.equal(w.controller._movementType, "follow_player", "a new controller free-follows")
  Assert.isTrue(w.controller:isMovementSettled(), "a new controller has no in-flight movement")
  w.mgr:dispose()
end

function T.movement_mode_sets_start_no_actor_movement()
  for _, mode in ipairs({ "follow_player", "follow_transition_a", "follow_transition_b" }) do
    local w = world()
    w.svc:setLead(0, mon())
    tick(w, 2)
    local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
    local before = assert(w.mgr:getPosition(partnerId), "the partner position is required")
    w.controller:setMovementType(mode)
    w.controller:setMovementType(mode)
    Assert.equal(w.controller._movementType, mode, "a repeated set keeps the mode without faulting")
    local after = assert(w.mgr:getPosition(partnerId), "the partner survives the mode sets")
    Assert.equal(after.fieldX, before.fieldX, mode .. " must not displace the partner")
    Assert.equal(after.fieldZ, before.fieldZ, mode .. " must not displace the partner")
    Assert.isTrue(w.controller:isMovementSettled(), mode .. " must start no actor movement by itself")
    w.mgr:dispose()
  end
end

function T.movement_mode_keeps_the_latest_transition_identity()
  local w = world()
  w.controller:setMovementType("follow_transition_a")
  w.controller:setMovementType("follow_transition_b")
  Assert.equal(
    w.controller._movementType,
    "follow_transition_b",
    "the latest set wins even when both modes share transition behavior"
  )
  w.mgr:dispose()
end

function T.movement_mode_rejects_values_outside_the_semantic_trio()
  local w = world()
  for _, bad in ipairs({ "jump", "follow_swimmer", "", "FOLLOW_PLAYER", "stationary" }) do
    Assert.throws(function()
      w.controller:setMovementType(bad)
    end, "an unknown mode must fail, got: " .. tostring(bad))
  end
  local raw = 48
  Assert.throws(function()
    w.controller:setMovementType(raw --[[@as string]])
  end, "a raw source selector must never reach the runtime setter")
  Assert.equal(w.controller._movementType, "follow_player", "a rejected set keeps the previous mode")
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

-- Ordinary following starts in the same fixed-step epoch as the player
-- step: once the player begins a normal walk, the follower is already
-- walking toward the vacated tile before the player commits, instead of
-- waiting a whole step and replaying the trail afterwards.
function T.ordinary_follow_starts_before_the_player_commits()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  local installed = assert(w.mgr:getById(partnerId), "the partner actor is required")
  local startWorldZ = installed.worldZ
  local vacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }

  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  Assert.isTrue(w.player.motion ~= "idle", "the player step is in flight")
  -- The same fixed-step epoch the production runtime uses: the player has
  -- resolved and begun, and following observes before the player advances.
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the follower starts while the player step is still in flight")
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the step start")
  Assert.equal(actor.pose, "walk", "the follower walks while the player step is in flight")
  Assert.equal(actor.facing, "south", "the follower faces the vacated tile")

  -- Mid-step both actors are in flight on the same interval.
  for _ = 1, 3 do
    w.player:updateFixed({})
    w.controller:update()
  end
  Assert.isTrue(w.player.motion ~= "idle", "the player is still in flight mid-step")
  actor = assert(w.mgr:getById(partnerId), "the partner survives mid-step")
  Assert.equal(actor.pose, "walk", "the follower is still walking mid-step")
  Assert.isTrue(actor.worldZ > startWorldZ, "the follower has visibly left its original tile")

  -- Both settle on the normal walk boundary with the follower on the tile
  -- the player vacated, not on the player destination.
  for _ = 1, 12 do
    if w.player.motion ~= "idle" then
      w.player:updateFixed({})
    end
    w.controller:update()
  end
  Assert.equal(w.player.motion, "idle", "the player step completes")
  Assert.equal(w.player.fieldZ, vacated.fieldZ + 1, "the player commits one tile south")
  actor = assert(w.mgr:getById(partnerId), "the partner survives the step")
  Assert.equal(actor.fieldX, vacated.fieldX, "the follower targets the vacated tile")
  Assert.equal(actor.fieldZ, vacated.fieldZ, "the follower targets the vacated tile")
  Assert.isTrue(w.controller:isMovementSettled(), "the ordinary follow settles")
  w.mgr:dispose()
end

-- Consuming a step at movement start must not make the later commit
-- revision replay the same vacated tile a second time. After one ordinary
-- follow completes, idle ticks stay settled, and a genuine discontinuity
-- still restores the follower behind the player.
function T.observed_step_is_never_replayed_from_the_commit()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  local vacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }

  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the follower starts while the player step is still in flight")
  -- A second observation of the same started step is idempotent: the
  -- follower keeps its one in-flight walk instead of starting over.
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "a repeated observation starts no second walk")

  for _ = 1, 12 do
    if w.player.motion ~= "idle" then
      w.player:updateFixed({})
    end
    w.controller:update()
  end
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the step")
  Assert.equal(actor.fieldX, vacated.fieldX, "the follower sits on the vacated tile")
  Assert.equal(actor.fieldZ, vacated.fieldZ, "the follower sits on the vacated tile")
  Assert.isTrue(w.controller:isMovementSettled(), "the ordinary follow settles")

  -- The later commit revision must not enqueue the already-consumed tile
  -- again: idle ticks never restart the follower.
  tick(w, 10)
  actor = assert(w.mgr:getById(partnerId), "the partner survives idle ticks")
  Assert.equal(actor.fieldX, vacated.fieldX, "no duplicate walk replays the consumed tile")
  Assert.equal(actor.fieldZ, vacated.fieldZ, "no duplicate walk replays the consumed tile")
  Assert.isTrue(w.controller:isMovementSettled(), "the follower stays settled while idle")

  -- A genuine discontinuity still repairs through the existing snap path.
  w.player:setScriptPosition({ fieldX = 20, fieldZ = 20 })
  tick(w, 3)
  actor = assert(w.mgr:getById(partnerId), "the partner survives the discontinuity")
  Assert.equal(actor.fieldX, 20, "the snap lands behind the player")
  Assert.equal(actor.fieldZ, 19, "the snap lands behind the player")
  Assert.isTrue(w.controller:isMovementSettled(), "stale anchors never replay after a snap")
  w.mgr:dispose()
end

-- A follower attached after history seeds the current revision instead of
-- replaying the completed step: installing behind the settled player starts
-- no walk toward the old vacated tile.
function T.late_attach_ignores_completed_history()
  local w = world()
  stepSouth(w)
  Assert.equal(w.player.fieldZ, 6, "the pre-attach step commits before the follower exists")
  w.svc:setLead(0, mon())
  tick(w, 3)
  local partnerId = assert(w.mgr:partnerId(), "the late attach still installs the partner")
  local actor = assert(w.mgr:getById(partnerId), "the partner actor is required")
  Assert.equal(actor.fieldX, 4, "the late attach installs behind the settled player")
  Assert.equal(actor.fieldZ, 5, "the late attach installs behind the settled player")
  Assert.isTrue(w.controller:isMovementSettled(), "the completed step replays no walk")
  tick(w, 10)
  actor = assert(w.mgr:getById(partnerId), "the partner survives idle ticks")
  Assert.equal(actor.fieldX, 4, "idle ticks start no replay of the historical step")
  Assert.equal(actor.fieldZ, 5, "idle ticks start no replay of the historical step")
  Assert.isTrue(w.controller:isMovementSettled(), "the follower stays settled while idle")
  w.mgr:dispose()
end

-- A scripted walk in a transition movement mode trails exactly like an
-- ordinary walk: the follower starts toward the vacated tile in the same
-- fixed-step epoch the scripted step begins, walks (never jumps) while the
-- player step is in flight, and settles onto the vacated tile with the
-- same stable actor it installed.
function T.transition_mode_scripted_walk_starts_the_trail_before_the_player_commits()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  w.controller:setMovementType("follow_transition_a")
  local vacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }
  local startWorldY = assert(w.mgr:getById(partnerId), "the partner actor is required").worldY

  w.player:beginScriptedAction({ action = "walk", direction = "south", speed = "normal" })
  Assert.isTrue(w.player:isScriptedMoving(), "the scripted walk is in flight")
  -- The same fixed-step epoch the production runtime uses: the script has
  -- resolved and begun, and following observes before anything advances.
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the follower starts while the scripted step is still in flight")
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the scripted step start")
  Assert.equal(actor.pose, "walk", "the follower walks while the scripted step is in flight")
  local motion = assert(actor:scriptedMotionState(), "the follower has an active presentation")
  Assert.equal(motion.action, "walk", "the scripted trail walks toward the vacated tile, never jumps")

  for progress = 1, 4 do
    w.player:advanceScriptedAction(progress, 8)
    w.controller:update()
  end
  actor = assert(w.mgr:getById(partnerId), "the partner survives mid-step")
  Assert.near(
    assert(actor.worldY, "the partner height is required"),
    assert(startWorldY, "the trail start height is required"),
    1e-9,
    "the trail holds its height mid-step instead of jumping"
  )
  for progress = 5, 8 do
    w.player:advanceScriptedAction(progress, 8)
    w.controller:update()
  end
  w.player:commitScriptedAction()
  for _ = 1, 12 do
    w.controller:update()
  end
  Assert.equal(w.player.fieldZ, vacated.fieldZ + 1, "the scripted step commits one tile south")
  actor = assert(w.mgr:getById(partnerId), "the partner survives the scripted step")
  Assert.equal(actor.fieldX, vacated.fieldX, "the follower settles onto the vacated tile")
  Assert.equal(actor.fieldZ, vacated.fieldZ, "the follower settles onto the vacated tile")
  Assert.equal(w.mgr:partnerId(), partnerId, "an adjacent scripted trail keeps the stable actor")
  Assert.isTrue(w.controller:isMovementSettled(), "the scripted follow settles")
  w.mgr:dispose()
end

-- An arriving walk start begins the real trail in the same update without
-- queueing behind anything stationary: the follower holds no presentation
-- action, so the trail starts at once.
function T.arriving_walk_start_begins_the_real_trail_in_the_same_update()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 3)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  local idle = assert(w.mgr:getById(partnerId), "the partner actor is required")
  Assert.equal(idle.pose, "idle", "the free stationary follower presents idle")
  Assert.isNil(idle:scriptedMotionState(), "no presentation action owns the stationary follower")
  Assert.isTrue(w.controller:isMovementSettled(), "the stationary follower is logically settled")

  local vacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }
  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the arriving walk starts a real trail in the same update")
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the step start")
  local trail = assert(actor:scriptedMotionState(), "the trail has an active presentation")
  Assert.equal(trail.action, "walk", "the trail replaces the presentation instead of queueing behind it")

  for _ = 1, 12 do
    if w.player.motion ~= "idle" then
      w.player:updateFixed({})
    end
    w.controller:update()
  end
  Assert.equal(w.player.fieldZ, vacated.fieldZ + 1, "the player commits one tile south")
  actor = assert(w.mgr:getById(partnerId), "the partner survives the step")
  Assert.equal(actor.fieldX, vacated.fieldX, "the follower targets the vacated tile")
  Assert.equal(actor.fieldZ, vacated.fieldZ, "the follower targets the vacated tile")
  w.mgr:dispose()
end

-- A visible free follower idles while stationary: every tick presents
-- idle with no scripted action, logical coordinates never move, and the
-- controller stays settled and interactable.
function T.free_stationary_follower_idles_without_starting_movement()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 3)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  local home = assert(w.mgr:getPosition(partnerId), "the partner position is required")
  local homeWorldY = assert(w.mgr:getById(partnerId), "the partner actor is required").worldY
  for _ = 1, 30 do
    w.controller:update()
    local actor = assert(w.mgr:getById(partnerId), "the partner survives stationary ticks")
    Assert.equal(actor.pose, "idle", "every stationary tick presents idle, never locomotion")
    Assert.isNil(actor:scriptedMotionState(), "stationary ticks start no movement action")
    Assert.equal(actor.fieldX, home.fieldX, "native idle never changes the logical tile")
    Assert.equal(actor.fieldZ, home.fieldZ, "native idle never changes the logical tile")
    Assert.isTrue(w.controller:isMovementSettled(), "native idle stays logically settled")
  end
  local after = assert(w.mgr:getById(partnerId), "the partner survives the idle ticks")
  Assert.equal(after.fieldX, home.fieldX, "repeated idle never displaces the logical tile")
  Assert.equal(after.fieldZ, home.fieldZ, "repeated idle never displaces the logical tile")
  Assert.near(
    assert(after.worldY, "the partner height is required"),
    assert(homeWorldY, "the idle start height is required"),
    1e-9,
    "native idle never changes the height anchor"
  )
  Assert.isTrue(w.controller:isEventTrigger(1, 0), "the idling follower stays available for interaction")
  w.mgr:dispose()
end

-- Pausing keeps a real trail in flight to its normal commit: the trail
-- still walks while paused, and the paused follower holds afterwards. A
-- stationary follower pauses with no action either way.
function T.pausing_keeps_the_real_trail_in_flight()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 3)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  Assert.equal(
    assert(w.mgr:getById(partnerId), "the partner actor is required").pose,
    "idle",
    "setup presents native idle"
  )
  w.controller:setMovementPaused(true)
  w.controller:update()
  local held = assert(w.mgr:getById(partnerId), "the partner survives the pause")
  Assert.equal(held.pose, "idle", "pausing a stationary follower changes nothing visual")
  Assert.isNil(held:scriptedMotionState(), "no movement action exists while paused")
  Assert.isTrue(w.controller:isMovementSettled(), "a paused stationary follower never hangs a wait")

  w.controller:setMovementPaused(false)
  local vacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }
  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the trail starts after release")
  w.controller:setMovementPaused(true)
  Assert.isFalse(w.controller:isMovementSettled(), "pausing keeps the in-flight trail live")
  for _ = 1, 12 do
    if w.player.motion ~= "idle" then
      w.player:updateFixed({})
    end
    w.controller:update()
  end
  Assert.equal(w.player.motion, "idle", "the player step completes")
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the paused trail")
  Assert.equal(actor.fieldX, vacated.fieldX, "the in-flight trail reaches the vacated tile")
  Assert.equal(actor.fieldZ, vacated.fieldZ, "the in-flight trail reaches the vacated tile")
  Assert.isTrue(w.controller:isMovementSettled(), "the committed trail settles even while paused")
  w.controller:setMovementPaused(false)
  w.mgr:dispose()
end

-- Settlement tracks real trails only: a stationary follower with an empty
-- queue is settled, a real trail is not, and a paused retained queue with
-- no trail in flight is settled so waits never hang.
function T.settlement_counts_only_real_trails()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 3)
  Assert.isTrue(w.controller:isMovementSettled(), "a stationary follower with an empty queue is settled")
  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "a real trail is unsettled")
  for _ = 1, 12 do
    if w.player.motion ~= "idle" then
      w.player:updateFixed({})
    end
    w.controller:update()
  end
  Assert.isTrue(w.controller:isMovementSettled(), "the drained trail settles")
  w.controller:setMovementPaused(true)
  Assert.isTrue(w.player:tryStep("south"), "a paused step still starts")
  for _ = 1, 10 do
    w.player:updateFixed({})
  end
  Assert.equal(w.player.motion, "idle", "the paused player step completes")
  tick(w, 5)
  Assert.isTrue(w.controller:isMovementSettled(), "a paused retained queue with no trail is settled")
  w.controller:setMovementPaused(false)
  w.mgr:dispose()
end

-- A stationary follower stays eligible for event triggers while a real
-- trail stays movement-busy: native idle never makes the visible partner
-- logically moving.
function T.stationary_follower_stays_available_for_interaction()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 3)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  Assert.equal(
    assert(w.mgr:getById(partnerId), "the partner actor is required").pose,
    "idle",
    "setup presents native idle"
  )
  Assert.isTrue(w.controller:isEventTrigger(1, 0), "the stationary follower stays stationary for triggers")
  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  w.controller:update()
  Assert.isFalse(w.controller:isEventTrigger(1, 0), "a real trail stays movement-busy for triggers")
  w.mgr:dispose()
end

-- Leaving free follow for a transition mode while paused starts no
-- movement, and returning to free follow while still paused starts none
-- either: release restarts nothing, since stationary followers hold no
-- presentation action.
function T.mode_change_starts_no_movement_while_paused_or_released()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 3)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  w.controller:setMovementPaused(true)
  w.controller:setMovementType("follow_transition_a")
  tick(w, 3)
  Assert.equal(
    assert(w.mgr:getById(partnerId), "the partner actor is required").pose,
    "idle",
    "no movement starts while paused"
  )
  w.controller:setMovementType("follow_player")
  tick(w, 3)
  Assert.equal(
    assert(w.mgr:getById(partnerId), "the partner actor is required").pose,
    "idle",
    "returning to free follow while paused starts nothing"
  )
  w.controller:setMovementPaused(false)
  tick(w, 2)
  Assert.equal(
    assert(w.mgr:getById(partnerId), "the partner actor is required").pose,
    "idle",
    "release starts no movement action either"
  )
  Assert.isNil(w.controller._action, "release leaves no movement obligation")
  w.mgr:dispose()
end

-- Map exit clears movement state and restores free follow for the next
-- actor ownership epoch, so a script-only transition mode never leaks
-- into unrelated free field after reconstruction.
function T.map_exit_clears_movement_and_restores_free_follow()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 3)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  Assert.equal(
    assert(w.mgr:getById(partnerId), "the partner actor is required").pose,
    "idle",
    "setup presents native idle"
  )
  w.controller:setMovementType("follow_transition_a")
  w.controller:handleMapExit()
  Assert.equal(
    w.controller._movementType,
    "follow_player",
    "map exit restores free follow for the next ownership epoch"
  )
  Assert.isTrue(w.controller:isMovementSettled(), "map exit leaves no movement behind")
  local nextMap = runtimeMap(62)
  w.mgr:enterMap(nextMap, FieldEventState.new())
  w.player.currentMap = nextMap
  tick(w, 3)
  local reinstalledId = assert(w.mgr:partnerId(), "the new map reinstalls the partner")
  local actor = assert(w.mgr:getById(reinstalledId), "the reinstalled partner is required")
  Assert.equal(actor.mapId, 62, "the reinstalled actor belongs to the new map")
  Assert.equal(actor.pose, "idle", "the new map resumes native idle with no movement action")
  Assert.isNil(actor:scriptedMotionState(), "the reinstalled partner holds no scripted motion")
  w.mgr:dispose()
end

return { tests = T }
