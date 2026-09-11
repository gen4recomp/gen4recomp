-- Acceptance-harness component contract. Synthetic runtimes keep the harness
-- mechanics fast and deterministic; ROM-backed flows belong in the companion
-- acceptance suite below.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = { tags = { "acceptance-harness" } },
  tests = {},
}

local function fakeRuntime(game)
  local runtime = {
    versionId = game.versionId,
    session = { tick = 0 },
    player = { fieldX = 4, fieldZ = 7, facing = "south", motion = "idle" },
    runtimeMap = { mapId = 12, mapSymbol = "MAP_TEST" },
    transition = { phase = "idle" },
    disposeCalls = 0,
  }
  function runtime:update()
    self.session.tick = self.session.tick + 1
  end
  function runtime:press(direction)
    self.player.facing = direction
  end
  function runtime:release() end
  function runtime:captureGameSave()
    return self.game
  end
  runtime.game = game
  function runtime:dispose()
    self.disposeCalls = self.disposeCalls + 1
  end
  return runtime
end

function T.tests.synthetic_boot_is_closed_once_and_uses_a_unique_save_namespace()
  local deleted = {}
  local runtimes = {}
  local graphics = love.graphics
  local originalShader = graphics.newShader
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(game)
      local runtime = fakeRuntime(game)
      runtimes[#runtimes + 1] = runtime
      return runtime
    end,
    saveNamespace = function(versionId, serial)
      return "acceptance-test/" .. versionId .. "/" .. serial
    end,
    removeSaveNamespace = function(path)
      deleted[#deleted + 1] = path
    end,
  })

  local first = harness:boot({ versionId = "heartgold", save = "fresh" })
  local second = harness:boot({ versionId = "heartgold", save = "fresh" })
  Assert.equal(runtimes[1].game.playTime:seconds(), 0)
  Assert.equal(runtimes[2].game.playTime:seconds(), 0)
  Assert.isTrue(first.saveNamespace ~= second.saveNamespace, "each boot needs an isolated save namespace")
  first:close()
  first:close()
  second:close()
  Assert.equal(runtimes[1].disposeCalls, 1)
  Assert.equal(runtimes[2].disposeCalls, 1)
  Assert.deepEqual(deleted, { first.saveNamespace, second.saveNamespace })
  -- Each boot installs a render trap over the process-global graphics
  -- namespace; a second boot captures the trapped functions as its
  -- "originals", so any close order must still restore the real functions.
  Assert.equal(graphics.newShader, originalShader, "closing every game restores the graphics namespace")
end

function T.tests.synthetic_boot_keeps_the_global_save_catalog_inside_its_namespace()
  local harness = AcceptanceHarness.new({ versions = { "heartgold" }, runtimeFactory = fakeRuntime })
  local priorCatalog = love.filesystem.getInfo("saves/catalog.lua")
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })
  Assert.notNil(love.filesystem.getInfo(game.saveNamespace .. "/global/catalog.lua"))
  Assert.isNil(love.filesystem.getInfo(game.saveNamespace .. "/version/catalog.lua"))
  Assert.deepEqual(
    love.filesystem.getInfo("saves/catalog.lua"),
    priorCatalog,
    "acceptance must not touch the real save root"
  )
  -- A parallel worker process privately receives a run-unique,
  -- worker-unique token (only ever present when this suite actually runs as
  -- a worker of a full parallel `scripts/test.sh` command); the default
  -- namespace must fold it in without disturbing serial/focused behavior.
  local workerToken = os.getenv("G4RECOMP_TEST_ACCEPTANCE_NAMESPACE")
  if workerToken ~= nil then
    Assert.isTrue(
      game.saveNamespace:find("/" .. workerToken .. "-", 1, true) ~= nil,
      "the default namespace must contain the private worker token: " .. game.saveNamespace
    )
  end
  game:close()
end

function T.tests.advance_until_timeout_contains_a_bounded_semantic_trace()
  local harness = AcceptanceHarness.new({ versions = { "heartgold" }, runtimeFactory = fakeRuntime })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })
  local err = Assert.throws(function()
    game:advanceUntil("impossible state", function()
      return false
    end, 3)
  end)
  local message = tostring(err)
  Assert.isTrue(message:find("impossible state", 1, true) ~= nil)
  Assert.isTrue(message:find("tick", 1, true) ~= nil, "timeout must include snapshot diagnostics")
  Assert.isTrue(#game:trace() <= 3, "the failure trace must stay bounded")
  game:close()
end

function T.tests.wait_for_transition_returns_the_observed_destination_before_follow_up_scripts()
  local lockTicks = 0
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(game)
      local runtime = fakeRuntime(game)
      runtime.scripts = {
        scheduler = {
          playerInputLocked = function()
            return lockTicks < 4
          end,
          playerInputOwned = function()
            return lockTicks < 4
          end,
          foregroundEnvironmentId = function()
            return nil
          end,
          foregroundScriptId = function()
            return nil
          end,
        },
      }
      function runtime:update()
        lockTicks = lockTicks + 1
        self.session.tick = lockTicks
        if lockTicks == 2 then
          self.runtimeMap.mapId = 13
          self.runtimeMap.mapSymbol = "MAP_DESTINATION"
        elseif lockTicks == 3 then
          self.runtimeMap.mapId = 12
          self.runtimeMap.mapSymbol = "MAP_TEST"
        end
      end
      return runtime
    end,
  })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })
  game:step()

  local transition = game:waitForTransition()

  Assert.equal(transition.destination.mapSymbol, "MAP_DESTINATION")
  Assert.isTrue(transition.destination.fieldLocked)
  Assert.equal(transition.destination.tick, 2)
  game:close()
