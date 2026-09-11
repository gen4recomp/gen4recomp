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
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FollowingMonController = require("libs.hgss.src.field.FollowingMonController")
local Personality = require("libs.mons.src.gen4.Personality")

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

-- Drives one scripted player walk through the same fixed-step epoch the
-- production runtime uses, then settles both actors. Returns the tile the
-- player vacated.
local function driveScriptedWalk(w, direction, speed)
  local vacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }
  local duration = MovementCalibration.SPEED_TICKS[speed]
  w.player:beginScriptedAction({ action = "walk", direction = direction, speed = speed })
  w.controller:update()
  for progress = 1, duration do
    w.player:advanceScriptedAction(progress, duration)
    w.controller:update()
  end
  w.player:commitScriptedAction()
  for _ = 1, 12 do
    w.controller:update()
  end
  return vacated
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
  Assert.equal(actor:getFieldPosition().fieldX, 4, "initial placement is the tile behind the player")
  Assert.equal(actor:getFieldPosition().fieldZ, 4, "initial placement is the tile behind the player")
  Assert.equal(actor.facing, "south", "installation keeps the player facing")
  w.mgr:dispose()
end

function T.mid_map_lead_birth_installs_hidden_but_map_entry_stays_visible()
  local mapEntry = world()
  mapEntry.svc:setLead(0, mon())
  tick(mapEntry, 2)
  local visible = assert(mapEntry.mgr:getById("field:partner"), "a map-entry lead installs a partner")
  Assert.isTrue(visible:isVisible(), "normal map-entry reconstruction remains visible")
  mapEntry.mgr:dispose()

  local midMap = world()
  tick(midMap, 1)
  midMap.svc:setLead(0, mon())
  tick(midMap, 2)
  local hidden = assert(midMap.mgr:getById("field:partner"), "the mid-map lead birth installs a partner")
  Assert.isFalse(hidden:isVisible(), "a newly published mid-map lead starts hidden")
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
  Assert.isFalse(actor:isVisible(), "the retry keeps the hidden publication intent")
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
  Assert.isTrue(actor:isVisible(), "a replacement lead does not inherit stale hidden intent")
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

-- The live party query answers from current party state without waiting for
-- reconciliation: empty and ineligible parties read false, eligible leads
-- of either gender read true, and the query never installs, replaces, or
-- clears the reconciled lead.
function T.live_party_query_answers_without_touching_the_reconciled_lead()
  local w = world()
  Assert.isFalse(w.controller:isSourceActive(), "an empty party holds no live lead")
  Assert.isNil(w.controller._lead, "the query installs no reconciled lead")
  w.svc:setLead(0, mon("EEVEE"))
  Assert.isFalse(w.controller:isSourceActive(), "a lead without a follower visual holds no live lead")
  Assert.isNil(w.controller._lead, "an ineligible query still installs nothing")
  local malePid, femalePid
  for pid = 0, 600 do
    local gender = Personality.gender(31, pid)
    if gender == "male" and malePid == nil then
      malePid = pid
    end
    if gender == "female" and femalePid == nil then
      femalePid = pid
    end
  end
  assert(malePid ~= nil and femalePid ~= nil, "the fixture ratio must yield both genders")
  w.svc:setLead(0, mon("CHIKORITA", malePid))
  Assert.isTrue(w.controller:isSourceActive(), "an eligible male lead is live before reconciliation")
  Assert.isNil(w.controller._lead, "the query still installs no reconciled lead")
  w.svc:setLead(0, mon("CHIKORITA", femalePid))
  Assert.isTrue(w.controller:isSourceActive(), "an eligible female lead is live before reconciliation")
  Assert.isNil(w.controller._lead, "the query still installs no reconciled lead")
  tick(w, 2)
  local installed = assert(w.controller._lead, "reconciliation installs the lead")
  Assert.equal(installed.species, "CHIKORITA", "reconciliation keeps the live lead")
  Assert.isTrue(w.controller:isSourceActive(), "the installed lead stays live")
  w.svc:clearLead()
  Assert.isFalse(w.controller:isSourceActive(), "clearing the party reads inactive immediately")
  Assert.equal(w.controller._lead, installed, "the query never clears the reconciled lead")
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
  Assert.equal(actor:getFieldPosition().fieldX, 4, "the partner replays the vacated tile")
  Assert.equal(actor:getFieldPosition().fieldZ, 5, "the partner replays the vacated tile")
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
  Assert.equal(actor:getFieldPosition().fieldZ, 4, "a paused follower holds its tile")
  -- A paused queue is retained, not drained, so a wait issued while paused
  -- settles instead of hanging: settlement never means "queue empty" alone.
  Assert.isTrue(w.controller:isMovementSettled(), "a paused follower never hangs a wait")
  w.controller:setMovementPaused(false)
  tick(w, 30)
  actor = assert(w.mgr:getById("field:partner"))
  Assert.equal(actor:getFieldPosition().fieldZ, 5, "resume replays the retained anchor")
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
  Assert.equal(
    actor:getFieldPosition().fieldZ,
    14,
    "the overlong queue snaps behind the player instead of replaying stale anchors"
  )
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

