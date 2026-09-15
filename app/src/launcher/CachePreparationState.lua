-- Concrete bootstrap/quiescence progress state for the app shell. It pumps
-- no compilation itself: normal App updates keep the source session moving
-- while this state waits, displays concrete progress or failure, and
-- transfers exactly once on readiness. A disposed or stale state never
-- fires its completion callback.

---@class CachePreparationOptions
---@field kind "bootstrap"|"quiescence"
---@field epoch integer selected source epoch guarded against stale completion
---@field provisioner? table<string, function> bootstrap only: the borrowed selected session host
---@field pool table<string, unknown>? quiescence only: the borrowed process pool, required
---@field isCurrent fun(epoch: integer): boolean owner liveness: the epoch is still selected
---@field onReady fun() exactly-once transfer on readiness
---@field onCancel fun() return to the owning selection

---@class CachePreparationState
---@field kind string
---@field epoch integer
---@field provisioner table<string, function>?
---@field pool table<string, unknown>?
---@field isCurrent fun(epoch: integer): boolean
---@field onReady fun()
---@field onCancel fun()
---@field tick integer
---@field fired boolean
---@field dead boolean
---@field error unknown?
local CachePreparationState = {}
CachePreparationState.__index = CachePreparationState

---@param options CachePreparationOptions
---@return CachePreparationState
function CachePreparationState.new(options)
  assert(type(options) == "table", "cache preparation requires its composition")
  assert(options.kind == "bootstrap" or options.kind == "quiescence", "cache preparation kind is required")
  assert(
    type(options.epoch) == "number" and options.epoch % 1 == 0 and options.epoch >= 0,
    "cache preparation epoch must be a non-negative integer"
  )
  assert(type(options.isCurrent) == "function", "cache preparation requires its liveness check")
  assert(type(options.onReady) == "function", "cache preparation requires its transfer")
  assert(type(options.onCancel) == "function", "cache preparation requires its cancellation")
  if options.kind == "bootstrap" then
    assert(type(options.provisioner) == "table", "bootstrap preparation requires the selected session host")
  else
    assert(type(options.pool) == "table", "quiescence preparation requires the process pool")
    assert(type(options.pool.isQuiescent) == "function", "quiescence preparation requires pool quiescence")
  end
  return setmetatable({
    kind = options.kind,
    epoch = options.epoch,
    provisioner = options.provisioner,
    pool = options.pool,
    isCurrent = options.isCurrent,
    onReady = options.onReady,
    onCancel = options.onCancel,
    tick = 0,
    fired = false,
    dead = false,
    error = nil,
  }, CachePreparationState)
end

function CachePreparationState:_fire()
  if self.fired or self.dead then
    return
  end
  self.fired = true
  self.onReady()
end

function CachePreparationState:_pollBootstrap()
  local host = assert(self.provisioner, "bootstrap preparation requires the selected session host")
  local ok, ready, failure = pcall(host.requestMilestone, "bootstrap", "required")
  if not ok then
    self.error = ready
    return
  end
  if failure ~= nil then
    self.error = failure
    return
  end
  -- A latched producer failure surfaces even when the milestone probe stays
  -- pending: the public host observation carries the recorded cause.
  local statusOk, statusErr = pcall(host.status)
  if not statusOk then
    self.error = statusErr
    return
  end
  if ready then
    self:_fire()
  end
end

function CachePreparationState:_pollQuiescence()
  local pool = assert(self.pool, "quiescence preparation requires the process pool")
  -- A recorded infrastructure failure stays visible instead of waiting out a
  -- barrier that can never complete; raw import never starts past it.
  local diagnosticsFn = pool.diagnostics
  if type(diagnosticsFn) == "function" then
    local diagOk, diagnostics = pcall(diagnosticsFn, pool)
    if diagOk and type(diagnostics) == "table" and diagnostics.error ~= nil then
      self.error = diagnostics.error
      return
    end
  end
  local isQuiescent = assert(pool.isQuiescent, "quiescence preparation requires pool quiescence")
  -- The pool reports quiescence through a plain dot-called operation.
  local quiescentOk, quiescent = pcall(isQuiescent, pool)
  if not quiescentOk then
    error(quiescent, 0)
  end
  if quiescent then
    self:_fire()
  end
end

function CachePreparationState:update(_)
  if self.fired or self.dead then
    return
  end
  self.tick = self.tick + 1
  local liveOk, live = pcall(self.isCurrent, self.epoch)
  if not liveOk or not live then
    self.dead = true
    return
  end
  if self.error ~= nil then
    return
  end
  if self.kind == "bootstrap" then
    self:_pollBootstrap()
  else
    self:_pollQuiescence()
  end
end

function CachePreparationState:draw()
  local lg = love.graphics
  if self.error ~= nil then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Cache preparation failed:", 24, 24)
    lg.printf(tostring(self.error), 24, 48, lg.getWidth() - 48)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print("Press escape to return.", 24, 96)
    return
  end
  lg.setColor(1, 1, 1)
  if self.kind == "bootstrap" then
    lg.print("Preparing derived cache...", 24, 24)
    local host = assert(self.provisioner, "bootstrap preparation requires the selected session host")
    local statusOk, status = pcall(host.status)
    if statusOk and type(status) == "table" then
      lg.setColor(0.7, 0.7, 0.75)
      lg.print(
        string.format(
          "bootstrap: %s  ready %d  queued %d  running %d",
          tostring(status.bootstrap),
          status.ready or 0,
          status.queued or 0,
          status.running or 0
        ),
        24,
        48
      )
    end
  else
    lg.print("Waiting for source readers to drain...", 24, 24)
  end
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Press escape to cancel.", 24, 72)
end

---@param key string
function CachePreparationState:keypressed(key, _, _)
  if key == "escape" and not self.fired and not self.dead then
    self.dead = true
    self.onCancel()
  end
end

function CachePreparationState:filedropped(_)
  -- A replacement dropped while waiting stays queued behind quiescence;
  -- reentering import here would retire the selection under the wait.
end

function CachePreparationState:dispose()
  self.dead = true
end

return CachePreparationState