end

function T.tests.failed_boot_disposes_the_partial_runtime_and_removes_its_namespace()
  local deleted = {}
  local runtime = fakeRuntime({ versionId = "heartgold" })
  runtime.captureGameSave = nil
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function()
      return runtime
    end,
    saveNamespace = function()
      return "acceptance-test/heartgold/failed-boot"
    end,
    removeSaveNamespace = function(path)
      deleted[#deleted + 1] = path
    end,
  })

  Assert.throws(function()
    harness:boot({ versionId = "heartgold", save = "fresh" })
  end)
  Assert.equal(runtime.disposeCalls, 1)
  Assert.deepEqual(deleted, { "acceptance-test/heartgold/failed-boot" })
end

function T.tests.failed_namespace_cleanup_can_be_retried_without_disposing_twice()
  local runtime = fakeRuntime("heartgold")
  local removals = 0
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function()
      return runtime
    end,
    removeSaveNamespace = function()
      removals = removals + 1
      if removals == 1 then
        error("injected namespace cleanup failure")
      end
    end,
  })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })

  Assert.throws(function()
    game:close()
  end)
  game:close()
  Assert.equal(runtime.disposeCalls, 1)
  Assert.equal(removals, 2)
end

function T.tests.selected_versions_are_iterated_in_declared_order()
  local harness = AcceptanceHarness.new({
    versions = { "heartgold", "soulsilver" },
    runtimeFactory = fakeRuntime,
  })
  local seen = {}
  harness:forEachVersion(function(versionId)
    seen[#seen + 1] = versionId
  end)
  Assert.deepEqual(seen, { "heartgold", "soulsilver" })
end

function T.tests.primary_version_uses_the_first_selected_version()
  local harness = AcceptanceHarness.new({ versions = { "soulsilver" } })
  Assert.equal(harness:primaryVersion(), "soulsilver")
end

function T.tests.restart_reuses_the_save_namespace_and_disposes_the_replaced_runtime_once()
  local runtimes = {}
  local optionsSeen = {}
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(game, options)
      optionsSeen[#optionsSeen + 1] = options
      local runtime = fakeRuntime(game)
      runtimes[#runtimes + 1] = runtime
      return runtime
    end,
    saveNamespace = function()
      return "acceptance-test/heartgold/restart"
    end,
  })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })

  local resumed = game:restart({ save = "resume" })

  Assert.equal(resumed, game)
  Assert.equal(runtimes[1].game.playTime:seconds(), runtimes[2].game.playTime:seconds())
  Assert.equal(runtimes[1].disposeCalls, 1)
  game:close()
  Assert.equal(runtimes[2].disposeCalls, 1)
end

function T.tests.restart_reuses_the_original_field_options()
  local optionsSeen = {}
  local fieldOptions = {
    viewportWidth = 1280,
    viewportHeight = 720,
    screenTopology = { id = "dual-display" },
  }
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(game, options)
      optionsSeen[#optionsSeen + 1] = options
      return fakeRuntime(game)
    end,
  })
  local game = harness:boot({
    versionId = "heartgold",
    save = "fresh",
    fieldOptions = fieldOptions,
  })

  game:restart({ save = "resume" })

  Assert.equal(optionsSeen[2].viewportWidth, 1280)
  Assert.equal(optionsSeen[2].viewportHeight, 720)
  Assert.equal(optionsSeen[2].screenTopology, fieldOptions.screenTopology)
  game:close()
end

