-- Aggregate entry point of the test suite, invoked via `love app/ --test`
-- (`scripts/test.sh`). It owns only the approved discovery roots and their
-- default layers plus the wiring of argument parsing, capability detection,
-- execution, and reporting; those live in `tests/runner/`. There is no module
-- registry: a suite runs because the file exists.

local Capabilities = require("tests.runner.Capabilities")
local Cli = require("tests.runner.Cli")
local Progress = require("tests.runner.Progress")
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
    print(table.concat(Cli.renderPlan(plan, unionSelectedCapabilities(list(plan))), "\n"))
    return 0
  end

  local capabilities, versions = Capabilities.detect({ env = ENV })
  if plan.romSource ~= nil then
    -- The shell entrypoint imported and built that source into an isolated save
    -- root before this run; parsing already proved the path readable.
    capabilities.rom_source = true
  end

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