-- An accepted mode set is a movement reset boundary: it cancels the
-- in-flight trail through the actor owner, clears the retained queue,
-- rebaselines player observation to the live transaction and commit, and
-- keeps the pause latch. Steps committed from a dropped start never replay,
-- while steps begun after the set trail fresh under the new mode.
function T.mode_change_clears_stale_trail_and_rebaselines_while_keeping_pause()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  local home = assert(w.mgr:getPosition(partnerId), "the partner position is required")

  Assert.isTrue(w.player:tryStep("south"), "the fixture step must start")
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the trail starts while the player step is in flight")
  w.controller:setMovementType("follow_transition_a")
  Assert.equal(w.controller._movementType, "follow_transition_a", "the new mode stores")
  Assert.isNil(w.controller._action, "the accepted set holds no in-flight obligation")
  Assert.equal(#w.controller._queue, 0, "the accepted set clears the retained queue")
  Assert.isNil(
    assert(w.mgr:getById(partnerId), "the partner survives the mode set"):scriptedMotionState(),
    "the accepted set cancels the trail through the actor owner"
  )
  for _ = 1, 10 do
    w.player:updateFixed({})
  end
  Assert.equal(w.player.motion, "idle", "the player step still commits")
  tick(w, 20)
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the dropped step")
  Assert.equal(actor:getFieldPosition().fieldX, home.fieldX, "the dropped start never replays from its commit")
  Assert.equal(actor:getFieldPosition().fieldZ, home.fieldZ, "the dropped start never replays from its commit")
  Assert.isTrue(w.controller:isMovementSettled(), "the dropped step settles without movement")

  w.controller:setMovementPaused(true)
  Assert.isTrue(w.player:tryStep("south"), "the paused step must start")
  w.controller:update()
  Assert.equal(#w.controller._queue, 1, "the paused step retains its obligation")
  local queuedTx = assert(w.player:movementTransaction(), "the paused step publishes its transaction")
  w.controller:setMovementType("follow_transition_b")
  Assert.equal(w.controller._movementType, "follow_transition_b", "the second mode stores")
  Assert.equal(#w.controller._queue, 0, "the accepted set clears the paused obligation")
  Assert.isTrue(w.controller._paused, "the accepted set preserves the pause latch")
  Assert.equal(
    w.controller._lastMovementTransactionRevision,
    queuedTx.revision,
    "the accepted set rebaselines to the live transaction"
  )
  for _ = 1, 10 do
    w.player:updateFixed({})
  end
  Assert.equal(w.player.motion, "idle", "the paused player step still commits")
  tick(w, 5)
  Assert.equal(#w.controller._queue, 0, "the dropped commit never re-enqueues while paused")
  w.controller:setMovementPaused(false)
  tick(w, 5)
  actor = assert(w.mgr:getById(partnerId), "the partner survives the release")
  Assert.equal(actor:getFieldPosition().fieldX, home.fieldX, "release replays no dropped history")
  Assert.equal(actor:getFieldPosition().fieldZ, home.fieldZ, "release replays no dropped history")
  Assert.isTrue(w.controller:isMovementSettled(), "the follower stays settled after the release")
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
  Assert.equal(actor:getFieldPosition().fieldX, 20, "the snap lands behind the player")
  Assert.equal(actor:getFieldPosition().fieldZ, 19, "the snap lands behind the player")
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
  local startWorldZ = installed:getWorldPosition().z
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
  Assert.isTrue(actor:getWorldPosition().z > startWorldZ, "the follower has visibly left its original tile")

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
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX, "the follower targets the vacated tile")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ, "the follower targets the vacated tile")
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
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX, "the follower sits on the vacated tile")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ, "the follower sits on the vacated tile")
  Assert.isTrue(w.controller:isMovementSettled(), "the ordinary follow settles")

  -- The later commit revision must not enqueue the already-consumed tile
  -- again: idle ticks never restart the follower.
  tick(w, 10)
  actor = assert(w.mgr:getById(partnerId), "the partner survives idle ticks")
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX, "no duplicate walk replays the consumed tile")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ, "no duplicate walk replays the consumed tile")
  Assert.isTrue(w.controller:isMovementSettled(), "the follower stays settled while idle")

  -- A genuine discontinuity still repairs through the existing snap path.
  w.player:setScriptPosition({ fieldX = 20, fieldZ = 20 })
  tick(w, 3)
  actor = assert(w.mgr:getById(partnerId), "the partner survives the discontinuity")
  Assert.equal(actor:getFieldPosition().fieldX, 20, "the snap lands behind the player")
  Assert.equal(actor:getFieldPosition().fieldZ, 19, "the snap lands behind the player")
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
  Assert.equal(actor:getFieldPosition().fieldX, 4, "the late attach installs behind the settled player")
  Assert.equal(actor:getFieldPosition().fieldZ, 5, "the late attach installs behind the settled player")
  Assert.isTrue(w.controller:isMovementSettled(), "the completed step replays no walk")
  tick(w, 10)
  actor = assert(w.mgr:getById(partnerId), "the partner survives idle ticks")
  Assert.equal(actor:getFieldPosition().fieldX, 4, "idle ticks start no replay of the historical step")
  Assert.equal(actor:getFieldPosition().fieldZ, 5, "idle ticks start no replay of the historical step")
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
  local startWorldY = assert(w.mgr:getById(partnerId), "the partner actor is required"):getWorldPosition().y

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
    assert(actor:getWorldPosition().y, "the partner height is required"),
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
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX, "the follower settles onto the vacated tile")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ, "the follower settles onto the vacated tile")
  Assert.equal(w.mgr:partnerId(), partnerId, "an adjacent scripted trail keeps the stable actor")
  Assert.isTrue(w.controller:isMovementSettled(), "the scripted follow settles")
  w.mgr:dispose()
