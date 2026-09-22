-- TrainerCardController contract tests: the close-input-only card
-- controller receives the authoritative player profile and copies the
-- required immutable fields (name/trainerId) at construction, so later
-- mutation of the caller's profile cannot change the open card. Gender is
-- not a card presentation field: the controller does not require it and the
-- status never carries it, even when the input profile does. Status exposes
-- exactly the implemented fields plus the open flag -- no future-card
-- placeholder keys -- and every call returns a fresh table. It owns no Start
-- Menu internals: a cancel edge records exactly one { kind = "close" }
-- result; every foreign input (directions/confirm/menu/pointers) changes
-- nothing; dispose is idempotent and discards a pending result; and
-- construction requires the profile. The controller requests no sound.

local Assert = require("tests.support.Assert")
local TrainerCardController = require("libs.hgss.src.ui.TrainerCardController")

local T = {
  tests = {},
}

local function throws(fn)
  return Assert.throws(fn)
end

local function demoProfile()
  return { name = "GOLD", gender = 0, trainerId = 0, money = 3000 }
end

local function fixture(profile)
  return TrainerCardController.new({ profile = profile or demoProfile(), playTimeSeconds = 0 })
end

function T.tests.construction_requires_the_profile()
  throws(function()
    TrainerCardController.new({})
  end)
  throws(function()
    TrainerCardController.new({ profile = {} })
  end)
  throws(function()
    TrainerCardController.new({ profile = { name = "GOLD" } })
  end)
  throws(function()
    TrainerCardController.new({ profile = { gender = 0, trainerId = 0 } })
  end)
  -- Gender is not a card presentation field: a profile without it is a
  -- valid construction input.
  Assert.notNil(
    TrainerCardController.new({ profile = { name = "GOLD", trainerId = 0, money = 3000 }, playTimeSeconds = 0 })
  )
end

-- The card must expose only the implemented profile fields: extra keys are
-- a contract violation even when their value is nil.
function T.tests.status_exposes_exactly_the_implemented_profile_fields()
  local status = fixture():status()
  Assert.equal(status.open, true)
  Assert.equal(status.name, "GOLD")
  Assert.equal(status.trainerId, 0)
  Assert.keySet(status, "money,name,open,playTimeSeconds,trainerId,visibleTrainerId")
end

function T.tests.status_passes_boundary_profile_values_through()
  local controller = TrainerCardController.new({
    profile = { name = "ABCDEFG", trainerId = 0x1234FFFF, money = 999999 },
    playTimeSeconds = 3599999,
  })
  local status = controller:status()
  Assert.equal(status.name, "ABCDEFG")
  Assert.equal(status.trainerId, 0x1234FFFF)
  Assert.equal(status.visibleTrainerId, 65535)
  Assert.equal(status.money, 999999)
  Assert.equal(status.playTimeSeconds, 3599999)
end

function T.tests.open_and_cancel_emit_card_effects()
  local effects = {}
  local controller = TrainerCardController.new({
    profile = { name = "GOLD", trainerId = 0, money = 3000 },
    playTimeSeconds = 62,
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
  })
  Assert.deepEqual(effects, { "SEQ_SE_DP_CARD3" })
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(effects[2], "SEQ_SE_GS_GEARCANCEL")
end

function T.tests.construction_copies_the_required_fields()
  local profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000 }
  local controller = TrainerCardController.new({ profile = profile, playTimeSeconds = 0 })
  profile.name = "HIKARI"
  profile.trainerId = 1
  local status = controller:status()
  Assert.equal(status.name, "GOLD", "the card keeps the construction-time profile copy")
  Assert.equal(status.trainerId, 0)
end

function T.tests.a_dismiss_edge_records_one_close_result()
  local controller = fixture()
  Assert.isTrue(controller:status().open, "the card starts open")
  controller:updateFixed({ { type = "dismiss" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" }, "dismiss closes exactly like cancel")
  Assert.equal(controller:takeResult(), nil, "the close result is delivered exactly once")
  Assert.isFalse(controller:status().open, "the card is closed")
end

function T.tests.dismiss_ends_the_batch_so_later_input_cannot_reopen_the_card()
  local controller = fixture()
  controller:updateFixed({ { type = "dismiss" }, { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" }, "only the terminal close survives the batch")
end

function T.tests.a_cancel_edge_records_one_close_result()
  local controller = fixture()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
  Assert.equal(controller:takeResult(), nil, "the close result is delivered exactly once")
end

function T.tests.foreign_input_changes_nothing()
  local controller = fixture()
  controller:updateFixed({
    { type = "navigate", direction = "south" },
    { type = "confirm" },
    { type = "menu" },
    { type = "pointer_down", pointerId = "touch:1", x = 192, y = 19 },
    { type = "pointer_up", pointerId = "touch:1", x = 192, y = 19 },
  })
  Assert.equal(controller:takeResult(), nil, "foreign input must never close or launch the card")
  local status = controller:status()
  Assert.equal(status.open, true, "the card stays open under foreign input")
  Assert.equal(status.trainerId, 0, "the presentation is unchanged")
end

function T.tests.the_menu_edge_does_not_close_the_card()
  local controller = fixture()
  controller:updateFixed({ { type = "menu" } })
  Assert.equal(controller:takeResult(), nil, "the menu key must not tear down a child application")
  Assert.equal(controller:status().open, true)
end

function T.tests.dispose_is_idempotent_and_discards_a_pending_result()
  local controller = fixture()
  controller:updateFixed({ { type = "cancel" } })
  controller:dispose()
  controller:dispose()
  Assert.equal(controller:takeResult(), nil, "dispose discards the pending close result")
  Assert.equal(controller:status().open, false)
end

function T.tests.update_fixed_after_close_is_a_noop()
  local controller = fixture()
  controller:updateFixed({ { type = "cancel" } })
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" }, "only the first cancel edge produces the close result")
  Assert.equal(controller:takeResult(), nil, "the second cancel edge produces nothing")
end

return T
