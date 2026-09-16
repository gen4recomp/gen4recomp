-- Runner probe and targeted-preparation contracts: the ROM probe reports
-- canonical version identity without importing or building, preparation
-- without a ready dump is a usage fault, rebuilds outside the requested
-- scope are rejected before any work, and genuine failures exit nonzero.
-- Source and builder modules are faked through package.loaded; requirement
-- validation below uses the real execution owner without touching the host.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
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

local function withRunnerHarness(fn)
  local realQuit = love.event.quit
  local realOpts, realImporter = Runner.opts, Runner.importer
  local realIsReady = RomImporter.isReady
  local saved = {
    RomSource = package.loaded["romdump.src.source.RomSource"],
    NdsRom = package.loaded["romdump.src.source.NdsRom"],
    RomFs = package.loaded["romdump.src.source.RomFs"],
    CacheBuilder = package.loaded["romdump.src.CacheBuilder"],
    ProducerFingerprint = package.loaded["romdump.src.ProducerFingerprint"],
  }
  local exitCode
  love.event.quit = function(code)
    exitCode = code
  end
  local function quitCode()
    return exitCode
  end
  local ok, result = pcall(fn, quitCode)
  love.event.quit = realQuit
  Runner.opts, Runner.importer = realOpts, realImporter
  RomImporter.isReady = realIsReady
  package.loaded["romdump.src.source.RomSource"] = saved.RomSource
  package.loaded["romdump.src.source.NdsRom"] = saved.NdsRom
  package.loaded["romdump.src.source.RomFs"] = saved.RomFs
  package.loaded["romdump.src.CacheBuilder"] = saved.CacheBuilder
  package.loaded["romdump.src.ProducerFingerprint"] = saved.ProducerFingerprint
  if not ok then
    error(result, 0)
  end
  return result
end

local function fakeSource(released)
  return {
    sha1 = function()
      return string.rep("a", 40)
    end,
    release = function()
      released.released = true
    end,
  }
end

function T.probe_reports_version_identity_and_releases_the_source()
  local released = {}
  withRunnerHarness(function(quitCode)
    package.loaded["romdump.src.source.RomSource"] = {
      fromPath = function(path)
        Assert.equal(path, "/tmp/hg.nds")
        return fakeSource(released)
      end,
    }
    package.loaded["romdump.src.source.NdsRom"] = {
      open = function()
        return {
          versionInfo = function()
            return { id = "heartgold" }
          end,
          release = function()
            released.released = true
          end,
        }
      end,
    }
    capturedOutput = {}
    Runner.load({ command = "probe-rom", romPath = "/tmp/hg.nds" })
    Assert.equal(quitCode(), 0)
    Assert.deepEqual(capturedOutput, { "version=heartgold", "rom_sha1=" .. string.rep("a", 40) })
    Assert.isTrue(released.released, "the probe releases the source on every path")
    Assert.isNil(Runner.importer, "the probe never starts an import")
  end)
end

function T.probe_with_unsupported_rom_fails_without_importing()
  local released = {}
  withRunnerHarness(function(quitCode)
    package.loaded["romdump.src.source.RomSource"] = {
      fromPath = function()
        return fakeSource(released)
      end,
    }
    package.loaded["romdump.src.source.NdsRom"] = {
      open = function()
        return nil, Errors.new("NDS_UNKNOWN_ROM", "no supported version matches", {})
      end,
    }
    capturedOutput = {}
    Runner.load({ command = "probe-rom", romPath = "/tmp/unknown.nds" })
    Assert.equal(quitCode(), 1, "an unsupported ROM is a validation failure, not a usage fault")
    Assert.isTrue(released.released, "a rejected probe still releases the source")
    Assert.isNil(Runner.importer, "a rejected probe never starts an import")
  end)
end

function T.prepare_without_a_ready_dump_is_a_usage_fault()
  withRunnerHarness(function(quitCode)
    RomImporter.isReady = function()
      return false
    end
    local built = false
    package.loaded["romdump.src.CacheBuilder"] = {
      prepareVersion = function()
        built = true
      end,
    }
    Runner.load({ command = "prepare-cache", version = "heartgold", requirements = { "map:7" }, rebuild = {} })
    Assert.equal(quitCode(), 2, "no ready source where required is a usage fault")
    Assert.isFalse(built, "a usage fault starts no preparation")
  end)
end

