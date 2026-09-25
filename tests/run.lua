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
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")

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
-- data-only Lua table the common builder wrote after its scoped preparation
-- succeeded; it is read back in an empty environment and strictly validated,
-- never executed as code with ambient privileges. Every predecessor schema
-- is rejected rather than adapted.
local PREPARATION_SCHEMA = "g4-test-preparation-v2"
local PREPARATION_ENV = "PORTEMON_TEST_PREPARATION"

local PREPARATION_FIELDS = {
  schema = true,
  saveDirectory = true,
  versionId = true,
  romSha1 = true,
  generationId = true,
  requested = true,
  requestedReady = true,
  complete = true,
}

---@param value unknown
---@return boolean
local function isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

---@param record table
---@return string|nil failure
local function checkPreparationShape(record)
  if record.schema ~= PREPARATION_SCHEMA then
    return "preparation record schema mismatch"
  end
  for key in pairs(record) do
    if PREPARATION_FIELDS[key] ~= true then
      return "preparation record carries an unknown field '" .. tostring(key) .. "'"
    end
  end
  for _, key in ipairs({
    "saveDirectory",
    "versionId",
    "romSha1",
    "generationId",
    "requested",
    "requestedReady",
    "complete",
  }) do
    if record[key] == nil then
      return "preparation record carries no " .. key
    end
  end
  if not isNonEmptyString(record.saveDirectory) then
    return "preparation record carries no private save directory"
  end
  if not isNonEmptyString(record.versionId) then
    return "preparation record names no version"
  end
  if type(record.romSha1) ~= "string" or #record.romSha1 ~= 40 or record.romSha1:find("[^0-9a-f]") ~= nil then
    return "preparation record names no ROM identity"
  end
  if not isNonEmptyString(record.generationId) then
    return "preparation record carries no generation"
  end
  if type(record.requested) ~= "table" then
    return "preparation record names no prepared closure"
  end
  local count = 0
  for key in pairs(record.requested) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return "preparation record names no prepared closure"
    end
    count = count + 1
  end
  local previous = nil
  for index = 1, count do
    local requirement = record.requested[index]
    if not isNonEmptyString(requirement) then
      return "preparation record names no prepared closure"
    end
    if previous ~= nil and requirement <= previous then
      return "preparation record closure is not a sorted unique list"
    end
    previous = requirement
  end
  if type(record.requestedReady) ~= "boolean" then
    return "preparation record names no prepared closure"
  end
  if type(record.complete) ~= "boolean" then
    return "preparation record names no exhaustive result"
  end
  return nil
end

---@param path string
---@return table|nil, string|nil
local function readPreparationRecord(path)
  local handle, openError = io.open(path, "r")
  if handle == nil then
    return nil, "cannot read preparation record: " .. tostring(openError)
  end
  local source = handle:read("*a")
  handle:close()
  if type(source) ~= "string" then
    return nil, "cannot read preparation record: " .. path
  end
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
  local shapeError = checkPreparationShape(record)
  if shapeError ~= nil then
    return nil, shapeError
  end
  return record, nil
end

-- The deduplicated union of derived-cache requirements declared by the
-- suites this process will execute. A narrower shard consumes the
-- invocation union but can never widen it: every selected requirement must
-- appear in the verified receipt.
---@param plan table
---@param shard table|nil
---@return string[]|nil, string|nil
local function selectedRequirements(plan, shard)
  local ok, listing = pcall(list, {
    layer = plan.layer,
    filter = plan.filter,
    tag = plan.tag,
    slow = plan.slow,
    shard = shard,
  })
  if not ok then
    return nil, "cannot list the selected suites: " .. tostring(listing)
  end
  return TestRunner.selectedRequirements(listing), nil
end

