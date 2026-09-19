-- Per-open Trainer Card wrapper: the existing close-only controller beside
-- one presentation session. The wrapper publishes the copied profile fields
-- with the resolved presentation plan, drives the close edge exactly once
-- through the host contract, discards pointer content without semantic
-- effects, and releases both owners idempotently.

local Assert = require("tests.support.Assert")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local TrainerCardScreenState = require("game.hgss.src.field.TrainerCardScreenState")

local T = {}

local function measurement(width, height, topology)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = "card-screen-state-test:" .. width .. "x" .. height,
  }
end

local function singleDisplay(width, height)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
  return measurement(width, height, topology)
end

local PROFILE = { name = "GOLD", trainerId = 12345, money = 5000 }

local function composition(overrides)
  overrides = overrides or {}
  local box = { topology = nil }
  local options = {
    profile = { name = PROFILE.name, trainerId = PROFILE.trainerId, money = PROFILE.money },
    playTimeSeconds = 3723,
    measureDisplay = function()
      return singleDisplay(640, 480)
    end,
    windowState = { wide = { x = 0.5, y = 0.5 }, tall = { x = 0.5, y = 0.5 } },
  }
  for key, value in pairs(overrides) do
    options[key] = value
  end
  box.state = TrainerCardScreenState.new(options)
  return box
end

function T.status_carries_profile_fields_and_a_presentation_plan()
  local box = composition()
  local status = box.state:status()
  Assert.equal(status.open, true, "the card opens")
  Assert.equal(status.name, "GOLD", "the wrapper publishes the copied name")
  Assert.equal(status.trainerId, 12345, "the wrapper publishes the copied trainer id")
  Assert.equal(status.money, 5000, "the wrapper publishes the copied money")
  local plan = assert(status.presentation, "the wrapper publishes its presentation plan")
  Assert.equal(plan.inputKey, "trainer-card", "the plan names the card input geometry")
  Assert.equal(#plan.panes, 1, "the native-like card shows one content pane")
  box.state:dispose()
end

function T.cancel_edge_closes_exactly_once_through_the_host_contract()
  local box = composition()
  box.state:updateFixed({ { type = "cancel" } })
  local result = assert(box.state:takeResult(), "the close edge produces a result")
  Assert.equal(result.kind, "close", "the card application only returns close")
  Assert.isNil(box.state:takeResult(), "the close is reported exactly once")
  Assert.equal(box.state:status().open, false, "the closed card reports shut")
  box.state:dispose()
end

function T.pointer_content_never_closes_or_mutates_the_card()
  local box = composition()
  box.state:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 10, y = 10 } })
  box.state:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = 20, y = 20 } })
  box.state:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 20, y = 20 } })
  box.state:updateFixed({ { type = "pointer_cancel", pointerId = "touch:1" } })
  Assert.isNil(box.state:takeResult(), "pointer content produces no result")
  Assert.equal(box.state:status().open, true, "pointer content leaves the card open")
  Assert.equal(box.state:status().name, "GOLD", "pointer content preserves the profile snapshot")
  box.state:dispose()
end

function T.cancel_capture_drops_the_session_gesture_without_semantics()
  local box = composition()
  box.state:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 10, y = 10 } })
  box.state:cancelPointerCapture()
  box.state:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 10, y = 10 } })
  Assert.isNil(box.state:takeResult(), "the cancelled release produces no result")
  Assert.equal(box.state:status().open, true, "the cancelled release leaves the card open")
  box.state:dispose()
end

function T.failed_plan_publication_keeps_controller_state()
  local box = composition()
  local before = box.state:status()
  box.state:updateFixed({})
  local after = box.state:status()
  Assert.equal(after.name, before.name, "an empty batch preserves the profile snapshot")
  Assert.equal(after.presentation.inputKey, before.presentation.inputKey, "an empty batch keeps the input geometry")
  box.state:dispose()
end

function T.dispose_discards_the_pending_close()
  local box = composition()
  box.state:updateFixed({ { type = "cancel" } })
  box.state:dispose()
  Assert.isNil(box.state:takeResult(), "disposal discards the pending close")
  box.state:dispose()
end

function T.missing_capabilities_fail_at_construction()
  local withoutDisplay = {
    profile = { name = "GOLD", trainerId = 1, money = 0 },
    playTimeSeconds = 0,
    windowState = { wide = { x = 0.5, y = 0.5 }, tall = { x = 0.5, y = 0.5 } },
  }
  Assert.throws(function()
    TrainerCardScreenState.new(withoutDisplay --[[@as TrainerCardScreenState.Options]])
  end, "a card without display facts fails")
  local withoutWindows = {
    profile = { name = "GOLD", trainerId = 1, money = 0 },
    playTimeSeconds = 0,
    measureDisplay = function()
      return singleDisplay(640, 480)
    end,
  }
  Assert.throws(function()
    TrainerCardScreenState.new(withoutWindows --[[@as TrainerCardScreenState.Options]])
  end, "a card without window memory fails")
  local withoutProfile = {
    playTimeSeconds = 0,
    measureDisplay = function()
      return singleDisplay(640, 480)
    end,
    windowState = { wide = { x = 0.5, y = 0.5 }, tall = { x = 0.5, y = 0.5 } },
  }
  Assert.throws(function()
    TrainerCardScreenState.new(withoutProfile --[[@as TrainerCardScreenState.Options]])
  end, "a card without a profile fails")
end

return { tests = T }
