-- Executes one normalized suite and returns its results. Every result is
-- exactly one of pass, fail, or skip: a skip is always explicit
-- (`context:skip(reason)` or an unavailable declared capability) and can never
-- be produced by a test body returning early.
--
-- Hooks and test bodies run under xpcall with a traceback-preserving handler.
-- `afterAll` runs on every terminal path once `beforeAll` was entered, so a
-- setup that acquired resources before failing still releases them.

-- Capability availability stays here with the skip policy; test selection
-- itself is owned by the caller.
local Selection = require("tests.runner.Selection")

local Execution = {}

local SKIP = {}

local function now()
  if love ~= nil and love.timer ~= nil then
    return love.timer.getTime()
  end
  return os.clock()
end

local function handler(err)
  if type(err) == "table" and getmetatable(err) == SKIP then
    return err
  end
  return debug.traceback(tostring(err), 2)
end

-- Protected call returning `status, payload` where status is "pass", "skip", or
-- "fail"; payload is the skip reason or the traceback.
local function protected(fn, context)
  local ok, err = xpcall(assert(fn), handler, context)
  if ok then
    return "pass", nil
  end
  if type(err) == "table" and getmetatable(err) == SKIP then
    return "skip", err.reason
  end
  return "fail", tostring(err)
end

---@param available table<string, boolean>
---@return table context passed to hooks and test bodies
local function newContext(available)
  local context = {}
  function context:hasCapability(name)
    return available[name] == true
  end
  function context:skip(reason)
    error(setmetatable({ reason = tostring(reason) }, SKIP), 0)
  end
  return context
end

local function result(suite, testName, status, message, duration)
  return {
    module = suite.module,
    test = testName,
    status = status,
    message = message,
    layer = suite.layer,
    duration = duration,
  }
end

-- Runs `suite`'s already selected tests, in their given order. Selection is
-- owned by the caller; an empty list means the suite was not selected and
-- nothing is executed. Returns a results array and hook-inclusive timing.
---@param suite RunnerSuite
---@param options { capabilities: table<string, boolean> }
---@param selectedTests string[]|nil explicit test names; defaults to every test of the suite
---@return table[] results, table timing
function Execution.runSuite(suite, options, selectedTests)
  local selected = selectedTests or suite.tests
  assert(type(selected) == "table", "Execution.runSuite needs explicit selected test names")
  if #selected == 0 then
    return {}, { beforeAll = 0, tests = 0, afterAll = 0, total = 0 }
  end

  local available = options.capabilities or {}
  local missing = Selection.missingCapability(suite.capabilities, available)
  if missing ~= nil then
    local results = {}
    for _, name in ipairs(selected) do
      results[#results + 1] = result(suite, name, "skip", "missing capability: " .. missing, 0)
    end
    return results, { beforeAll = 0, tests = 0, afterAll = 0, total = 0 }
  end

  local context = newContext(available)
  local results = {}
  local runTests = true
  local beforeAll = 0
  local tests = 0
  local afterAll = 0

  if suite.beforeAll ~= nil then
    local started = now()
    local status, message = protected(suite.beforeAll, context)
    local elapsed = now() - started
    beforeAll = elapsed
    if status == "skip" then
      -- Setup owns the suite-wide precondition, so its skip skips every test.
      runTests = false
      for _, name in ipairs(selected) do
        results[#results + 1] = result(suite, name, "skip", message, 0)
      end
    elseif status == "fail" then
      runTests = false
      results[#results + 1] = result(suite, "<beforeAll>", "fail", "beforeAll failed: " .. tostring(message), elapsed)
    end
  end

  if runTests then
    for _, name in ipairs(selected) do
      local started = now()
      local status, message = protected(suite.fns[name], context)
      local elapsed = now() - started
      tests = tests + elapsed
      results[#results + 1] = result(suite, name, status, message, elapsed)
    end
  end

  if suite.afterAll ~= nil then
    local started = now()
    -- A skip in cleanup is meaningless, so anything but a pass is a failure.
    local status, message = protected(suite.afterAll, context)
    local elapsed = now() - started
    afterAll = elapsed
    if status ~= "pass" then
      results[#results + 1] = result(suite, "<afterAll>", "fail", "afterAll failed: " .. tostring(message), elapsed)
    end
  end

  local total = beforeAll + tests + afterAll
  return results, { beforeAll = beforeAll, tests = tests, afterAll = afterAll, total = total }
end

return Execution