function T.tests.recording_script_hosts_are_an_explicit_composition_choice()
  local optionsSeen = {}
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(game, options)
      optionsSeen[#optionsSeen + 1] = options
      local runtime = fakeRuntime(game)
      runtime.scriptHosts = options.scriptHosts
      return runtime
    end,
  })

  local productionLike = harness:boot({ versionId = "heartgold", save = "fresh" })
  Assert.isNil(optionsSeen[1].scriptHosts, "default acceptance composition must not inject recording hosts")
  Assert.throws(function()
    productionLike:hostEvents()
  end, "recording-only observations must require explicit recording hosts")
  productionLike:close()

  local recording = harness:boot({
    versionId = "heartgold",
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  Assert.notNil(optionsSeen[2].scriptHosts, "explicit recording composition must provide script hosts")
  Assert.notNil(recording:hostEvents().records, "explicit recording composition must expose event records")
  recording:close()
end

-- The three readiness boundaries are genuinely distinct: map identity,
-- `FieldTransition` settlement, and ordinary-input availability clear at
-- different ticks. A deterministic fake proves the harness observes each
-- boundary independently instead of collapsing them into one wait.
local function readinessRuntime(game)
  local runtime = fakeRuntime(game)
  runtime.session.mapEntryStage = "staging"
  runtime.transition.phase = "fade_in"
  runtime.dialogue = {
    modal = true,
    status = function(self)
      return self
    end,
  }
  local locked = true
  runtime.scripts = {
    scheduler = {
      playerInputLocked = function()
        return locked
      end,
      playerInputOwned = function()
        return locked
      end,
      foregroundEnvironmentId = function()
        return locked and "foreground" or nil
      end,
      foregroundScriptId = function()
        return nil
      end,
    },
  }
  function runtime:update()
    self.session.tick = self.session.tick + 1
    local tick = self.session.tick
    if tick >= 2 then
      self.runtimeMap.mapId = 13
      self.runtimeMap.mapSymbol = "MAP_DESTINATION"
    end
    if tick >= 4 then
      self.transition.phase = "idle"
    end
    if tick >= 6 then
      locked = false
    end
    if tick >= 8 then
      self.dialogue.modal = false
      self.session.mapEntryStage = nil
    end
  end
  return runtime
end

function T.tests.map_swap_transition_completion_and_field_readiness_clear_at_distinct_ticks()
  local harness = AcceptanceHarness.new({ versions = { "heartgold" }, runtimeFactory = readinessRuntime })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })

  local swapped = game:waitForMapSwap()
  Assert.equal(swapped.destination.mapSymbol, "MAP_DESTINATION")
  Assert.equal(swapped.destination.tick, 2, "map swap must return as soon as the destination map identity changes")
  Assert.isFalse(swapped.destination.transition.phase == "idle", "transition may still be settling at map swap")

  local completed = game:waitForTransition()
  Assert.equal(completed.destination.tick, 4, "transition completion must wait for the transition's own idle phase")
  Assert.isTrue(completed.destination.fieldLocked, "a destination lifecycle script may still own the field")

  local ready = game:waitForFieldReady()
  Assert.equal(ready.tick, 8, "field readiness must wait for lifecycle, entry staging, and dialogue to all clear")
  Assert.isFalse(ready.fieldLocked)
  Assert.isFalse(ready.dialogue.modal)
  Assert.isNil(ready.mapEntryStage)

  game:close()
end

function T.tests.field_readiness_reports_the_blocking_state_when_it_never_clears()
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(game)
      local runtime = fakeRuntime(game)
      runtime.dialogue = {
        modal = true,
        status = function(self)
          return self
        end,
      }
      runtime.scripts = {
        scheduler = {
          playerInputLocked = function()
            return true
          end,
          playerInputOwned = function()
            return true
          end,
          foregroundEnvironmentId = function()
            return "foreground"
          end,
          foregroundScriptId = function()
            return "vanilla.stuck_script"
          end,
        },
      }
      return runtime
    end,
  })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })

  local err = Assert.throws(function()
    game:waitForFieldReady(2)
  end)
  local message = tostring(err)
  Assert.isTrue(message:find("dialogueModal=true", 1, true) ~= nil, "timeout must name the blocking dialogue state")
  Assert.isTrue(
    message:find("vanilla.stuck_script", 1, true) ~= nil,
    "timeout must name the foreground script still owning the field"
  )
  game:close()
end

-- A step blocked by production movement resolution (an actor occupying the
-- destination, in real composition) settles idle without reaching the
-- expected coordinate. `_moveOne` reports that outcome as unmatched rather
-- than asserting on it, so a caller planning around live actors can replan
-- instead of treating it as fatal -- even though facing already matches the
-- requested direction.
function T.tests.moveOne_reports_a_blocked_step_even_when_facing_already_matches()
  local harness = AcceptanceHarness.new({
    versions = { "heartgold" },
    runtimeFactory = function(game)
      local runtime = fakeRuntime(game)
      runtime.player.facing = "east"
      function runtime:press(direction)
        -- Production blocked this step: facing updates, coordinates do not.
        self.player.facing = direction
      end
      return runtime
    end,
  })
  local game = harness:boot({ versionId = "heartgold", save = "fresh" })

  local after, matched = game:_moveOne("east", { fieldX = 5, fieldZ = 7 })
  Assert.isTrue(not matched, "a blocked step must not report as matched")
  Assert.equal(after.player.fieldX, 4, "a blocked step must not silently commit the planned coordinate")
  game:close()
end

return T
