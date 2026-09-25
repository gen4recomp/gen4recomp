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
    milestoneStatus = function()
      return { state = "pending", ready = 0, total = nil }
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
    milestoneStatus = function()
      return { state = "pending", ready = 0, total = nil }
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

local function recordDraw(draw)
  local calls = { rectangles = {}, prints = {} }
  local previousLove = rawget(_G, "love")
  rawset(_G, "love", {
    graphics = {
      setColor = function() end,
      print = function(text, _, _)
        calls.prints[#calls.prints + 1] = tostring(text)
      end,
      printf = function(text, _, _, _)
        calls.prints[#calls.prints + 1] = tostring(text)
      end,
      getWidth = function()
        return 640
      end,
      rectangle = function(_, x, y, w, h)
        calls.rectangles[#calls.rectangles + 1] = { x = x, y = y, w = w, h = h }
      end,
    },
  })
  local ok, err = pcall(draw)
  rawset(_G, "love", previousLove)
  return { ok = ok, err = err, rectangles = calls.rectangles, prints = calls.prints }
end

local function widestFill(rectangles)
  local widest = 0
  for _, rect in ipairs(rectangles) do
    if rect.w > widest and rect.w < 360 then
      widest = rect.w
    end
  end
  return widest
end

local function hasPrint(prints, pattern)
  for _, text in ipairs(prints) do
    if text:find(pattern) ~= nil then
      return true
    end
  end
  return false
end

function T.preparation_renders_progress_from_the_intro_milestone_only()
  local snapshot = { state = "pending", ready = 3, total = 8 }
  local host = {
    requestMilestone = function(name, urgency)
      Assert.equal(name, "new-game-intro")
      Assert.equal(urgency, "required")
      return false
    end,
    milestoneStatus = function(name)
      Assert.equal(name, "new-game-intro")
      return snapshot
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
  Assert.equal(state.phase, "pending")
  Assert.deepEqual(state.progress, snapshot, "the update retains the milestone-local snapshot")
  Assert.equal(readyCalls, 0, "progress observation never triggers the transfer")
  local drawn = recordDraw(function()
    state:draw()
  end)
  Assert.isTrue(drawn.ok, "drawing the progress bar never fails: " .. tostring(drawn.err))
  local fill = widestFill(drawn.rectangles)
  Assert.near(fill, 360 * 3 / 8, 1e-9, "the fill tracks ready over total")
  Assert.isTrue(hasPrint(drawn.prints, "38%%"), "the percentage matches the rounded fraction")
end

function T.preparation_renders_an_empty_bar_while_membership_is_unknown()
  local host = {
    requestMilestone = function()
      return false
    end,
    milestoneStatus = function()
      return { state = "pending", ready = 0, total = nil }
    end,
  }
  local state = NewGamePreparationState.new({
    derivedAssets = host,
    onReady = function() end,
    onCancel = function() end,
  })
  state:update(0)
  Assert.equal(state.phase, "pending")
  local drawn = recordDraw(function()
    state:draw()
  end)
  Assert.isTrue(drawn.ok, "an unknown denominator never breaks drawing: " .. tostring(drawn.err))
  local background = false
  for _, rect in ipairs(drawn.rectangles) do
    if rect.w == 360 then
      background = true
    end
  end
  Assert.isTrue(background, "an unknown denominator still renders the empty bar")
  local fill = 0
  for _, rect in ipairs(drawn.rectangles) do
    if rect.w ~= 360 and rect.w > fill then
      fill = rect.w
    end
  end
  Assert.equal(fill, 0, "an unknown denominator fills nothing")
end

function T.preparation_failure_hides_the_progress_bar()
  local host = {
    requestMilestone = function()
      return false, "intro milestone failed"
    end,
    milestoneStatus = function()
      return { state = "failed", ready = 1, total = 8, failure = "intro milestone failed" }
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
  Assert.equal(state.phase, "failed")
  Assert.equal(readyCalls, 0, "a failed milestone never transfers")
  local drawn = recordDraw(function()
    state:draw()
  end)
  Assert.isTrue(drawn.ok, "drawing the failure never fails")
  Assert.equal(#drawn.rectangles, 0, "the failure view renders no progress bar")
  Assert.isTrue(hasPrint(drawn.prints, "failed"), "the failure view names the failure")
end

return { tests = T }