end

-- The previous-tile transition mode steers the follower toward the tile the
-- player vacated and remembers the executed walk as the follower command:
-- one cardinal step at the transaction pace, no duplicate obligation, and a
-- descriptive command record that never holds a wait by itself.
function T.transition_a_steers_to_the_vacated_tile_and_remembers_the_follower_command()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  w.controller:setMovementType("follow_transition_a")
  local vacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }

  w.player:beginScriptedAction({ action = "walk", direction = "south", speed = "normal" })
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the transition step starts while the player step is in flight")
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the transition step start")
  Assert.equal(actor.pose, "walk", "the transition step walks toward the vacated tile")
  Assert.equal(actor.facing, "south", "the transition step faces the vacated tile")
  local motion = assert(actor:scriptedMotionState(), "the transition step has an active presentation")
  Assert.equal(motion.action, "walk", "the transition step walks toward the vacated tile, never jumps")
  Assert.equal(motion.speed, "normal", "the transition step keeps the transaction speed")

  for progress = 1, MovementCalibration.SPEED_TICKS.normal do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.normal)
    w.controller:update()
  end
  w.player:commitScriptedAction()
  for _ = 1, 12 do
    w.controller:update()
  end
  actor = assert(w.mgr:getById(partnerId), "the partner survives the transition step")
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX, "the follower settles onto the vacated tile")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ, "the follower settles onto the vacated tile")
  Assert.equal(#w.controller._queue, 0, "no duplicate obligation remains queued")
  Assert.isTrue(w.controller:isMovementSettled(), "the transition step settles")
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "the executed transition walk is remembered as the follower command"
  )
  Assert.isTrue(w.controller:isMovementSettled(), "the remembered command never holds a wait by itself")
  w.mgr:dispose()
end

-- Seeds an east/fast remembered command through two real scripted walks: an
-- east step whose trail walks south, then a north step whose trail walks
-- east at fast pace. Returns with the player standing north of the follower.
local function seedEastFastCommand(w)
  driveScriptedWalk(w, "east", "fast")
  driveScriptedWalk(w, "north", "fast")
end

