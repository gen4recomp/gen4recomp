-- Runner command-selection and process-exit contracts: the build-cache
-- outcome when no ready dump is available, the options parameter of
-- _runBuild, the import-completion status handling, and the completion-path
-- audit/build/boot/dispose lifecycle ordering. Cache construction itself
-- belongs to CacheBuilder and its writer tests.

local Assert = require("tests.support.Assert")
local Cli = require("romdump.src.cli.Cli")
local RomImporter = require("romdump.src.source.RomImporter")
local Runner = require("romdump.src.cli.Runner")

local T = {}
local realPrint
local capturedOutput

local function captureOutput()
  realPrint = print
  capturedOutput = {}
  _G.print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
      parts[index] = tostring(select(index, ...))
    end
    capturedOutput[#capturedOutput + 1] = table.concat(parts, "\t")
  end
end

local function restoreOutput()
  _G.print = realPrint
  realPrint = nil
  capturedOutput = nil
end

function T.build_cache_without_a_ready_dump_exits_with_usage_failure()
  local realIsReady, realQuit = RomImporter.isReady, love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local exitCode
  RomImporter.isReady = function()
    return false
  end
  love.event.quit = function(code)
    exitCode = code
  end

  local ok, err = xpcall(function()
    Runner.load({ command = "build-cache" })
  end, debug.traceback)
  RomImporter.isReady, love.event.quit = realIsReady, realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 2)
end

-- _runBuild receives its own options table; the allowCompileExclusions
-- decision must come from that parameter, not from the module-global opts the
-- CLI parser wrote, so the import-completion path can control the build
-- outcome per call.
function T.run_build_honors_its_options_parameter_allow_compile_exclusions()
  local realOpts, realImporter = Runner.opts, Runner.importer
  local realBuilder = package.loaded["romdump.src.CacheBuilder"]
  local received, report
  package.loaded["romdump.src.CacheBuilder"] = {
    buildVersions = function(versionIds, options)
      received = { versionIds = versionIds, options = options }
      return { published = true, complete = true, exclusionCount = 0 }
    end,
  }
  Runner.opts = { allowCompileExclusions = true }

  local ok, err = xpcall(function()
    report = Runner._runBuild({ versionIds = { "heartgold" }, allowCompileExclusions = false, noQuit = true })
  end, debug.traceback)
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded["romdump.src.CacheBuilder"] = realBuilder
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(received.versionIds, { "heartgold" })
  Assert.isFalse(received.options.allowCompileExclusions, "the options parameter must win over Runner.opts")
  Assert.deepEqual(
    report,
    { published = true, complete = true, exclusionCount = 0 },
    "_runBuild must pass the builder's report through unchanged"
  )
end

-- The CLI path still delivers --allow-compile-exclusions to the builder when
-- _runBuild is invoked through load; switching _runBuild to its parameter
-- must not silently drop the flag.
function T.cli_build_cache_flag_allow_compile_exclusions_reaches_the_builder()
  local realIsReady, realQuit = RomImporter.isReady, love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local realBuilder = package.loaded["romdump.src.CacheBuilder"]
  local received
  local exitCode
  package.loaded["romdump.src.CacheBuilder"] = {
    buildVersions = function(_, options)
      received = options
      return { published = true, complete = true, exclusionCount = 0 }
    end,
  }
  RomImporter.isReady = function()
    return true
  end
  love.event.quit = function(code)
    exitCode = code
  end

  local ok, err = xpcall(function()
    Runner.load({ command = "build-cache", allowCompileExclusions = true })
  end, debug.traceback)
  RomImporter.isReady, love.event.quit = realIsReady, realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded["romdump.src.CacheBuilder"] = realBuilder
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 0)
  Assert.isTrue(received.allowCompileExclusions, "the CLI flag must reach the builder")
end

-- The import-completion path prints the status report and then uses the same
-- report for the build handoff; the importer's status must be queried exactly
-- once per completion.
function T.completed_import_status_is_queried_once()
  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local statusCalls = 0
  local exitCode
  love.event.quit = function(code)
    exitCode = code
  end
  Runner.importer = {
    state = "complete",
    status = function()
      statusCalls = statusCalls + 1
      return {
        versionId = "heartgold",
        report = { sha1 = "abc", fatEntryCount = 2, totalBytesWritten = 3 },
      }
    end,
  }
  Runner.opts = {}

  local ok, err = xpcall(function()
    Runner._maybeExit()
  end, debug.traceback)
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 0)
  Assert.equal(statusCalls, 1, "status must not be queried twice per completion")