-- Whether the verified receipt covers every requirement the selection
-- promises. A receipt for a narrower closure never authorizes a wider run.
---@param record table
---@param required string[]
---@return string|nil failure
local function checkRequestedScope(record, required)
  local satisfied = {}
  for _, requirement in ipairs(record.requested) do
    satisfied[requirement] = true
  end
  for _, requirement in ipairs(required) do
    if satisfied[requirement] ~= true then
      return "the preparation record does not cover the selected requirement '" .. requirement .. "'"
    end
  end
  if record.requestedReady ~= true then
    return "the preparation left its requested closure unready"
  end
  return nil
end

-- The expected development identity for the recorded version, derived
-- independently from the current checkout and the published dump: the
-- working-tree digest through the producer owner plus the strict selection
-- identity. Nothing is copied from the alleged proof except the version it
-- claims, which the ready dump must then confirm.
---@param versionId string
---@return table|nil, string|nil
local function expectedDevelopmentIdentity(versionId)
  if GameVersion.VERSIONS[versionId] == nil then
    return nil, "unsupported version '" .. tostring(versionId) .. "'"
  end
  if not RomImporter.isReady(versionId) then
    return nil, "no ready dump for '" .. tostring(versionId) .. "'"
  end
  local RomFs = require("romdump.src.source.RomFs")
  local opened, openErr = RomFs.open(versionId)
  if opened == nil then
    return nil, "cannot open the dump of '" .. tostring(versionId) .. "': " .. tostring(openErr)
  end
  local sha1 = opened:metadata().sha1
  opened:close()
  local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local sourceBase = love.filesystem.getSourceBaseDirectory()
  local digestOk, producerId = pcall(function()
    return ProducerFingerprint.compute(ProducerFingerprint.checkoutBackend(sourceBase))
  end)
  if not digestOk then
    return nil, "cannot digest the working tree: " .. tostring(producerId)
  end
  local identityOk, identity = pcall(DerivedCacheState.currentForSelection, {
    versionId = versionId,
    romSha1 = sha1,
    producerId = producerId,
    developmentRepositoryRoot = sourceBase,
  })
  if not identityOk then
    return nil, "cannot identify the current development generation: " .. tostring(identity)
  end
  return identity, nil
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

-- The capability context for one executing process: the private source the
-- shell prepared and the exact closure it proved, validated against the
-- current checkout, the published dump, the actual save directory, and the
-- selected requirement union before any suite setup. A corrupt or stale
-- record is an explicit failure, never a silent downgrade into skips.
---@param plan table
---@param shard table|nil
---@return table, string|nil
local function preparationContext(plan, shard)
  local context = {}
  local path = ENV[PREPARATION_ENV]
  if type(path) ~= "string" or path == "" then
    return context, nil
  end
  local record, reason = readPreparationRecord(path)
  if record == nil then
    return context, tostring(reason) .. ": " .. path
  end
  local homeError = checkDataHome(record.saveDirectory)
  if homeError ~= nil then
    return context, homeError .. ": " .. path
  end
  local required, listError = selectedRequirements(plan, shard)
  if required == nil then
    return context, tostring(listError)
  end
  local scopeError = checkRequestedScope(record, required)
  if scopeError ~= nil then
    return context, scopeError .. ": " .. path
  end
  local identity, identityError = expectedDevelopmentIdentity(record.versionId)
  if identity == nil then
    return context, tostring(identityError) .. ": " .. path
  end
  if record.romSha1 ~= identity.romSha1 then
    return context, "the preparation record names another ROM source: " .. path
  end
  if record.generationId ~= identity.generationId then
    return context, "the preparation record names a stale generation: " .. path
  end
  context.dataHome = record.saveDirectory
  context.source = {
    versionId = record.versionId,
    romSha1 = identity.romSha1,
    generationId = identity.generationId,
  }
  context.preparation = {
    versionId = record.versionId,
    romSha1 = record.romSha1,
    generationId = record.generationId,
    requested = record.requested,
    requestedReady = record.requestedReady,
    complete = record.complete,
  }
  return context, nil
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

  local shard = nil
  if context.kind == "worker" then
    shard = { index = context.index, count = context.count }
  end
  local preparation, preparationError = preparationContext(plan, shard)
  local function detect()
    local capabilities, versions = Capabilities.detect({
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