-- The command-replay transition mode is observably distinct from
-- previous-tile steering: with an east/fast command remembered and the next
-- vacated tile lying north of the follower, replay steps east at fast pace
-- while steering steps north onto the vacated tile at the transaction pace.
function T.transition_b_replays_the_remembered_command_instead_of_steering()
  local replay = world()
  replay.svc:setLead(0, mon())
  tick(replay, 2)
  seedEastFastCommand(replay)
  local partnerId = assert(replay.mgr:partnerId(), "setup installs the partner")
  replay.controller:setMovementType("follow_transition_b")
  local followerStart = assert(replay.mgr:getPosition(partnerId), "the follower position is required")

  replay.player:beginScriptedAction({ action = "walk", direction = "north", speed = "normal" })
  replay.controller:update()
  Assert.isFalse(replay.controller:isMovementSettled(), "the replay starts while the player step is in flight")
  local actor = assert(replay.mgr:getById(partnerId), "the partner survives the replay start")
  local motion = assert(actor:scriptedMotionState(), "the replay has an active presentation")
  Assert.equal(motion.action, "walk", "the replay walks instead of steering toward the vacated tile")
  Assert.equal(motion.speed, "fast", "the replay keeps the remembered speed, not the transaction speed")
  Assert.equal(actor.facing, "east", "the replay faces the remembered direction, not the vacated tile")
  for progress = 1, MovementCalibration.SPEED_TICKS.normal do
    replay.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.normal)
    replay.controller:update()
  end
  replay.player:commitScriptedAction()
  for _ = 1, 12 do
    replay.controller:update()
  end
  actor = assert(replay.mgr:getById(partnerId), "the partner survives the replay")
  Assert.equal(
    actor:getFieldPosition().fieldX,
    followerStart.fieldX + 1,
    "the replay steps east instead of onto the vacated tile"
  )
  Assert.equal(actor:getFieldPosition().fieldZ, followerStart.fieldZ, "the replay holds its row while stepping east")
  Assert.isTrue(replay.controller:isMovementSettled(), "the replay settles with no stale obligation")
  Assert.deepEqual(
    replay.controller._lastFollowerCommand,
    { direction = "east", speed = "fast" },
    "replaying preserves the remembered command"
  )
  replay.mgr:dispose()

  local steering = world()
  steering.svc:setLead(0, mon())
  tick(steering, 2)
  seedEastFastCommand(steering)
  local steeringId = assert(steering.mgr:partnerId(), "setup installs the partner")
  steering.controller:setMovementType("follow_transition_a")
  local steeringVacated = { fieldX = steering.player.fieldX, fieldZ = steering.player.fieldZ }
  steering.player:beginScriptedAction({ action = "walk", direction = "north", speed = "normal" })
  steering.controller:update()
  for progress = 1, MovementCalibration.SPEED_TICKS.normal do
    steering.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.normal)
    steering.controller:update()
  end
  steering.player:commitScriptedAction()
  for _ = 1, 12 do
    steering.controller:update()
  end
  local steered = assert(steering.mgr:getById(steeringId), "the partner survives the steering step")
  Assert.equal(steered:getFieldPosition().fieldX, steeringVacated.fieldX, "steering settles onto the vacated tile")
  Assert.equal(steered:getFieldPosition().fieldZ, steeringVacated.fieldZ, "steering settles onto the vacated tile")
  Assert.isTrue(steering.controller:isMovementSettled(), "the steering step settles")
  steering.mgr:dispose()
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
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX, "the follower targets the vacated tile")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ, "the follower targets the vacated tile")
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
  local homeWorldY = assert(w.mgr:getById(partnerId), "the partner actor is required"):getWorldPosition().y
  for _ = 1, 30 do
    w.controller:update()
    local actor = assert(w.mgr:getById(partnerId), "the partner survives stationary ticks")
    Assert.equal(actor.pose, "idle", "every stationary tick presents idle, never locomotion")
    Assert.isNil(actor:scriptedMotionState(), "stationary ticks start no movement action")
    Assert.equal(actor:getFieldPosition().fieldX, home.fieldX, "native idle never changes the logical tile")
    Assert.equal(actor:getFieldPosition().fieldZ, home.fieldZ, "native idle never changes the logical tile")
    Assert.isTrue(w.controller:isMovementSettled(), "native idle stays logically settled")
  end
  local after = assert(w.mgr:getById(partnerId), "the partner survives the idle ticks")
  Assert.equal(after:getFieldPosition().fieldX, home.fieldX, "repeated idle never displaces the logical tile")
  Assert.equal(after:getFieldPosition().fieldZ, home.fieldZ, "repeated idle never displaces the logical tile")
  Assert.near(
    assert(after:getWorldPosition().y, "the partner height is required"),
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
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX, "the in-flight trail reaches the vacated tile")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ, "the in-flight trail reaches the vacated tile")
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

