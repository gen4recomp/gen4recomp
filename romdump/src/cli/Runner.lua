-- Headless ROM/asset command runner for the romdump CLI. Each command prints
-- machine-readable output and exits with a status code so agents and scripts
-- can drive imports and verification without a human. Synchronous commands quit
-- inside load(); the ROM import is a coroutine pumped by update() so progress
-- stays responsive. All love coupling lives here; the underlying work is done
-- by the romdump app and the shared libraries under libs/

local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local Errors = require("libs.errors.src.Errors")
local Cli = require("romdump.src.cli.Cli")

local Runner = {}

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then
      out[#out + 1] = id
    end
  end
  return out
end

-- Dispatch the parsed command. Cli.parse rejects conflicting commands, so
-- exactly one action runs per invocation; a missing command is a usage fault.
function Runner.load(opts)
  Runner.opts = opts or {}
  Runner.importer = nil

  local command = Runner.opts.command
  if command == "import" then
    assert(Runner.opts.romPath, "import requires a ROM path")
    return Runner._startImport(Runner.opts.romPath)
  end
  if command == "build-cache" then
    return Runner._runBuildCache()
  end
  if command == "check-dump" then
    return Runner._runCheckDump()
  end
  if command == "check-derived-cache" then
    return Runner._runCheckDerivedCache()
  end
  if command == "discover-app" then
    return Runner._runDiscoverApp()
  end
  if command == "probe-rom" then
    return Runner._runProbeRom()
  end
  if command == "prepare-cache" then
    return Runner._runPrepareCache()
  end
  print(
    "romdump: no command given (expected --import-rom, --check-dump, --check-derived-cache, --build-cache,"
      .. " --discover-app, --probe-rom, or --prepare-cache)"
  )
  love.event.quit(Cli.EXIT_USAGE)
end

-- Direct ROM-only discovery: never touches the import/cache pipeline.
-- AppDiscovery is lazy-required so no other command pays for loading it.
function Runner._runDiscoverApp()
  local opts = Runner.opts
  local AppDiscovery = require("romdump.src.appdiscovery.AppDiscovery")
  local result, err = AppDiscovery.runPath({
    romPath = opts.romPath,
    overlayId = opts.overlayId,
    outputPath = opts.outputPath,
    resourceDetails = opts.resourceDetails,
  })
  if not result then
    print("appdiscovery failed [" .. tostring(err and err.code or "ERROR") .. "]: " .. Errors.format(err))
    return love.event.quit(1)
  end
  local s = result.summary
  print("app discovery complete: " .. result.outputPath)
  print(
    "  overlay "
      .. s.overlayId
      .. " ("
      .. s.versionId
      .. "): "
      .. s.entrypointCandidateCount
      .. " entrypoint candidate(s), "
      .. s.functionCount
      .. " function(s), "
      .. s.applicationGapCount
      .. " application gap(s)"
  )
  print(
    "  resources: "
      .. s.resourceFileCount
      .. " file(s), "
      .. s.narcCount
      .. " NARC(s), "
      .. s.narcMemberCount
      .. " member(s), "
      .. s.resourceGapCount
      .. " gap(s)"
  )
  love.event.quit(0)
end

-- Build the derived cache from every ready dump; with --forcedump (or an
-- explicit ROM path) the ROM is imported first and the build runs when the
-- import completes.
function Runner._runBuildCache()
  local opts = Runner.opts
  if opts.forceDump then
    assert(opts.romPath, "forcedump requires a ROM path")
    return Runner._startImport(opts.romPath)
  end
  local targets = readyVersions()
  if #targets > 0 then
    return Runner._runBuild({ allowCompileExclusions = opts.allowCompileExclusions, dev = opts.dev })
  end
  if opts.romPath then
    return Runner._startImport(opts.romPath)
  end
  print("build-cache: no ready dump; pass a ROM path")
  return love.event.quit(Cli.EXIT_USAGE)
end

-- Resolve the expected generation for a version through the same
-- development/release policy the prepare command uses: the validated ROM
-- hash from the published dump plus the working-tree digest in development
-- mode or the explicit per-game counter otherwise. Read-only apart from
-- closing the source handle it opens.
---@param version string
---@return table<string, unknown>|nil identity
---@return Errors.Error|string|nil err
local function selectionIdentity(version)
  local RomFs = require("romdump.src.source.RomFs")
  local opened, openErr = RomFs.open(version)
  if opened == nil then
    return nil, openErr --[[@as Errors.Error]]
  end
  local sha1 = opened:metadata().sha1
  opened:close()
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
  local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
  -- Development selection hashes the producer working tree resolved against
  -- the repository root this process runs from: none of the default source
  -- roots resolve under the packaged VFS root, so the VFS backend would hash
  -- the empty manifest. Release selection uses the explicit per-game counter
  -- and reads no producer sources.
  local dev = Runner.opts ~= nil and Runner.opts.dev == true
  local sourceBase = love.filesystem.getSourceBaseDirectory()
  local producerId
  if dev then
    producerId = ProducerFingerprint.compute(ProducerFingerprint.checkoutBackend(sourceBase))
  else
    producerId = "r" .. tostring(assert(DerivedCacheVersions[version], "release counter is required"))
  end
  return DerivedCacheState.currentForSelection({
    versionId = version,
    romSha1 = sha1,
    producerId = producerId,
    developmentRepositoryRoot = dev and sourceBase or nil,
  })
end

-- Check that the current published derived artifacts are usable without
-- recompiling: the expected generation must resolve and the exhaustive
-- generation audit over the published inventory must pass. A foreign or
-- absent generation, missing planning metadata, or any damaged payload
-- fails. Read-only: performs no repair and no writes.
function Runner._runCheckDerivedCache()
  local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local CacheFs = require("libs.storage.src.CacheFs")
  local targets = readyVersions()
  if #targets == 0 then
    print("check-derived-cache: no ready dump")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local cacheFs = CacheFs.forVersion(version)
    local identity, identityErr = selectionIdentity(version)
    local ok, reason
    if identity == nil then
      ok, reason = false, "no current generation identity: " .. Errors.format(identityErr)
    else
      local plans, plansReason = ArtifactJobs.publishedPlans(cacheFs, identity)
      if plans == nil then
        ok, reason = false, plansReason
      else
        ok, reason = DerivedCacheAudit.isAvailable(cacheFs, identity, plans)
      end
    end
    print("derived cache: " .. version .. " -> " .. (ok and "PASS" or "FAIL"))
    if not ok then
      allOk = false
      print("  " .. tostring(reason))
    end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Audit every ready version and exit 0 only if all pass. Runtime boot is
-- verified by the game/application tests, not by this ROM-source command.
function Runner._runCheckDump()
  local DumpAudit = require("romdump.src.source.DumpAudit")
  local targets = readyVersions()
  if #targets == 0 then
    print("check-dump: no ready version to audit")
    return love.event.quit(1)
  end
  local allOk = true
  for _, version in ipairs(targets) do
    local report = DumpAudit.run(version)
    for _, line in ipairs(DumpAudit.lines(report)) do
      print(line)
    end
    if not report.ok then
      allOk = false
    end
  end
  love.event.quit(allOk and 0 or 1)
end

-- Build the derived cache for every listed version (or every ready version)
-- and quit with the build status. The pipeline itself lives in CacheBuilder;
-- this wrapper owns only the process exit codes; the machine-readable report
-- is the builder's own, passed through unchanged. The development flag is
-- forwarded explicitly to the build owners: true selects the development
-- cache identity (producer working-tree bytes), false the release identity
-- (the explicit per-game counter). The mode is never inferred from the
-- working directory. A map whose cell could not
-- be selected is recorded as `excluded`; a resolved map
-- rejected with a structured compiler error is recorded as `compileExcluded`,
-- writes no partial artifacts, and makes the build exit nonzero unless the
-- allowCompileExclusions option accepts them. A map whose completion marker
-- already matches the current build is left in place, so an unchanged cache
-- rebuilds only what is stale. The option wins over any CLI state; callers
-- pass the parsed flag through explicitly.
---@param options { versionIds: string[]?, allowCompileExclusions: boolean?, dev: boolean?, developmentRepositoryRoot?: string, profile: string?, noQuit: boolean? }|nil
---@return table<string, unknown>|nil, string|nil
function Runner._runBuild(options)
  options = options or {}
  local dev = options.dev
  if dev == nil then
    dev = Runner.opts ~= nil and Runner.opts.dev == true
  end
  local profile = options.profile
  if profile == nil then
    profile = Runner.opts ~= nil and Runner.opts.profile or nil
  end
  -- The batch builder resolves development sources against this checkout
  -- root; default to the repository root this process runs from. All love
  -- coupling stays in this CLI owner; the builder receives an explicit root.
  local developmentRepositoryRoot = options.developmentRepositoryRoot
  if developmentRepositoryRoot == nil and dev == true then
    developmentRepositoryRoot = love.filesystem.getSourceBaseDirectory()
  end
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local report, err = CacheBuilder.buildVersions(options.versionIds or readyVersions(), {
    allowCompileExclusions = options.allowCompileExclusions,
    dev = dev,
    developmentRepositoryRoot = developmentRepositoryRoot,
    profile = profile,
  })
  if report then
    if not options.noQuit then
      love.event.quit(0)
    end
    return report
  end
  if not options.noQuit then
    love.event.quit(1)
  end
  return nil, err
end

-- Validate one ROM path through the canonical source owner and report its
-- version identity without importing, creating cache state, or starting
-- compiler workers. The hash covers the selected NDS bytes, never a ZIP
-- container or filename.
function Runner._runProbeRom()
  local path = assert(Runner.opts.romPath, "probe requires a ROM path")
  local RomSource = require("romdump.src.source.RomSource")
  local NdsRom = require("romdump.src.source.NdsRom")
  local source, sourceErr = RomSource.fromPath(path)
  if source == nil then
    print("probe failed: " .. Errors.format(sourceErr))
    return love.event.quit(1)
  end
  local rom, romErr = NdsRom.open(source)
  if rom == nil then
    source:release()
    print("probe failed: " .. Errors.format(romErr))
    return love.event.quit(1)
  end
  local versionId = rom:versionInfo().id
  local sha1 = source:sha1()
  rom:release()
  print("version=" .. versionId)
  print("rom_sha1=" .. sha1)
  return love.event.quit(0)
end

-- Prepare exactly the declared closure through the common session. A targeted
-- scope never starts an unrelated sweep and its success never attests a
-- complete cache; only an explicitly requested complete scope can publish
-- full attestation. Usage faults exit 2, genuine preparation failures exit 1.
function Runner._runPrepareCache()
  local opts = Runner.opts
  local version = assert(opts.version, "prepare requires a version")
  local requirements = assert(opts.requirements, "prepare requires at least one requirement")
  local rebuild = opts.rebuild or {}
  if #rebuild > 0 then
    if opts.dev ~= true then
      print("prepare-cache: --rebuild requires --dev")
      return love.event.quit(Cli.EXIT_USAGE)
    end
    local exhaustive = false
    for _, requirement in ipairs(requirements) do
      if requirement == "complete" then
        exhaustive = true
      end
    end
    for _, job in ipairs(rebuild) do
      local included = exhaustive
      if not included then
        for _, requirement in ipairs(requirements) do
          if requirement == job then
            included = true
            break
          end
        end
      end
      if not included then
        print("prepare-cache: --rebuild '" .. job .. "' is not in --require")
        return love.event.quit(Cli.EXIT_USAGE)
      end
    end
  end
  if not RomImporter.isReady(version) then
    print("prepare-cache: no ready dump for " .. version .. "; import a ROM first")
    return love.event.quit(Cli.EXIT_USAGE)
  end
  local identity, identityErr = selectionIdentity(version)
  if identity == nil then
    print("prepare-cache: " .. version .. " failed: " .. Errors.format(identityErr))
    return love.event.quit(1)
  end
  local CacheBuilder = require("romdump.src.CacheBuilder")
  local report, err = CacheBuilder.prepareVersion(version, {
    identity = identity,
    requirements = requirements,
    rebuild = rebuild,
    profile = opts.profile,
    allowCompileExclusions = opts.allowCompileExclusions,
    dev = opts.dev == true,
    preparationRecord = opts.preparationRecord,
    saveDirectory = love.filesystem.getSaveDirectory(),
  })
  if report == nil then
    print("prepare-cache: " .. version .. " failed: " .. Errors.format(err))
    return love.event.quit(1)
  end
  if report.requestedReady ~= true then
    print(
      string.format(
        "prepare-cache: %s not ready (requestedReady=%s complete=%s planned=%d successful=%d failed=%d cancelled=%d excluded=%d)",
        version,
        tostring(report.requestedReady),
        tostring(report.complete),
        report.counts.planned,
        report.counts.successful,
        report.counts.failed,
        report.counts.cancelled,
        report.counts.excluded
      )
    )
    return love.event.quit(1)
  end
  for _, requirement in ipairs(requirements) do
    if requirement == "complete" and report.complete ~= true then
      print(
        string.format(
          "prepare-cache: %s ready=%s complete=%s planned=%d successful=%d failed=%d cancelled=%d excluded=%d",
          version,
          tostring(report.requestedReady),
          tostring(report.complete),
          report.counts.planned,
          report.counts.successful,
          report.counts.failed,
          report.counts.cancelled,
          report.counts.excluded
        )
      )
      return love.event.quit(1)
    end
  end
  print(
    string.format(
      "prepare-cache: %s ready=%s complete=%s planned=%d successful=%d failed=%d cancelled=%d excluded=%d",
      version,
      tostring(report.requestedReady),
      tostring(report.complete),
      report.counts.planned,
      report.counts.successful,
      report.counts.failed,
      report.counts.cancelled,
      report.counts.excluded
    )
  )
  return love.event.quit(0)
end

function Runner._startImport(path)
  Runner.importer = RomImporter.new()
  Runner.importer:startPath(path)
end

-- Print a compact summary of a finished import for scripted consumers.
local function printImportResult(status)
  local r = status.report
  print("import complete: " .. status.versionId)
  print("  sha1:   " .. r.sha1)
  print("  files:  " .. r.fatEntryCount .. " FAT entries, " .. r.totalBytesWritten .. " bytes")
  if r.matrix then
    print(string.format("  matrix: %q %dx%d", r.matrix.name, r.matrix.width, r.matrix.height))
  end
end

function Runner._maybeExit()
  local imp = Runner.importer
  if not imp then
    return
  end
  local s = RomImporter.STATES
  if imp.state == s.COMPLETE then
    local status = imp:status()
    printImportResult(status)
    Runner.importer = nil
    if Runner.opts.command == "build-cache" then
      return Runner._finishImport(status)
    end
    love.event.quit(0)
  elseif imp.state == s.ERROR then
    local status = imp:status()
    print("import failed [" .. tostring(status.errorCode or "ERROR") .. "]: " .. Errors.format(status.error))
    love.event.quit(1)
  end
end

-- Complete a finished build-cache import: audit the imported dump, build the
-- derived cache, and use an already-loaded runtime verifier when the host
-- supplies one. The optional lookup keeps this source-only app independent of
-- the game runtime while preserving the completion seam used by integration
-- hosts.
---@param status table<string, unknown>
---@return nil
function Runner._finishImport(status)
  local DumpAudit = require("romdump.src.source.DumpAudit")
  local versionId = status.versionId
  assert(type(versionId) == "string", "import must report versionId")
  local audit = DumpAudit.run(versionId)
  if not audit.ok then
    for _, line in ipairs(DumpAudit.lines(audit)) do
      print(line)
    end
    return love.event.quit(1)
  end
  local report, err = Runner._runBuild({
    versionIds = { versionId },
    allowCompileExclusions = Runner.opts.allowCompileExclusions,
    dev = Runner.opts.dev,
    noQuit = true,
  })
  if not report then
    print("build-cache: " .. versionId .. " failed: " .. tostring(err))
    return love.event.quit(1)
  end
  local runtime = package.loaded["game.hgss.src.field.FieldRuntime"]
  if runtime then
    local game = {
      versionId = versionId,
      location = {
        mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
        fieldX = 6,
        fieldZ = 6,
      },
      playerData = {},
    }
    local ok, instance = pcall(runtime.new, game)
    if not ok then
      print("build-cache: runtime boot failed: " .. tostring(instance))
      return love.event.quit(1)
    end
    assert(instance):dispose()
  end
  return love.event.quit(0)
end

function Runner.update()
  local imp = Runner.importer
  if not imp then
    return
  end
  if imp:isBusy() then
    imp:update()
  end
  Runner._maybeExit()
end

return Runner
