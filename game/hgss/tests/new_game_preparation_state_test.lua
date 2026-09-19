-- The pending New Game transition requests its semantic milestone as
-- required, transfers exactly once on readiness, and cancels safely back
-- to the menu without composing Oak or reserving a candidate.

local Assert = require("tests.support.Assert")
local NewGamePreparationState = require("game.hgss.src.newgame.NewGamePreparationState")

local T = {}

local function pendingHost()
  local calls = {}
  return {
    calls = calls,
    requestMilestone = function(name, urgency)
      calls[#calls + 1] = { name = name, urgency = urgency }
      return false
    end,
  }
end

function T.pending_preparation_requests_the_intro_milestone_without_transferring()
  local host = pendingHost()
  local readyCalls = 0
  local state = NewGamePreparationState.new({
    derivedAssets = host,
    onReady = function()
      readyCalls = readyCalls + 1
    end,
    onCancel = function() end,
  })
  state:update(0)
  state:update(0)
  Assert.equal(#host.calls, 2, "every update polls the semantic milestone")
  for _, call in ipairs(host.calls) do
    Assert.equal(call.name, "new-game-intro")
    Assert.equal(call.urgency, "required")
  end
  Assert.equal(readyCalls, 0, "no candidate or Oak transfer happens while pending")
end

function T.ready_preparation_transfers_exactly_once()
  local host = pendingHost()
  local ready = false
  host.requestMilestone = function(name, urgency)
    Assert.equal(name, "new-game-intro")
    Assert.equal(urgency, "required")
    return ready
  end
  local readyCalls = 0
  local state = NewGamePreparationState.new({
    derivedAssets = host,
    onReady = function()
      readyCalls = readyCalls + 1
    end,
    onCancel = function() end,
  })
  state:update(0)
  Assert.equal(readyCalls, 0, "no transfer happens while pending")
  ready = true
  state:update(0)
  state:update(0)
  state:update(0)
  Assert.equal(readyCalls, 1, "readiness transfers exactly once")
end

function T.failed_preparation_latches_its_error_without_transferring()
  local host = {
    requestMilestone = function()
      return false, "intro milestone failed"
    end,
  }
  local readyCalls = 0
  local state = NewGamePreparationState.new({
    derivedAssets = host,
    onReady = function()
      readyCalls = readyCalls + 1
    end,
    onCancel = function() end,
  })
  state:update(0)
  state:update(0)
  Assert.equal(readyCalls, 0, "a failed milestone never transfers")
  Assert.equal(state.phase, "failed")
  Assert.equal(state.error, "intro milestone failed")
end

function T.escape_cancels_back_to_menu_without_a_later_transfer()
  local host = pendingHost()
  local readyCalls, cancelCalls = 0, 0
  local state = NewGamePreparationState.new({
    derivedAssets = host,
    onReady = function()
      readyCalls = readyCalls + 1
    end,
    onCancel = function()
      cancelCalls = cancelCalls + 1
    end,
  })
  state:update(0)
  state:keypressed("escape")
  Assert.equal(cancelCalls, 1, "cancellation returns to the menu once")
  host.requestMilestone = function()
    return true
  end
  state:update(0)
  Assert.equal(readyCalls, 0, "a cancelled state never fires its ready callback later")
  Assert.equal(cancelCalls, 1, "a second escape never cancels twice")
  state:keypressed("escape")
  Assert.equal(cancelCalls, 1, "a second escape never cancels twice")
end

function T.disposed_preparation_never_transfers()
  local host = pendingHost()
  local readyCalls = 0
  local state = NewGamePreparationState.new({
    derivedAssets = host,
    onReady = function()
      readyCalls = readyCalls + 1
    end,
    onCancel = function() end,
  })
  state:dispose()
  host.requestMilestone = function()
    return true
  end
  state:update(0)
  Assert.equal(readyCalls, 0, "a disposed state never transfers")
end

function T.constructor_validates_its_composition()
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- the missing composition is the invalid input under test
    NewGamePreparationState.new("nope")
  end)
  Assert.throws(function()
    local options = { derivedAssets = {}, onReady = function() end }
    options.onCancel = "menu"
    ---@diagnostic disable-next-line: param-type-mismatch -- the mistyped callback is the invalid input under test
    NewGamePreparationState.new(options)
  end)
end

return { tests = T }
