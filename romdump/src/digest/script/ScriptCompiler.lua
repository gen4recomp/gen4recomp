-- Script translation orchestrator : decodes every scr_seq
-- member of the ROM dump's script archive (the retail binary format, see
-- ScriptBinaryDecoder), lowers and structures each script, emits the DSL
-- resource, verifies the translation accounting, and aggregates one corpus
-- coverage record. The opcode names, operand widths, movement widths, std
-- catalog, and member message banks all come from pinned in-repo references,
-- so translation has no dependency on any decomp checkout. Output is
-- deterministic: identical dumps produce identical resources. Pure domain
-- module: no love dependency.

local S = require("gen4.script")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local LuaEmitter = require("romdump.src.digest.script.LuaEmitter")
local Verifier = require("romdump.src.digest.script.Verifier")
local Coverage = require("romdump.src.digest.script.Coverage")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local Hashing = require("romdump.src.digest.Hashing")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")
local ScriptMembers = require("romdump.src.reference.hgss.script_members")

local ScriptCompiler = {}

-- Strip translator diagnostic fields from lowered steps (they ride on the
-- steps but are not DSL fields); `if` bodies are walked recursively. Shared
-- by the cache compiler and the override generator.
---@param items table[]
function ScriptCompiler.scrub(items)
  for _, item in ipairs(items) do
    if item.op == "if" then
      ScriptCompiler.scrub(item.yes)
      ScriptCompiler.scrub(item.no)
    end
    item.movementComplete = nil
    item.movementUnsupported = nil
    item.yieldsNextTick = nil
    item.sourceNotes = nil
  end
end

-- Implementation freshness is owned by the producer fingerprint: any edit
-- under romdump/src forces a full derived rebuild, so generated script output
-- changes never need a manual version bump.

-- The public resource id for one script index: standard-script members
-- resolve through the std catalog to `common.<name>`; ordinary scripts use
-- the shared mechanical identity.

---@param member integer
---@param scriptIndex integer
---@param stdCatalog table<string, unknown>|nil
---@return string
function ScriptCompiler.publicId(member, scriptIndex, stdCatalog)
  if stdCatalog ~= nil then
    for _, group in ipairs(stdCatalog.groups) do
      if group.member == member then
        local name = stdCatalog.namesById[group.threshold + scriptIndex]
        if name ~= nil then
          return "common." .. name
        end
      end
    end
  end
  return ScriptIdentity.formatVanilla(member, scriptIndex)
end

-- Translate one script into a DSL resource.
---@param memberIr table<string, unknown>
---@param scriptIndex integer
---@param opts table<string, unknown> { stdCatalog, publicId, romSha1, repository, game, sourceHash }
---@return table<string, unknown> resource, table<string, unknown> report
local function translateScript(memberIr, scriptIndex, opts)
  local script = memberIr.scripts[scriptIndex]
  if opts.publicIdFor == nil then
    local function publicIdFor(member, index)
      return ScriptCompiler.publicId(member, index, opts.stdCatalog)
    end
    opts.publicIdFor = publicIdFor
  end
  local lowered = SemanticLowering.lowerScript(script, memberIr, opts)
  local steps = Structurer.structure(lowered, scriptIndex)
  -- The verifier runs on the final program (post-structuring and scrub):
  -- the transformations between lowering and emission are exactly the
  -- places semantic changes would hide, so they must be verified too.
  ScriptCompiler.scrub(steps)
  local report = Verifier.verifyScript(steps, script, memberIr, lowered.omissions)
  local ok, validateErr = S.validate({ api = 1, id = "check", steps = steps })
  if not ok then
    error("generated script for " .. tostring(scriptIndex) .. " fails validation: " .. tostring(validateErr))
  end

  local id = opts.publicId or ScriptCompiler.publicId(memberIr.member, scriptIndex, opts.stdCatalog)
  local resource = {
    api = 1,
    id = id,
    metadata = {
      generated = true,
      generator = { name = "hgss-script-translator", version = LuaEmitter.GENERATOR_VERSION },
      source = {
        repository = opts.repository,
        romSha1 = opts.romSha1,
        path = memberIr.sourcePath,
        game = opts.game,
        archive = "scr_seq",
        member = memberIr.member,
        scriptIndex = scriptIndex,
        sourceHash = opts.sourceHash or "",
      },
      coverage = {
        complete = report.complete,
        unsupportedCount = report.unsupportedCount,
      },
    },
    steps = steps,
  }
  return resource, report
end