function T.prepare_delegates_scope_and_reports_requested_readiness()
  withRunnerHarness(function(quitCode)
    RomImporter.isReady = function(version)
      Assert.equal(version, "heartgold")
      return true
    end
    local closed = false
    package.loaded["romdump.src.source.RomFs"] = {
      open = function(version)
        Assert.equal(version, "heartgold")
        return {
          metadata = function()
            return { sha1 = string.rep("b", 40) }
          end,
          close = function()
            closed = true
          end,
        }
      end,
    }
    package.loaded["romdump.src.ProducerFingerprint"] = {
      checkoutBackend = function()
        return {}
      end,
      appBackend = function()
        return {}
      end,
      compute = function()
        return "d" .. string.rep("1", 64)
      end,
    }
    local received
    package.loaded["romdump.src.CacheBuilder"] = {
      prepareVersion = function(version, options)
        received = { version = version, options = options }
        return {
          complete = false,
          requestedReady = true,
          exclusions = {},
          failures = {},
          counts = { planned = 1, successful = 1, failed = 0, cancelled = 0, excluded = 0 },
        }
      end,
    }
    capturedOutput = {}
    Runner.load({
      command = "prepare-cache",
      version = "heartgold",
      requirements = { "map:7" },
      rebuild = {},
      dev = true,
    })
    Assert.equal(quitCode(), 0, "a prepared targeted scope succeeds without attesting completeness")
    Assert.isTrue(closed, "the identity probe closes its source handle")
    Assert.equal(received.version, "heartgold")
    Assert.deepEqual(received.options.requirements, { "map:7" })
    Assert.isTrue(received.options.dev, "the development flag reaches preparation")
    Assert.isTrue(capturedOutput[1]:find("complete=false", 1, true) ~= nil, capturedOutput[1])
  end)
end

function T.prepare_rejects_rebuild_outside_the_requested_scope()
  withRunnerHarness(function(quitCode)
    RomImporter.isReady = function()
      return true
    end
    local built = false
    package.loaded["romdump.src.CacheBuilder"] = {
      prepareVersion = function()
        built = true
      end,
    }
    Runner.load({
      command = "prepare-cache",
      version = "heartgold",
      requirements = { "map:7" },
      rebuild = { "map:9" },
      dev = true,
    })
    Assert.equal(quitCode(), 2, "a rebuild outside the requested scope is a usage fault")
    Assert.isFalse(built, "a usage fault starts no preparation")
  end)
end

function T.prepare_failure_exits_nonzero()
  withRunnerHarness(function(quitCode)
    RomImporter.isReady = function()
      return true
    end
    package.loaded["romdump.src.source.RomFs"] = {
      open = function()
        return {
          metadata = function()
            return { sha1 = string.rep("b", 40) }
          end,
          close = function() end,
        }
      end,
    }
    package.loaded["romdump.src.ProducerFingerprint"] = {
      checkoutBackend = function()
        return {}
      end,
      appBackend = function()
        return {}
      end,
      compute = function()
        return "d" .. string.rep("1", 64)
      end,
    }
    package.loaded["romdump.src.CacheBuilder"] = {
      prepareVersion = function()
        return nil, Errors.new("CACHE_PREPARATION_FAILED", "cache preparation failed", {})
      end,
    }
    Runner.load({
      command = "prepare-cache",
      version = "heartgold",
      requirements = { "map:7" },
      rebuild = {},
      dev = true,
    })
    Assert.equal(quitCode(), 1, "a genuine preparation failure exits nonzero")
  end)
end

-- The execution owner rejects an unwritable observation path before any
-- cache mutation, using the real modules without touching the host.
function T.profile_to_an_unwritable_path_fails_before_mutation()
  local saved = package.loaded["romdump.src.CacheBuilder"]
  package.loaded["romdump.src.CacheBuilder"] = nil
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local report, err = CacheBuilder.prepareVersion("heartgold", {
    identity = { versionId = "heartgold", generationId = "test-generation", producerId = "d" .. string.rep("1", 64) },
    requirements = { "map:7" },
    profile = "/nonexistent-dir-xyz/profile.jsonl",
    log = function() end,
  })
  package.loaded["romdump.src.CacheBuilder"] = saved
  Assert.isNil(report)
  Assert.notNil(err)
  Assert.isTrue(Errors.is(err), "observation failures are structured")
end

-- Explicit rebuilds require development mode, enforced before any session.
function T.rebuild_without_development_mode_fails()
  local saved = package.loaded["romdump.src.CacheBuilder"]
  package.loaded["romdump.src.CacheBuilder"] = nil
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local report, err = CacheBuilder.prepareVersion("heartgold", {
    identity = { versionId = "heartgold", generationId = "test-generation", producerId = "d" .. string.rep("1", 64) },
    requirements = { "map:7" },
    rebuild = { "map:7" },
    log = function() end,
  })
  package.loaded["romdump.src.CacheBuilder"] = saved
  Assert.isNil(report)
  Assert.notNil(err)
end