-- A fast scripted player walk trails at its own pace instead of faulting:
-- the follower starts in the same epoch at the matching calibrated timing,
-- a run walk normalizes to the same fast follower timing, queued obligations
-- keep each step's own speed, and every trail settles onto the vacated tile.
function T.fast_scripted_walk_trails_at_its_own_pace_and_keeps_queued_speeds()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  local vacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }

  w.player:beginScriptedAction({ action = "walk", direction = "south", speed = "fast" })
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the follower starts while the fast step is still in flight")
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the fast step start")
  local motion = assert(actor:scriptedMotionState(), "the fast trail has an active presentation")
  Assert.equal(motion.action, "walk", "the fast trail walks toward the vacated tile")
  Assert.equal(motion.speed, "fast", "the follower preserves the fast semantic speed")
  Assert.equal(
    assert(w.controller._action, "the fast trail holds a movement obligation").duration,
    MovementCalibration.SPEED_TICKS.fast,
    "the fast trail uses its own calibrated duration"
  )
  for progress = 1, MovementCalibration.SPEED_TICKS.fast do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.fast)
    w.controller:update()
  end
  w.player:commitScriptedAction()
  for _ = 1, 12 do
    w.controller:update()
  end
  actor = assert(w.mgr:getById(partnerId), "the partner survives the fast step")
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX, "the fast trail settles onto the vacated tile")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ, "the fast trail settles onto the vacated tile")
  Assert.isTrue(w.controller:isMovementSettled(), "the fast trail settles")

  local runVacated = { fieldX = w.player.fieldX, fieldZ = w.player.fieldZ }
  w.player:beginScriptedAction({ action = "walk", direction = "south", speed = "run" })
  w.controller:update()
  Assert.isFalse(w.controller:isMovementSettled(), "the follower starts while the run step is still in flight")
  local runner = assert(w.mgr:getById(partnerId), "the partner survives the run step start")
  local runMotion = assert(runner:scriptedMotionState(), "the run trail has an active presentation")
  Assert.equal(runMotion.speed, "fast", "a run player walk normalizes to fast follower timing")
  Assert.equal(
    assert(w.controller._action, "the run trail holds a movement obligation").duration,
    MovementCalibration.SPEED_TICKS.fast,
    "the normalized run trail uses the fast calibrated duration"
  )
  for progress = 1, MovementCalibration.SPEED_TICKS.run do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.run)
    w.controller:update()
  end
  w.player:commitScriptedAction()
  for _ = 1, 12 do
    w.controller:update()
  end
  runner = assert(w.mgr:getById(partnerId), "the partner survives the run step")
  Assert.equal(
    runner:getFieldPosition().fieldX,
    runVacated.fieldX,
    "the normalized trail settles onto the vacated tile"
  )
  Assert.equal(
    runner:getFieldPosition().fieldZ,
    runVacated.fieldZ,
    "the normalized trail settles onto the vacated tile"
  )
  Assert.isTrue(w.controller:isMovementSettled(), "the normalized trail settles")

  w.controller:setMovementPaused(true)
  w.player:beginScriptedAction({ action = "walk", direction = "south", speed = "fast" })
  w.controller:update()
  for progress = 1, MovementCalibration.SPEED_TICKS.fast do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.fast)
  end
  w.player:commitScriptedAction()
  tick(w, 1)
  w.player:beginScriptedAction({ action = "walk", direction = "south", speed = "normal" })
  w.controller:update()
  for progress = 1, MovementCalibration.SPEED_TICKS.normal do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.normal)
  end
  w.player:commitScriptedAction()
  tick(w, 1)
  Assert.equal(#w.controller._queue, 2, "both paused steps retain their own obligation")
  Assert.equal(w.controller._queue[1].speed, "fast", "the first queued step keeps its own speed")
  Assert.equal(w.controller._queue[2].speed, "normal", "the second queued step keeps its own speed")
  w.controller:setMovementPaused(false)
  w.controller:update()
  Assert.equal(
    assert(w.controller._action, "the replayed head holds a movement obligation").duration,
    MovementCalibration.SPEED_TICKS.fast,
    "replay uses the head step speed, not the latest transaction"
  )
  for _ = 1, 60 do
    w.controller:update()
  end
  Assert.isTrue(w.controller:isMovementSettled(), "the queued trails settle")
  w.mgr:dispose()
end

-- A repeated set under the same mode is still a reset boundary for stale
-- work, but the live actor never retired: the queue and in-flight step
-- drop while the remembered walk survives, and the dropped commit never
-- replays after release.
function T.repeated_mode_set_drops_stale_work_but_keeps_the_last_walk()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  driveScriptedWalk(w, "south", "normal")
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "setup remembers the executed walk"
  )
  w.controller:setMovementPaused(true)
  w.player:beginScriptedAction({ action = "walk", direction = "south", speed = "fast" })
  w.controller:update()
  Assert.equal(#w.controller._queue, 1, "the paused step retains its obligation")
  w.controller:setMovementType("follow_player")
  Assert.equal(#w.controller._queue, 0, "a repeated set clears the retained obligation")
  Assert.isNil(w.controller._action, "a repeated set holds no in-flight obligation")
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "a repeated set keeps the remembered walk"
  )
  Assert.isTrue(w.controller._paused, "a repeated set preserves the pause latch")
  for progress = 1, MovementCalibration.SPEED_TICKS.fast do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.fast)
  end
  w.player:commitScriptedAction()
  tick(w, 5)
  Assert.equal(#w.controller._queue, 0, "the dropped commit never re-enqueues")
  w.controller:setMovementPaused(false)
  tick(w, 5)
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "release replays no dropped history and keeps the walk"
  )
  Assert.isTrue(w.controller:isMovementSettled(), "the follower stays settled after the release")
  w.mgr:dispose()
