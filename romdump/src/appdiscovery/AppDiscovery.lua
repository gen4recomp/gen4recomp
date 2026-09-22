-- Direct end-to-end discovery workflow: opens a supplied canonical ROM,
-- composes RomImage/ApplicationAnalyzer/ResourceCatalog into one transient
-- evidence aggregate, builds the deterministic evidence bundle/archive, and
-- owns the complete ROM source and output-file lifecycle for the headless
-- `--discover-app` command.

local Errors = require("libs.errors.src.Errors")
local RomSource = require("romdump.src.source.RomSource")
local NdsRom = require("romdump.src.source.NdsRom")
local RomImage = require("romdump.src.appdiscovery.RomImage")
local ApplicationAnalyzer = require("romdump.src.appdiscovery.ApplicationAnalyzer")
local ResourceCatalog = require("romdump.src.appdiscovery.ResourceCatalog")
local EvidenceBundle = require("romdump.src.appdiscovery.EvidenceBundle")
local EvidenceArchive = require("romdump.src.appdiscovery.EvidenceArchive")

---@alias AppDiscovery.RomSource table<string, unknown>

---@class AppDiscovery.Collected
---@field source table<string, unknown>
---@field targetImage RomImage.Record
---@field application ApplicationAnalyzer.Evidence
---@field applicationDisassembly ApplicationAnalyzer.Disassembly
---@field resources table<string, unknown>

---@class AppDiscovery.ManifestFile
---@field path string
---@field size integer
---@field sha1 string
---@field mediaType string

---@class AppDiscovery.Manifest
---@field schema string
---@field source table<string, unknown>
---@field target table<string, unknown>
---@field applicationSchema string
---@field disassemblySchema string
---@field resourceSchema string
---@field coverage { application: table<string, unknown>, resources: table<string, unknown> }
---@field files AppDiscovery.ManifestFile[]

---@class AppDiscovery.Summary
---@field versionId string
---@field overlayId integer
---@field entrypointCandidateCount integer
---@field functionCount integer
---@field resourceFileCount integer
---@field narcCount integer
---@field narcMemberCount integer
---@field applicationGapCount integer
---@field resourceGapCount integer

---@class AppDiscovery.BuildResult
---@field files table<string, string>
---@field manifest AppDiscovery.Manifest
---@field summary AppDiscovery.Summary

local AppDiscovery = {}

---@param rom AppDiscovery.RomSource
---@param overlayId integer
---@param resourceDetails { fileId: integer, memberId: integer }[]|nil
---@return AppDiscovery.Collected
function AppDiscovery.collect(rom, overlayId, resourceDetails)
  assert(rom, "AppDiscovery.collect requires an NdsRom")
  assert(type(overlayId) == "number", "AppDiscovery.collect requires a numeric overlayId")
  resourceDetails = resourceDetails or {}

  local romImage = RomImage.new(rom)
  local application, applicationDisassembly = ApplicationAnalyzer.analyze(romImage, overlayId)
  local resources = ResourceCatalog.scan(rom, romImage, resourceDetails)
  local targetImage = romImage:overlay("arm9", overlayId)

  local versionInfo = rom:versionInfo()
  return {
    source = {
      basis = "rom-only",
      versionId = versionInfo.id,
      displayName = versionInfo.displayName,
      sha1 = versionInfo.sha1,
      gameCode = versionInfo.gameCode,
      size = rom:size(),
    },
    targetImage = targetImage,
    application = application,
    applicationDisassembly = applicationDisassembly,
    resources = resources,
  }
end

---@param collected AppDiscovery.Collected
---@return AppDiscovery.BuildResult
function AppDiscovery.build(collected)
  return EvidenceBundle.build(collected)
end

local function defaultOutputPath(versionId, overlayId)
  return "app-evidence-" .. versionId .. "-arm9-overlay-" .. overlayId .. ".zip"
end

local function writeOutput(path, bytes)
  local file, openErr = io.open(path, "wb")
  if not file then
    Errors.raise(
      "APPDISCOVERY_OUTPUT_OPEN_FAILED",
      "cannot open output path " .. tostring(path) .. ": " .. tostring(openErr),
      { path = path }
    )
  end
  ---@cast file -nil
  local writeOk, writeErr = file:write(bytes)
  local closeOk, closeErr = file:close()
  if not writeOk or not closeOk then
    os.remove(path)
    Errors.raise(
      "APPDISCOVERY_OUTPUT_WRITE_FAILED",
      "failed to write output " .. tostring(path) .. ": " .. tostring(writeErr or closeErr),
      { path = path }
    )
  end
end

---@param request { romPath: string, overlayId: integer, outputPath: string|nil, resourceDetails: { fileId: integer, memberId: integer }[]|nil }
---@return { outputPath: string, summary: AppDiscovery.Summary }|nil, Errors.Error|nil
function AppDiscovery.runPath(request)
  assert(type(request) == "table", "AppDiscovery.runPath requires a request table")
  local romPath, overlayId, outputPath = request.romPath, request.overlayId, request.outputPath
  local resourceDetails = request.resourceDetails or {}

  local source, sourceErr = RomSource.fromPath(romPath)
  if not source then
    return nil, sourceErr
  end

  local rom
  local ok, result = xpcall(function()
    local opened, romErr = NdsRom.open(source)
    if not opened then
      error(romErr)
    end
    rom = opened

    local collected = AppDiscovery.collect(rom, overlayId, resourceDetails)
    local built = AppDiscovery.build(collected)
    local archiveBytes = EvidenceArchive.encode(built.files)

    local finalOutputPath = outputPath or defaultOutputPath(collected.source.versionId, overlayId)
    writeOutput(finalOutputPath, archiveBytes)

    return { outputPath = finalOutputPath, summary = built.summary }
  end, function(failure)
    return failure
  end)

  if rom then
    rom:release()
  else
    source:release()
  end

  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return AppDiscovery
