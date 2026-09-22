-- Discovery dispatch/exit contract: `--discover-app` is lazy-routed to
-- `AppDiscovery.runPath` with exactly the parsed target/source/output,
-- success/failure map to the correct exit codes and printed report, and the
-- command never touches the normal ROM import/cache machinery. AppDiscovery
-- itself is replaced with a focused fake throughout, matching the pattern
-- already used by the build-cache runner tests.

local Assert = require("tests.support.Assert")
local RomImporter = require("romdump.src.source.RomImporter")
local Runner = require("romdump.src.cli.Runner")

local T = {}

local APP_DISCOVERY_MODULE = "romdump.src.appdiscovery.AppDiscovery"
local CACHE_BUILDER_MODULE = "romdump.src.CacheBuilder"

local function captureOutput()
  local realPrint = print
  local lines = {}
  _G.print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
      parts[index] = tostring(select(index, ...))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  return lines, function()
    _G.print = realPrint
  end
end

local function forbiddenModule(label)
  return setmetatable({}, {
    __index = function()
      error(label .. " must not be touched by discovery", 0)
    end,
  })
end

-- Runs `body(state)` with love.event.quit, RomImporter.isReady, and
-- CacheBuilder all replaced, restoring every real value afterwards
-- regardless of how `body` exits.
local function withDiscoveryHarness(body)
  local realQuit = love.event.quit
  local realAppDiscovery = package.loaded[APP_DISCOVERY_MODULE]
  local realIsReady = RomImporter.isReady
  local realBuilder = package.loaded[CACHE_BUILDER_MODULE]
  local realOpts, realImporter = Runner.opts, Runner.importer

  local state = { exitCode = nil }
  love.event.quit = function(code)
    state.exitCode = code
  end
  RomImporter.isReady = function()
    error("discover-app must not touch RomImporter.isReady", 0)
  end
  package.loaded[CACHE_BUILDER_MODULE] = forbiddenModule("CacheBuilder")

  local ok, err = xpcall(function()
    body(state)
  end, debug.traceback)

  love.event.quit = realQuit
  package.loaded[APP_DISCOVERY_MODULE] = realAppDiscovery
  RomImporter.isReady = realIsReady
  package.loaded[CACHE_BUILDER_MODULE] = realBuilder
  Runner.opts, Runner.importer = realOpts, realImporter

  if not ok then
    error(err, 0)
  end
  return state
end

function T.discover_app_dispatches_to_app_discovery_with_exactly_the_parsed_request()
  local received
  local state = withDiscoveryHarness(function()
    package.loaded[APP_DISCOVERY_MODULE] = {
      runPath = function(request)
        received = request
        return {
          outputPath = "/tmp/app-evidence-heartgold-arm9-overlay-15.zip",
          summary = {
            versionId = "heartgold",
            overlayId = 15,
            entrypointCandidateCount = 1,
            functionCount = 5,
            resourceFileCount = 3,
            narcCount = 1,
            narcMemberCount = 4,
            applicationGapCount = 0,
            resourceGapCount = 0,
          },
        }
      end,
    }
    Runner.load({
      command = "discover-app",
      romPath = "/tmp/hg.nds",
      overlayId = 15,
      outputPath = nil,
      resourceDetails = {},
    })
  end)

  Assert.notNil(received, "AppDiscovery.runPath was never called")
  Assert.equal(received.romPath, "/tmp/hg.nds")
  Assert.equal(received.overlayId, 15)
  Assert.isNil(received.outputPath)
  Assert.deepEqual(received.resourceDetails, {})
  Assert.equal(state.exitCode, 0)
end