end

-- The import-completion build path keeps the runSource ordering contract: the
-- imported version is audited, the derived cache is built from it with the
-- CLI's compile-exclusion flag, the runtime boots from that cache, and is
-- disposed before the process exits with success.
function T.completed_import_with_build_cache_runs_audit_build_then_boot_and_dispose()
  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local saved = {
    dumpAudit = package.loaded["romdump.src.source.DumpAudit"],
    builder = package.loaded["romdump.src.CacheBuilder"],
    runtime = package.loaded["game.hgss.src.field.FieldRuntime"],
  }
  local calls, exitCode, buildOptions
  package.loaded["romdump.src.source.DumpAudit"] = {
    run = function(versionId)
      calls[#calls + 1] = "audit:" .. versionId
      return { ok = true }
    end,
    lines = function()
      return {}
    end,
  }
  package.loaded["romdump.src.CacheBuilder"] = {
    buildVersions = function(versionIds, options)
      calls[#calls + 1] = "build:" .. table.concat(versionIds, ",")
      buildOptions = { versionIds = versionIds, options = options }
      return { published = true, complete = true, exclusionCount = 0 }
    end,
  }
  package.loaded["game.hgss.src.field.FieldRuntime"] = {
    new = function(game)
      calls[#calls + 1] = "boot:" .. game.versionId
      Assert.equal(game.location.mapSymbol, "MAP_NEW_BARK_PLAYER_HOUSE_2F")
      Assert.equal(game.location.fieldX, 6)
      Assert.equal(game.location.fieldZ, 6)
      Assert.isTrue(game.playerData ~= nil)
      return {
        session = {},
        dispose = function()
          calls[#calls + 1] = "dispose"
        end,
      }
    end,
  }
  love.event.quit = function(code)
    exitCode = code
  end
  Runner.importer = {
    state = "complete",
    status = function()
      return {
        versionId = "heartgold",
        report = { sha1 = "abc", fatEntryCount = 2, totalBytesWritten = 3 },
      }
    end,
  }
  Runner.opts = { command = "build-cache", romPath = "provided.nds", allowCompileExclusions = true }
  calls = {}

  local ok, err = xpcall(function()
    Runner._maybeExit()
  end, debug.traceback)
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded["romdump.src.source.DumpAudit"] = saved.dumpAudit
  package.loaded["romdump.src.CacheBuilder"] = saved.builder
  package.loaded["game.hgss.src.field.FieldRuntime"] = saved.runtime
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 0)
  Assert.deepEqual(calls, { "audit:heartgold", "build:heartgold", "boot:heartgold", "dispose" })
  Assert.deepEqual(buildOptions.versionIds, { "heartgold" })
  Assert.isTrue(buildOptions.options.allowCompileExclusions, "the completion path passes the CLI flag through")
end

-- A failed dump audit on the completion path exits nonzero and never builds
-- or boots: a bad import must not be reported as a completed build-cache.
function T.completed_import_audit_failure_exits_nonzero_without_building()
  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local saved = {
    dumpAudit = package.loaded["romdump.src.source.DumpAudit"],
    builder = package.loaded["romdump.src.CacheBuilder"],
  }
  local calls, exitCode
  package.loaded["romdump.src.source.DumpAudit"] = {
    run = function()
      calls[#calls + 1] = "audit"
      return { version = "heartgold", ok = false, checks = {} }
    end,
    lines = function()
      return {}
    end,
  }
  package.loaded["romdump.src.CacheBuilder"] = {
    buildVersions = function()
      calls[#calls + 1] = "build"
      return { published = true, complete = true, exclusionCount = 0 }
    end,
  }
  love.event.quit = function(code)
    exitCode = code
  end
  Runner.importer = {
    state = "complete",
    status = function()
      return {
        versionId = "heartgold",
        report = { sha1 = "abc", fatEntryCount = 2, totalBytesWritten = 3 },
      }
    end,
  }
  Runner.opts = { command = "build-cache", romPath = "provided.nds" }
  calls = {}

  local ok, err = xpcall(function()
    Runner._maybeExit()
  end, debug.traceback)
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded["romdump.src.source.DumpAudit"] = saved.dumpAudit
  package.loaded["romdump.src.CacheBuilder"] = saved.builder
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 1, "a failed completion-path audit must exit nonzero")
  Assert.deepEqual(calls, { "audit" }, "a failed audit must never build or boot")
end

-- A failed cache build on the completion path exits nonzero and never boots
-- the runtime: the pipeline must not claim success after a failed build.
function T.completed_import_build_failure_exits_nonzero_without_booting()
  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local saved = {
    dumpAudit = package.loaded["romdump.src.source.DumpAudit"],
    builder = package.loaded["romdump.src.CacheBuilder"],
    runtime = package.loaded["game.hgss.src.field.FieldRuntime"],
  }
  local calls, exitCode
  package.loaded["romdump.src.source.DumpAudit"] = {
    run = function(versionId)
      calls[#calls + 1] = "audit:" .. versionId
      return { ok = true }
    end,
    lines = function()
      return {}
    end,
  }
  package.loaded["romdump.src.CacheBuilder"] = {
    buildVersions = function()
      calls[#calls + 1] = "build"
      return nil, "cache preparation failed"
    end,
  }
  package.loaded["game.hgss.src.field.FieldRuntime"] = {
    new = function()
      calls[#calls + 1] = "boot"
      return { dispose = function() end }
    end,
  }
  love.event.quit = function(code)
    exitCode = code
  end
  Runner.importer = {
    state = "complete",
    status = function()
      return {
        versionId = "heartgold",
        report = { sha1 = "abc", fatEntryCount = 2, totalBytesWritten = 3 },
      }
    end,
  }
  Runner.opts = { command = "build-cache", romPath = "provided.nds" }
  calls = {}

  local ok, err = xpcall(function()
    Runner._maybeExit()
  end, debug.traceback)
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded["romdump.src.source.DumpAudit"] = saved.dumpAudit
  package.loaded["romdump.src.CacheBuilder"] = saved.builder
  package.loaded["game.hgss.src.field.FieldRuntime"] = saved.runtime
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 1, "a failed completion-path build must exit nonzero")
  Assert.deepEqual(calls, { "audit:heartgold", "build" }, "a failed build must never boot the runtime")
end

-- A raising runtime constructor is the production failure shape after binary
-- construction: the completion path must convert the raise into a nonzero
-- process exit, never leave it to crash the loop or claim boot success.
function T.completed_import_constructor_raise_exits_nonzero()
  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local saved = {
    dumpAudit = package.loaded["romdump.src.source.DumpAudit"],
    builder = package.loaded["romdump.src.CacheBuilder"],
    runtime = package.loaded["game.hgss.src.field.FieldRuntime"],
  }
  local calls, exitCode
  package.loaded["romdump.src.source.DumpAudit"] = {
    run = function(versionId)
      calls[#calls + 1] = "audit:" .. versionId
      return { ok = true }
    end,
    lines = function()
      return {}
    end,
  }
  package.loaded["romdump.src.CacheBuilder"] = {
    buildVersions = function(versionIds)
      calls[#calls + 1] = "build:" .. table.concat(versionIds, ",")
      return { published = true, complete = true, exclusionCount = 0 }
    end,
  }
  package.loaded["game.hgss.src.field.FieldRuntime"] = {
    new = function(game)
      calls[#calls + 1] = "boot:" .. game.versionId
      error("field actor index missing")
    end,
  }
  love.event.quit = function(code)
    exitCode = code
  end
  Runner.importer = {
    state = "complete",
    status = function()
      return {
        versionId = "heartgold",
        report = { sha1 = "abc", fatEntryCount = 2, totalBytesWritten = 3 },
      }
    end,
  }
  Runner.opts = { command = "build-cache", romPath = "provided.nds" }
  calls = {}

  local ok, err = xpcall(function()
    Runner._maybeExit()
  end, debug.traceback)
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded["romdump.src.source.DumpAudit"] = saved.dumpAudit
  package.loaded["romdump.src.CacheBuilder"] = saved.builder
  package.loaded["game.hgss.src.field.FieldRuntime"] = saved.runtime
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 1, "a raising runtime constructor must exit nonzero")
  Assert.deepEqual(calls, { "audit:heartgold", "build:heartgold", "boot:heartgold" }, "a failed boot is not disposed")
end

-- A failed import exits nonzero on the error state and never touches the
-- audit/build/boot pipeline.
function T.failed_import_exits_nonzero_without_running_the_build_pipeline()
  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local exitCode
  love.event.quit = function(code)
    exitCode = code
  end
  Runner.importer = {
    state = "error",
    status = function()
      return { errorCode = "NDS_UNKNOWN_ROM", error = "boom" }
    end,
  }
  Runner.opts = { command = "build-cache", romPath = "wrong.nds" }

  local ok, err = xpcall(function()
    Runner._maybeExit()
  end, debug.traceback)
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 1)
end

-- A missing command is a usage fault: nothing dispatches and the process
-- exits with the usage status.
function T.no_command_exits_with_usage_failure()
  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local exitCode
  love.event.quit = function(code)
    exitCode = code
  end

  local ok, err = xpcall(function()
    Runner.load({})
  end, debug.traceback)
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 2, "a missing command must usage-quit")
end

-- Through the production seam (main.lua runs Runner.load(Cli.parse(argv))),
-- conflicting commands are rejected before any action dispatches: the
-- rejection may surface as a parse raise or a usage-quit (exit 2), but no
-- command runs.
function T.conflicting_cli_commands_are_rejected_before_dispatch()
  local realIsReady, realQuit = RomImporter.isReady, love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local saved = package.loaded["romdump.src.source.DumpAudit"]
  local dumpAuditCalls = 0
  local exitCode
  package.loaded["romdump.src.source.DumpAudit"] = {
    run = function()
      dumpAuditCalls = dumpAuditCalls + 1
      return { ok = true }
    end,
    lines = function()
      return {}
    end,
  }
  RomImporter.isReady = function()
    return true
  end
  love.event.quit = function(code)
    exitCode = code
  end

  local ok, err = xpcall(function()
    Runner.load(Cli.parse({ "--check-dump", "--import-rom", "/tmp/hg.nds" }))
  end, debug.traceback)
  RomImporter.isReady, love.event.quit = realIsReady, realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded["romdump.src.source.DumpAudit"] = saved

  Assert.equal(dumpAuditCalls, 0, "conflicting commands must never dispatch an action")
  Assert.isTrue(not ok or exitCode == 2, "conflicting commands must raise or usage-quit, never run: " .. tostring(err))
end

-- check-dump audits every ready version exactly once and its exit code
-- reflects every report verdict.
function T.check_dump_audits_every_ready_version_once()
  local realIsReady, realQuit = RomImporter.isReady, love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local saved = package.loaded["romdump.src.source.DumpAudit"]
  local calls, exitCodes = {}, {}
  local verdicts = {
    heartgold = { ok = true },
    soulsilver = { ok = false },
  }
  package.loaded["romdump.src.source.DumpAudit"] = {
    run = function(version)
      calls[#calls + 1] = "audit:" .. version
      return verdicts[version]
    end,
    lines = function()
      return {}
    end,
  }
  RomImporter.isReady = function()
    return true
  end
  love.event.quit = function(code)
    exitCodes[#exitCodes + 1] = code
  end

  local ok1, err1 = xpcall(Runner._runCheckDump, debug.traceback)
  verdicts = { heartgold = { ok = true }, soulsilver = { ok = true } }
  local ok2, err2 = xpcall(Runner._runCheckDump, debug.traceback)
  RomImporter.isReady, love.event.quit = realIsReady, realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded["romdump.src.source.DumpAudit"] = saved
  if not ok1 then
    error(err1, 0)
  end
  if not ok2 then
    error(err2, 0)
  end

  Assert.deepEqual(calls, { "audit:heartgold", "audit:soulsilver", "audit:heartgold", "audit:soulsilver" })
  Assert.deepEqual(exitCodes, { 1, 0 }, "any failing report must fail the exit code")
end

return {
  beforeAll = captureOutput,
  afterAll = restoreOutput,
  tests = T,
}
