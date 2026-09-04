-- Follower-transition lifecycle: the transient two-part effect the
-- nonblocking follower command starts. Instances capture the live partner
-- generation, hold a two-update prelude on the companion part, then switch
-- to the animated part, reveal the ordinary partner exactly once, advance
-- the source clip to completion, and retire. Target replacement, removal,
-- or map change drops only the stale instance without touching the
-- replacement actor. Fake actor and model seams keep the timing
-- authoritative without ROM or GPU state.

local Assert = require("tests.support.Assert")
local FollowingMonTransitionController = require("libs.hgss.src.field.FollowingMonTransitionController")

local T = {}

local PARTNER_ID = "field:partner"

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

function T.start_without_a_partner_starts_nothing()
  local actors = fakeActors()
  local transitions, made = controller(actors)
  Assert.isFalse(transitions:start(), "no partner means no instance")
  Assert.equal(#transitions:status().instances, 0, "no partner means no live effect")
  Assert.equal(#made, 0, "no partner allocates no model state")
  Assert.equal(#actors._shows, 0, "no partner reveals nothing")
end

function T.start_captures_the_partner_without_consuming_prelude()
  local actors = fakeActors()
  actors:install(partnerRecord())
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
  Assert.equal(actors:getById(PARTNER_ID).visible, false, "starting never reveals early")
  Assert.equal(#actors._shows, 0, "starting performs no reveal")
  Assert.equal(#actors._hides, 0, "starting performs no hide")
end

function T.two_updates_switch_parts_and_reveal_the_partner_once()
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

function T.reveal_stays_idempotent_over_an_already_visible_partner()
  local actors = fakeActors()
  actors:install(partnerRecord({ visible = true }))
  local transitions = controller(actors)
  transitions:start()
  transitions:updateFixed()
  Assert.equal(#actors._shows, 0, "the prelude adds no visibility change")
  transitions:updateFixed()
  Assert.equal(#actors._shows, 1, "the boundary reveal still runs once")
  Assert.equal(#actors._hides, 0, "an already-visible partner is never hidden first")
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
  actors:install(partnerRecord())
  local transitions = controller(actors)
  transitions:start()
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
  actors:install(partnerRecord())
  local transitions, made = controller(actors)
  Assert.isTrue(transitions:start(), "the first start creates an instance")
  Assert.isTrue(transitions:start(), "a repeated start creates its own instance")
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
  actors:install(partnerRecord())
  local transitions, made = controller(actors, 5, {}, 3)
  Assert.isTrue(transitions:start(), "the first start succeeds")
  local ok = pcall(function()
    transitions:start()
  end)
  Assert.isFalse(ok, "the failed start propagates its construction failure")
  Assert.equal(#transitions:status().instances, 1, "the live instance survives the failed start")
  Assert.equal(made[1].disposed, false, "the live instance keeps its model state")
  Assert.equal(made[3].disposed, true, "the failed start releases its partial model state")
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