end

-- Switching modes with queued replay work drops the queued replay but
-- keeps the remembered walk: queueing alone never publishes, and the new
-- mode starts clean from the live actor.
function T.switching_modes_drops_queued_replay_but_keeps_the_last_walk()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  driveScriptedWalk(w, "south", "normal")
  w.controller:setMovementType("follow_transition_b")
  w.controller:setMovementPaused(true)
  w.player:beginScriptedAction({ action = "walk", direction = "east", speed = "normal" })
  w.controller:update()
  Assert.equal(#w.controller._queue, 1, "the paused replay retains its obligation")
  Assert.equal(
    w.controller._queue[1].direction,
    "south",
    "the queued replay carries the remembered direction, not the player step"
  )
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "queueing a replay publishes nothing"
  )
  w.controller:setMovementType("follow_transition_a")
  Assert.equal(w.controller._movementType, "follow_transition_a", "the new mode stores")
  Assert.equal(#w.controller._queue, 0, "the mode switch clears the queued replay")
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "the mode switch keeps the remembered walk"
  )
  for progress = 1, MovementCalibration.SPEED_TICKS.normal do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.normal)
  end
  w.player:commitScriptedAction()
  tick(w, 5)
  Assert.equal(#w.controller._queue, 0, "the dropped commit never re-enqueues under the new mode")
  w.controller:setMovementPaused(false)
  tick(w, 5)
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "release replays no dropped replay"
  )
  Assert.isTrue(w.controller:isMovementSettled(), "the follower stays settled after the release")
  w.mgr:dispose()
end

-- The remembered walk describes the live partner actor: losing the lead
-- or changing maps forgets it, and a fresh install remembers nothing
-- until a new real walk starts.
function T.retiring_the_partner_forgets_the_last_walk()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  driveScriptedWalk(w, "south", "normal")
  Assert.notNil(w.controller._lastFollowerCommand, "setup remembers the executed walk")
  w.svc:clearLead()
  tick(w, 2)
  Assert.isNil(w.controller._lastFollowerCommand, "losing the lead forgets the walk")
  Assert.isTrue(w.controller:isMovementSettled(), "the retired follower stays settled")
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.notNil(w.mgr:partnerId(), "the new lead reinstalls the partner")
  Assert.isNil(w.controller._lastFollowerCommand, "a fresh install remembers nothing")
  driveScriptedWalk(w, "south", "normal")
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "a new real walk is remembered again"
  )
  local nextMap = runtimeMap(62)
  w.mgr:enterMap(nextMap, FieldEventState.new())
  w.player.currentMap = nextMap
  tick(w, 3)
  Assert.notNil(w.mgr:partnerId(), "the new map reinstalls the partner")
  Assert.isNil(w.controller._lastFollowerCommand, "a map change forgets the walk")
  Assert.isTrue(w.controller:isMovementSettled(), "the reinstalled follower stays settled")
  w.mgr:dispose()