-- The execution owner's request grammar accepts closed scopes and canonical
-- jobs and rejects everything else before any cache state is touched.
function T.request_grammar_matches_the_command_boundary()
  local saved = package.loaded["romdump.src.CacheBuilder"]
  package.loaded["romdump.src.CacheBuilder"] = nil
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local bootstrap = assert(CacheBuilder.parseRequirement("bootstrap"))
  Assert.equal(bootstrap.scope, "bootstrap")
  local fieldCore = assert(CacheBuilder.parseRequirement("field-core"))
  Assert.equal(fieldCore.scope, "field-core")
  local complete = assert(CacheBuilder.parseRequirement("complete"))
  Assert.equal(complete.scope, "complete")
  local job = assert(CacheBuilder.parseRequirement("map:7"))
  Assert.equal(job.jobKey, "map:7")
  local cell = assert(CacheBuilder.parseRequirement("field-cell:3-11"))
  Assert.equal(cell.jobKey, "field-cell:3-11")
  for _, text in ipairs({ "fused:7", "maps/7/complete", "plan.lua", "map: 7", "map:7 ", "map:-7", "map:", ":7", "" }) do
    local parsed, _ = CacheBuilder.parseRequirement(text)
    Assert.isNil(parsed, "malformed requirement must fail: " .. text)
  end
  package.loaded["romdump.src.CacheBuilder"] = saved
end

-- A read-only cache check must reject a foreign generation instead of
-- passing on intact markers: with all completion markers present but a
-- foreign receipt generation and no current planning data, the check exits
-- nonzero with its failure named and mutates nothing.
function T.check_rejects_a_foreign_generation_without_mutation()
  withRunnerHarness(function(quitCode)
    local CacheFs = require("libs.storage.src.CacheFs")
    local FakeCache = require("tests.support.FakeCache")
    local ArtifactState = require("romdump.src.build.ArtifactState")
    local AudioCache = require("libs.assets.src.audio.AudioCache")
    local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
    local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
    local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
    local MapAssetCache = require("libs.assets.src.MapAssetCache")
    local ScriptCache = require("libs.assets.src.ScriptCache")
    local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
    local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
    local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
    local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
    local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
    local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
    local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")
    local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
    local MonCache = require("libs.assets.src.MonCache")
    local ItemCache = require("libs.assets.src.ItemCache")
    local BagCache = require("libs.assets.src.BagCache")
    local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
    local realCacheFs = package.loaded["libs.storage.src.CacheFs"]
    local backend = FakeCache.new()
    local checkCacheFs = {
      forVersion = function(versionId)
        return CacheFs.forVersion(versionId, backend)
      end,
    }
    package.loaded["libs.storage.src.CacheFs"] = checkCacheFs
    local code, output
    local ok, err = pcall(function()
      RomImporter.isReady = function(versionId)
        return versionId == "heartgold"
      end
      -- The read-only check resolves the expected generation from the
      -- published dump exactly like preparation does; the foreign receipt
      -- below must disagree with whatever generation that resolves to.
      package.loaded["romdump.src.source.RomFs"] = {
        open = function(versionId)
          Assert.equal(versionId, "heartgold")
          return {
            metadata = function()
              return { sha1 = string.rep("a", 40) }
            end,
            close = function() end,
          }
        end,
      }
      local cache = CacheFs.forVersion("heartgold", backend)
      for _, path in ipairs({
        FieldActorCache.markerPath(),
        FieldCameraCache.markerPath(),
        FieldFontCache.markerPath(),
        FieldMessageCache.markerPath(),
        FieldUiAssetCache.markerPath(),
        IntroAssetCache.markerPath(),
        StarterChoiceAssetCache.markerPath(),
        FieldWeatherCache.markerPath(),
        FieldEffectAssetCache.markerPath(),
        FieldEmoteAssetCache.markerPath(),
        NewGameInitCache.markerPath(),
        FieldCellCache.indexMarkerPath(),
        MonCache.markerPath(),
        ItemCache.markerPath(),
        BagCache.markerPath(),
        ScriptCache.markerPath(),
        AudioCache.markerPath(),
      }) do
        cache:write(path, "complete")
      end
      cache:writeLua(MapAssetCache.worldPath(), { maps = {} })
      cache:writeLua(ArtifactState.path("field-camera", "global"), {
        schema = ArtifactState.RECEIPT_SCHEMA,
        generationId = "foreign-generation",
        kind = "field-camera",
        key = "global",
        marker = "complete",
      })
      local before = {}
      for path, data in pairs(backend.files) do
        before[path] = data
      end
      capturedOutput = {}
      Runner.load({ command = "check-derived-cache" })
      code = quitCode()
      output = table.concat(capturedOutput, "\n")
      local after = {}
      for path, data in pairs(backend.files) do
        after[path] = data
      end
      Assert.deepEqual(after, before, "a read-only check performs no writes")
    end)
    package.loaded["libs.storage.src.CacheFs"] = realCacheFs
    if not ok then
      error(err, 0)
    end
    Assert.isTrue(code ~= 0, "a foreign generation must fail the read-only check")
    Assert.isTrue(output:find("FAIL", 1, true) ~= nil, "the check names its failure, got: " .. tostring(output))
  end)