function T.discover_app_forwards_sorted_resource_details_without_interpretation()
  local received
  withDiscoveryHarness(function()
    package.loaded[APP_DISCOVERY_MODULE] = {
      runPath = function(request)
        received = request
        return {
          outputPath = "/tmp/app-evidence.zip",
          summary = {
            versionId = "heartgold",
            overlayId = 15,
            entrypointCandidateCount = 0,
            functionCount = 0,
            resourceFileCount = 0,
            narcCount = 0,
            narcMemberCount = 0,
            applicationGapCount = 0,
            resourceGapCount = 0,
          },
        }
      end,
    }
    Runner.load({
      command = "discover-app",
      romPath = "/tmp/hg.nds",
      overlayId = 15,
      resourceDetails = {
        { fileId = 12, memberId = 3 },
        { fileId = 144, memberId = 49 },
      },
    })
  end)

  Assert.deepEqual(received.resourceDetails, {
    { fileId = 12, memberId = 3 },
    { fileId = 144, memberId = 49 },
  })
end

function T.discover_app_forwards_an_explicit_output_path()
  local received
  withDiscoveryHarness(function()
    package.loaded[APP_DISCOVERY_MODULE] = {
      runPath = function(request)
        received = request
        return {
          outputPath = "/tmp/bag-evidence.zip",
          summary = {
            versionId = "heartgold",
            overlayId = 15,
            entrypointCandidateCount = 0,
            functionCount = 0,
            resourceFileCount = 0,
            narcCount = 0,
            narcMemberCount = 0,
            applicationGapCount = 0,
            resourceGapCount = 0,
          },
        }
      end,
    }
    Runner.load({
      command = "discover-app",
      romPath = "/tmp/hg.nds",
      overlayId = 15,
      outputPath = "/tmp/bag-evidence.zip",
    })
  end)

  Assert.equal(received.outputPath, "/tmp/bag-evidence.zip")
end

function T.discover_app_prints_the_output_path_on_success()
  local lines, restore = captureOutput()
  local ok, err = pcall(withDiscoveryHarness, function()
    package.loaded[APP_DISCOVERY_MODULE] = {
      runPath = function()
        return {
          outputPath = "/tmp/app-evidence-heartgold-arm9-overlay-15.zip",
          summary = {
            versionId = "heartgold",
            overlayId = 15,
            entrypointCandidateCount = 1,
            functionCount = 5,
            resourceFileCount = 3,
            narcCount = 1,
            narcMemberCount = 4,
            applicationGapCount = 0,
            resourceGapCount = 0,
          },
        }
      end,
    }
    Runner.load({ command = "discover-app", romPath = "/tmp/hg.nds", overlayId = 15 })
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  local joined = table.concat(lines, "\n")
  Assert.isTrue(
    joined:find("/tmp/app-evidence-heartgold-arm9-overlay-15.zip", 1, true) ~= nil,
    "success output must include the output path"
  )
end

function T.discover_app_maps_a_structured_failure_to_exit_one_and_a_locked_message()
  local lines, restore = captureOutput()
  local ok, err = pcall(withDiscoveryHarness, function(state)
    package.loaded[APP_DISCOVERY_MODULE] = {
      runPath = function()
        return nil, { code = "APPDISCOVERY_OUTPUT_WRITE_FAILED", message = "disk full", context = {} }
      end,
    }
    Runner.load({ command = "discover-app", romPath = "/tmp/hg.nds", overlayId = 15 })
    Assert.equal(state.exitCode, 1)
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  local joined = table.concat(lines, "\n")
  Assert.isTrue(joined:find("appdiscovery failed", 1, true) ~= nil, "failure output must use the locked prefix")
  Assert.isTrue(
    joined:find("APPDISCOVERY_OUTPUT_WRITE_FAILED", 1, true) ~= nil,
    "failure output must include the error code"
  )
end

function T.app_discovery_is_lazy_required_and_untouched_by_other_commands()
  local realAppDiscovery = package.loaded[APP_DISCOVERY_MODULE]
  package.loaded[APP_DISCOVERY_MODULE] = nil

  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  love.event.quit = function() end

  local ok, err = xpcall(function()
    Runner.load({ command = "check-dump" })
  end, debug.traceback)

  local stillUnloaded = package.loaded[APP_DISCOVERY_MODULE] == nil
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  package.loaded[APP_DISCOVERY_MODULE] = realAppDiscovery
  if not ok then
    error(err, 0)
  end

  Assert.isTrue(stillUnloaded, "a non-discovery command must never require AppDiscovery")
end

return { tests = T }
