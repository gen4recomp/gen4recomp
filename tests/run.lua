-- Aggregate entry point of the test suite, invoked via `love app/ --test`
-- (`scripts/test.sh`). It owns only the approved discovery roots and their
-- default layers plus the wiring of argument parsing, capability detection,
-- execution, and reporting; those live in `tests/runner/`. There is no module
-- registry: a suite runs because the file exists.

local Capabilities = require("tests.runner.Capabilities")
local Cli = require("tests.runner.Cli")
local Progress = require("tests.runner.Progress")
local Parallel = require("tests.runner.Parallel")
local RepoFiles = require("tests.runner.RepoFiles")
local Report = require("tests.runner.Report")
local TestRunner = require("tests.runner.TestRunner")

-- The process environment, read lazily. Passed explicitly into the pure command
-- modules so their behavior never depends on an ambient lookup.
local ENV = setmetatable({}, {
  __index = function(_, name)
    return os.getenv(name)
  end,
})

-- `options` accepts `layer`, `filter`, `tag`, `slow`, and `capabilities`;
-- `main` parses them out of the argv.
---@param options table|nil
---@return table
local function runnerOptions(options)
  options = options or {}
  return {
    fs = RepoFiles.new(love.filesystem.getSourceBaseDirectory()),
    capabilities = options.capabilities,
    layer = options.layer,
    filter = options.filter,
    tag = options.tag,
    slow = options.slow,
    onResult = options.onResult,
    shard = options.shard,
  }
end

-- Discovery without execution, for `--list`.
---@param options table|nil
---@return table[] listing
local function list(options)
  return TestRunner.list(runnerOptions(options))
end

-- The de-duplicated union of capability declarations from listed suites that
-- have at least one selected test. Load-error rows carry no tests, so they
-- contribute nothing.
---@param listing table[]
---@return table<string, boolean>
local function unionSelectedCapabilities(listing)
  local caps = {}
  for _, suite in ipairs(listing) do
    if #suite.tests > 0 then
      for _, name in ipairs(suite.capabilities) do
        caps[name] = true
      end
    end
  end
  return caps
end

-- The whole command: parse, detect capabilities, run or list, report, and
-- return the process exit status.
---@param argv string[]
---@return integer exitCode
local function main(argv)
  local ok, context = pcall(Parallel.context, ENV)
  if not ok then
    io.stderr:write("test: parallel infrastructure failure: " .. tostring(context) .. "\n")
    return 1
  end
  local plan, message = Cli.parse(argv, { env = ENV })
  if plan == nil then
    io.stderr:write("test: " .. tostring(message) .. "\n")
    return Cli.EXIT_USAGE
  end

  if plan.planMode then
    -- Machine-readable orchestration response for the shell entrypoint; a
    -- parse failure above already answered with the usage status. Planning
    -- discovers the same selected suites execution would run so cache
    -- preparation follows the selection, not the layer.
    if context.kind ~= "normal" then
      io.stderr:write("test: parallel infrastructure failure: plan mode cannot use a worker context\n")
      return 1
    end
    local listing = list(plan)
    local processorCount = 1
    if love.system ~= nil and love.system.getProcessorCount ~= nil then
      processorCount = math.max(1, love.system.getProcessorCount())
    end
    local jobs = Parallel.effectiveJobs(plan, #listing, processorCount)
    print(table.concat(Cli.renderPlan(plan, unionSelectedCapabilities(listing), jobs), "\n"))
    return 0
  end

  local function detect()
    local capabilities, versions = Capabilities.detect({ env = ENV })
    if plan.romSource ~= nil then
      capabilities.rom_source = true
    end
    return capabilities, versions
  end

  if context.kind == "worker" then
    local workerOk, workerError = pcall(function()
      local capabilities, versions = detect()
      local result = TestRunner.run(runnerOptions({
        capabilities = capabilities,
        layer = plan.layer,
        filter = plan.filter,
        tag = plan.tag,
        slow = plan.slow,
        shard = { index = context.index, count = context.count },
      }))
      result.versions = versions
      Parallel.writeFragment(context.runDir, context.index, context.count, result)
    end)
    if not workerOk then
      io.stderr:write("test: parallel worker failure: " .. tostring(workerError) .. "\n")
      return 1
    end
    return 0
  end

  if context.kind == "aggregate" then
    local aggregateOk, aggregateError = pcall(function()
      local capabilities, versions = detect()
      local result = Parallel.merge(Parallel.readFragments(context.runDir, context.count))
      result.capabilities = capabilities
      result.versions = versions
      print(table.concat(Report.lines(result), "\n"))
      io.stdout:flush()
      local outcome = Cli.outcome(plan, capabilities, result)
      if outcome.warning ~= nil then
        io.stderr:write(outcome.warning .. "\n")
      end
      if outcome.failure ~= nil then
        io.stderr:write("test: " .. outcome.failure .. "\n")
      end
      return outcome.exitCode
    end)
    if not aggregateOk then
      io.stderr:write("test: parallel infrastructure failure: " .. tostring(aggregateError) .. "\n")
      return 1
    end
    return aggregateError
  end

  local capabilities, versions = detect()

  if plan.list then
    print(table.concat(Report.listingLines(list(plan)), "\n"))
    return 0
  end

  local progress = Progress.new(function(text)
    io.write(text)
    io.stdout:flush()
  end)
  local result = TestRunner.run(runnerOptions({
    capabilities = capabilities,
    layer = plan.layer,
    filter = plan.filter,
    tag = plan.tag,
    slow = plan.slow,
    onResult = function(entry)
      progress:record(entry)
    end,
  }))
  progress:finish()
  result.versions = versions
  print(table.concat(Report.lines(result), "\n"))

  -- Flush first so the warning banner cannot land inside the buffered report.
  io.stdout:flush()

  local outcome = Cli.outcome(plan, capabilities, result)
  if outcome.warning ~= nil then
    io.stderr:write(outcome.warning .. "\n")
  end
  if outcome.failure ~= nil then
    io.stderr:write("test: " .. outcome.failure .. "\n")
  end
  return outcome.exitCode
end

return { main = main, list = list }