end

-- Settlement observes real obligations only: a remembered walk with an
-- empty queue is settled, and pausing a stationary follower changes
-- nothing.
function T.remembered_walk_never_holds_a_wait_by_itself()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  driveScriptedWalk(w, "south", "normal")
  Assert.notNil(w.controller._lastFollowerCommand, "setup remembers the executed walk")
  Assert.isTrue(w.controller:isMovementSettled(), "the remembered walk alone stays settled")
  w.controller:setMovementPaused(true)
  tick(w, 3)
  Assert.isTrue(w.controller:isMovementSettled(), "a paused stationary follower stays settled")
  w.controller:setMovementPaused(false)
  tick(w, 2)
  Assert.isTrue(w.controller:isMovementSettled(), "release starts no obligation from the memory")
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "idling never rewrites the remembered walk"
  )
  w.mgr:dispose()
end

-- A controller that never started a real walk seeds its first replay from
-- the live step and remembers exactly the walk the actor executes.
function T.first_replay_seeds_from_the_live_step()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  Assert.isNil(w.controller._lastFollowerCommand, "a fresh controller remembers nothing")
  w.controller:setMovementType("follow_transition_b")
  local vacated = driveScriptedWalk(w, "east", "normal")
  local actor = assert(w.mgr:getById(assert(w.mgr:partnerId(), "setup installs the partner")))
  Assert.equal(actor:getFieldPosition().fieldX, vacated.fieldX + 1, "the seeded replay steps with the live direction")
  Assert.equal(actor:getFieldPosition().fieldZ, vacated.fieldZ - 1, "the seeded replay holds the live row")
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "east", speed = "normal" },
    "the seeded walk becomes the remembered walk"
  )
  Assert.isTrue(w.controller:isMovementSettled(), "the seeded replay settles")
  w.mgr:dispose()
end

-- A rejected replay start publishes nothing: the placement rejection
-- reconciles through the discontinuity path, leaving no obligation and
-- no remembered walk behind.
function T.rejected_replay_start_publishes_nothing()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  w.controller:setMovementType("follow_transition_b")
  Assert.isNil(w.controller._lastFollowerCommand, "a fresh controller remembers nothing")
  local begin = w.mgr.beginScriptedAction
  w.mgr.beginScriptedAction = function()
    Errors.raise(FieldErrors.FIELD_COORDINATES_OUT_OF_COVERAGE, "test placement rejection", {})
  end
  w.player:beginScriptedAction({ action = "walk", direction = "east", speed = "normal" })
  w.controller:update()
  w.mgr.beginScriptedAction = begin
  Assert.isNil(w.controller._lastFollowerCommand, "a rejected start remembers nothing")
  Assert.isNil(w.controller._action, "a rejected start holds no in-flight obligation")
  Assert.equal(#w.controller._queue, 0, "a rejected start queues nothing")
  for progress = 1, MovementCalibration.SPEED_TICKS.normal do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.normal)
  end
  w.player:commitScriptedAction()
  tick(w, 5)
  Assert.isNil(w.controller._lastFollowerCommand, "recovery publishes no walk on its own")
  w.mgr:dispose()
end

-- Failures the placement classifier does not recognize propagate to the
-- caller instead of reconciling, and no walk is remembered as though
-- movement began.
function T.unrelated_actor_failure_propagates_without_remembering()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  w.controller:setMovementType("follow_transition_b")
  local begin = w.mgr.beginScriptedAction
  w.mgr.beginScriptedAction = function()
    error("boom-test-failure")
  end
  w.player:beginScriptedAction({ action = "walk", direction = "east", speed = "normal" })
  local err = Assert.throws(function()
    w.controller:update()
  end)
  w.mgr.beginScriptedAction = begin
  Assert.isTrue(tostring(err):find("boom-test-failure", 1, true) ~= nil, "the unrelated failure propagates")
  Assert.isNil(w.controller._lastFollowerCommand, "a failed start remembers nothing")
  Assert.isNil(w.controller._action, "a failed start holds no in-flight obligation")
  w.mgr:dispose()
end

