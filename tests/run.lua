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

-- The invocation preparation receipt the shell entrypoint verified for this
-- run, or nil when no private preparation backs the run. The file is a
-- data-only Lua table the shell wrote inside the private test root; it is
-- read back in an empty environment and schema-checked, never executed as
-- code with ambient privileges.
local PREPARATION_SCHEMA = "g4-test-preparation-v1"
local PREPARATION_ENV = "G4RECOMP_TEST_PREPARATION"

---@param path string
---@return table|nil, string|nil
local function readPreparationRecord(path)
  local handle, openError = io.open(path, "r")
  if handle == nil then
    return nil, "cannot read preparation record: " .. tostring(openError)
  end
  local source = handle:read("*a")
  handle:close()
  local chunk, loadError
  if loadstring ~= nil then
    chunk, loadError = loadstring(source, "@" .. path)
    if chunk ~= nil then
      setfenv(chunk, {})
    end
  else
    chunk, loadError = load(source, "@" .. path, "t", {})
  end
  if chunk == nil then
    return nil, "cannot parse preparation record: " .. tostring(loadError)
  end
  local ok, record = pcall(chunk)
  if not ok or type(record) ~= "table" then
    return nil, "preparation record is not a data table"
  end
  if record.schema ~= PREPARATION_SCHEMA then
    return nil, "preparation record schema mismatch"
  end
  if type(record.data_home) ~= "string" or record.data_home == "" then
    return nil, "preparation record carries no private data home"
  end
  for _, section in ipairs({ "source", "preparation" }) do
    local entry = record[section]
    if type(entry) ~= "table" then
      return nil, "preparation record carries no " .. section
    end
    if type(entry.version_id) ~= "string" or type(entry.rom_sha1) ~= "string" then
      return nil, "preparation record " .. section .. " names no source identity"
    end
  end
  local preparation = record.preparation
  if type(preparation.requested) ~= "table" or type(preparation.requested_ready) ~= "boolean" then
    return nil, "preparation record names no prepared closure"
  end
  return record, nil
end

-- The capability context for one executing process: the private source the
-- shell selected and the exact closure it prepared, validated against the
-- record the shell verified for this invocation. A corrupt record is an
-- explicit failure, never a silent downgrade into skips.
---@return table, string|nil
local function preparationContext()
  local context = {}
  local path = ENV[PREPARATION_ENV]
  if type(path) ~= "string" or path == "" then
    return context, nil
  end
  local record, reason = readPreparationRecord(path)
  if record == nil then
    return context, tostring(reason) .. ": " .. path
  end
  context.dataHome = record.data_home
  context.source = {
    versionId = record.source.version_id,
    romSha1 = record.source.rom_sha1,
    generationId = record.source.generation_id,
  }
  local requested = {}
  for _, requirement in ipairs(record.preparation.requested) do
    if type(requirement) == "string" then
      requested[#requested + 1] = requirement
    end
  end
  context.preparation = {
    versionId = record.preparation.version_id,
    romSha1 = record.preparation.rom_sha1,
    generationId = record.preparation.generation_id,
    requested = requested,
    requestedReady = record.preparation.requested_ready,
    complete = record.preparation.complete == true,
  }
  return context, nil
end

-- Fails before any test setup or mutable fixture when the process save
-- directory escaped the private data home the invocation record carries
-- (an inherited wrapper or environment file redirected it elsewhere).
---@param dataHome string|nil
---@return string|nil failure
local function checkDataHome(dataHome)
  if dataHome == nil then
    return nil
  end
  local saveDirectory = love.filesystem.getSaveDirectory()
  if saveDirectory == dataHome or saveDirectory:sub(1, #dataHome + 1) == dataHome .. "/" then
    return nil
  end
  return "the save directory " .. tostring(saveDirectory) .. " escaped the private test root " .. tostring(dataHome)
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
    local planOk, lines =
      pcall(Cli.renderPlan, plan, unionSelectedCapabilities(listing), jobs, TestRunner.selectedRequirements(listing))
    if not planOk then
      io.stderr:write("test: " .. tostring(lines) .. "\n")
      return Cli.EXIT_USAGE
    end
    print(table.concat(lines, "\n"))
    return 0
  end

  local preparation, preparationError = preparationContext()
  local function detect()
    local capabilities, versions = Capabilities.detect({
      env = ENV,
      source = preparation.source,
      preparation = preparation.preparation,
    })
    if plan.romSource ~= nil then
      capabilities.rom_source = true
    end
    return capabilities, versions
  end

  if context.kind == "worker" then
    local workerOk, workerError = pcall(function()
      if preparationError ~= nil then
        error("test: " .. preparationError, 0)
      end
      local homeError = checkDataHome(preparation.dataHome)
      if homeError ~= nil then
        error("test: " .. homeError, 0)
      end
      local capabilities = detect()
      local result = TestRunner.run(runnerOptions({
        capabilities = capabilities,
        layer = plan.layer,
        filter = plan.filter,
        tag = plan.tag,
        slow = plan.slow,
        shard = { index = context.index, count = context.count },
      }))
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

  if preparationError ~= nil then
    io.stderr:write("test: " .. preparationError .. "\n")
    return 1
  end
  local homeError = checkDataHome(preparation.dataHome)
  if homeError ~= nil then
    io.stderr:write("test: " .. homeError .. "\n")
    return 1
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
