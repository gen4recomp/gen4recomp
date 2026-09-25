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
---@field progress { state: string, ready: integer, total: integer|nil, failure: unknown }?
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
    progress = nil,
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
  -- Progress is a read-only observation of the same milestone: it never
  -- enrolls work and never substitutes for the readiness request above.
  local progressOk, progress = pcall(self.derivedAssets.milestoneStatus, "new-game-intro")
  if not progressOk then
    self:_fail(progress)
    return
  end
  if type(progress) ~= "table" then
    self:_fail("derived-asset progress is unavailable")
    return
  end
  self.progress = {
    state = progress.state,
    ready = progress.ready,
    total = progress.total,
    failure = progress.failure,
  }
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
  local fraction = 0
  local snapshot = self.progress
  if type(snapshot) == "table" and type(snapshot.total) == "number" and snapshot.total > 0 then
    local ready = type(snapshot.ready) == "number" and snapshot.ready or 0
    if ready < 0 then
      ready = 0
    end
    if ready > snapshot.total then
      ready = snapshot.total
    end
    fraction = ready / snapshot.total
  end
  local barX, barY, barWidth, barHeight = 24, 48, 360, 14
  lg.setColor(0.2, 0.22, 0.28)
  lg.rectangle("fill", barX, barY, barWidth, barHeight)
  lg.setColor(0.35, 0.75, 0.55)
  lg.rectangle("fill", barX, barY, barWidth * fraction, barHeight)
  lg.setColor(0.7, 0.7, 0.75)
  lg.print(string.format("%d%%", math.floor(fraction * 100 + 0.5)), barX + barWidth + 12, barY - 2)
  lg.print("Press escape to cancel.", 24, 72)
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
