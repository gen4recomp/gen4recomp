-- Field-interaction input ownership: a foreground root launched through
-- ScriptInteractionClient:consume owns player input for its environment's
-- lifetime even without an explicit LOCK_PLAYER/LockAll opcode, while a root
-- launched through ScriptInteractionClient:startInitScript never gains that
-- ownership implicitly. Explicit lock, interaction claim, and their combined
-- OR must remain three separately observable scheduler facts, and normal
-- completion, fault, and cancellation must all release the claim through the
-- same environment teardown boundary. These fixtures compose synthetic
-- scripts so no ROM dump is required.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
local ChildScriptTask = require("libs.script.src.tasks.ChildScriptTask")
local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
local FakeServices = require("tests.support.script.FakeServices")
---@cast WaitTicksTask TaskImplementation
---@cast ChildScriptTask TaskImplementation

local T = {}

local function harness()
  local services = FakeServices.new()
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("child_script", 1, ChildScriptTask)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  -- A fixed-answer bindings fake: every intent resolves to the one installed
  -- interaction script. The client under test never inspects the intent
  -- beyond handing it to bindings, so a fixed resolution is sufficient to
  -- prove launch-origin behavior.
  local resolvedScriptId = nil
  local bindings = {
    resolveIntent = function(_, _, _)
      if resolvedScriptId == nil then
        return nil
      end
      return { scriptId = resolvedScriptId, trigger = { type = "field_interaction" } }
    end,
  }
  local client = ScriptInteractionClient.new({
    bindings = bindings,
    compose = function(id)
      return composition:effective(id)
    end,
    scheduler = scheduler,
    scriptBankId = 0,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    scheduler = scheduler,
    client = client,
    setResolvedScriptId = function(id)
      resolvedScriptId = id
    end,
  }
end

local function script(id, steps)
  return S.script({ api = 1, id = id, steps = steps })
end

local function install(h, resource)
  h.registry:installBase(resource.id, resource, "generated")
  return assert(h.composition:effective(resource.id))
end

-- An interaction root with blocking/wait nodes and no LOCK_PLAYER must be
-- reported as owning player input through the interaction-claim fact and
-- the combined fact, while the explicit-lock fact stays false.
function T.interaction_root_owns_input_without_lock_all()
  local h = harness()
  install(
    h,
    script("test.interaction_no_lock", {
      S.yieldTick(),
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    })
  )
  h.setResolvedScriptId("test.interaction_no_lock")

  local result = h.client:consume({ kind = "background" }, 100)
  Assert.equal(result, ScriptInteractionClient.RESULTS.started)

  Assert.notNil(h.scheduler:foregroundEnvironmentId(), "a consumed interaction must own the field")
  Assert.isFalse(h.scheduler:explicitPlayerLocked(), "no LOCK_PLAYER/LockAll opcode ran")
  Assert.isTrue(h.scheduler:interactionOwnsPlayerInput(), "the root was launched by field interaction")
  Assert.isTrue(h.scheduler:playerInputOwned(), "combined ownership must be explicit OR interaction")
end

-- The claim belongs to the root environment, not to individual children or
-- lock toggles. A common child completing, and an explicit lock acquired
-- then released, must both leave the interaction claim (and therefore
-- combined ownership) true until the root itself ends.
function T.interaction_claim_survives_child_execution_and_explicit_unlock()
  local h = harness()
  install(
    h,
    script("common.ownership_child", {
      { op = "signal_caller" },
      S.setVar({ variable = "VAR_CHILD_FALLTHROUGH", value = 1 }),
      S.stop(),
    })
  )
  install(
    h,
    script("test.interaction_with_child_and_lock", {
      S.lockPlayer(),
      S.callCommon({ target = "common.ownership_child" }),
      S.waitTicks({ ticks = 2 }),
      S.releasePlayer(),
      S.waitTicks({ ticks = 2 }),
      S.stop(),
    })
  )
  h.setResolvedScriptId("test.interaction_with_child_and_lock")

  h.client:consume({ kind = "background" }, 200)

  -- Immediately after launch: LOCK_PLAYER ran and the common child executed
  -- in the same tick (its slot had not yet been visited), so both explicit
  -- and interaction facts are true.
  Assert.isTrue(h.scheduler:explicitPlayerLocked(), "LOCK_PLAYER already ran")
  Assert.isTrue(h.scheduler:interactionOwnsPlayerInput())
  Assert.isTrue(h.scheduler:playerInputOwned())
  Assert.equal(
    h.services.world:getVar("VAR_CHILD_FALLTHROUGH"),
    1,
    "the child must continue through its real successor before handoff"
  )

  -- Advance until the child has completed and the parent resumed past
  -- RELEASE_PLAYER: the explicit lock must clear while the interaction claim
  -- (and therefore combined ownership) stays true because the root
  -- environment is still alive.
  for tick = 201, 210 do
    if not h.scheduler:explicitPlayerLocked() then
      break
    end
    h.scheduler:step(tick, nil)
  end
  Assert.isFalse(h.scheduler:explicitPlayerLocked(), "RELEASE_PLAYER must have run by now")
  Assert.notNil(h.scheduler:foregroundEnvironmentId(), "the root has not completed yet")
  Assert.isTrue(
    h.scheduler:interactionOwnsPlayerInput(),
    "child completion and explicit unlock must not release the environment's interaction claim"
  )
  Assert.isTrue(h.scheduler:playerInputOwned(), "combined ownership must stay true from the surviving claim")
end

-- A map-init root gets no implicit interaction claim. Explicit lock opcodes
-- still work normally and independently drive the explicit and combined
-- facts while held.
function T.map_init_root_does_not_implicitly_own_player_input()
  local h = harness()
  install(
    h,
    script("test.map_init_no_lock", {
      S.yieldTick(),
      S.waitTicks({ ticks = 5 }),
      S.stop(),
    })
  )

  local started = h.client:startInitScript("test.map_init_no_lock", 300)
  Assert.isTrue(started)

  Assert.notNil(h.scheduler:foregroundEnvironmentId(), "map init still starts a foreground root")
  Assert.isFalse(h.scheduler:explicitPlayerLocked())
  Assert.isFalse(
    h.scheduler:interactionOwnsPlayerInput(),
    "map initialization must never acquire the field-interaction claim"
  )
  Assert.isFalse(h.scheduler:playerInputOwned(), "a non-owning map-init root must not own player input")
end

function T.map_init_root_with_explicit_lock_owns_input_only_while_held()
  local h = harness()
  install(
    h,
    script("test.map_init_with_lock", {
      S.lockPlayer(),
      S.waitTicks({ ticks = 2 }),
      S.releasePlayer(),
      S.waitTicks({ ticks = 2 }),
      S.stop(),
    })
  )

  h.client:startInitScript("test.map_init_with_lock", 400)

  Assert.isTrue(h.scheduler:explicitPlayerLocked(), "LOCK_PLAYER already ran on the trigger tick")
  Assert.isFalse(h.scheduler:interactionOwnsPlayerInput(), "map init never gains the interaction claim")
  Assert.isTrue(h.scheduler:playerInputOwned(), "the explicit lock alone must still own combined input")

  for tick = 401, 410 do
    if not h.scheduler:explicitPlayerLocked() then
      break
    end
    h.scheduler:step(tick, nil)
  end
  Assert.isFalse(h.scheduler:explicitPlayerLocked())
  Assert.isFalse(h.scheduler:interactionOwnsPlayerInput())
  Assert.isFalse(h.scheduler:playerInputOwned(), "releasing the only owning fact must release combined ownership")
end

-- Fault and cancellation must release the interaction claim through the
-- same environment teardown as normal completion, never leaving a stale
-- claim and never blocking a later interaction from starting.
function T.faulting_interaction_root_releases_the_claim()
  local h = harness()
  install(
    h,
    script("test.interaction_faults", {
      S.call({ target = "scripts.nowhere" }),
      S.stop(),
    })
  )
  h.setResolvedScriptId("test.interaction_faults")

  h.client:consume({ kind = "background" }, 500)

  Assert.isNil(h.scheduler:foregroundEnvironmentId(), "the faulting root must already have torn down")
  Assert.isFalse(h.scheduler:explicitPlayerLocked())
  Assert.isFalse(h.scheduler:interactionOwnsPlayerInput(), "a faulted environment must not retain its claim")
  Assert.isFalse(h.scheduler:playerInputOwned())
end

function T.cancelling_an_interaction_root_releases_the_claim_and_a_later_interaction_can_start()
  local h = harness()
  install(
    h,
    script("test.interaction_cancel_me", {
      S.yieldTick(),
      S.waitTicks({ ticks = 20 }),
      S.stop(),
    })
  )
  h.setResolvedScriptId("test.interaction_cancel_me")

  h.client:consume({ kind = "background" }, 600)
  local envId = assert(h.scheduler:foregroundEnvironmentId())
  Assert.isTrue(h.scheduler:interactionOwnsPlayerInput())

  h.scheduler:cancelEnvironment(envId, "test cancellation")

  Assert.isNil(h.scheduler:foregroundEnvironmentId())
  Assert.isFalse(h.scheduler:explicitPlayerLocked())
  Assert.isFalse(
    h.scheduler:interactionOwnsPlayerInput(),
    "cancellation must release the claim like any other teardown"
  )
  Assert.isFalse(h.scheduler:playerInputOwned())

  -- A later interaction may start once the field is free again.
  install(
    h,
    script("test.interaction_after_cancel", {
      S.waitTicks({ ticks = 1 }),
      S.stop(),
    })
  )
  h.setResolvedScriptId("test.interaction_after_cancel")
  local result = h.client:consume({ kind = "background" }, 601)
  Assert.equal(result, ScriptInteractionClient.RESULTS.started)
  Assert.isTrue(h.scheduler:interactionOwnsPlayerInput())
end

-- Truth table coverage: false/false and true/false are exercised by
-- `map_init_root_does_not_implicitly_own_player_input` and
-- `map_init_root_with_explicit_lock_owns_input_only_while_held` above;
-- false/true and true/true are exercised by `interaction_root_owns_input_
-- without_lock_all` and `interaction_claim_survives_child_execution_and_
-- explicit_unlock`. No composed-script fixture is needed to prove the fourth
-- combination beyond those already covered by the acceptance contract.

return { tests = T }