-- A slower remembered replay must not discard a later queued replay when it
-- completes: two fast player steps behind a normal remembered walk execute
-- both follower replays in order, and the final tile reflects both.
function T.transition_b_second_fast_replay_survives_first_replay_completion()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  driveScriptedWalk(w, "south", "normal")
  Assert.deepEqual(
    w.controller._lastFollowerCommand,
    { direction = "south", speed = "normal" },
    "setup remembers the normal walk"
  )
  w.controller:setMovementType("follow_transition_b")
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  local start = assert(w.mgr:getPosition(partnerId), "the follower position is required")
  local startX, startZ = start.fieldX, start.fieldZ

  w.player:beginScriptedAction({ action = "walk", direction = "east", speed = "fast" })
  w.controller:update()
  Assert.notNil(w.controller._action, "the first replay starts immediately")
  Assert.equal(#w.controller._queue, 0, "an immediate replay queues nothing")
  for progress = 1, MovementCalibration.SPEED_TICKS.fast do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.fast)
    w.controller:update()
  end
  w.player:commitScriptedAction()
  w.controller:update()
  Assert.notNil(w.controller._action, "the normal replay is still in flight after the fast player step")

  w.player:beginScriptedAction({ action = "walk", direction = "east", speed = "fast" })
  w.controller:update()
  Assert.notNil(w.controller._action, "the first replay is still active when the second step starts")
  Assert.equal(#w.controller._queue, 1, "the second replay waits while the first is active")

  for progress = 1, MovementCalibration.SPEED_TICKS.fast do
    w.player:advanceScriptedAction(progress, MovementCalibration.SPEED_TICKS.fast)
    w.controller:update()
  end
  w.player:commitScriptedAction()
  for _ = 1, 40 do
    w.controller:update()
  end
  local actor = assert(w.mgr:getById(partnerId), "the partner survives both replays")
  Assert.equal(actor:getFieldPosition().fieldX, startX, "both replays hold the remembered column")
  Assert.equal(actor:getFieldPosition().fieldZ, startZ + 2, "both remembered replays execute in order")
  Assert.equal(#w.controller._queue, 0, "no pending replay remains")
  Assert.isNil(w.controller._action, "no replay remains in flight")
  Assert.isTrue(w.controller:isMovementSettled(), "both replays settle")
  w.mgr:dispose()
end

-- A queued head leaves the pending queue when its walk starts, not when an
-- action completes: starting the oldest obligation drains exactly it, the
-- later obligation keeps its order, and completing the active walk never
-- drops pending work.
function T.started_queue_head_leaves_pending_queue_at_start()
  local w = world()
  w.svc:setLead(0, mon())
  tick(w, 2)
  local partnerId = assert(w.mgr:partnerId(), "setup installs the partner")
  w.controller:setMovementPaused(true)
  driveScriptedWalk(w, "south", "fast")
  driveScriptedWalk(w, "south", "normal")
  Assert.equal(#w.controller._queue, 2, "both paused steps retain their own obligation")
  Assert.equal(w.controller._queue[1].speed, "fast", "the first queued step keeps its own speed")
  Assert.equal(w.controller._queue[2].speed, "normal", "the second queued step keeps its own speed")

  w.controller:setMovementPaused(false)
  w.controller:update()
  local action = assert(w.controller._action, "the oldest queued walk starts on release")
  Assert.equal(
    action.duration,
    MovementCalibration.SPEED_TICKS.fast,
    "the started walk keeps the head step speed, not the latest transaction"
  )
  Assert.equal(#w.controller._queue, 1, "the started head is no longer pending")
  Assert.equal(w.controller._queue[1].speed, "normal", "the later obligation keeps its order")
  Assert.equal(w.controller._queue[1].fieldZ, 6, "the later obligation keeps its target")

  for _ = 1, 60 do
    if w.controller._action == nil then
      break
    end
    w.controller:update()
  end
  Assert.isNil(w.controller._action, "the first walk completes")
  Assert.equal(#w.controller._queue, 1, "completing the walk drops no pending obligation")
  w.controller:update()
  Assert.notNil(w.controller._action, "the later obligation starts next")
  Assert.equal(#w.controller._queue, 0, "starting the later walk drains it")
  for _ = 1, 60 do
    w.controller:update()
  end
  local actor = assert(w.mgr:getById(partnerId), "the partner survives the drained queue")
  Assert.equal(actor:getFieldPosition().fieldX, 4, "both queued walks hold the remembered column")
  Assert.equal(actor:getFieldPosition().fieldZ, 6, "both queued walks replay in order")
  Assert.isTrue(w.controller:isMovementSettled(), "the drained queue settles")
  w.mgr:dispose()
end

return { tests = T }