end

-- A present report without requested readiness still fails the command: the
-- runner maps actual scope satisfaction to its exit status instead of
-- treating any report table as success.
function T.prepare_without_requested_readiness_fails_instead_of_succeeding()
  withRunnerHarness(function(quitCode)
    RomImporter.isReady = function()
      return true
    end
    package.loaded["romdump.src.source.RomFs"] = {
      open = function()
        return {
          metadata = function()
            return { sha1 = string.rep("b", 40) }
          end,
          close = function() end,
        }
      end,
    }
    package.loaded["romdump.src.ProducerFingerprint"] = {
      checkoutBackend = function()
        return {}
      end,
      appBackend = function()
        return {}
      end,
      compute = function()
        return "d" .. string.rep("1", 64)
      end,
    }
    package.loaded["romdump.src.CacheBuilder"] = {
      prepareVersion = function()
        return {
          complete = false,
          requestedReady = false,
          exclusions = {},
          failures = { "map:99999: unknown canonical target" },
          counts = { planned = 1, successful = 0, failed = 1, cancelled = 0, excluded = 0 },
        }
      end,
    }
    Runner.load({
      command = "prepare-cache",
      version = "heartgold",
      requirements = { "map:99999" },
      rebuild = {},
      dev = true,
    })
    Assert.equal(quitCode(), 1, "an unreadied scope fails even when a report table exists")
  end)
end

-- The invocation receipt request reaches preparation with the actual save
-- identity: the runner forwards the output path instead of writing its own
-- receipt, and a receipt write failure fails the command.
function T.prepare_forwards_the_invocation_receipt_with_the_actual_save_identity()
  withRunnerHarness(function(quitCode)
    RomImporter.isReady = function()
      return true
    end
    package.loaded["romdump.src.source.RomFs"] = {
      open = function()
        return {
          metadata = function()
            return { sha1 = string.rep("b", 40) }
          end,
          close = function() end,
        }
      end,
    }
    package.loaded["romdump.src.ProducerFingerprint"] = {
      checkoutBackend = function()
        return {}
      end,
      appBackend = function()
        return {}
      end,
      compute = function()
        return "d" .. string.rep("1", 64)
      end,
    }
    local received
    package.loaded["romdump.src.CacheBuilder"] = {
      prepareVersion = function(version, options)
        received = { version = version, options = options }
        return {
          complete = false,
          requestedReady = true,
          exclusions = {},
          failures = {},
          counts = { planned = 1, successful = 1, failed = 0, cancelled = 0, excluded = 0 },
        }
      end,
    }
    capturedOutput = {}
    Runner.load({
      command = "prepare-cache",
      version = "heartgold",
      requirements = { "map:7" },
      rebuild = {},
      dev = true,
      preparationRecord = "/tmp/invocation-preparation.lua",
    })
    Assert.equal(quitCode(), 0)
    Assert.equal(received.options.preparationRecord, "/tmp/invocation-preparation.lua")
    Assert.equal(received.options.saveDirectory, love.filesystem.getSaveDirectory())
  end)
end

function T.prepare_receipt_write_failure_fails_the_command()
  withRunnerHarness(function(quitCode)
    RomImporter.isReady = function()
      return true
    end
    package.loaded["romdump.src.source.RomFs"] = {
      open = function()
        return {
          metadata = function()
            return { sha1 = string.rep("b", 40) }
          end,
          close = function() end,
        }
      end,
    }
    package.loaded["romdump.src.ProducerFingerprint"] = {
      checkoutBackend = function()
        return {}
      end,
      appBackend = function()
        return {}
      end,
      compute = function()
        return "d" .. string.rep("1", 64)
      end,
    }
    package.loaded["romdump.src.CacheBuilder"] = {
      prepareVersion = function()
        return nil, Errors.new("PREPARATION_RECORD_FAILED", "the invocation proof cannot be opened", {})
      end,
    }
    Runner.load({
      command = "prepare-cache",
      version = "heartgold",
      requirements = { "map:7" },
      rebuild = {},
      dev = true,
      preparationRecord = "/nonexistent-dir-xyz/preparation.lua",
    })
    Assert.equal(quitCode(), 1, "a receipt write failure fails the command without an independent runner receipt")
  end)
end

return {
  beforeAll = captureOutput,
  afterAll = restoreOutput,
  tests = T,
}