-- Compile the complete script corpus for one version dump into a cache
-- bundle: every script member decoded, translated, and verified, plus the
-- aggregated coverage record and the dependency marker.
---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string
---@param hashLua? fun(value: unknown): string
---@return table<string, unknown> bundle
function ScriptCompiler.compile(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local version = romFs:version()
  local romSha1 = romFs:metadata().sha1
  local archiveInfo = assert(romFs:resolvedNarc("field_scripts"), "field_scripts NARC is unavailable")
  local archiveBytes = assert(romFs:read(archiveInfo.fileId))
  local source = {
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
  }
  local archive = assert(romFs:openNarc("field_scripts"))
  local stdCatalog = SourceCatalog.catalog()
  local sourcePath = "romfs/" .. source.archiveInfo.path
  local catalog = {
    sounds = require("romdump.src.reference.hgss.sndseq").byId,
    flags = require("romdump.src.reference.hgss.flags").byId,
    vars = require("romdump.src.reference.hgss.vars").byId,
    maps = require("romdump.src.reference.hgss.maps").byId,
    spawns = require("romdump.src.reference.hgss.spawns").byId,
  }
  local memberIrs = ScriptBinaryDecoder.decodeArchive(archive, ScriptMembers.banks, sourcePath, catalog)

  local records = {}
  local resources = {}
  local skippedMembers = {}
  local scriptCount = 0
  local decodeNotes = 0
  local scriptMemberCount = 0
  for member = 0, archive:memberCount() - 1 do
    local memberIr = memberIrs[member]
    if memberIr == nil then
      skippedMembers[#skippedMembers + 1] = member
    else
      scriptMemberCount = scriptMemberCount + 1
      local memberBytes = assert(archive:readMember(member))
      local memberSha1 = sha1hex(memberBytes)
      local results = {}
      -- Deterministic iteration: the script map is keyed by zero-based
      -- script index; the sorted index list fixes the translation order.
      local scriptIndices = {}
      for index in pairs(memberIr.scripts) do
        scriptIndices[#scriptIndices + 1] = index
      end
      table.sort(scriptIndices)
      for _, index in ipairs(scriptIndices) do
        local script = memberIr.scripts[index]
        local resource, report = translateScript(memberIr, index, {
          stdCatalog = stdCatalog,
          romSha1 = romSha1,
          repository = "g4recomp",
          game = version,
          sourceHash = memberSha1,
        })
        results[index] = { script = script, resource = resource, report = report }
        resources[#resources + 1] = {
          id = resource.id,
          member = member,
          scriptIndex = index,
          resource = resource,
          report = report,
          sourceHash = memberSha1,
        }
        scriptCount = scriptCount + 1
        if script.decodeNote ~= nil then
          decodeNotes = decodeNotes + 1
        end
      end
      local record = Coverage.record(memberIr, results, {
        repository = "g4recomp",
        romSha1 = romSha1,
      })
      records[#records + 1] = record
    end
  end
  local coverageRecord = Coverage.aggregate(records)
  coverageRecord.decodeNotes = decodeNotes
  coverageRecord.skippedMembers = skippedMembers
  coverageRecord.source = { repository = "g4recomp", romSha1 = romSha1 }

  local index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = version,
    memberCount = archive:memberCount(),
    scriptMemberCount = scriptMemberCount,
    skippedMemberCount = #skippedMembers,
    scriptCount = scriptCount,
    resourceCount = #resources,
  }
  local dependencies = {
    cacheFormat = ScriptCache.FORMAT,
    commandCatalog = ScriptCompiler.commandCatalogVersion(),
    movementCatalog = ScriptCompiler.movementCatalogVersion(),
    stdCatalog = ScriptCompiler.stdCatalogVersion(),
    memberBanks = ScriptCompiler.memberBanksVersion(),
    versionRomSha1 = romSha1,
    scrSeqNarc = {
      symbol = source.archiveInfo.symbol,
      alias = source.archiveInfo.alias,
      narcId = source.archiveInfo.narcId,
      fileId = source.archiveInfo.fileId,
      path = source.archiveInfo.path,
      sha1 = source.archiveSha1,
    },
  }
  local marker = ScriptCache.marker(romSha1, hashLua(dependencies))
  -- The index mirrors the sorted resources so discovery order never leaks
  -- into the emitted output.
  table.sort(resources, function(a, b)
    return a.id < b.id
  end)
  index.resources = {}
  for _, entry in ipairs(resources) do
    index.resources[#index.resources + 1] = {
      id = entry.id,
      member = entry.member,
      scriptIndex = entry.scriptIndex,
    }
  end
  return {
    marker = marker,
    index = index,
    resources = resources,
    coverageRecord = coverageRecord,
    dependencies = dependencies,
  }
end

local function sourceOf(module)
  return module.source and module.source.commit .. ":" .. (module.source.inputs and #module.source.inputs or 0)
end

function ScriptCompiler.commandCatalogVersion()
  return sourceOf(require("romdump.src.reference.hgss.script_commands"))
end

function ScriptCompiler.movementCatalogVersion()
  return sourceOf(require("romdump.src.reference.hgss.movement_commands"))
end

function ScriptCompiler.stdCatalogVersion()
  return sourceOf(require("romdump.src.reference.hgss.std_script_catalog"))
end

function ScriptCompiler.memberBanksVersion()
  return sourceOf(require("romdump.src.reference.hgss.script_members"))
end

-- Emit the Lua text for one resource (the cache writer persists it).
---@param entry table<string, unknown> { id, member, scriptIndex, resource, report }
---@param opts table<string, unknown> { sourcePath, romSha1, game, sourceHash }
---@return string
function ScriptCompiler.emit(entry, opts)
  return LuaEmitter.emit(entry.resource, {
    member = entry.member,
    scriptIndex = entry.scriptIndex,
    sourcePath = opts.sourcePath,
    romSha1 = opts.romSha1,
    repository = "g4recomp",
    game = opts.game,
    sourceHash = entry.sourceHash or opts.sourceHash,
    coverage = entry.resource.metadata.coverage,
  })
end

return ScriptCompiler
