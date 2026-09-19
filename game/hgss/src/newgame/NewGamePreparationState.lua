-- Pending New Game ownership between the Main Menu intent and Oak
-- composition. It requests the semantic New Game intro milestone as
-- required, then transfers to the already-registered ready callback exactly
-- once. Failures are visible and cancellable; cancellation returns to the
-- menu without composing Oak or reserving a candidate, and it never
-- retires the selected generation's compiled output.

---@class NewGamePreparationOptions
---@field derivedAssets table<string, function> semantic derived-asset host
---@field onReady fun() compose the New Game candidate and Oak intro
---@field onCancel fun()? return to the owning menu

---@class NewGamePreparationState
---@field derivedAssets table<string, function>
---@field onReady fun()?
---@field onCancel fun()?
---@field phase "pending"|"failed"|"done"
---@field error unknown?
---@field fired boolean
---@field cancelled boolean
local NewGamePreparationState = {}
NewGamePreparationState.__index = NewGamePreparationState

---@param options NewGamePreparationOptions
---@return NewGamePreparationState
function NewGamePreparationState.new(options)
  assert(type(options) == "table", "New Game preparation requires its composition")
  assert(type(options.derivedAssets) == "table", "New Game preparation requires the derived-asset host")
  assert(type(options.onReady) == "function", "New Game preparation requires its ready transfer")
  if options.onCancel ~= nil then
    assert(type(options.onCancel) == "function", "New Game preparation cancellation must be a function")
  end
  return setmetatable({
    derivedAssets = options.derivedAssets,
    onReady = options.onReady,
    onCancel = options.onCancel,
    phase = "pending",
    error = nil,
    fired = false,
    cancelled = false,
  }, NewGamePreparationState)
end

function NewGamePreparationState:_fail(err)
  if self.phase ~= "failed" then
    self.phase = "failed"
    self.error = err
  end
end

function NewGamePreparationState:update(_)
  if self.fired or self.cancelled or self.phase == "failed" or self.phase == "done" then
    return
  end
  -- The semantic host is a plain function table (dot calls, no self).
  local ok, ready, failure = pcall(self.derivedAssets.requestMilestone, "new-game-intro", "required")
  if not ok then
    self:_fail(ready)
    return
  end
  if failure ~= nil then
    self:_fail(failure)
    return
  end
  if ready then
    -- The ready transfer composes the candidate and Oak; a failure there
    -- is composition behavior, never relabeled as cache work. The latch
    -- is set before the call so a reentrant update cannot transfer twice.
    self.fired = true
    self.phase = "done"
    local transfer = assert(self.onReady, "New Game preparation requires its ready transfer")
    transfer()
  end
end

function NewGamePreparationState:draw()
  local lg = love.graphics
  lg.setColor(1, 1, 1)
  if self.phase == "failed" then
    lg.setColor(1, 0.5, 0.5)
    lg.print("New Game preparation failed:", 24, 24)
    lg.printf(tostring(self.error), 24, 48, lg.getWidth() - 48)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print("Press escape to return.", 24, 96)
    return
  end
  lg.print("Preparing New Game...", 24, 24)
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Press escape to cancel.", 24, 48)
end

---@param key string
function NewGamePreparationState:keypressed(key, _, _)
  if key == "escape" and not self.fired and not self.cancelled then
    self.cancelled = true
    if self.onCancel then
      self.onCancel()
    end
  end
end

function NewGamePreparationState:dispose()
  -- Cancellation or replacement never composes Oak or reserves a
  -- candidate: only this state's references are dropped. The borrowed host
  -- stays with its owner; registered cache interest is non-preemptive and
  -- stays available for a later attempt.
  self.cancelled = true
  self.onReady = nil
  self.onCancel = nil
end

return NewGamePreparationState
