-- Follower-transition lifecycle: the transient two-part effect the
-- nonblocking follower command starts. Instances capture the live partner
-- generation, hold a two-update prelude on the companion part, then switch
-- to the animated part, reveal the ordinary partner exactly once, advance
-- the source clip to completion, and retire. Target replacement, removal,
-- or map change drops only the stale instance without touching the
-- replacement actor. Fake actor and model seams keep the timing
-- authoritative without ROM or GPU state.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FollowingMonTransitionController = require("libs.hgss.src.field.FollowingMonTransitionController")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local PARTNER_ID = "field:partner"

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local function definition(clipFrames)
  return {
    models = {
      { kind = "static" },
      { kind = "nitro-dynamic", animations = { { name = "transition", frameCount = clipFrames } } },
    },
    lifecycle = { mode = "once", preludeTicks = 2, frameCount = clipFrames },
    placementOffset = { x = 0, y = 6, z = 0 },
  }
end

local function partnerRecord(overrides)
  local record = {
    actorId = PARTNER_ID,
    mapId = 61,
    spriteId = 20153,
    fieldX = 4,
    fieldZ = 5,
    worldY = 2,
    visible = false,
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function fakeActors()
  local actors = { _partner = nil, _shows = {}, _hides = {} }
  function actors:partnerId()
    return self._partner ~= nil and PARTNER_ID or nil
  end
  function actors:getById(actorId)
    if actorId == PARTNER_ID then
      return self._partner
    end
    return nil
  end
  function actors:show(actorId)
    self._shows[#self._shows + 1] = actorId
    local actor = assert(self:getById(actorId), "show requires a live actor")
    actor.visible = true
  end
  function actors:hide(actorId)
    self._hides[#self._hides + 1] = actorId
    local actor = assert(self:getById(actorId), "hide requires a live actor")
    actor.visible = false
  end
  function actors:isVisible(actorId)
    local actor = assert(self:getById(actorId), "visibility requires a live actor")
    return actor.visible ~= false
  end
  function actors:install(record)
    self._partner = record
  end
  function actors:remove()
    self._partner = nil
  end
  return actors
end

local function fakeFactory(made, failsAfter)
  local calls = 0
  return function(part, descriptor)
    calls = calls + 1
    if failsAfter ~= nil and calls > failsAfter then
      error("boom-model-" .. part, 0)
    end
    local frameCount = 0
    if part == "animated" then
      frameCount = assert(descriptor.animations, "the animated part carries the source clip")[1].frameCount
    end
    local player = {
      part = part,
      frame = 0,
      frameCount = frameCount,
      updates = 0,
      resets = 0,
      disposed = false,
    }
    function player:updateFixed()
      self.updates = self.updates + 1
      self.frame = self.frame + 1
      if self.frame >= self.frameCount then
        self.complete = true
      end
    end
    function player:isComplete()
      return self.complete == true
    end
    function player:reset()
      self.resets = self.resets + 1
      self.frame = 0
      self.complete = false
    end
    function player:dispose()
      self.disposed = true
    end
    made[#made + 1] = player
    return player
  end
end

local function realManager()
  local assets = {
    knows = function(_, spriteId)
      return spriteId == 20153
    end,
    acquire = function(_, spriteId)
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function() end,
  }
  local map = {
    mapId = 61,
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
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
    mapSymbol = "test-map",
    scene = {},
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 4,
    fieldData = { events = { objects = {}, background = {}, warps = {}, coordinates = {} } },
    release = function() end,
    updateAnimated = function() end,
  }
  local actors = FieldActorManager.new({ assets = assets, policy = POLICY })
  actors:enterMap(map, FieldEventState.new())
  actors:installPartner({
    numericId = 253,
    visualId = 20153,
    mapId = 61,
    fieldX = 4,
    fieldZ = 5,
    facing = "south",
  })
  return actors
end

---@param actors table<string, unknown> actor manager or test seam owning partner identity and visibility
---@param clipFrames integer? clip frame count override
---@param made table<string, unknown>? made-instance collector
---@param failsAfter integer? model factory failure injector
---@return FollowingMonTransitionController
---@return table<string, unknown>
local function controller(actors, clipFrames, made, failsAfter)
  clipFrames = clipFrames or 5
  made = made or {}
  return FollowingMonTransitionController.new({
    actors = actors,
    definition = definition(clipFrames),
    modelFactory = fakeFactory(made, failsAfter),
  }),
    made
end

local function liveInstance(transitions)
  local instances = transitions:status().instances
  Assert.equal(#instances, 1, "exactly one transition must be live")
  return instances[1]
end

function T.start_without_a_partner_accepts_one_pending_request()
  local actors = fakeActors()
  local transitions, made = controller(actors)
  Assert.isTrue(transitions:start(), "a pre-publication request is accepted, not dropped")
  Assert.equal(#transitions:status().instances, 0, "a pending request binds no instance yet")
  Assert.equal(#made, 0, "a pending request allocates no model state")
  Assert.equal(#actors._shows, 0, "a pending request reveals nothing")
  for _ = 1, 3 do
    transitions:updateFixed()
  end
  Assert.equal(#transitions:status().instances, 0, "quiet updates bind nothing without a partner")
  Assert.equal(#made, 0, "quiet updates allocate no model state without a partner")
  Assert.equal(#actors._shows, 0, "quiet updates reveal nothing without a partner")
end

function T.pending_request_binds_the_first_hidden_partner_through_the_reveal_boundary()
  local actors = fakeActors()
  local transitions, made = controller(actors)
  Assert.isTrue(transitions:start(), "the pre-publication request is accepted")
  Assert.equal(#made, 0, "nothing allocates before publication")
  actors:install(partnerRecord())
  Assert.isFalse(actors:isVisible(PARTNER_ID), "the published partner starts hidden")

  transitions:updateFixed()
  local bound = liveInstance(transitions)
  Assert.equal(bound.phase, "prelude", "binding holds the companion part first")
  Assert.equal(bound.targetActorId, PARTNER_ID, "binding captures the published partner")
  Assert.equal(#made, 2, "binding allocates both effect parts exactly once")
  Assert.equal(#actors._shows, 0, "binding performs no early reveal")

  transitions:updateFixed()
  local revealed = liveInstance(transitions)
  Assert.equal(revealed.phase, "animated", "the second update switches parts")
  Assert.equal(#actors._shows, 1, "the switch reveals the partner exactly once")
  Assert.equal(actors._shows[1], PARTNER_ID, "the reveal targets the captured partner")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the partner stays visible after the reveal")
end

function T.repeated_pending_starts_coalesce_into_one_future_effect()
  local actors = fakeActors()
  local transitions, made = controller(actors)
  Assert.isTrue(transitions:start(), "the first pre-publication request is accepted")
  Assert.isTrue(transitions:start(), "a repeated pre-publication request is accepted")
  Assert.equal(#made, 0, "repeated pending starts allocate nothing")
  actors:install(partnerRecord())
  transitions:updateFixed()
  transitions:updateFixed()
  Assert.equal(#transitions:status().instances, 1, "coalesced requests bind exactly one instance")
  Assert.equal(#made, 2, "coalesced requests own exactly one pair of effect parts")
  Assert.equal(#actors._shows, 1, "coalesced requests reveal exactly once")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the partner ends visible")
end

function T.clear_and_dispose_before_publication_cancel_the_pending_request()
  local actors = fakeActors()
  local cleared, clearedMade = controller(actors)
  Assert.isTrue(cleared:start(), "setup accepts the pending request")
  cleared:clear()
  actors:install(partnerRecord())
  for _ = 1, 4 do
    cleared:updateFixed()
  end
  Assert.equal(#cleared:status().instances, 0, "a cleared request binds nothing after publication")
  Assert.equal(#clearedMade, 0, "a cleared request allocates nothing after publication")
  Assert.equal(#actors._shows, 0, "a cleared request reveals nothing")
  Assert.isFalse(actors:isVisible(PARTNER_ID), "the later partner keeps its own hidden state")

  local disposedActors = fakeActors()
  local disposed, disposedMade = controller(disposedActors)
  Assert.isTrue(disposed:start(), "setup accepts the pending request")
  disposed:dispose()
  disposedActors:install(partnerRecord())
  for _ = 1, 4 do
    disposed:updateFixed()
  end
  Assert.equal(#disposed:status().instances, 0, "a disposed request binds nothing after publication")
  Assert.equal(#disposedMade, 0, "a disposed request allocates nothing after publication")
  Assert.equal(#disposedActors._shows, 0, "a disposed request reveals nothing")
end

function T.bound_pending_reveal_never_shows_a_replacement_partner()
  local actors = fakeActors()
  local transitions = controller(actors)
  Assert.isTrue(transitions:start(), "the pre-publication request is accepted")
  actors:install(partnerRecord())
  transitions:updateFixed()
  liveInstance(transitions)
  local replacement = partnerRecord({ spriteId = 20154, visible = false })
  actors:install(replacement)
  transitions:updateFixed()
  Assert.equal(#transitions:status().instances, 0, "the stale bound instance drops on replacement")
  Assert.equal(#actors._shows, 0, "the stale bound instance never reveals the replacement actor")
  Assert.isFalse(replacement.visible, "the replacement keeps its own hidden visibility")
end

function T.start_captures_the_partner_without_consuming_prelude()
  local actors = fakeActors()
  actors:install(partnerRecord({ visible = true }))
  local transitions, made = controller(actors)
  Assert.isTrue(transitions:start(), "a live partner starts one instance")
  Assert.equal(#made, 2, "one start allocates both effect parts")
  local instance = liveInstance(transitions)
  Assert.equal(instance.phase, "prelude", "a fresh instance holds the companion part")
  Assert.equal(instance.preludeAge, 0, "starting consumes no prelude update")
  Assert.isTrue(instance.initialActive, "the companion part starts active")
  Assert.isFalse(instance.animatedActive, "the animated part starts inactive")
  Assert.equal(instance.frame, 0, "the animated clip starts at frame zero")
  Assert.equal(instance.targetActorId, PARTNER_ID, "the instance targets the installed partner")
  Assert.isTrue(actors:getById(PARTNER_ID).visible, "starting preserves an already-visible partner")
  Assert.equal(#actors._shows, 0, "starting performs no reveal")
  Assert.equal(#actors._hides, 0, "starting performs no hide")
end

function T.fake_manager_reveals_hidden_captured_partner_at_the_boundary()
  local actors = fakeActors()
  actors:install(partnerRecord())
  local transitions = controller(actors)
  transitions:start()

  transitions:updateFixed()
  local first = liveInstance(transitions)
  Assert.equal(first.phase, "prelude", "one update stays in the prelude")
  Assert.equal(first.preludeAge, 1, "the first update counts once")
  Assert.equal(#actors._shows, 0, "the prelude reveals nothing")

  transitions:updateFixed()
  local second = liveInstance(transitions)
  Assert.equal(second.phase, "animated", "the second update switches parts")
  Assert.isFalse(second.initialActive, "the switch retires the companion part")
  Assert.isTrue(second.animatedActive, "the switch activates the animated part")
  Assert.equal(second.frame, 0, "the switch resets the animated clip to frame zero")
  Assert.equal(#actors._shows, 1, "the switch reveals the partner exactly once")
  Assert.equal(actors._shows[1], PARTNER_ID, "the reveal targets the captured partner")
  Assert.equal(#actors._hides, 0, "the reveal never hides: it clears the hidden state")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the partner stays visible after the reveal")
end

function T.transition_start_preserves_visible_partner_until_reveal()
  local actors = realManager()
  local made = {}
  local constructionVisibility = {}
  local makePlayer = fakeFactory(made)
  local transitions = FollowingMonTransitionController.new({
    actors = actors,
    definition = definition(5),
    modelFactory = function(part, descriptor)
      constructionVisibility[#constructionVisibility + 1] = actors:isVisible(PARTNER_ID)
      return makePlayer(part, descriptor)
    end,
  })

  Assert.isTrue(actors:isVisible(PARTNER_ID), "a real manager installation starts visible")
  Assert.isTrue(transitions:start(), "the real manager partner starts the transition")
  Assert.deepEqual(constructionVisibility, { true, true }, "construction observes the visible partner")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "start preserves the captured partner visibility")

  transitions:updateFixed()
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the real partner stays visible through the prelude")

  transitions:updateFixed()
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the existing reveal boundary shows the real partner")
  Assert.equal(#made, 2, "the transition used two synthetic model players")
  actors:dispose()
end

function T.reveal_stays_idempotent_over_an_already_visible_partner()
  local actors = fakeActors()
  actors:install(partnerRecord({ visible = true }))
  local transitions = controller(actors)
  transitions:start()
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the visible partner stays visible for the prelude")
  Assert.equal(#actors._hides, 0, "starting does not hide the captured visible partner")
  transitions:updateFixed()
  Assert.equal(#actors._shows, 0, "the prelude adds no visibility change")
  transitions:updateFixed()
  Assert.equal(#actors._shows, 1, "the boundary reveal still runs once")
  Assert.equal(#actors._hides, 0, "the reveal does not hide the partner")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the partner remains visible")
end

function T.animated_phase_advances_one_frame_per_update_until_exact_completion()
  local actors = fakeActors()
  actors:install(partnerRecord())
  local transitions = controller(actors, 5)
  transitions:start()
  transitions:updateFixed()
  transitions:updateFixed()
  for tick = 1, 4 do
    transitions:updateFixed()
    local instance = liveInstance(transitions)
    Assert.equal(instance.frame, tick, "animated update " .. tick .. " advances one frame")
    Assert.equal(instance.phase, "animated", "the effect stays live before the final frame")
  end
  transitions:updateFixed()
  Assert.equal(#transitions:status().instances, 0, "the instance retires on exact clip completion")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "retirement never hides the revealed partner")
  Assert.equal(#actors._hides, 0, "retirement performs no hide")
end

function T.effect_anchor_tracks_the_live_partner_with_the_normalized_offset()
  local actors = fakeActors()
  actors:install(partnerRecord())
  local transitions = controller(actors)
  transitions:start()
  local partner = assert(actors:getById(PARTNER_ID))
  partner.fieldX = 7
  partner.fieldZ = 9
  partner.worldY = 3
  transitions:updateFixed()
  local instance = liveInstance(transitions)
  Assert.equal(instance.fieldX, 7, "the anchor re-samples the live partner tile")
  Assert.equal(instance.fieldZ, 9, "the anchor re-samples the live partner tile")
  Assert.equal(instance.worldY, 3, "the anchor re-samples the live partner height")
  Assert.deepEqual(
    instance.offset,
    { x = 0, y = 6, z = 0 },
    "the effect carries the normalized vertical placement offset"
  )
end

function T.replaced_target_drops_only_the_stale_instance()
  local actors = fakeActors()
  actors:install(partnerRecord({ visible = true }))
  local transitions = controller(actors)
  transitions:start()
  local captured = assert(actors:getById(PARTNER_ID))
  Assert.isTrue(captured.visible, "starting leaves the captured generation visible")
  transitions:updateFixed()
  local replacement = partnerRecord({ spriteId = 20154, visible = false })
  actors:install(replacement)
  transitions:updateFixed()
  Assert.equal(#transitions:status().instances, 0, "the stale instance drops on replacement")
  Assert.equal(#actors._shows, 0, "the stale instance never reveals the replacement actor")
  Assert.equal(#actors._hides, 0, "the stale instance never mutates the replacement actor")
  Assert.equal(replacement.visible, false, "the replacement keeps its own visibility")
end

function T.removed_target_drops_silently()
  local actors = fakeActors()
  actors:install(partnerRecord())
  local transitions = controller(actors)
  transitions:start()
  transitions:updateFixed()
  transitions:updateFixed()
  actors:remove()
  transitions:updateFixed()
  Assert.equal(#transitions:status().instances, 0, "a removed target ends the effect")
  Assert.equal(#actors._shows, 1, "only the boundary reveal ran before removal")
end

function T.map_changed_target_drops_silently()
  local actors = fakeActors()
  actors:install(partnerRecord())
  local transitions = controller(actors)
  transitions:start()
  transitions:updateFixed()
  assert(actors:getById(PARTNER_ID)).mapId = 62
  transitions:updateFixed()
  Assert.equal(#transitions:status().instances, 0, "a map-changed target ends the effect")
  Assert.equal(#actors._shows, 0, "the stale instance reveals nothing on a new map")
end

function T.repeated_starts_stay_independent()
  local actors = fakeActors()
  actors:install(partnerRecord({ visible = true }))
  local transitions, made = controller(actors)
  Assert.isTrue(transitions:start(), "the first start creates an instance")
  Assert.isTrue(transitions:start(), "a repeated start creates its own instance")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "repeated starts keep the captured partner visible")
  Assert.equal(#actors._hides, 0, "repeated starts never hide the generation")
  Assert.equal(#transitions:status().instances, 2, "both transient instances stay live")
  Assert.equal(#made, 4, "each instance owns both mutable effect parts")
  Assert.isTrue(made[1] ~= made[3], "repeated starts never share mutable animation state")
  transitions:updateFixed()
  transitions:updateFixed()
  Assert.equal(#actors._shows, 2, "each instance reveals once at its own boundary")
  for _ = 1, 5 do
    transitions:updateFixed()
  end
  Assert.equal(#transitions:status().instances, 0, "independent instances complete on the same clip end")
end

function T.failed_second_start_preserves_the_live_instance()
  local actors = fakeActors()
  actors:install(partnerRecord({ visible = true }))
  local transitions, made = controller(actors, 5, {}, 3)
  Assert.isTrue(transitions:start(), "the first start succeeds")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the first transition preserves the visible prelude")
  local ok = pcall(function()
    transitions:start()
  end)
  Assert.isFalse(ok, "the failed start propagates its construction failure")
  Assert.equal(#transitions:status().instances, 1, "the live instance survives the failed start")
  Assert.equal(made[1].disposed, false, "the live instance keeps its model state")
  Assert.equal(made[3].disposed, true, "the failed start releases its partial model state")
  Assert.equal(#actors._hides, 0, "the failed start never hides the captured generation")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the failed start preserves the live transition visibility")
end

function T.delayed_pending_bind_failure_is_consumed_without_retry()
  local actors = fakeActors()
  local transitions, made = controller(actors, 5, {}, 1)
  Assert.isTrue(transitions:start(), "a pre-publication request is accepted, not dropped")
  Assert.equal(#made, 0, "a pending request allocates no model state before publication")
  actors:install(partnerRecord())
  Assert.isFalse(actors:isVisible(PARTNER_ID), "the published partner starts hidden")

  local err = Assert.throws(function()
    transitions:updateFixed()
  end, "the delayed bind failure propagates instead of being swallowed")
  Assert.isTrue(
    string.find(err, "boom-model-animated", 1, true) ~= nil,
    "the failure comes from the delayed animated bind, not the initial start"
  )
  Assert.equal(#transitions:status().instances, 0, "the failed bind leaves no live instance")
  Assert.equal(#made, 1, "only the companion part allocated before the animated failure")
  Assert.equal(made[1].part, "initial", "the partial allocation is the companion part")
  Assert.isTrue(made[1].disposed, "the failed bind releases its partial companion state")
  Assert.equal(#actors._shows, 0, "the failed bind reveals nothing")
  Assert.isFalse(actors:isVisible(PARTNER_ID), "the partner stays hidden after the failed bind")

  local rebound = {}
  transitions:setModelFactory(fakeFactory(rebound))
  local quiet = pcall(function()
    transitions:updateFixed()
  end)
  Assert.isTrue(quiet, "the tick after the failure stays quiet without another error")
  Assert.equal(#rebound, 0, "the consumed request allocates nothing on the later tick")
  Assert.equal(#transitions:status().instances, 0, "the consumed request binds nothing later")
  Assert.equal(#actors._shows, 0, "the consumed request reveals nothing later")
  Assert.isFalse(actors:isVisible(PARTNER_ID), "the partner keeps its own hidden state")

  Assert.isTrue(transitions:start(), "a fresh request is accepted after the failure")
  transitions:updateFixed()
  transitions:updateFixed()
  Assert.equal(#transitions:status().instances, 1, "the fresh request binds after the failure")
  Assert.equal(#actors._shows, 1, "the fresh request reveals exactly once")
  Assert.isTrue(actors:isVisible(PARTNER_ID), "the partner ends visible")
end

function T.clear_and_dispose_release_exactly_once()
  local actors = fakeActors()
  actors:install(partnerRecord())
  local transitions, made = controller(actors)
  transitions:start()
  transitions:start()
  transitions:clear()
  Assert.equal(#transitions:status().instances, 0, "clearing ends every transient instance")
  for _, player in ipairs(made) do
    Assert.isTrue(player.disposed, "clearing releases every mutable model part")
  end
  transitions:clear()
  transitions:dispose()
  local releases = 0
  for _, player in ipairs(made) do
    if player.disposed then
      releases = releases + 1
    end
  end
  Assert.equal(releases, #made, "repeated clear and dispose release nothing twice")
  Assert.equal(#transitions:status().instances, 0, "disposal leaves no live effect")
end

return { tests = T }
